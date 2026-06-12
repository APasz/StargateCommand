# Address Book

The address book is authoritative server state managed in-game.

## Authority Model

- one `address_book_server` is the writer
- site controllers cache the latest revision locally
- no peer-to-peer merge logic
- remote proposals can exist later, but approval is central

## Schema Rules

- site ids must be stable machine-readable identifiers
- address arrays are validated by expected length
- visibility references must point to known site ids or `*`
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
