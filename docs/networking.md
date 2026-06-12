# Networking

StargateCommand uses wired rednet for the local site network and treats all network input as untrusted.

## Recommended Layout

- one wired modem side for the site network
- one separate modem side for monitors or other local peripherals
- optional wireless / Ender modem only on the `site_controller`

Keeping wireless limited to the site controller reduces the number of machines that can send or receive inter-site traffic.

## Protocols

Current protocol names:

- `sgc.hello`
- `sgc.command`
- `sgc.event`
- `sgc.state`
- `sgc.addressbook`
- `sgc.update`

Every envelope carries a schema version, message id, site id, sender role, timestamp, and payload.

## Trust Model

Rednet is not trusted by default.

- message protocol names are validated
- envelope schema and basic fields are validated
- sender allowlist hooks are available in config
- auth extension points exist for later signing or shared-secret work

Real cryptographic authentication is intentionally deferred.

