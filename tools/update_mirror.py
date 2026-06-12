from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import enum
import hashlib
import http
import http.server
import io
import json
import os
import pathlib
import re
import shutil
import socketserver
import subprocess
import tarfile
import tempfile
import urllib.parse
from typing import Final


MANIFEST_SCHEMA_VERSION: Final[int] = 1
CONFIG_SCHEMA_VERSION: Final[int] = 1
CHANNEL_NAME_PATTERN: Final[re.Pattern[str]] = re.compile(r"^[a-z][a-z0-9_-]*$")


class MirrorError(RuntimeError):
    """Raised when the mirror configuration or refresh process is invalid."""


class SourceKind(str, enum.Enum):
    WORKSPACE = "workspace"
    GIT_REMOTE = "git_remote"


class WorkspaceRevisionMode(str, enum.Enum):
    NONE = "none"
    GIT_HEAD = "git_head"


@dataclasses.dataclass(frozen=True)
class DeployEntry:
    path: str
    is_directory: bool

    @property
    def pathspec(self) -> str:
        if self.is_directory:
            return self.path[:-1]
        return self.path


@dataclasses.dataclass(frozen=True)
class WorkspaceSourceConfig:
    root: pathlib.Path
    revision_mode: WorkspaceRevisionMode

    @property
    def kind(self) -> SourceKind:
        return SourceKind.WORKSPACE


@dataclasses.dataclass(frozen=True)
class GitRemoteSourceConfig:
    remote: str
    ref: str

    @property
    def kind(self) -> SourceKind:
        return SourceKind.GIT_REMOTE


SourceConfig = WorkspaceSourceConfig | GitRemoteSourceConfig


@dataclasses.dataclass(frozen=True)
class ChannelConfig:
    name: str
    source: SourceConfig


@dataclasses.dataclass(frozen=True)
class MirrorConfig:
    bind: str
    port: int
    deploy_manifest: pathlib.Path
    snapshot_root: pathlib.Path
    channels: tuple[ChannelConfig, ...]


@dataclasses.dataclass(frozen=True)
class FileRecord:
    path: str
    size: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class ChannelManifest:
    schema: int
    channel: str
    source_kind: SourceKind
    revision: str
    generated_at: str
    managed_paths: tuple[str, ...]
    files: tuple[FileRecord, ...]
    source_ref: str | None = None

    def to_json(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "schema": self.schema,
            "channel": self.channel,
            "source_kind": self.source_kind.value,
            "revision": self.revision,
            "generated_at": self.generated_at,
            "managed_paths": list(self.managed_paths),
            "files": [dataclasses.asdict(record) for record in self.files],
        }
        if self.source_ref is not None:
            payload["source_ref"] = self.source_ref
        return payload


