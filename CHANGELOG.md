# Changelog

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
