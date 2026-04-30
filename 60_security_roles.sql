DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'mqtt_ingest_writer'
    ) THEN
        CREATE ROLE mqtt_ingest_writer NOLOGIN;
    END IF;
END;
$$;

ALTER ROLE mqtt_ingest_writer NOLOGIN;

REVOKE ALL ON SCHEMA mqtt_ingest FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA mqtt_ingest FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA mqtt_ingest FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mqtt_ingest FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA mqtt_ingest FROM mqtt_ingest_writer;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA mqtt_ingest FROM mqtt_ingest_writer;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mqtt_ingest FROM mqtt_ingest_writer;

GRANT USAGE ON SCHEMA mqtt_ingest TO mqtt_ingest_writer;

GRANT EXECUTE ON FUNCTION mqtt_ingest.ingest_message(TEXT, TEXT, TIMESTAMPTZ, JSONB)
    TO mqtt_ingest_writer;
GRANT EXECUTE ON FUNCTION mqtt_ingest.ingest_topics(TEXT, TEXT, TIMESTAMPTZ, JSONB)
    TO mqtt_ingest_writer;