def _load_json(path: pathlib.Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise MirrorError(f"Config file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MirrorError(f"Invalid JSON in {path}: {exc}") from exc


def _expect_dict(value: object, path: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise MirrorError(f"{path} must be an object")
    return value


def _expect_list(value: object, path: str) -> list[object]:
    if not isinstance(value, list):
        raise MirrorError(f"{path} must be an array")
    return value


def _expect_string(value: object, path: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MirrorError(f"{path} must be a non-empty string")
    return value


def _expect_int(value: object, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise MirrorError(f"{path} must be an integer")
    return value


def _resolve_relative_path(config_path: pathlib.Path, raw_path: str) -> pathlib.Path:
    path = pathlib.Path(raw_path)
    if path.is_absolute():
        return path
    return (config_path.parent / path).resolve()


def _normalize_deploy_path(raw_path: str) -> DeployEntry:
    is_directory = raw_path.endswith("/")
    stripped = raw_path[:-1] if is_directory else raw_path
    pure_path = pathlib.PurePosixPath(stripped)
    if pure_path.is_absolute():
        raise MirrorError(f"Deploy manifest entry must be relative: {raw_path}")
    if any(part in {"", ".", ".."} for part in pure_path.parts):
        raise MirrorError(f"Deploy manifest entry contains invalid path segments: {raw_path}")
    normalized = pure_path.as_posix()
    if is_directory:
        normalized = normalized + "/"
    return DeployEntry(path=normalized, is_directory=is_directory)


def read_deploy_manifest(path: pathlib.Path) -> tuple[DeployEntry, ...]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as exc:
        raise MirrorError(f"Deploy manifest not found: {path}") from exc

    entries: list[DeployEntry] = []
    seen_paths: set[str] = set()

    for line_number, line in enumerate(lines, start=1):
        trimmed = line.strip()
        if trimmed == "" or trimmed.startswith("#"):
            continue
        entry = _normalize_deploy_path(trimmed)
        if entry.path in seen_paths:
            raise MirrorError(f"Duplicate deploy manifest entry at {path}:{line_number}: {entry.path}")
        seen_paths.add(entry.path)
        entries.append(entry)

    if not entries:
        raise MirrorError(f"Deploy manifest is empty: {path}")

    return tuple(entries)


def _parse_workspace_source(config_path: pathlib.Path, value: dict[str, object]) -> WorkspaceSourceConfig:
    root = _resolve_relative_path(config_path, _expect_string(value.get("root"), "source.root"))
    raw_mode = value.get("revision_mode", WorkspaceRevisionMode.GIT_HEAD.value)
    revision_mode_text = _expect_string(raw_mode, "source.revision_mode")
    try:
        revision_mode = WorkspaceRevisionMode(revision_mode_text)
    except ValueError as exc:
        raise MirrorError(f"source.revision_mode has unsupported value: {revision_mode_text}") from exc
    return WorkspaceSourceConfig(root=root, revision_mode=revision_mode)


def _is_probably_local_git_remote(remote: str) -> bool:
    return "://" not in remote and not remote.startswith("git@")


def _parse_git_remote_source(config_path: pathlib.Path, value: dict[str, object]) -> GitRemoteSourceConfig:
    remote = _expect_string(value.get("remote"), "source.remote")
    if _is_probably_local_git_remote(remote):
        remote = str(_resolve_relative_path(config_path, remote))
    return GitRemoteSourceConfig(
        remote=remote,
        ref=_expect_string(value.get("ref"), "source.ref"),
    )


def load_config(path: pathlib.Path) -> MirrorConfig:
    payload = _expect_dict(_load_json(path), "config")
    schema_version = _expect_int(payload.get("schema"), "config.schema")
    if schema_version != CONFIG_SCHEMA_VERSION:
        raise MirrorError(
            f"Unsupported config schema version: {schema_version}; expected {CONFIG_SCHEMA_VERSION}"
        )

    bind = _expect_string(payload.get("bind", "127.0.0.1"), "config.bind")
    port = _expect_int(payload.get("port", 8080), "config.port")
    if port < 1 or port > 65535:
        raise MirrorError(f"config.port must be between 1 and 65535: {port}")
    snapshot_root = _resolve_relative_path(
        path,
        _expect_string(payload.get("snapshot_root", "dist/update_mirror"), "config.snapshot_root"),
    )
    deploy_manifest = _resolve_relative_path(
        path,
        _expect_string(payload.get("deploy_manifest", "tools/deploy_manifest.txt"), "config.deploy_manifest"),
    )
    channel_payloads = _expect_list(payload.get("channels"), "config.channels")

    channels: list[ChannelConfig] = []
    seen_names: set[str] = set()

    for index, channel_value in enumerate(channel_payloads):
        channel_data = _expect_dict(channel_value, f"config.channels[{index}]")
        name = _expect_string(channel_data.get("name"), f"config.channels[{index}].name")
        if CHANNEL_NAME_PATTERN.match(name) is None:
            raise MirrorError(f"config.channels[{index}].name is invalid: {name}")
        if name in seen_names:
            raise MirrorError(f"config.channels[{index}].name is duplicated: {name}")
        seen_names.add(name)

        source_data = _expect_dict(channel_data.get("source"), f"config.channels[{index}].source")
        source_kind_text = _expect_string(source_data.get("kind"), f"config.channels[{index}].source.kind")

        try:
            source_kind = SourceKind(source_kind_text)
        except ValueError as exc:
            raise MirrorError(
                f"config.channels[{index}].source.kind has unsupported value: {source_kind_text}"
            ) from exc

        if source_kind is SourceKind.WORKSPACE:
            source = _parse_workspace_source(path, source_data)
        else:
            source = _parse_git_remote_source(path, source_data)

        channels.append(ChannelConfig(name=name, source=source))

    if not channels:
        raise MirrorError("config.channels must contain at least one channel")

    return MirrorConfig(
        bind=bind,
        port=port,
        deploy_manifest=deploy_manifest,
        snapshot_root=snapshot_root,
        channels=tuple(channels),
    )


def _run_git(args: list[str], cwd: pathlib.Path | None = None) -> str:
    process = subprocess.run(
        ["git", *args],
        cwd=None if cwd is None else str(cwd),
        check=False,
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        message = process.stderr.strip() or process.stdout.strip() or "git command failed"
        raise MirrorError(message)
    return process.stdout.strip()


def _run_git_archive(git_dir: pathlib.Path, revision: str, entries: tuple[DeployEntry, ...]) -> bytes:
    process = subprocess.run(
        ["git", f"--git-dir={git_dir}", "archive", "--format=tar", revision, *[entry.pathspec for entry in entries]],
        check=False,
        capture_output=True,
    )
    if process.returncode != 0:
        message = process.stderr.decode("utf-8", errors="replace").strip()
        raise MirrorError(message or "git archive failed")
    return process.stdout


def _resolve_git_revision(git_dir: pathlib.Path, ref: str) -> str:
    candidates = (
        ref,
        f"{ref}^{{commit}}",
        f"refs/heads/{ref}^{{commit}}",
        f"refs/tags/{ref}^{{commit}}",
        f"refs/remotes/origin/{ref}^{{commit}}",
    )
    for candidate in candidates:
        try:
            return _run_git([f"--git-dir={git_dir}", "rev-parse", candidate])
        except MirrorError:
            continue
    raise MirrorError(f"Unable to resolve git ref: {ref}")


def _ensure_directory(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def _copy_file(source: pathlib.Path, target: pathlib.Path) -> None:
    _ensure_directory(target.parent)
    shutil.copy2(source, target)


def _file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _scan_exported_files(root: pathlib.Path) -> tuple[FileRecord, ...]:
    files: list[FileRecord] = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            relative_path = path.relative_to(root).as_posix()
            files.append(
                FileRecord(
                    path=relative_path,
                    size=path.stat().st_size,
                    sha256=_file_sha256(path),
                )
            )
    return tuple(files)


def _copy_deploy_entries(entries: tuple[DeployEntry, ...], source_root: pathlib.Path, output_root: pathlib.Path) -> None:
    copied_paths: set[str] = set()

    for entry in entries:
        source_path = source_root / entry.pathspec
        if not source_path.exists():
            raise MirrorError(f"Deploy entry not found in source tree: {entry.pathspec}")

        if entry.is_directory:
            if not source_path.is_dir():
                raise MirrorError(f"Deploy entry is not a directory: {entry.pathspec}")
            for file_path in sorted(source_path.rglob("*")):
                if not file_path.is_file():
                    continue
                relative_path = file_path.relative_to(source_root).as_posix()
                if relative_path in copied_paths:
                    raise MirrorError(f"Deploy manifest would export the same file twice: {relative_path}")
                copied_paths.add(relative_path)
                _copy_file(file_path, output_root / relative_path)
        else:
            if not source_path.is_file():
                raise MirrorError(f"Deploy entry is not a file: {entry.pathspec}")
            if entry.pathspec in copied_paths:
                raise MirrorError(f"Deploy manifest would export the same file twice: {entry.pathspec}")
            copied_paths.add(entry.pathspec)
            _copy_file(source_path, output_root / entry.pathspec)


def _extract_tar_bytes(archive_bytes: bytes, output_root: pathlib.Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive:
        for member in archive.getmembers():
            member_path = pathlib.PurePosixPath(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise MirrorError(f"Refusing to extract unsafe archive member: {member.name}")
            if member.isdir():
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                raise MirrorError(f"Unable to extract archive member: {member.name}")
            target_path = output_root / member_path.as_posix()
            _ensure_directory(target_path.parent)
            with target_path.open("wb") as handle:
                shutil.copyfileobj(extracted, handle)


def _write_json(path: pathlib.Path, payload: dict[str, object]) -> None:
    _ensure_directory(path.parent)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _build_manifest(
    *,
    channel_name: str,
    source_kind: SourceKind,
    revision: str,
    source_ref: str | None,
    deploy_entries: tuple[DeployEntry, ...],
    files_root: pathlib.Path,
) -> ChannelManifest:
    files = _scan_exported_files(files_root)
    if not files:
        raise MirrorError(f"Channel {channel_name} did not export any files")
    return ChannelManifest(
        schema=MANIFEST_SCHEMA_VERSION,
        channel=channel_name,
        source_kind=source_kind,
        revision=revision,
        generated_at=dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        managed_paths=tuple(entry.path for entry in deploy_entries),
        files=files,
        source_ref=source_ref,
    )


def _refresh_workspace_channel(
    *,
    channel: ChannelConfig,
    source: WorkspaceSourceConfig,
    deploy_entries: tuple[DeployEntry, ...],
    files_root: pathlib.Path,
) -> ChannelManifest:
    if not source.root.exists():
        raise MirrorError(f"Workspace source root does not exist: {source.root}")

    _copy_deploy_entries(deploy_entries, source.root, files_root)

    if source.revision_mode is WorkspaceRevisionMode.GIT_HEAD:
        revision = _run_git(["-C", str(source.root), "rev-parse", "HEAD"])
    else:
        revision = "workspace"

    return _build_manifest(
        channel_name=channel.name,
        source_kind=SourceKind.WORKSPACE,
        revision=revision,
        source_ref=None,
        deploy_entries=deploy_entries,
        files_root=files_root,
    )


def _refresh_git_remote_channel(
    *,
    channel: ChannelConfig,
    source: GitRemoteSourceConfig,
    deploy_entries: tuple[DeployEntry, ...],
    cache_root: pathlib.Path,
    files_root: pathlib.Path,
) -> ChannelManifest:
    channel_cache = cache_root / f"{channel.name}.git"
    if not channel_cache.exists():
        _ensure_directory(cache_root)
        _run_git(["clone", "--mirror", source.remote, str(channel_cache)])
    else:
        _run_git([f"--git-dir={channel_cache}", "remote", "set-url", "origin", source.remote])
        _run_git([f"--git-dir={channel_cache}", "fetch", "--prune", "origin"])

    revision = _resolve_git_revision(channel_cache, source.ref)
    archive_bytes = _run_git_archive(channel_cache, revision, deploy_entries)
    _extract_tar_bytes(archive_bytes, files_root)

    return _build_manifest(
        channel_name=channel.name,
        source_kind=SourceKind.GIT_REMOTE,
        revision=revision,
        source_ref=source.ref,
        deploy_entries=deploy_entries,
        files_root=files_root,
    )


def _refresh_channel(
    channel: ChannelConfig,
    config: MirrorConfig,
    deploy_entries: tuple[DeployEntry, ...],
) -> ChannelManifest:
    channels_root = config.snapshot_root / "channels"
    cache_root = config.snapshot_root / ".cache"
    channel_root = channels_root / channel.name
    _ensure_directory(channels_root)

    with tempfile.TemporaryDirectory(prefix=f"{channel.name}_", dir=str(config.snapshot_root)) as temp_dir_name:
        temp_root = pathlib.Path(temp_dir_name)
        files_root = temp_root / "files"
        _ensure_directory(files_root)

        if isinstance(channel.source, WorkspaceSourceConfig):
            manifest = _refresh_workspace_channel(
                channel=channel,
                source=channel.source,
                deploy_entries=deploy_entries,
                files_root=files_root,
            )
        else:
            manifest = _refresh_git_remote_channel(
                channel=channel,
                source=channel.source,
                deploy_entries=deploy_entries,
                cache_root=cache_root,
                files_root=files_root,
            )

        _write_json(temp_root / "manifest.json", manifest.to_json())

        if channel_root.exists():
            shutil.rmtree(channel_root)
        shutil.move(str(temp_root), str(channel_root))

    return manifest


def refresh_mirror(config: MirrorConfig, only_channels: set[str] | None = None) -> list[ChannelManifest]:
    _ensure_directory(config.snapshot_root)
    deploy_entries = read_deploy_manifest(config.deploy_manifest)
    manifests: list[ChannelManifest] = []

    if only_channels is not None:
        known_channels = {channel.name for channel in config.channels}
        unknown_channels = sorted(channel_name for channel_name in only_channels if channel_name not in known_channels)
        if unknown_channels:
            raise MirrorError(f"Unknown channel selection: {', '.join(unknown_channels)}")

    selected_channels = [
        channel for channel in config.channels if only_channels is None or channel.name in only_channels
    ]
    if not selected_channels:
        raise MirrorError("No channels matched the requested refresh selection")

    for channel in selected_channels:
        manifests.append(_refresh_channel(channel, config, deploy_entries))

    return manifests


def _json_response(handler: http.server.BaseHTTPRequestHandler, status: http.HTTPStatus, payload: object) -> None:
    encoded = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.end_headers()
    handler.wfile.write(encoded)


def _send_file(handler: http.server.BaseHTTPRequestHandler, path: pathlib.Path) -> None:
    handler.send_response(http.HTTPStatus.OK)
    handler.send_header("Content-Type", "application/octet-stream")
    handler.send_header("Content-Length", str(path.stat().st_size))
    handler.end_headers()
    with path.open("rb") as handle:
        shutil.copyfileobj(handle, handler.wfile)


def list_snapshot_channels(snapshot_root: pathlib.Path) -> tuple[str, ...]:
    channels_root = snapshot_root / "channels"
    if not channels_root.exists():
        return ()
    return tuple(
        path.name
        for path in sorted(channels_root.iterdir())
        if path.is_dir() and (path / "manifest.json").is_file()
    )


def load_snapshot_manifest(snapshot_root: pathlib.Path, channel_name: str) -> dict[str, object] | None:
    manifest_path = snapshot_root / "channels" / channel_name / "manifest.json"
    if not manifest_path.is_file():
        return None
    return _expect_dict(json.loads(manifest_path.read_text(encoding="utf-8")), "manifest")


def resolve_snapshot_file(
    snapshot_root: pathlib.Path,
    channel_name: str,
    raw_relative_path: str,
) -> pathlib.Path | None:
    relative_path = pathlib.PurePosixPath(urllib.parse.unquote(raw_relative_path))
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise MirrorError(f"Invalid channel file path: {raw_relative_path}")
    file_path = snapshot_root / "channels" / channel_name / "files" / relative_path.as_posix()
    if not file_path.is_file():
        return None
    return file_path


class MirrorRequestHandler(http.server.BaseHTTPRequestHandler):
    server: "MirrorHttpServer"

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/healthz":
            _json_response(self, http.HTTPStatus.OK, {"status": "ok"})
            return

        if path == "/v1/channels":
            _json_response(
                self,
                http.HTTPStatus.OK,
                {
                    "channels": sorted(list_snapshot_channels(self.server.snapshot_root)),
                },
            )
            return

        manifest_match = re.fullmatch(r"/v1/channels/([a-z][a-z0-9_-]*)/manifest\.json", path)
        if manifest_match is not None:
            channel_name = manifest_match.group(1)
            payload = load_snapshot_manifest(self.server.snapshot_root, channel_name)
            if payload is None:
                _json_response(self, http.HTTPStatus.NOT_FOUND, {"error": "channel_not_found"})
                return
            _json_response(self, http.HTTPStatus.OK, payload)
            return

        file_match = re.fullmatch(r"/v1/channels/([a-z][a-z0-9_-]*)/files/(.+)", path)
        if file_match is not None:
            channel_name = file_match.group(1)
            try:
                file_path = resolve_snapshot_file(self.server.snapshot_root, channel_name, file_match.group(2))
            except MirrorError:
                _json_response(self, http.HTTPStatus.BAD_REQUEST, {"error": "invalid_path"})
                return
            if file_path is None:
                _json_response(self, http.HTTPStatus.NOT_FOUND, {"error": "file_not_found"})
                return
            _send_file(self, file_path)
            return

        _json_response(self, http.HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def log_message(self, format: str, *args: object) -> None:
        return


class MirrorHttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int], snapshot_root: pathlib.Path) -> None:
        super().__init__(server_address, MirrorRequestHandler)
        self.snapshot_root = snapshot_root


def serve_mirror(config: MirrorConfig) -> None:
    _ensure_directory(config.snapshot_root)
    with MirrorHttpServer((config.bind, config.port), config.snapshot_root) as server:
        print(f"Serving update mirror on http://{config.bind}:{config.port}")
        server.serve_forever()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build and serve StargateCommand update snapshots.")
    parser.add_argument(
        "--config",
        default="examples/update_mirror.example.json",
        help="Path to the mirror JSON config file.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    refresh_parser = subparsers.add_parser("refresh", help="Refresh one or more channels into the snapshot directory.")
    refresh_parser.add_argument(
        "--channel",
        action="append",
        dest="channels",
        help="Refresh only the named channel. Repeat to select multiple channels.",
    )

    serve_parser = subparsers.add_parser("serve", help="Serve previously refreshed snapshots over HTTP.")
    serve_parser.add_argument(
        "--refresh",
        action="store_true",
        help="Refresh channels before starting the HTTP server.",
    )

    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    config = load_config(pathlib.Path(args.config).resolve())

    if args.command == "refresh":
        manifests = refresh_mirror(config, set(args.channels) if args.channels else None)
        for manifest in manifests:
            print(f"Refreshed {manifest.channel} at {manifest.revision}")
        return 0

    if args.command == "serve":
        if args.refresh:
            manifests = refresh_mirror(config)
            for manifest in manifests:
                print(f"Refreshed {manifest.channel} at {manifest.revision}")
        serve_mirror(config)
        return 0

    raise MirrorError(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MirrorError as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
