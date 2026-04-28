# Bootstrap And Queries

This fork keeps a minimal SQL-only operational path.

## Bootstrap

Start the local database:

```bash
docker compose up -d
```

The database bootstrap is driven by the ordered SQL files in the repository root, mounted into `/docker-entrypoint-initdb.d`.

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
