CREATE OR REPLACE FUNCTION mqtt_migration.mapped_topic_for_rule(
    source_topic TEXT,
    rule_type TEXT,
    source_pattern TEXT,
    target_topic TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN rule_type = 'exact' THEN target_topic
        WHEN rule_type = 'prefix' THEN target_topic || substr(source_topic, length(source_pattern) + 1)
        WHEN rule_type = 'regex' THEN regexp_replace(source_topic, source_pattern, target_topic)
        ELSE NULL
    END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.parse_device_id(topic TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    WITH s AS (
        SELECT regexp_split_to_array(topic, '/') AS parts
    )
    SELECT CASE
        WHEN array_length(parts, 1) = 3
          AND parts[1] = 'sensors'
          AND parts[2] <> ''
          AND parts[3] <> ''
            THEN parts[2]
        WHEN array_length(parts, 1) = 5
          AND parts[1] = 'shellies'
          AND parts[2] <> ''
          AND parts[3] = 'relay'
          AND parts[4] = '0'
          AND parts[5] IN ('power', 'energy')
            THEN parts[2]
        WHEN array_length(parts, 1) = 4
          AND parts[1] = 'shellies'
          AND parts[2] <> ''
          AND parts[3] = 'relay'
          AND parts[4] = '0'
            THEN parts[2]
        ELSE NULL
    END
    FROM s;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.parse_metric_name(topic TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    WITH s AS (
        SELECT regexp_split_to_array(topic, '/') AS parts
    )
    SELECT CASE
        WHEN array_length(parts, 1) = 3
          AND parts[1] = 'sensors'
          AND parts[2] <> ''
          AND parts[3] <> ''
            THEN parts[3]
        WHEN array_length(parts, 1) = 5
          AND parts[1] = 'shellies'
          AND parts[2] <> ''
          AND parts[3] = 'relay'
          AND parts[4] = '0'
          AND parts[5] IN ('power', 'energy')
            THEN parts[5]
        WHEN array_length(parts, 1) = 4
          AND parts[1] = 'shellies'
          AND parts[2] <> ''
          AND parts[3] = 'relay'
          AND parts[4] = '0'
            THEN 'relay_state'
        ELSE NULL
    END
    FROM s;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.try_parse_double(payload TEXT)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN payload IS NOT NULL
         AND btrim(payload) ~ '^[+-]?((\d+(\.\d*)?)|(\.\d+))([eE][+-]?\d+)?$'
            THEN btrim(payload)::DOUBLE PRECISION
        ELSE NULL
    END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.create_import_batch(
    dump_name TEXT,
    source_timezone TEXT DEFAULT NULL,
    metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    new_batch_id BIGINT;
BEGIN
    INSERT INTO mqtt_migration.import_batches (
        dump_name,
        source_timezone,
        metadata
    )
    VALUES (
        create_import_batch.dump_name,
        COALESCE(NULLIF(create_import_batch.source_timezone, ''), NULLIF(current_setting('TimeZone', TRUE), ''), 'UTC'),
        create_import_batch.metadata
    )
    RETURNING batch_id INTO new_batch_id;

    RETURN new_batch_id;
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.stage_legacy_mqtt_table(
    batch_id BIGINT,
    source_table REGCLASS,
    from_time TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL,
    to_time TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    inserted_rows BIGINT;
    qualified_source_table TEXT;
BEGIN
    SELECT format('%I.%I', n.nspname, c.relname)
    INTO qualified_source_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = source_table;

    EXECUTE format(
        $sql$
        INSERT INTO mqtt_migration.staged_messages (
            batch_id,
            source_table,
            source_created_at,
            source_topic,
            source_unit,
            source_payload
        )
        SELECT
            $1,
            %L,
            created_at,
            topic,
            unit,
            payload::TEXT
        FROM %s
        WHERE ($2 IS NULL OR created_at >= $2)
          AND ($3 IS NULL OR created_at < $3)
        $sql$,
        qualified_source_table,
        source_table
    )
    USING batch_id, from_time, to_time;

    GET DIAGNOSTICS inserted_rows = ROW_COUNT;
    RETURN inserted_rows;
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.stage_legacy_mqtt(
    batch_id BIGINT,
    from_time TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL,
    to_time TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL,
    include_topics BOOLEAN DEFAULT TRUE
)
RETURNS TABLE(source_table TEXT, row_count BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    candidate TEXT;
    inserted_rows BIGINT;
    topic_rows BIGINT;
BEGIN
    FOREACH candidate IN ARRAY ARRAY[
        'public.mqtt_power',
        'public.mqtt_energy',
        'public.mqtt_status',
        'public.mqtt_switch',
        'public.mqtt_online',
        'public.mqtt_infos',
        'public.mqtt_announcements',
        'public.mqtt_dump'
    ]
    LOOP
        IF to_regclass(candidate) IS NOT NULL THEN
            inserted_rows := mqtt_migration.stage_legacy_mqtt_table(
                batch_id,
                candidate::REGCLASS,
                from_time,
                to_time
            );
            source_table := candidate;
            row_count := inserted_rows;
            RETURN NEXT;
        END IF;
    END LOOP;

    IF include_topics AND to_regclass('public.mqtt_topics') IS NOT NULL THEN
        INSERT INTO mqtt_migration.staged_topics (
            batch_id,
            source_topic,
            source_payload
        )
        SELECT
            stage_legacy_mqtt.batch_id,
            topic,
            payload
        FROM public.mqtt_topics;

        GET DIAGNOSTICS topic_rows = ROW_COUNT;
        source_table := 'public.mqtt_topics';
        row_count := topic_rows;
        RETURN NEXT;
    END IF;

    UPDATE mqtt_migration.import_batches b
    SET
        status = 'staged',
        staged_row_count = (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_messages sm
            WHERE sm.batch_id = stage_legacy_mqtt.batch_id
        ) + (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_topics st
            WHERE st.batch_id = stage_legacy_mqtt.batch_id
        ),
        source_min_at = (
            SELECT MIN(sm.source_created_at AT TIME ZONE b.source_timezone)
            FROM mqtt_migration.staged_messages sm
            WHERE sm.batch_id = stage_legacy_mqtt.batch_id
        ),
        source_max_at = (
            SELECT MAX(sm.source_created_at AT TIME ZONE b.source_timezone)
            FROM mqtt_migration.staged_messages sm
            WHERE sm.batch_id = stage_legacy_mqtt.batch_id
        ),
        updated_at = now()
    WHERE b.batch_id = stage_legacy_mqtt.batch_id;
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.apply_topic_mappings(batch_id BIGINT)
RETURNS TABLE(status TEXT, row_count BIGINT)
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM mqtt_migration.rejected_messages rm
    WHERE rm.batch_id = apply_topic_mappings.batch_id;

    WITH matched AS (
        SELECT
            sm.staged_message_id,
            sm.source_created_at,
            b.source_timezone,
            m.mapping_id,
            m.rule_type,
            m.source_pattern,
            m.target_topic,
            m.target_kind
        FROM mqtt_migration.staged_messages sm
        JOIN mqtt_migration.import_batches b
          ON b.batch_id = sm.batch_id
        LEFT JOIN LATERAL (
            SELECT tm.*
            FROM mqtt_migration.topic_mapping tm
            WHERE tm.enabled
              AND (tm.source_table IS NULL OR tm.source_table = sm.source_table)
              AND (
                    (tm.rule_type = 'exact' AND sm.source_topic = tm.source_pattern)
                 OR (tm.rule_type = 'prefix' AND sm.source_topic LIKE tm.source_pattern || '%')
                 OR (tm.rule_type = 'regex' AND sm.source_topic ~ tm.source_pattern)
              )
            ORDER BY tm.priority, tm.mapping_id
            LIMIT 1
        ) m ON TRUE
        WHERE sm.batch_id = apply_topic_mappings.batch_id
          AND NOT sm.inserted
    )
    UPDATE mqtt_migration.staged_messages sm
    SET
        mapping_id = matched.mapping_id,
        mapped_topic = CASE
            WHEN matched.target_kind = 'skip' THEN NULL
            ELSE mqtt_migration.mapped_topic_for_rule(sm.source_topic, matched.rule_type, matched.source_pattern, matched.target_topic)
        END,
        mapped_kind = matched.target_kind,
        validation_status = CASE
            WHEN matched.mapping_id IS NULL THEN 'unmapped'
            WHEN matched.target_kind = 'skip' THEN 'skipped'
            ELSE 'mapped'
        END,
        validation_error = CASE
            WHEN matched.mapping_id IS NULL THEN 'no topic mapping matched'
            WHEN matched.target_kind = 'skip' THEN 'topic mapping target kind is skip'
            ELSE NULL
        END,
        production_received_at = CASE
            WHEN matched.mapping_id IS NULL OR matched.target_kind = 'skip' THEN NULL
            ELSE sm.source_created_at AT TIME ZONE matched.source_timezone
        END
    FROM matched
    WHERE sm.staged_message_id = matched.staged_message_id;

    WITH matched AS (
        SELECT
            st.staged_topic_id,
            m.mapping_id,
            m.rule_type,
            m.source_pattern,
            m.target_topic,
            m.target_kind
        FROM mqtt_migration.staged_topics st
        JOIN mqtt_migration.import_batches b
          ON b.batch_id = st.batch_id
        LEFT JOIN LATERAL (
            SELECT tm.*
            FROM mqtt_migration.topic_mapping tm
            WHERE tm.enabled
              AND (tm.source_table IS NULL OR tm.source_table = 'public.mqtt_topics')
              AND (
                    (tm.rule_type = 'exact' AND st.source_topic = tm.source_pattern)
                 OR (tm.rule_type = 'prefix' AND st.source_topic LIKE tm.source_pattern || '%')
                 OR (tm.rule_type = 'regex' AND st.source_topic ~ tm.source_pattern)
              )
            ORDER BY tm.priority, tm.mapping_id
            LIMIT 1
        ) m ON TRUE
        WHERE st.batch_id = apply_topic_mappings.batch_id
          AND NOT st.inserted
    )
    UPDATE mqtt_migration.staged_topics st
    SET
        mapping_id = matched.mapping_id,
        mapped_topic = CASE
            WHEN matched.target_kind = 'skip' THEN NULL
            ELSE mqtt_migration.mapped_topic_for_rule(st.source_topic, matched.rule_type, matched.source_pattern, matched.target_topic)
        END,
        mapped_kind = matched.target_kind,
        validation_status = CASE
            WHEN matched.mapping_id IS NULL THEN 'unmapped'
            WHEN matched.target_kind = 'skip' THEN 'skipped'
            ELSE 'mapped'
        END,
        validation_error = CASE
            WHEN matched.mapping_id IS NULL THEN 'no topic mapping matched'
            WHEN matched.target_kind = 'skip' THEN 'topic mapping target kind is skip'
            ELSE NULL
        END
    FROM matched
    WHERE st.staged_topic_id = matched.staged_topic_id;

    INSERT INTO mqtt_migration.rejected_messages (
        batch_id,
        staged_message_id,
        source_table,
        source_topic,
        source_payload,
        reason
    )
    SELECT
        sm.batch_id,
        sm.staged_message_id,
        sm.source_table,
        sm.source_topic,
        sm.source_payload,
        sm.validation_error
    FROM mqtt_migration.staged_messages sm
    WHERE sm.batch_id = apply_topic_mappings.batch_id
      AND sm.validation_status IN ('unmapped', 'skipped')
    ON CONFLICT (staged_message_id) DO NOTHING;

    INSERT INTO mqtt_migration.rejected_messages (
        batch_id,
        staged_topic_id,
        source_table,
        source_topic,
        source_payload,
        reason
    )
    SELECT
        st.batch_id,
        st.staged_topic_id,
        'public.mqtt_topics',
        st.source_topic,
        st.source_payload,
        st.validation_error
    FROM mqtt_migration.staged_topics st
    WHERE st.batch_id = apply_topic_mappings.batch_id
      AND st.validation_status IN ('unmapped', 'skipped')
    ON CONFLICT (staged_topic_id) DO NOTHING;

    UPDATE mqtt_migration.import_batches b
    SET
        status = 'mapped',
        mapped_row_count = (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_messages sm
            WHERE sm.batch_id = apply_topic_mappings.batch_id
              AND sm.validation_status = 'mapped'
        ) + (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_topics st
            WHERE st.batch_id = apply_topic_mappings.batch_id
              AND st.validation_status = 'mapped'
        ),
        skipped_row_count = (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_messages sm
            WHERE sm.batch_id = apply_topic_mappings.batch_id
              AND sm.validation_status IN ('unmapped', 'skipped')
        ) + (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_topics st
            WHERE st.batch_id = apply_topic_mappings.batch_id
              AND st.validation_status IN ('unmapped', 'skipped')
        ),
        updated_at = now()
    WHERE b.batch_id = apply_topic_mappings.batch_id;

    RETURN QUERY
    SELECT sm.validation_status, COUNT(*)::BIGINT
    FROM mqtt_migration.staged_messages sm
    WHERE sm.batch_id = apply_topic_mappings.batch_id
    GROUP BY sm.validation_status
    UNION ALL
    SELECT 'topic_' || st.validation_status, COUNT(*)::BIGINT
    FROM mqtt_migration.staged_topics st
    WHERE st.batch_id = apply_topic_mappings.batch_id
    GROUP BY st.validation_status
    ORDER BY 1;
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.load_mapped_messages(batch_id BIGINT)
RETURNS TABLE(inserted_messages BIGINT, inserted_relay_events BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    message_rows BIGINT;
    relay_rows BIGINT;
BEGIN
    WITH candidates AS MATERIALIZED (
        SELECT
            sm.staged_message_id,
            sm.production_received_at AS received_at,
            sm.mapped_topic AS topic,
            mqtt_migration.parse_device_id(sm.mapped_topic) AS device_id,
            mqtt_migration.parse_metric_name(sm.mapped_topic) AS metric_name,
            COALESCE(sm.source_payload, '') AS payload,
            mqtt_migration.try_parse_double(sm.source_payload) AS numeric_value,
            jsonb_build_object(
                'migration_batch_id', sm.batch_id,
                'source_table', sm.source_table,
                'source_topic', sm.source_topic,
                'source_unit', sm.source_unit,
                'source_created_at', to_char(sm.source_created_at, 'YYYY-MM-DD HH24:MI:SS.US'),
                'target_kind', sm.mapped_kind,
                'imported_at', now()
            ) || sm.metadata AS metadata
        FROM mqtt_migration.staged_messages sm
        WHERE sm.batch_id = load_mapped_messages.batch_id
          AND sm.validation_status = 'mapped'
          AND sm.mapped_kind IN ('measurement', 'status')
          AND sm.mapped_topic IS NOT NULL
          AND sm.production_received_at IS NOT NULL
          AND NOT sm.inserted
          AND NOT EXISTS (
              SELECT 1
              FROM mqtt_ingest.messages existing
              WHERE existing.received_at = sm.production_received_at
                AND existing.topic = sm.mapped_topic
                AND existing.payload = COALESCE(sm.source_payload, '')
                AND existing.metadata ->> 'source_table' = sm.source_table
                AND existing.metadata ->> 'source_topic' = sm.source_topic
                AND (
                    existing.metadata ->> 'source_created_at' = to_char(sm.source_created_at, 'YYYY-MM-DD HH24:MI:SS.US')
                    OR NOT existing.metadata ? 'source_created_at'
                )
          )
    ),
    inserted AS (
        INSERT INTO mqtt_ingest.messages (
            received_at,
            topic,
            device_id,
            metric_name,
            payload,
            numeric_value,
            metadata
        )
        SELECT
            received_at,
            topic,
            device_id,
            metric_name,
            payload,
            numeric_value,
            metadata
        FROM candidates
        RETURNING 1
    ),
    updated AS (
        UPDATE mqtt_migration.staged_messages sm
        SET
            inserted = TRUE,
            validation_status = 'inserted',
            inserted_at = now()
        WHERE sm.staged_message_id IN (
            SELECT staged_message_id
            FROM candidates
        )
        RETURNING 1
    )
    SELECT COUNT(*) INTO message_rows
    FROM inserted;

    WITH candidates AS MATERIALIZED (
        SELECT
            sm.staged_message_id,
            sm.production_received_at AS event_at,
            sm.mapped_topic AS topic,
            mqtt_migration.parse_device_id(sm.mapped_topic) AS device_id,
            lower(btrim(COALESCE(sm.source_payload, ''))) AS state,
            COALESCE(sm.source_payload, '') AS payload,
            jsonb_build_object(
                'migration_batch_id', sm.batch_id,
                'source_table', sm.source_table,
                'source_topic', sm.source_topic,
                'source_unit', sm.source_unit,
                'source_created_at', to_char(sm.source_created_at, 'YYYY-MM-DD HH24:MI:SS.US'),
                'target_kind', sm.mapped_kind,
                'imported_at', now()
            ) || sm.metadata AS metadata
        FROM mqtt_migration.staged_messages sm
        WHERE sm.batch_id = load_mapped_messages.batch_id
          AND sm.mapped_kind = 'status'
          AND mqtt_migration.parse_metric_name(sm.mapped_topic) = 'relay_state'
          AND lower(btrim(COALESCE(sm.source_payload, ''))) IN ('on', 'off')
          AND sm.production_received_at IS NOT NULL
          AND NOT sm.relay_inserted
          AND NOT EXISTS (
              SELECT 1
              FROM mqtt_ingest.relay_state_events existing
              WHERE existing.event_at = sm.production_received_at
                AND existing.topic = sm.mapped_topic
                AND existing.payload = COALESCE(sm.source_payload, '')
                AND existing.metadata ->> 'source_table' = sm.source_table
                AND existing.metadata ->> 'source_topic' = sm.source_topic
                AND (
                    existing.metadata ->> 'source_created_at' = to_char(sm.source_created_at, 'YYYY-MM-DD HH24:MI:SS.US')
                    OR NOT existing.metadata ? 'source_created_at'
                )
          )
    ),
    inserted AS (
        INSERT INTO mqtt_ingest.relay_state_events (
            event_at,
            topic,
            device_id,
            relay_index,
            state,
            is_on,
            payload,
            metadata
        )
        SELECT
            event_at,
            topic,
            device_id,
            0,
            state,
            state = 'on',
            payload,
            metadata
        FROM candidates
        WHERE device_id IS NOT NULL
        RETURNING 1
    ),
    updated AS (
        UPDATE mqtt_migration.staged_messages sm
        SET relay_inserted = TRUE
        WHERE sm.staged_message_id IN (
            SELECT staged_message_id
            FROM candidates
        )
        RETURNING 1
    )
    SELECT COUNT(*) INTO relay_rows
    FROM inserted;

    UPDATE mqtt_migration.import_batches b
    SET
        status = 'loaded',
        inserted_row_count = (
            SELECT COUNT(*)
            FROM mqtt_migration.staged_messages sm
            WHERE sm.batch_id = load_mapped_messages.batch_id
              AND sm.inserted
        ),
        updated_at = now()
    WHERE b.batch_id = load_mapped_messages.batch_id;

    inserted_messages := COALESCE(message_rows, 0);
    inserted_relay_events := COALESCE(relay_rows, 0);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.load_mapped_topics(batch_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    topic_rows BIGINT;
BEGIN
    WITH candidates AS MATERIALIZED (
        SELECT
            st.staged_topic_id,
            st.mapped_topic AS topic,
            st.source_payload AS payload,
            jsonb_build_object(
                'migration_batch_id', st.batch_id,
                'source_table', 'public.mqtt_topics',
                'source_topic', st.source_topic,
                'target_kind', st.mapped_kind,
                'imported_at', now()
            ) || st.metadata AS metadata
        FROM mqtt_migration.staged_topics st
        WHERE st.batch_id = load_mapped_topics.batch_id
          AND st.validation_status = 'mapped'
          AND st.mapped_kind = 'topic_inventory'
          AND st.mapped_topic IS NOT NULL
          AND NOT st.inserted
    ),
    deduped_topics AS (
        SELECT DISTINCT ON (topic)
            topic,
            payload,
            metadata
        FROM candidates
        ORDER BY topic, staged_topic_id DESC
    ),
    upserted AS (
        INSERT INTO mqtt_ingest.topic_overview (
            topic,
            first_seen_at,
            last_seen_at,
            message_count,
            last_payload,
            last_metadata,
            refreshed_at
        )
        SELECT
            topic,
            now(),
            now(),
            1,
            payload,
            metadata,
            now()
        FROM deduped_topics
        ON CONFLICT ON CONSTRAINT topic_overview_pkey DO UPDATE SET
            last_seen_at = EXCLUDED.last_seen_at,
            message_count = mqtt_ingest.topic_overview.message_count + 1,
            last_payload = EXCLUDED.last_payload,
            last_metadata = EXCLUDED.last_metadata,
            refreshed_at = EXCLUDED.refreshed_at
        RETURNING 1
    ),
    updated AS (
        UPDATE mqtt_migration.staged_topics st
        SET
            inserted = TRUE,
            validation_status = 'inserted',
            inserted_at = now()
        WHERE st.staged_topic_id IN (
            SELECT staged_topic_id
            FROM candidates
        )
        RETURNING 1
    )
    SELECT COUNT(*) INTO topic_rows
    FROM upserted;

    RETURN COALESCE(topic_rows, 0);
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_migration.refresh_import_batch(batch_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    from_time TIMESTAMPTZ;
    to_time TIMESTAMPTZ;
BEGIN
    SELECT
        MIN(production_received_at),
        MAX(production_received_at)
    INTO from_time, to_time
    FROM mqtt_migration.staged_messages
    WHERE staged_messages.batch_id = refresh_import_batch.batch_id
      AND inserted;

    IF from_time IS NULL OR to_time IS NULL THEN
        RETURN;
    END IF;

    PERFORM mqtt_ingest.refresh_message_3m_aggregates(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_message_15m_aggregates(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_message_60m_aggregates(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_message_24h_aggregates(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_power_energy_3m_reconciliation(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_power_energy_15m_reconciliation(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_power_energy_60m_reconciliation(from_time, to_time, now());
    PERFORM mqtt_ingest.refresh_power_energy_24h_reconciliation(from_time, to_time, now());

    UPDATE mqtt_migration.import_batches b
    SET
        status = 'refreshed',
        updated_at = now()
    WHERE b.batch_id = refresh_import_batch.batch_id;
END;
$$;

CREATE OR REPLACE VIEW mqtt_migration.batch_summary AS
SELECT
    b.batch_id,
    b.dump_name,
    b.source_timezone,
    b.status,
    b.source_min_at,
    b.source_max_at,
    b.staged_row_count,
    b.mapped_row_count,
    b.skipped_row_count,
    b.inserted_row_count,
    COALESCE(message_status.status_counts, '{}'::JSONB) AS message_status_counts,
    COALESCE(topic_status.status_counts, '{}'::JSONB) AS topic_status_counts,
    b.created_at,
    b.updated_at
FROM mqtt_migration.import_batches b
LEFT JOIN LATERAL (
    SELECT jsonb_object_agg(validation_status, row_count ORDER BY validation_status) AS status_counts
    FROM (
        SELECT validation_status, COUNT(*) AS row_count
        FROM mqtt_migration.staged_messages sm
        WHERE sm.batch_id = b.batch_id
        GROUP BY validation_status
    ) counts
) message_status ON TRUE
LEFT JOIN LATERAL (
    SELECT jsonb_object_agg(validation_status, row_count ORDER BY validation_status) AS status_counts
    FROM (
        SELECT validation_status, COUNT(*) AS row_count
        FROM mqtt_migration.staged_topics st
        WHERE st.batch_id = b.batch_id
        GROUP BY validation_status
    ) counts
) topic_status ON TRUE;

CREATE OR REPLACE VIEW mqtt_migration.top_unmapped_topics AS
SELECT
    batch_id,
    source_table,
    source_topic,
    COUNT(*) AS row_count,
    MIN(source_created_at) AS first_seen_at,
    MAX(source_created_at) AS last_seen_at
FROM mqtt_migration.staged_messages
WHERE validation_status = 'unmapped'
GROUP BY batch_id, source_table, source_topic
UNION ALL
SELECT
    batch_id,
    'public.mqtt_topics' AS source_table,
    source_topic,
    COUNT(*) AS row_count,
    NULL::TIMESTAMP WITHOUT TIME ZONE AS first_seen_at,
    NULL::TIMESTAMP WITHOUT TIME ZONE AS last_seen_at
FROM mqtt_migration.staged_topics
WHERE validation_status = 'unmapped'
GROUP BY batch_id, source_topic;
