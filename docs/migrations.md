# Migrations

This project primarily uses ordered bootstrap SQL files. For an existing database,
apply only the files needed for the change unless you intentionally want to
reapply the full bootstrap.

## Legacy MQTT Dump Migration Helpers

Use these files when adding the reusable `mqtt_migration` staging and loading
surface to an already-running database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 70_migration_tables.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 71_migration_functions.sql
```

The helpers do not migrate data by themselves. Restore the legacy dump into a
scratch database, seed `mqtt_migration.topic_mapping`, then follow
[Legacy MQTT Dump Migration](legacy-mqtt-dump-migration.md).

## Shelly Relay State Coverage

Use this migration when upgrading an already-running database to the Shelly relay
state tracking and reconciliation coverage changes.

Version range: from `0.9.2-fork2.1` to `0.9.2-fork2.2`.

Run these files in order:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 12_aggregate_helpers.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 13_power_energy_reconciliation_helpers.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 14_relay_state_events_table.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 24_power_energy_3m_reconciliation_table.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 25_power_energy_15m_reconciliation_table.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 26_power_energy_60m_reconciliation_table.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 27_power_energy_24h_reconciliation_table.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 30_refresh_3m_aggregates_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 31_refresh_15m_aggregates_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 32_refresh_60m_aggregates_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 33_refresh_24h_aggregates_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 34_refresh_power_energy_3m_reconciliation_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 35_refresh_power_energy_15m_reconciliation_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 36_refresh_power_energy_60m_reconciliation_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 37_refresh_power_energy_24h_reconciliation_function.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 40_ingest_message_function.sql
```

The job files do not need to be rerun if the TimescaleDB background jobs already
exist. `60_security_roles.sql` also does not need to be rerun unless you want to
reapply ingest-role grants.

## Subscriber Status Topic Optimization

Use this migration only if you already applied the Shelly relay state coverage
SQL before the subscriber status-topic optimization was included. For a normal
upgrade from `0.9.2-fork2.1` to `0.9.2-fork2.2`, the previous migration already
includes this `40_ingest_message_function.sql` update.

This optimization is useful after deploying `mqtt2postgres-subscriber` `1.2.0`
or newer when `status_topics` are configured and metadata contains `topic_kind`.

Version range: from an early `0.9.2-fork2.2` pre-release checkout with Shelly
relay state coverage to final `0.9.2-fork2.2`.

Run this file:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 40_ingest_message_function.sql
```

This keeps raw status messages and relay events, but skips generic message
aggregate refreshes for messages with `metadata.topic_kind = 'status'`.
