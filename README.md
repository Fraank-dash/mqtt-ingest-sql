# mqtt-ingest-sql

Standalone TimescaleDB/PostgreSQL bootstrap SQL for the `mqtt_ingest` schema used by `mqtt2postgres`.

This fork starts from the parent repository baseline `0.9.2`. The current standalone version is `0.9.2-fork2.2`.

## Scope

This repository focuses on backend SQL helper functionality for MQTT ingest data:

- accepting MQTT payloads through `mqtt_ingest.ingest_message(...)` and `mqtt_ingest.ingest_topics(...)`
- storing raw messages and topic inventory
- processing those rows into aggregate and reconciliation tables
- exposing SQL helpers, jobs, and verification queries for that data-processing surface

Security architecture, server architecture, deployment topology, certificate management,
and broader PostgreSQL operations are intentionally solved outside this repository.
Files such as [`60_security_roles.sql`](60_security_roles.sql) and
[`docker-compose.yml`](docker-compose.yml) are included as standalone runnable examples
for development, testing, and local verification. Treat them as reference scaffolding,
not as the authoritative production security or infrastructure model.

## Included Surface

- ordered bootstrap SQL for `mqtt_ingest`
- aggregate and reconciliation helper functions
- reusable legacy `public.mqtt_*` dump migration staging helpers
- TimescaleDB background job bootstrap
- SQL-focused query helpers
- a minimal TimescaleDB-only local compose stack
- SQL-focused documentation copied from the parent repo and reduced to the database surface

## Quick Start

Apply the SQL bootstrap to an existing TimescaleDB/PostgreSQL server:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/mqtt ./scripts/apply-sql.sh
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/mqtt ./scripts/verify-postgres.sh
```

The scripts also support standard PostgreSQL connection environment variables:

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=mqtt PGUSER=postgres PGPASSWORD=postgres ./scripts/apply-sql.sh
```

Apply the bootstrap as the PostgreSQL admin or another role allowed to create roles and manage privileges.

For a full no-Docker setup runbook, see [Setup Existing TimescaleDB](docs/setup-existing-timescaledb.md).
That guide also covers GUI-based SQL application, the standalone verifier SQL file, and password or certificate subscriber-role examples.

For a fresh local TimescaleDB instance, the optional example Compose stack mounts the ordered SQL files into `/docker-entrypoint-initdb.d`:

```bash
docker compose up -d
```

Verify the local Compose bootstrap contract:

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
- relay state event table `mqtt_ingest.relay_state_events`
- aggregate tables `mqtt_ingest.message_*_aggregates`
- topic inventory table `mqtt_ingest.topic_overview`
- reconciliation tables `mqtt_ingest.power_energy_*_reconciliation`
- background-job bootstrap for aggregate and reconciliation refresh
- least-privilege ingest role `mqtt_ingest_writer`
- migration schema `mqtt_migration` for staging historical MQTT dumps

`mqtt2postgres` is expected to remain compatible with these object names and file ordering.

For historical dump imports from legacy `public.mqtt_*` tables, see
[Legacy MQTT Dump Migration](docs/legacy-mqtt-dump-migration.md).

## MQTT Subscriber Access

The bootstrap creates `mqtt_ingest_writer` as a shared `NOLOGIN` role for MQTT subscriber accounts. It can use schema `mqtt_ingest` and execute only:

- `mqtt_ingest.ingest_message(text,text,timestamp with time zone,jsonb)`
- `mqtt_ingest.ingest_topics(text,text,timestamp with time zone,jsonb)`

Create real subscriber users separately and grant the group role:

```sql
CREATE ROLE mqtt_ingest_user1 LOGIN INHERIT PASSWORD 'change-me';
GRANT mqtt_ingest_writer TO mqtt_ingest_user1;
```

Subscriber users should write through the ingest functions only; direct table access is intentionally not granted.

## Provenance

- source repository: `mqtt2postgres`
- source baseline version: `0.9.2`
- first fork version: `0.9.2-fork2.0`
- current standalone version: `0.9.2-fork2.2`

See [FORKNOTE.md](FORKNOTE.md) and [CHANGELOG.md](CHANGELOG.md) for fork provenance and release history.
