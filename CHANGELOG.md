# Changelog

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
