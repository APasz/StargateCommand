# Deployment

Suggested deployments are intentionally modular.

## SGC / Command Site

- `site_controller` with wired site modem and optional wireless / Ender modem
- `gate_controller` adjacent to the Stargate Interface
- one or more `dial_console` computers
- optional `veto_console`
- optional `display` computers on monitors
- optional dedicated `address_book_server`

## Small Outpost

- one combined `site_controller` + `gate_controller` machine is acceptable
- a separate `display` is optional
- avoid wireless unless the machine is also acting as the site controller

## Practical Rule

Keep hardware ownership narrow:

- gate hardware belongs to the gate controller
- policy decisions belong to the site controller
- user interaction belongs to console and display roles

