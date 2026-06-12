from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import update_mirror  # noqa: E402


class UpdateMirrorTest(unittest.TestCase):
    def test_workspace_refresh_exports_deploy_manifest_only(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir_name:
            temp_dir = pathlib.Path(temp_dir_name)
            workspace_root = temp_dir / "workspace"
            snapshot_root = temp_dir / "snapshot"
            manifest_path = temp_dir / "deploy_manifest.txt"
            config_path = temp_dir / "mirror.json"

            self._create_workspace_repo(workspace_root)
            manifest_path.write_text("startup.lua\nsrc/\n", encoding="utf-8")
            config_path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "snapshot_root": str(snapshot_root),
                        "deploy_manifest": str(manifest_path),
                        "channels": [
                            {
                                "name": "dev",
                                "source": {
                                    "kind": "workspace",
                                    "root": str(workspace_root),
                                    "revision_mode": "git_head",
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            config = update_mirror.load_config(config_path)
            manifests = update_mirror.refresh_mirror(config)

            self.assertEqual(len(manifests), 1)
            manifest = manifests[0]
            self.assertEqual(manifest.channel, "dev")
            self.assertEqual(manifest.source_kind, update_mirror.SourceKind.WORKSPACE)
            self.assertRegex(manifest.revision, r"^[0-9a-f]{40}$")
            self.assertEqual(manifest.managed_paths, ("startup.lua", "src/"))
            self.assertEqual([record.path for record in manifest.files], ["src/main.lua", "startup.lua"])
            self.assertFalse((snapshot_root / "channels" / "dev" / "files" / "config.lua").exists())

    def test_git_remote_refresh_uses_local_repo_as_remote(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir_name:
            temp_dir = pathlib.Path(temp_dir_name)
            workspace_root = temp_dir / "workspace"
            snapshot_root = temp_dir / "snapshot"
            manifest_path = temp_dir / "deploy_manifest.txt"
            config_path = temp_dir / "mirror.json"

            self._create_workspace_repo(workspace_root)
            manifest_path.write_text("startup.lua\nsrc/\n", encoding="utf-8")
            config_path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "snapshot_root": str(snapshot_root),
                        "deploy_manifest": str(manifest_path),
                        "channels": [
                            {
                                "name": "stable",
                                "source": {
                                    "kind": "git_remote",
                                    "remote": str(workspace_root),
                                    "ref": "HEAD",
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            config = update_mirror.load_config(config_path)
            manifests = update_mirror.refresh_mirror(config)

            self.assertEqual(len(manifests), 1)
            manifest = manifests[0]
            self.assertEqual(manifest.channel, "stable")
            self.assertEqual(manifest.source_kind, update_mirror.SourceKind.GIT_REMOTE)
            self.assertEqual(manifest.source_ref, "HEAD")
            self.assertEqual(manifest.managed_paths, ("startup.lua", "src/"))
            self.assertEqual([record.path for record in manifest.files], ["src/main.lua", "startup.lua"])

    def test_snapshot_helpers_expose_manifest_and_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir_name:
            temp_dir = pathlib.Path(temp_dir_name)
            workspace_root = temp_dir / "workspace"
            snapshot_root = temp_dir / "snapshot"
            manifest_path = temp_dir / "deploy_manifest.txt"
            config_path = temp_dir / "mirror.json"

            self._create_workspace_repo(workspace_root)
            manifest_path.write_text("startup.lua\nsrc/\n", encoding="utf-8")
            config_path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "snapshot_root": str(snapshot_root),
                        "deploy_manifest": str(manifest_path),
                        "channels": [
                            {
                                "name": "dev",
                                "source": {
                                    "kind": "workspace",
                                    "root": str(workspace_root),
                                    "revision_mode": "git_head",
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            config = update_mirror.load_config(config_path)
            update_mirror.refresh_mirror(config)

            self.assertEqual(update_mirror.list_snapshot_channels(snapshot_root), ("dev",))

            manifest_payload = update_mirror.load_snapshot_manifest(snapshot_root, "dev")
            self.assertIsNotNone(manifest_payload)
            self.assertEqual(manifest_payload["channel"], "dev")
            self.assertEqual(manifest_payload["source_kind"], "workspace")
            self.assertEqual(manifest_payload["managed_paths"], ["startup.lua", "src/"])

            startup_path = update_mirror.resolve_snapshot_file(snapshot_root, "dev", "startup.lua")
            self.assertIsNotNone(startup_path)
            self.assertIn('require("src.startup")', startup_path.read_text(encoding="utf-8"))

    def _create_workspace_repo(self, root: pathlib.Path) -> None:
        (root / "src").mkdir(parents=True)
        (root / "startup.lua").write_text('require("src.startup")\n', encoding="utf-8")
        (root / "src" / "main.lua").write_text("return {}\n", encoding="utf-8")
        (root / "config.lua").write_text("return { ignored = true }\n", encoding="utf-8")

        self._run_git(["init", "-b", "main"], cwd=root)
        self._run_git(["config", "user.name", "Test User"], cwd=root)
        self._run_git(["config", "user.email", "test@example.com"], cwd=root)
        self._run_git(["add", "."], cwd=root)
        self._run_git(["commit", "-m", "Initial commit"], cwd=root)

    def _run_git(self, args: list[str], cwd: pathlib.Path) -> None:
        subprocess.run(["git", *args], cwd=str(cwd), check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
