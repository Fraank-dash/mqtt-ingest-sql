CREATE OR REPLACE FUNCTION mqtt_ingest.ingest_message(
    topic TEXT,
    payload TEXT,
    received_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, mqtt_ingest
AS $$
DECLARE
    decoded JSONB;
    topic_segments TEXT[];
    value_text TEXT;
    parsed_numeric DOUBLE PRECISION;
    parsed_device_id TEXT;
    parsed_metric_name TEXT;
    parsed_event_id TEXT;
    parsed_trace_id TEXT;
    parsed_publisher_id TEXT;
    parsed_sequence BIGINT;
    parsed_published_at TIMESTAMPTZ;
    parsed_relay_state TEXT;
    parsed_topic_kind TEXT;
BEGIN
    BEGIN
        decoded := $2::JSONB;
    EXCEPTION WHEN others THEN
        decoded := NULL;
    END;

    IF decoded IS NOT NULL AND jsonb_typeof(decoded) = 'object' THEN
        value_text := decoded ->> 'value';
        parsed_event_id := decoded ->> 'event_id';
        parsed_trace_id := decoded ->> 'trace_id';
        parsed_publisher_id := decoded ->> 'publisher_id';

        BEGIN
            parsed_sequence := NULLIF(decoded ->> 'sequence', '')::BIGINT;
        EXCEPTION WHEN others THEN
            parsed_sequence := NULL;
        END;

        BEGIN
            parsed_published_at := NULLIF(decoded ->> 'published_at', '')::TIMESTAMPTZ;
        EXCEPTION WHEN others THEN
            parsed_published_at := NULL;
        END;
    ELSE
        value_text := $2;
    END IF;

    parsed_topic_kind := lower(btrim(COALESCE($4 ->> 'topic_kind', '')));

    topic_segments := regexp_split_to_array($1, '/');
    IF array_length(topic_segments, 1) = 3
       AND topic_segments[1] = 'sensors'
       AND topic_segments[2] <> ''
       AND topic_segments[3] <> ''
    THEN
        parsed_device_id := topic_segments[2];
        parsed_metric_name := topic_segments[3];
    ELSIF array_length(topic_segments, 1) = 5
       AND topic_segments[1] = 'shellies'
       AND topic_segments[2] <> ''
       AND topic_segments[3] = 'relay'
       AND topic_segments[4] = '0'
       AND topic_segments[5] IN ('power', 'energy')
    THEN
        parsed_device_id := topic_segments[2];
        parsed_metric_name := topic_segments[5];
    ELSIF array_length(topic_segments, 1) = 4
       AND topic_segments[1] = 'shellies'
       AND topic_segments[2] <> ''
       AND topic_segments[3] = 'relay'
       AND topic_segments[4] = '0'
    THEN
        parsed_device_id := topic_segments[2];
        parsed_metric_name := 'relay_state';
    ELSE
        parsed_device_id := NULL;
        parsed_metric_name := NULL;
    END IF;

    BEGIN
        parsed_numeric := NULLIF(value_text, '')::DOUBLE PRECISION;
    EXCEPTION WHEN others THEN
        parsed_numeric := NULL;
    END;

    INSERT INTO mqtt_ingest.messages (
        received_at,
        topic,
        device_id,
        metric_name,
        payload,
        numeric_value,
        event_id,
        trace_id,
        publisher_id,
        sequence,
        published_at,
        metadata
    )
    VALUES (
        $3,
        $1,
        parsed_device_id,
        parsed_metric_name,
        $2,
        parsed_numeric,
        COALESCE(parsed_event_id, $4 ->> 'event_id'),
        COALESCE(parsed_trace_id, $4 ->> 'trace_id'),
        COALESCE(parsed_publisher_id, $4 ->> 'publisher_id'),
        COALESCE(parsed_sequence, NULLIF($4 ->> 'sequence', '')::BIGINT),
        COALESCE(parsed_published_at, NULLIF($4 ->> 'published_at', '')::TIMESTAMPTZ),
        $4
    );

    IF parsed_metric_name = 'relay_state' THEN
        parsed_relay_state := lower(btrim(COALESCE(value_text, '')));

        IF parsed_relay_state IN ('on', 'off') THEN
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
            VALUES (
                $3,
                $1,
                parsed_device_id,
                0,
                parsed_relay_state,
                parsed_relay_state = 'on',
                $2,
                $4
            );
        END IF;
    END IF;

    IF parsed_topic_kind <> 'status' THEN
        PERFORM mqtt_ingest.refresh_message_3m_aggregates($3, $3, now());
        PERFORM mqtt_ingest.refresh_message_15m_aggregates($3, $3, now());
        PERFORM mqtt_ingest.refresh_message_60m_aggregates($3, $3, now());
        PERFORM mqtt_ingest.refresh_message_24h_aggregates($3, $3, now());
    END IF;

    PERFORM mqtt_ingest.refresh_power_energy_3m_reconciliation($3, $3, now());
    PERFORM mqtt_ingest.refresh_power_energy_15m_reconciliation($3, $3, now());
    PERFORM mqtt_ingest.refresh_power_energy_60m_reconciliation($3, $3, now());
    PERFORM mqtt_ingest.refresh_power_energy_24h_reconciliation($3, $3, now());
END;
$$;
