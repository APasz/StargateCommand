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

This section is the simplest end-to-end path for getting one machine running with the updater enabled.

You need two things:

1. A normal computer on your real host OS running this repository.
2. A ComputerCraft computer in Minecraft that will run StargateCommand.

### 1. Prepare the host mirror

From the repo root on the real host machine:

1. Make sure `update_mirror.json` exists at the repo root.
2. For a local development channel, it should look like this:

```json
{
  "schema": 1,
  "bind": "127.0.0.1",
  "port": 8090,
  "snapshot_root": "dist/update_mirror",
  "deploy_manifest": "tools/deploy_manifest.txt",
  "channels": [
    {
      "name": "dev",
      "source": {
        "kind": "workspace",
        "root": ".",
        "revision_mode": "git_head"
      }
    }
  ]
}
```

3. Build the current snapshot:

```bash
python3 tools/update_mirror.py --config update_mirror.json refresh
```

4. Start the mirror server:

```bash
python3 tools/update_mirror.py --config update_mirror.json serve
```

5. Leave that process running while you test updates.

Relative path rule:
`update_mirror.json` is at the repo root, so its paths use `dist/update_mirror`, `tools/deploy_manifest.txt`, and `.`.

### 2. Copy only `startup.lua` onto the ComputerCraft machine

For first install, you only need the root [startup.lua](/lamda/Lager/0/Codes/StargateCommand/startup.lua:1) on the ComputerCraft computer.

You do not need to copy `src/` or create `config.lua` manually first.

When `startup.lua` sees that `src/startup.lua` does not exist yet, it switches into bootstrap mode and asks a few setup questions.

### 3. Boot the ComputerCraft machine for the first time

1. Put `startup.lua` at the computer root.
2. Reboot the machine or run `startup`.
3. Answer the bootstrap questions:
   `Mirror host`
   Default if you press Enter: `127.0.0.1`
   `Mirror port`
   Default if you press Enter: `8090`
   `Update channel`
   Default if you press Enter: `stable`
   `Site id`
   Example: `command`
   `Role`
   Example: `site_controller`
   `Automatically reboot after future updates`
   Default if you press Enter: `yes`
4. Confirm the bootstrap summary when prompted.

If the mirror is running on the same machine as the Minecraft server, `127.0.0.1` is usually correct.
If the mirror is running on another machine, enter that machine's LAN IP address or hostname instead.

What bootstrap does:

1. Fetches `manifest.json` from the selected channel.
2. Downloads the managed runtime files.
3. Writes a complete local `config.lua`.
4. Writes update state to `/sgc/state/update_state.lua`.
5. Continues booting using the newly downloaded runtime.

The generated config is a valid full config, not just an `update` block. If you already had a partial `config.lua`, bootstrap reuses what it can and fills in the missing defaults.

If you are using an address book cache path like `/sgc/cache/address_book.lua`, create the parent directories before first save if your deployment process does not already do that.

### 4. Optional: edit the generated config later

After bootstrap finishes, you can still edit `config.lua` or `/sgc/config.lua` manually if you want to change modem sides, logging, address book behavior, or update settings.

The generated config uses safe defaults and sets:

- `update.mode = "apply"`
- `update.base_url` to `http://<mirror-host>:<mirror-port>`
- `update.channel` to the channel you entered
- `update.state_path = "/sgc/state/update_state.lua"`
- `update.temp_dir = "/sgc/tmp/update"`

### 5. Understand what the updater manages

The updater only manages the deploy payload from [tools/deploy_manifest.txt](/lamda/Lager/0/Codes/StargateCommand/tools/deploy_manifest.txt:1). Right now that means:

- `startup.lua`
- `src/`

It intentionally does not manage:

- `config.lua`
- `/sgc/config.lua`
- address book cache files
- other mutable world or machine-local data

That means you should treat config and saved data as local state, not something the updater will replace for you.

### 6. Apply later updates

When you change code in this repository:

1. Refresh the host snapshot:

```bash
python3 tools/update_mirror.py --config update_mirror.json refresh
```

2. Keep the mirror server running.
3. Reboot the ComputerCraft machine, or run a machine configured with the `update_client` role, to make it check for updates again.

### 7. Update mode behavior

- `disabled`: do not check for updates
- `notify`: check and report if an update exists, but do not apply it
- `apply`: download and apply managed file changes before the main app starts

If `auto_reboot = false`, a successful apply stops startup and requires one manual reboot.
If `auto_reboot = true`, the machine requests a reboot automatically after a successful apply.

### 8. Common mistakes

- Forgetting to enable the HTTP API in ComputerCraft.
- Pointing `base_url` at the wrong host or wrong port.
- Typing a channel name that does not exist on the mirror.
- Stopping the mirror server before the first bootstrap download finishes.
- Forgetting to run `refresh` after changing code on the host.
- Expecting the updater to manage `config.lua` or saved game data.

The automated update payload is intentionally narrower than a full repository copy. See [docs/update_mirror.md](/lamda/Lager/0/Codes/StargateCommand/docs/update_mirror.md) for the fuller mirror and client details.

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
