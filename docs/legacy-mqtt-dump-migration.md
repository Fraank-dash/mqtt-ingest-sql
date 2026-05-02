# Legacy MQTT Dump Migration

This runbook migrates historical `public.mqtt_*` dump tables into the current
`mqtt_ingest` schema without replaying every row through
`mqtt_ingest.ingest_message(...)`.

The migration is designed to be reusable. Each import creates an audit batch,
stages source rows, applies data-driven topic mappings, bulk-loads mapped rows,
and refreshes derived aggregate tables once for the imported time window.

## Prerequisites

Restore one dump into a scratch server/database first. Do not restore a dump
directly over production.

The restored legacy database used for the dry run must contain:

- the restored legacy `public.mqtt_*` tables
- the current `mqtt_ingest` bootstrap SQL from this repository
- the `mqtt_migration` SQL files from this repository

Check the source timezone before importing:

```sql
SHOW TimeZone;
```

For the Timescale HA image this is normally `UTC` unless the container or
PostgreSQL config overrides it. The migration records this value in
`mqtt_migration.import_batches.source_timezone` and converts old
`timestamp without time zone` values with:

```sql
source_created_at AT TIME ZONE source_timezone
```

The provided `tsdb-db-1-test.sql` dump is a cluster-style dump: it contains
`CREATE DATABASE staging_mqtt`, `CREATE DATABASE tsdb`, and `\connect tsdb`.
Restore it by connecting to the maintenance database `postgres`. With this
repository's Compose stack, PostgreSQL is published on port `55432`.

Example restore command:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/postgres \
./scripts/restore-legacy-dump.sh ./pg_dump/tsdb-db-1-test.sql
```

Paste shell commands without surrounding quotes. For example, run `psql ...`,
not `"psql ..."`.

If a previous restore stopped partway through, reset the legacy objects before
retrying:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/postgres \
RESET_LEGACY_RESTORE=1 \
./scripts/restore-legacy-dump.sh ./pg_dump/tsdb-db-1-test.sql
```

The wrapper filters pg_dumpall `GRANTED BY` role-membership lines,
PostgreSQL 17-only `transaction_timeout` session settings, and TimescaleDB
internal catalog/config/chunk statements and triggers. Those can fail on a
local scratch Timescale HA PostgreSQL 16 instance and are not needed for the
MQTT data migration.

Then apply this repository's SQL bootstrap to the restored legacy database
before running the migration dry run:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
./scripts/apply-sql.sh
```

## Topic Mappings

Mappings live in `mqtt_migration.topic_mapping`. The migration never guesses a
new topic when no rule matches.

Set `source_table` when the same topic should be handled differently depending
on the old table it came from, for example `public.mqtt_status` versus
`public.mqtt_power`.

Rule behavior:

- `exact`: `source_pattern` must equal the old topic; `target_topic` is the full
  new topic.
- `prefix`: `source_pattern` must match the start of the old topic;
  `target_topic` replaces that prefix and the suffix is preserved.
- `regex`: `source_pattern` is a PostgreSQL regular expression and
  `target_topic` is the `regexp_replace` replacement.

Target kinds:

- `measurement`: insert into `mqtt_ingest.messages` and participate in normal
  aggregate parsing when the mapped topic shape is supported.
- `status`: insert into `mqtt_ingest.messages`; Shelly relay `on`/`off` rows are
  also inserted into `mqtt_ingest.relay_state_events`.
- `topic_inventory`: upsert staged `mqtt_topics` rows into
  `mqtt_ingest.topic_overview`.
- `skip`: preserve rows in staging/rejections but do not load them into
  production tables.

Example mapping seed:

```sql
INSERT INTO mqtt_migration.topic_mapping (
    priority,
    source_table,
    rule_type,
    source_pattern,
    target_topic,
    target_kind,
    notes
)
VALUES
    (10, 'public.mqtt_power', 'prefix', 'shellies/', 'shellies/', 'measurement', 'Keep legacy Shelly power topics unchanged'),
    (10, 'public.mqtt_energy', 'prefix', 'shellies/', 'shellies/', 'measurement', 'Keep legacy Shelly energy topics unchanged'),
    (10, 'public.mqtt_status', 'prefix', 'shellies/', 'shellies/', 'status', 'Keep legacy Shelly relay state topics unchanged'),
    (20, 'public.mqtt_topics', 'prefix', '$SYS/', '$SYS/', 'topic_inventory', 'Keep broker topic inventory'),
    (90, 'public.mqtt_topics', 'prefix', 'shellies/', 'shellies/', 'topic_inventory', 'Keep Shelly retained topic inventory');
```

Use more specific lower-priority-number rules before broad prefix rules when a
topic family changed names.

### Import Mapping From XLSX

The workbook `mapping/result_export.xlsx` contains device-name mappings in
worksheet `Tabelle2`. Import those rows into `mqtt_migration.topic_mapping`:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
./scripts/import-topic-mapping-xlsx.sh ./mapping/result_export.xlsx
```

The importer creates regex rules like:

