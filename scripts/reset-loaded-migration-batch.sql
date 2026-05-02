-- Usage:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v batch_id=2 -f scripts/reset-loaded-migration-batch.sql

DELETE FROM mqtt_ingest.relay_state_events
WHERE metadata ->> 'migration_batch_id' = :'batch_id';

DELETE FROM mqtt_ingest.messages
WHERE metadata ->> 'migration_batch_id' = :'batch_id';

UPDATE mqtt_migration.staged_messages
SET
    inserted = FALSE,
    relay_inserted = FALSE,
    validation_status = 'mapped',
    inserted_at = NULL
WHERE batch_id = :'batch_id'::BIGINT
  AND validation_status = 'inserted';

UPDATE mqtt_migration.staged_topics
SET
    inserted = FALSE,
    validation_status = 'mapped',
    inserted_at = NULL
WHERE batch_id = :'batch_id'::BIGINT
  AND validation_status = 'inserted';

UPDATE mqtt_migration.import_batches
SET
    status = 'mapped',
    inserted_row_count = 0,
    updated_at = now()
WHERE batch_id = :'batch_id'::BIGINT;
