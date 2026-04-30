# Bootstrap And Queries

This fork keeps a minimal SQL-only operational path.

## Bootstrap

Apply the ordered SQL files to an existing TimescaleDB/PostgreSQL server:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/mqtt ./scripts/apply-sql.sh
```

The script uses `DATABASE_URL` when it is set. Otherwise, it uses the standard PostgreSQL connection environment variables such as `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD`.

Run the bootstrap as the PostgreSQL admin or another role allowed to create roles and manage privileges.

For the full no-Docker setup flow, see [Setup Existing TimescaleDB](setup-existing-timescaledb.md).

Verify the bootstrap contract on the same server:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/mqtt ./scripts/verify-postgres.sh
```

For GUI clients, open and run `docs/sql/verify-postgres-bootstrap.sql` against the same database. It returns failed check names, or an empty result set when verification passes.

Before applying SQL, the script checks that `psql` is installed, the database is reachable, and both `timescaledb` and `timescaledb_toolkit` are available on the server.

## Subscriber Access

The bootstrap creates a reusable `NOLOGIN` role named `mqtt_ingest_writer`. Grant this role to MQTT subscriber login users that should ingest data:

```sql
CREATE ROLE mqtt_ingest_user1 LOGIN INHERIT PASSWORD 'change-me';
GRANT mqtt_ingest_writer TO mqtt_ingest_user1;
```

`mqtt_ingest_writer` has `USAGE` on schema `mqtt_ingest` and `EXECUTE` only on the two public ingest functions. It does not receive direct table privileges.

## Local Compose Bootstrap

Start the optional local database:

```bash
docker compose up -d
```

The local Compose bootstrap is driven by the ordered SQL files in the repository root, mounted into `/docker-entrypoint-initdb.d`.

Use the verification helper after first boot or after SQL changes:

```bash
./scripts/verify-bootstrap.sh
```

## Query Helpers

The helper scripts connect to the local `timescaledb` Compose service and inspect the retained SQL surface:

- `./scripts/query-local-sensor-temp.sh`
- `./scripts/query-local-trace-report.sh`
- `./scripts/query-local-topic-overview.sh`
- `./scripts/query-local-3m-aggregates.sh`
- `./scripts/query-local-15m-aggregates.sh`
- `./scripts/query-local-60m-aggregates.sh`
- `./scripts/query-local-24h-aggregates.sh`
- `./scripts/query-local-power-energy-reconciliation.sh`

## Reset

Recreate the database from the SQL bootstrap:

```bash
docker compose down -v
docker compose up -d
```
