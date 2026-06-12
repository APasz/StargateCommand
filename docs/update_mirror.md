# Update Mirror

The update mirror is a host-side HTTP service that snapshots a deployable subset of this repository and exposes it to ComputerCraft clients.

It exists to keep three concerns separate:

- runtime code updates
- machine-local config
- world-local mutable data such as the address book cache

Only runtime code is mirrored. Config files and address book state are intentionally excluded from the deploy manifest.

## Deploy Payload

The deployable file set is defined once in [tools/deploy_manifest.txt](/lamda/Lager/0/Codes/StargateCommand/tools/deploy_manifest.txt).

At the moment it contains:

- `startup.lua`
- `src/`

This keeps the update payload safe to apply without overwriting machine-local configuration.

## Source Types

Each channel has exactly one source.

- `workspace`: exports files directly from a local checkout
- `git_remote`: exports files from a remote Git repository via a local mirror clone

This maps cleanly to the intended environments:

- Debian production:
  - `stable` channel from the public GitHub repository
  - `testing` channel from the private GitHub repository
- Arch or EndeavourOS development:
  - `dev` channel from the current workspace checkout
  - when `revision_mode` is `git_head`, the mirror reads the local `.git` metadata to stamp the exported revision

## HTTP Surface

After a refresh, the mirror serves:

- `GET /healthz`
- `GET /v1/channels`
- `GET /v1/channels/<channel>/manifest.json`
- `GET /v1/channels/<channel>/files/<path>`

The manifest includes:

- schema version
- channel name
- source kind
- source ref for git channels
- resolved revision
- generation timestamp
- file list with size and SHA-256

## Refresh Model

The mirror works in two steps:

1. `refresh` materializes a snapshot under `snapshot_root`
2. `serve` exposes the latest snapshot over HTTP

That separation keeps the HTTP process simple and makes failures explicit. If a git fetch fails, it fails during refresh instead of during a client request.

## Example Config

See [examples/update_mirror.example.json](/lamda/Lager/0/Codes/StargateCommand/examples/update_mirror.example.json).

The example uses:

- `stable` -> public GitHub over HTTPS
- `testing` -> private GitHub over SSH
- `dev` -> current workspace with git-head revision stamping

For private GitHub access, use the host's normal Git authentication path such as:

- SSH deploy keys
- a machine user
- an existing credential helper

The mirror does not talk to the GitHub API directly. It only shells out to `git`, which keeps public and private remotes on the same code path.

## Commands

Refresh all channels:

```bash
python3 tools/update_mirror.py --config examples/update_mirror.example.json refresh
```

Refresh one channel only:

```bash
python3 tools/update_mirror.py --config examples/update_mirror.example.json refresh --channel dev
```

Refresh first, then serve:

```bash
python3 tools/update_mirror.py --config examples/update_mirror.example.json serve --refresh
```

## In-Game Client

The in-game updater now supports a first self-update slice:

- fetch the channel manifest over HTTP
- compare it against the saved update state and local file sizes
- download changed files into a staging directory
- delete managed files that are no longer in the manifest
- preserve machine-local config and mutable world data

Current limitations:

- local file content is not hashed unless the runtime exposes a SHA-256 helper, so same-size manual edits can evade detection
- update application is a one-shot sync during boot or manual `update_client` execution, not a background daemon
- after applying files, the machine must reboot before running the updated code

## Client Config

Each machine can opt into self-update with a config block like:

```lua
update = {
    mode = "apply",
    base_url = "http://mirror-host:8080",
    channel = "stable",
    state_path = "/sgc/state/update_state.lua",
    temp_dir = "/sgc/tmp/update",
    auto_reboot = false,
}
```

Modes:

- `disabled`: do nothing
- `notify`: check and log whether an update is available
- `apply`: download and apply updates before the main app starts
