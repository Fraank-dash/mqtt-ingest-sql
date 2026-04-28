# Changelog

## 0.9.2-fork2.0 - 2026-04-28

### Topic: Fork Extraction
- Forked the `mqtt_ingest` SQL bootstrap from `mqtt2postgres`.
- Kept the ordered SQL bootstrap files as the public contract for schema, functions, tables, and jobs.
- Added a standalone TimescaleDB-only Compose stack for bootstrapping and validation.
- Added SQL-focused query helpers and bootstrap verification scripts.
- Carried over SQL-focused documentation for ingest flow and aggregate-quality behavior.
