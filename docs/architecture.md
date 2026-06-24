# Architecture

StargateCommand is organized around logical services, not around individual computers.

## Service Ownership

- `site_controller` owns local policy, coordination, and inter-service decisions
- `gate_controller` owns direct Stargate Interface access
- `dial_console` requests dials through messages
- `veto_console` can observe and cancel actions but cannot initiate them
- `display` renders status only
- `iris_controller` owns iris actions when separated from gate control
- `alarm_controller` owns alarm outputs
- `energy_controller` owns readiness checks
- `address_book` owns the authoritative address book

## Deployment Rule

A physical computer may host one or more logical services, but the protocol and module boundaries are defined in logical terms. Moving a service to another machine should change deployment config, not the architecture.

## Current Scope

This foundation stage implements:

- typed config validation
- protocol envelopes
- rednet transport wrappers
- address-book validation and visibility logic
- Stargate Interface discovery and safe wrappers
- role-based app dispatch

It does not yet implement a full dialing workflow or production UI.
