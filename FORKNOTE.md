# Fork Note

This repository was fork-scaffolded from the SQL bootstrap assets in `mqtt2postgres`.

## Source Provenance

- source repository: `mqtt2postgres`
- source baseline version: `0.9.2`
- source baseline date: `2026-04-27`
- fork scaffold date: `2026-04-28`

## Source Scope

The fork started from the SQL-facing portion of the parent repo, primarily:

- `examples/sql/mqtt-ingest/*.sql`
- SQL-focused helper scripts under `scripts/dev/`
- SQL/bootstrap documentation under `docs/`
- the TimescaleDB bootstrap path from `examples/local-stack/docker-compose.yml`

## Intent

The intent of this fork is to split the `mqtt_ingest` TimescaleDB bootstrap into a separate repository with its own:

- `README.md`
- `CHANGELOG.md`
- SQL-only validation and query helpers
- minimal TimescaleDB-only Compose runtime
- SQL-focused operational docs

## Non-Goals Of This Fork

This fork does not currently carry over:

- the MQTT subscriber runtime
- the MQTT publisher runtime
- Mosquitto broker assets
- parent-repo Python packaging and tests
- the full `mqtt2postgres` documentation set

## First Fork Version

The initial fork changelog entry is `0.9.2-fork2.0` to make the parent baseline explicit and distinguish this as a second standalone fork from the parent repo.
