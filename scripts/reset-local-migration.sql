-- Usage:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v confirm=RESET_LOCAL_MIGRATION -f scripts/reset-local-migration.sql

SELECT CASE
    WHEN :'confirm' = 'RESET_LOCAL_MIGRATION' THEN 1
    ELSE 1 / 0
END AS reset_confirmation;

DELETE FROM mqtt_ingest.relay_state_events
WHERE metadata ? 'migration_batch_id';

DELETE FROM mqtt_ingest.messages
WHERE metadata ? 'migration_batch_id';

DELETE FROM mqtt_ingest.topic_overview
WHERE last_metadata ? 'migration_batch_id';

TRUNCATE mqtt_migration.import_batches RESTART IDENTITY CASCADE;
