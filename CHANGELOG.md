# Changelog

## Unreleased

## 0.9.2-fork2.3 - 2026-05-02

### Topic: Raw Data Retention
- Added `58_raw_retention_policies.sql` to manage TimescaleDB retention policies for `mqtt_ingest.messages` and `mqtt_ingest.relay_state_events`.
- Configured a rolling 12-month raw-data retention window with a daily retention-policy schedule.
- Extended bootstrap verification, local health checks, and setup documentation to assert and document raw-data retention.
- Documented the retention contract: aggregate and reconciliation history remains queryable after raw rows are pruned, but older periods can no longer be recomputed from raw history.
- Documented that retention duration changes should be made directly in `58_raw_retention_policies.sql`; there is intentionally no retention-interval parameterization yet.

### Topic: Legacy MQTT Dump Migration
- Added reusable `mqtt_migration` staging tables, mapping rules, rejected-row audit storage, and batch summaries for legacy `public.mqtt_*` dump imports.
- Added migration functions for staging legacy rows, applying topic mappings, duplicate-safe raw message loading, relay-state event loading, topic inventory upserts, and aggregate refresh.
- Added scripts for sanitized pg_dumpall restore, dry-run mapping reports, remapping, batch loading, range-based batch execution, reset helpers, and explicit skip-rule seeding.
- Added XLSX topic-mapping import for `mapping/result_export.xlsx` worksheet `Tabelle2`, including support for historical device aliases and double-prefix legacy Shelly topics.
- Added topic-mapping workbook templates with required columns and example device mappings for future migrations.
- Documented the local restore, mapping, dry-run, range-run, duplicate reset, and load workflow in [Legacy MQTT Dump Migration](docs/legacy-mqtt-dump-migration.md).
- Ignored local `pg_dump/` files so large scratch dumps are not committed.

## 0.9.2-fork2.2 - 2026-05-01

### Topic: Shelly Relay State Coverage
- Added Shelly relay state tracking and per-bucket relay coverage fields on power/energy reconciliation tables.
- Added Shelly topic parsing for `shellies/<device>/relay/0/power`, `shellies/<device>/relay/0/energy`, and `shellies/<device>/relay/0`.
- Added relay on/off coverage fields to power/energy reconciliation tables: `relay_on_seconds`, `relay_off_seconds`, `relay_on_pct`, `relay_off_pct`, `relay_event_count`, and `relay_state_known`.
- Preserved existing drift calculations while exposing relay coverage as context for measured versus unmeasured bucket time.
- Added an existing-database migration note: [Shelly Relay State Coverage](docs/migrations.md#shelly-relay-state-coverage).
- Optimized `ingest_message(...)` to use subscriber `topic_kind = status` metadata and skip generic aggregate refreshes for status messages.

### Topic: SQL Bootstrap And Verification
- Added `mqtt_ingest.relay_state_events` as a dedicated hypertable for Shelly relay state events.
- Updated local bootstrap verification and the example Compose healthcheck to include relay state event storage.
- Updated the local power/energy reconciliation query helper to display relay coverage fields.

## 0.9.2-fork2.1 - 2026-04-30

### Topic: SQL-First Operations
- Added a GUI-friendly PostgreSQL bootstrap verifier SQL file and updated the shell verifier to reuse it.
- Documented manual root-level `NN_*.sql` application for GUI PostgreSQL clients.
- Clarified password and certificate subscriber-role creation examples for `mqtt_ingest_writer`.
- Moved generic PostgreSQL login-role helper functions and documentation to the local `GATE` repository.

## 0.9.2-fork2.0 - 2026-04-28

### Topic: Fork Extraction
- Forked the `mqtt_ingest` SQL bootstrap from `mqtt2postgres`.
- Kept the ordered SQL bootstrap files as the public contract for schema, functions, tables, and jobs.
- Added a standalone TimescaleDB-only Compose stack for bootstrapping and validation.
- Added SQL-focused query helpers and bootstrap verification scripts.
- Carried over SQL-focused documentation for ingest flow and aggregate-quality behavior.
