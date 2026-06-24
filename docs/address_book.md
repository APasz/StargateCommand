# Address Book

The address book is authoritative server state managed in-game.

## Authority Model

- one `address_book` service is the writer
- site controllers cache the latest revision locally
- no peer-to-peer merge logic
- remote proposals can exist later, but approval is central

## Persistence

- the authoritative source of truth defaults to `/sgc/data/address_book.json`
- cached books can still use the legacy serialized `.lua` path, and the server will migrate a legacy authoritative `.lua` file into the new `.json` path automatically
- the standard `address_book` config now seeds the authoritative file from the built-in sample on first startup
- the running address-book server also exposes a local terminal console for `list`, `add <site_id>`, `edit <site_id>`, `del <site_id>`, and `push`
- `push` broadcasts the latest authoritative book to `site_controller`s; dial consoles then refresh when the updated site-status revision appears on the local network

## Schema Rules

- site ids must be stable machine-readable identifiers
- address arrays are validated by expected length
- visibility references must be site ids or `*`, even if the referenced site does not exist yet
- `hidden_at = { "*" }` hides a destination everywhere
- `intergalactic = { "*" }` exposes a destination cross-galaxy everywhere

## Visibility

UI code should not replicate visibility checks.

Use:

- `address_book.can_see(book, origin, destination)`
- `address_book.list_visible_destinations(book, origin)`
- `address_book.get_best_address(book, origin, destination)`

`get_best_address` currently assumes:

- same dimension prefers `system`
- same galaxy prefers `stellar`
- cross-galaxy or cross-universe prefers `galactic`

When the preferred address is absent, it falls back to the next available address class.
