# StargateCommand

StargateCommand is a ComputerCraft / CC:Tweaked project for coordinating modular Stargate Journey deployments in Minecraft.

The codebase treats physical computers as deployment details and logical services as the architecture. A site can split responsibilities across multiple machines, such as a `site_controller`, `gate_controller`, `dial_console`, `veto_console`, `display`, and optional support services like an `iris_controller` or `energy_controller`.

## Target Environment

- Minecraft with CC:Tweaked and Stargate Journey installed
- LuaLS annotations for editor support in VS Code

Stargate Journey Stargate interface docs:
https://lukaskabc.github.io/StargateJourney/computercraft/stargate-interface/

## Architecture

Core ownership rules:

- `site_controller`: site-local authority and policy coordinator
- `gate_controller`: owns Stargate Interface access
- `dial_console`: requests dials but does not touch hardware
- `veto_console`: can observe and veto pending actions
- `display`: informational rendering only
- `iris_controller`: logical iris control service
- `alarm_controller`: local alarm and redstone outputs
- `energy_controller`: optional readiness checks
- `address_book_server`: authoritative address book service
- `update_client`: reserved for future HTTP update pulls
- `bridge`: reserved protocol space for later integrations

The current repo implements the foundation only: typed config, protocol envelopes, rednet transport helpers, address-book validation and visibility logic, Stargate interface discovery, and app dispatch skeletons.

## Network Layout

Recommended modem layout:

- One wired modem side for the local site network
- One separate modem side for local monitors and peripherals
- Optional wireless / Ender modem only on the `site_controller`

Rednet is treated as untrusted. Every message uses:

- a protocol name
- a schema version
- a message id
- a logical role
- a site id
- a timestamp

The current scaffolding includes allowlist hooks and auth extension points, but does not implement real cryptographic signing yet.

## Address Book

The address book is treated as live in-game state, not GitHub-managed content.

- One `address_book_server` is authoritative
- Site controllers cache the latest revision locally
- Sites prefer the central service when reachable
- Sites fall back to local cache when central is unavailable
- Remote proposals are possible later, but central approval remains authoritative

Visibility logic is centralized in the `address_book` module so UI code does not need to duplicate rules.

## Config And Startup

The root [startup.lua](/lamda/Lager/0/Codes/StargateCommand/startup.lua) bootstraps `src/` module loading and hands off to [src/startup.lua](/lamda/Lager/0/Codes/StargateCommand/src/startup.lua). The bootloader looks for a local config in these paths:

- `/sgc/config.lua`
- `sgc/config.lua`
- `/config.lua`
- `config.lua`

Example configs live in [examples/configs](/lamda/Lager/0/Codes/StargateCommand/examples/configs).

## LuaLS Setup

The repo does not depend on a machine-specific CC:Tweaked library path.

- `.luarc.json` and `.vscode/settings.json` point at `${workspaceFolder}/.lua_ls/cc-tweaked-library`
- If you have the CC:Tweaked LuaLS library locally, place or symlink it there
- If you prefer a different location, update those files in your local workspace only

The repo also ships lightweight local type annotations in `src/types/`.

## Manual Installation

Early testing is expected to be manual:

1. Copy the repository files onto a ComputerCraft computer.
2. Copy one of the example configs to `config.lua` or `/sgc/config.lua`.
3. Ensure `startup.lua` is at the computer root.
4. Attach the required modem and Stargate Interface peripherals.
5. Reboot or run `startup`.

For an address book cache path like `/sgc/cache/address_book.lua`, create the parent directories before first save if your deployment process does not do that already.

For first install with the updater enabled:

1. Copy the initial runtime files manually.
   `startup.lua` must be at the computer root, and `src/` must be present.
2. Create the machine-local config at `config.lua` or `/sgc/config.lua`.
3. Add an `update` block to that config:

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

4. Start the host mirror on the machine that serves updates:

```bash
python3 tools/update_mirror.py --config examples/update_mirror.example.json refresh
python3 tools/update_mirror.py --config examples/update_mirror.example.json serve
```

5. Reboot the ComputerCraft machine or run `startup`.

On that first updater-enabled boot, the node will fetch `manifest.json` from the configured channel, download any managed files that differ, and save update state to `state_path`. The updater only manages the deploy payload from [tools/deploy_manifest.txt](/lamda/Lager/0/Codes/StargateCommand/tools/deploy_manifest.txt:1), which currently means:

- `startup.lua`
- `src/`

It intentionally does not manage:

- `config.lua`
- `/sgc/config.lua`
- address book cache or other mutable world data

For ongoing use:

1. Refresh the mirror whenever you publish a new version:

```bash
python3 tools/update_mirror.py --config examples/update_mirror.example.json refresh
```

2. Keep the mirror server running.
3. Reboot a node, or run the `update_client` role on a machine configured for updates, to make it check the channel again.

Update modes:

- `disabled`: skip update checks entirely
- `notify`: report that an update is available but do not apply it
- `apply`: stage and apply managed file changes before the main app starts

If `auto_reboot = false`, an applied update stops startup and requires a reboot before the new code runs. If `auto_reboot = true`, the updater requests a reboot automatically after a successful apply.

The automated update payload is narrower than a full repository copy. It intentionally excludes machine-local config and mutable world data. See [docs/update_mirror.md](/lamda/Lager/0/Codes/StargateCommand/docs/update_mirror.md) for the full host mirror and client details.

## Checks

Run the lightweight static check script from the repo root:

```bash
lua tools/check.lua
```

The script parses Lua files, validates the sample address book, and checks envelope creation. It does not execute ComputerCraft APIs or connect to Minecraft hardware.

## Future Update Design

Software updates are intentionally separate from the live address book.

- Runtime code should eventually be mirrored from GitHub to an HTTP-accessible endpoint
- In-game computers should later pull updates from that mirror
- The live address book should remain world/server state, not a GitHub-edited data file

The first host-side mirror implementation now lives in [tools/update_mirror.py](/lamda/Lager/0/Codes/StargateCommand/tools/update_mirror.py). See [docs/update_mirror.md](/lamda/Lager/0/Codes/StargateCommand/docs/update_mirror.md) for the channel model and example Debian/Arch setups.

The in-game updater now implements the first self-update pass: it can fetch a channel manifest, stage changed files, apply them to managed paths only, and persist update state for later boots.