```text
^shellies/<old-device>/(.*)$ -> shellies/<new-device>/\1
```

If `<old-mqtt-device-name>` already starts with `shellies/`, the importer keeps
that prefix. This intentionally supports historical double-prefix topics such
as `shellies/shellies/<device>/...`.

It creates source-table-specific rules for `public.mqtt_power`,
`public.mqtt_energy`, `public.mqtt_status`, the other legacy MQTT tables, and
`public.mqtt_topics`. It also adds a default `$SYS/` retained-topic inventory
rule. Rows marked `Not in Use` are skipped by default. Include them explicitly
with:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
./scripts/import-topic-mapping-xlsx.sh ./mapping/result_export.xlsx --include-not-in-use
```

Add explicit historical aliases with `--alias OLD_DEVICE=NEW_DEVICE` when an old
publisher used a one-off topic spelling that should map to a workbook device:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
./scripts/import-topic-mapping-xlsx.sh ./mapping/result_export.xlsx \
  --alias BV.SR.SY.PLG.Server=shellyplug-F43A50
```

Seed intentionally ignored legacy online topics:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/seed-legacy-skip-topic-rules.sql
```

## Dry Run

Create a batch, stage rows, apply current mappings, and report unmapped topics:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
SOURCE_TIMEZONE=UTC \
FROM_TIME='2025-10-03 00:00:00' \
TO_TIME='2025-10-04 00:00:00' \
./scripts/migration-dry-run.sh ./pg_dump/tsdb-db-1-test.sql
```

Omit `FROM_TIME` and `TO_TIME` only after a slice import has been validated.

The dump path argument is provenance only. The script reads legacy rows from
the already-restored `public.mqtt_*` tables in `DATABASE_URL`.

The dry run prints the batch id, row counts, and the top unmapped topics. Add or
adjust `topic_mapping` rows until unmapped rows are expected.

Create or load a range of daily batches:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
SOURCE_TIMEZONE=UTC \
START_DATE='2025-03-02' \
END_DATE='2025-06-10' \
MAX_BATCHES=100 \
LOAD_BATCHES=0 \
./scripts/migration-run-range.sh ./pg_dump/tsdb-db-1-test.sql
```

Set `LOAD_BATCHES=1` to load each created batch immediately after mapping:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
SOURCE_TIMEZONE=UTC \
START_DATE='2025-03-02' \
END_DATE='2025-06-10' \
MAX_BATCHES=100 \
LOAD_BATCHES=1 \
./scripts/migration-run-range.sh ./pg_dump/tsdb-db-1-test.sql
```

By default, non-timestamped `mqtt_topics` rows are staged only in the first
range batch. Override with `INCLUDE_TOPICS=all` or `INCLUDE_TOPICS=none`.

Reset the local migration and start again:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -v confirm=RESET_LOCAL_MIGRATION \
  -f scripts/reset-local-migration.sql
```

After changing mappings for an existing staged batch, reapply the mapping report:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
./scripts/migration-remap-report.sh 1
```

## Load

After reviewing the dry-run report, load the mapped rows for that batch:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
./scripts/migration-load.sh 1
```

If a batch was loaded by mistake, reset only that batch's inserted rows:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/tsdb \
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v batch_id=2 -f scripts/reset-loaded-migration-batch.sql
```

The load step:

1. bulk-inserts mapped measurement and status rows into `mqtt_ingest.messages`
2. bulk-inserts mapped relay state events into `mqtt_ingest.relay_state_events`
3. upserts mapped `mqtt_topics` rows into `mqtt_ingest.topic_overview`
4. refreshes 3m, 15m, 60m, and 24h aggregate/reconciliation tables once for the
   imported time range

## Verification Queries

Inspect the batch:

```sql
SELECT *
FROM mqtt_migration.batch_summary
WHERE batch_id = 1;
```

Confirm parsed device/metric fields:

```sql
SELECT topic, device_id, metric_name, COUNT(*)
FROM mqtt_ingest.messages
WHERE metadata ->> 'migration_batch_id' = '1'
GROUP BY topic, device_id, metric_name
ORDER BY COUNT(*) DESC
LIMIT 50;
```

Confirm relay state events:

```sql
SELECT device_id, state, COUNT(*)
FROM mqtt_ingest.relay_state_events
WHERE metadata ->> 'migration_batch_id' = '1'
GROUP BY device_id, state
ORDER BY device_id, state;
```

Confirm aggregate refresh:

```sql
SELECT COUNT(*) AS aggregate_rows
FROM mqtt_ingest.message_3m_aggregates
WHERE bucket_start >= (
    SELECT source_min_at
    FROM mqtt_migration.import_batches
    WHERE batch_id = 1
)
  AND bucket_start <= (
    SELECT source_max_at
    FROM mqtt_migration.import_batches
    WHERE batch_id = 1
);
```

Unmapped rows remain available for later mapping:

```sql
SELECT *
FROM mqtt_migration.top_unmapped_topics
WHERE batch_id = 1
ORDER BY row_count DESC
LIMIT 100;
```
