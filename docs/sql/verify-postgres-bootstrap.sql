WITH role_info AS (
    SELECT oid, rolcanlogin
    FROM pg_roles
    WHERE rolname = 'mqtt_ingest_writer'
),
ingest_functions AS (
    SELECT
        p.oid,
        p.proname,
        pg_get_function_identity_arguments(p.oid) AS identity_arguments,
        p.prosecdef
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'mqtt_ingest'
      AND p.proname IN ('ingest_message', 'ingest_topics')
),
checks(name, passed) AS (
    VALUES
        ('table mqtt_ingest.messages exists',
            to_regclass('mqtt_ingest.messages') IS NOT NULL),
        ('table mqtt_ingest.topic_overview exists',
            to_regclass('mqtt_ingest.topic_overview') IS NOT NULL),
        ('table mqtt_ingest.relay_state_events exists',
            to_regclass('mqtt_ingest.relay_state_events') IS NOT NULL),
        ('table mqtt_ingest.message_3m_aggregates exists',
            to_regclass('mqtt_ingest.message_3m_aggregates') IS NOT NULL),
        ('table mqtt_ingest.power_energy_3m_reconciliation exists',
            to_regclass('mqtt_ingest.power_energy_3m_reconciliation') IS NOT NULL),
        ('function mqtt_ingest.ingest_message exists',
            to_regprocedure('mqtt_ingest.ingest_message(text,text,timestamp with time zone,jsonb)') IS NOT NULL),
        ('function mqtt_ingest.ingest_topics exists',
            to_regprocedure('mqtt_ingest.ingest_topics(text,text,timestamp with time zone,jsonb)') IS NOT NULL),
        ('role mqtt_ingest_writer exists',
            EXISTS (
                SELECT 1
                FROM role_info
            )),
        ('role mqtt_ingest_writer is NOLOGIN',
            EXISTS (
                SELECT 1
                FROM role_info
                WHERE NOT rolcanlogin
            )),
        ('role mqtt_ingest_writer has schema USAGE',
            COALESCE((
                SELECT has_schema_privilege(oid, 'mqtt_ingest', 'USAGE')
                FROM role_info
            ), FALSE)),
        ('role mqtt_ingest_writer can execute ingest_message',
            COALESCE((
                SELECT has_function_privilege(role_info.oid, ingest_functions.oid, 'EXECUTE')
                FROM role_info
                CROSS JOIN ingest_functions
                WHERE ingest_functions.proname = 'ingest_message'
                  AND ingest_functions.identity_arguments = 'topic text, payload text, received_at timestamp with time zone, metadata jsonb'
            ), FALSE)),
        ('role mqtt_ingest_writer can execute ingest_topics',
            COALESCE((
                SELECT has_function_privilege(role_info.oid, ingest_functions.oid, 'EXECUTE')
                FROM role_info
                CROSS JOIN ingest_functions
                WHERE ingest_functions.proname = 'ingest_topics'
                  AND ingest_functions.identity_arguments = 'topic text, payload text, received_at timestamp with time zone, metadata jsonb'
            ), FALSE)),
        ('role mqtt_ingest_writer has no direct table privileges',
            COALESCE(NOT EXISTS (
                SELECT 1
                FROM role_info
                CROSS JOIN pg_tables
                WHERE pg_tables.schemaname = 'mqtt_ingest'
                  AND has_table_privilege(
                    role_info.oid,
                    format('%I.%I', pg_tables.schemaname, pg_tables.tablename),
                    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
                  )
            ), FALSE)),
        ('ingest_message is SECURITY DEFINER',
            EXISTS (
                SELECT 1
                FROM ingest_functions
                WHERE proname = 'ingest_message'
                  AND identity_arguments = 'topic text, payload text, received_at timestamp with time zone, metadata jsonb'
                  AND prosecdef
            )),
        ('ingest_topics is SECURITY DEFINER',
            EXISTS (
                SELECT 1
                FROM ingest_functions
                WHERE proname = 'ingest_topics'
                  AND identity_arguments = 'topic text, payload text, received_at timestamp with time zone, metadata jsonb'
                  AND prosecdef
            ))
)
SELECT name
FROM checks
WHERE NOT passed
ORDER BY name;
