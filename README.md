# mqtt-ingest-sql

Standalone TimescaleDB/PostgreSQL bootstrap SQL for the `mqtt_ingest` schema used by `mqtt2postgres`.

This fork starts from the parent repository baseline `0.9.2` and publishes its first standalone version as `0.9.2-fork2.0`.

## Included Surface

- ordered bootstrap SQL for `mqtt_ingest`
- aggregate and reconciliation helper functions
- TimescaleDB background job bootstrap
- SQL-focused query helpers
- a minimal TimescaleDB-only local compose stack
- SQL-focused documentation copied from the parent repo and reduced to the database surface

## Quick Start

Start a fresh local TimescaleDB instance and apply the SQL bootstrap:

```bash
docker compose up -d
```

Verify the bootstrap contract:

```bash
./scripts/verify-bootstrap.sh
```

Inspect recent rows:

```bash
./scripts/query-local-sensor-temp.sh
./scripts/query-local-topic-overview.sh
./scripts/query-local-3m-aggregates.sh
./scripts/query-local-power-energy-reconciliation.sh
```

Stop and remove the database volume:

```bash
docker compose down -v
```

## Public SQL Contract

This repository owns the bootstrap contract for:

- schema `mqtt_ingest`
- functions `mqtt_ingest.ingest_message(...)` and `mqtt_ingest.ingest_topics(...)`
- raw table `mqtt_ingest.messages`
- aggregate tables `mqtt_ingest.message_*_aggregates`
- topic inventory table `mqtt_ingest.topic_overview`
- reconciliation tables `mqtt_ingest.power_energy_*_reconciliation`
- background-job bootstrap for aggregate and reconciliation refresh

`mqtt2postgres` is expected to remain compatible with these object names and file ordering.

## Provenance

- source repository: `mqtt2postgres`
- source baseline version: `0.9.2`
- first fork version: `0.9.2-fork2.0`

See [FORKNOTE.md](FORKNOTE.md) and [CHANGELOG.md](CHANGELOG.md) for fork provenance and release history.
