CREATE OR REPLACE FUNCTION mqtt_ingest.ensure_power_energy_reconciliation_table(
    table_suffix TEXT,
    bucket_width INTERVAL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, mqtt_ingest, public
AS $$
DECLARE
    qualified_table TEXT := format('mqtt_ingest.%I', table_suffix);
    status_constraint_name TEXT := format('%s_status_check', table_suffix);
    bucket_constraint_name TEXT := format('%s_bucket_check', table_suffix);
BEGIN
    EXECUTE format(
        $sql$
        CREATE TABLE IF NOT EXISTS %s (
            bucket_start TIMESTAMPTZ NOT NULL,
            bucket_end TIMESTAMPTZ NOT NULL,
            device_id TEXT NOT NULL,
            power_topic TEXT,
            energy_topic TEXT,
            power_numeric_count BIGINT,
            energy_numeric_count BIGINT,
            power_locf_avg_w DOUBLE PRECISION,
            power_linear_avg_w DOUBLE PRECISION,
            power_locf_integral_ws DOUBLE PRECISION,
            power_linear_integral_ws DOUBLE PRECISION,
            energy_locf_value_at_bucket_start DOUBLE PRECISION,
            energy_locf_value_at_bucket_end DOUBLE PRECISION,
            energy_linear_value_at_bucket_start DOUBLE PRECISION,
            energy_linear_value_at_bucket_end DOUBLE PRECISION,
            energy_locf_delta_ws DOUBLE PRECISION,
            energy_linear_delta_ws DOUBLE PRECISION,
            drift_locf_signed_ws DOUBLE PRECISION,
            drift_locf_abs_ws DOUBLE PRECISION,
            drift_locf_pct DOUBLE PRECISION,
            drift_linear_signed_ws DOUBLE PRECISION,
            drift_linear_abs_ws DOUBLE PRECISION,
            drift_linear_pct DOUBLE PRECISION,
            relay_on_seconds DOUBLE PRECISION,
            relay_off_seconds DOUBLE PRECISION,
            relay_on_pct DOUBLE PRECISION,
            relay_off_pct DOUBLE PRECISION,
            relay_event_count BIGINT,
            relay_state_known BOOLEAN,
            status TEXT NOT NULL,
            refreshed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (bucket_start, device_id),
            CONSTRAINT %I
                CHECK (status IN ('aggregated', 'tba')),
            CONSTRAINT %I
                CHECK (bucket_end = bucket_start + %L::INTERVAL)
        );
        $sql$,
        qualified_table,
        status_constraint_name,
        bucket_constraint_name,
        bucket_width::TEXT
    );

    PERFORM create_hypertable(
        qualified_table,
        'bucket_start',
        if_not_exists => TRUE
    );

    EXECUTE format(
        $sql$
        ALTER TABLE %s
            ADD COLUMN IF NOT EXISTS relay_on_seconds DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS relay_off_seconds DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS relay_on_pct DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS relay_off_pct DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS relay_event_count BIGINT,
            ADD COLUMN IF NOT EXISTS relay_state_known BOOLEAN;
        $sql$,
        qualified_table
    );

    EXECUTE format(
        $comment$COMMENT ON TABLE %s IS %L$comment$,
        qualified_table,
        format(
            'Per-device power/energy reconciliation buckets for %s windows. Compares energy derived from power integration against cumulative energy counter deltas and reports Shelly relay on/off coverage.',
            bucket_width::TEXT
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION mqtt_ingest.refresh_power_energy_reconciliation(
    table_suffix TEXT,
    bucket_width INTERVAL,
    from_time TIMESTAMPTZ DEFAULT NULL,
    to_time TIMESTAMPTZ DEFAULT NULL,
    reference_time TIMESTAMPTZ DEFAULT now()
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, mqtt_ingest, public
AS $$
DECLARE
    refresh_from TIMESTAMPTZ;
    refresh_to TIMESTAMPTZ;
    qualified_table TEXT := format('mqtt_ingest.%I', table_suffix);
    bucket_width_text TEXT := bucket_width::TEXT;
BEGIN
    refresh_from := COALESCE(
        time_bucket(bucket_width, from_time),
        (SELECT time_bucket(bucket_width, MIN(received_at)) FROM mqtt_ingest.messages)
    );
    refresh_to := COALESCE(
        time_bucket(bucket_width, to_time) + bucket_width,
        date_trunc('minute', reference_time) + INTERVAL '1 minute'
    );

    IF refresh_from IS NULL THEN
        RETURN;
    END IF;

    EXECUTE format(
        $sql$
        INSERT INTO %s (
            bucket_start,
            bucket_end,
            device_id,
            power_topic,
            energy_topic,
            power_numeric_count,
            energy_numeric_count,
            power_locf_avg_w,
            power_linear_avg_w,
            power_locf_integral_ws,
            power_linear_integral_ws,
            energy_locf_value_at_bucket_start,
            energy_locf_value_at_bucket_end,
            energy_linear_value_at_bucket_start,
            energy_linear_value_at_bucket_end,
            energy_locf_delta_ws,
            energy_linear_delta_ws,
            drift_locf_signed_ws,
            drift_locf_abs_ws,
            drift_locf_pct,
            drift_linear_signed_ws,
            drift_linear_abs_ws,
            drift_linear_pct,
            relay_on_seconds,
            relay_off_seconds,
            relay_on_pct,
            relay_off_pct,
            relay_event_count,
            relay_state_known,
            status,
            refreshed_at
        )
        WITH bucket_devices AS (
            SELECT
                time_bucket(%L::INTERVAL, received_at) AS bucket_start,
                time_bucket(%L::INTERVAL, received_at) + %L::INTERVAL AS bucket_end,
                device_id
            FROM mqtt_ingest.messages
            WHERE received_at >= $1
              AND received_at < $2
              AND device_id IS NOT NULL
              AND metric_name IN ('power', 'energy')
              AND (
                    topic = format('sensors/%%s/power', device_id)
                 OR topic = format('sensors/%%s/energy', device_id)
                 OR topic = format('shellies/%%s/relay/0/power', device_id)
                 OR topic = format('shellies/%%s/relay/0/energy', device_id)
              )
            GROUP BY
                time_bucket(%L::INTERVAL, received_at),
                device_id
        ),
        device_scope AS (
            SELECT DISTINCT device_id
            FROM bucket_devices
        ),
        power_bucket_summaries AS (
            SELECT
                time_bucket(%L::INTERVAL, received_at) AS bucket_start,
                device_id,
                MIN(topic) AS power_topic,
                COUNT(numeric_value) AS power_numeric_count,
                time_weight('LOCF', received_at, numeric_value) AS locf_tws,
                time_weight('Linear', received_at, numeric_value) AS linear_tws
            FROM mqtt_ingest.messages
            WHERE numeric_value IS NOT NULL
              AND device_id IN (SELECT device_id FROM device_scope)
              AND metric_name = 'power'
              AND (
                    topic = format('sensors/%%s/power', device_id)
                 OR topic = format('shellies/%%s/relay/0/power', device_id)
              )
            GROUP BY
                time_bucket(%L::INTERVAL, received_at),
                device_id
        ),
        power_summary_windows AS (
            SELECT
                bucket_start,
                device_id,
                power_topic,
                power_numeric_count,
                locf_tws,
                linear_tws,
                LAG(locf_tws) OVER (
                    PARTITION BY device_id
                    ORDER BY bucket_start
                ) AS prev_locf_tws,
                LEAD(locf_tws) OVER (
                    PARTITION BY device_id
                    ORDER BY bucket_start
                ) AS next_locf_tws,
                LAG(linear_tws) OVER (
                    PARTITION BY device_id
                    ORDER BY bucket_start
                ) AS prev_linear_tws,
                LEAD(linear_tws) OVER (
                    PARTITION BY device_id
                    ORDER BY bucket_start
                ) AS next_linear_tws
            FROM power_bucket_summaries
        ),
        power_boundaries AS (
            SELECT
                b.bucket_start,
                b.bucket_end,
                b.device_id,
                sw.power_topic,
                sw.power_numeric_count,
                sw.locf_tws,
                sw.linear_tws,
                sw.prev_locf_tws,
                sw.next_locf_tws,
                sw.prev_linear_tws,
                sw.next_linear_tws,
                start_prev.received_at AS start_prev_received_at,
                start_prev.numeric_value AS start_prev_numeric_value,
                start_next.received_at AS start_next_received_at,
                start_next.numeric_value AS start_next_numeric_value,
                end_prev.received_at AS end_prev_received_at,
                end_prev.numeric_value AS end_prev_numeric_value,
                end_next.received_at AS end_next_received_at,
                end_next.numeric_value AS end_next_numeric_value
            FROM bucket_devices b
            LEFT JOIN power_summary_windows sw
              ON sw.bucket_start = b.bucket_start
             AND sw.device_id = b.device_id
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'power'
                  AND (
                        topic = format('sensors/%%s/power', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/power', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at <= b.bucket_start
                ORDER BY received_at DESC
                LIMIT 1
            ) AS start_prev ON TRUE
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'power'
                  AND (
                        topic = format('sensors/%%s/power', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/power', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at >= b.bucket_start
                ORDER BY received_at ASC
                LIMIT 1
            ) AS start_next ON TRUE
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'power'
                  AND (
                        topic = format('sensors/%%s/power', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/power', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at <= b.bucket_end
                ORDER BY received_at DESC
                LIMIT 1
            ) AS end_prev ON TRUE
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'power'
                  AND (
                        topic = format('sensors/%%s/power', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/power', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at >= b.bucket_end
                ORDER BY received_at ASC
                LIMIT 1
            ) AS end_next ON TRUE
        ),
        power_rows AS (
            SELECT
                bucket_start,
                bucket_end,
                device_id,
                power_topic,
                power_numeric_count,
                CASE
                    WHEN locf_tws IS NOT NULL
                     AND start_prev_received_at IS NOT NULL
                     AND end_prev_received_at IS NOT NULL
                     AND end_next_received_at IS NOT NULL
                    THEN interpolated_average(
                        locf_tws,
                        bucket_start,
                        %L::INTERVAL,
                        prev_locf_tws,
                        next_locf_tws
                    )
                    ELSE NULL
                END AS power_locf_avg_w,
                CASE
                    WHEN linear_tws IS NOT NULL
                     AND start_prev_received_at IS NOT NULL
                     AND start_next_received_at IS NOT NULL
                     AND end_prev_received_at IS NOT NULL
                     AND end_next_received_at IS NOT NULL
                    THEN interpolated_average(
                        linear_tws,
                        bucket_start,
                        %L::INTERVAL,
                        prev_linear_tws,
                        next_linear_tws
                    )
                    ELSE NULL
                END AS power_linear_avg_w
            FROM power_boundaries
            WHERE power_numeric_count IS NOT NULL
        ),
        energy_bucket_counts AS (
            SELECT
                time_bucket(%L::INTERVAL, received_at) AS bucket_start,
                device_id,
                MIN(topic) AS energy_topic,
                COUNT(numeric_value) AS energy_numeric_count
            FROM mqtt_ingest.messages
            WHERE numeric_value IS NOT NULL
              AND device_id IN (SELECT device_id FROM device_scope)
              AND metric_name = 'energy'
              AND (
                    topic = format('sensors/%%s/energy', device_id)
                 OR topic = format('shellies/%%s/relay/0/energy', device_id)
              )
            GROUP BY
                time_bucket(%L::INTERVAL, received_at),
                device_id
        ),
        energy_boundaries AS (
            SELECT
                b.bucket_start,
                b.bucket_end,
                b.device_id,
                ec.energy_topic,
                ec.energy_numeric_count,
                start_prev.received_at AS start_prev_received_at,
                start_prev.numeric_value AS start_prev_numeric_value,
                start_next.received_at AS start_next_received_at,
                start_next.numeric_value AS start_next_numeric_value,
                end_prev.received_at AS end_prev_received_at,
                end_prev.numeric_value AS end_prev_numeric_value,
                end_next.received_at AS end_next_received_at,
                end_next.numeric_value AS end_next_numeric_value
            FROM bucket_devices b
            LEFT JOIN energy_bucket_counts ec
              ON ec.bucket_start = b.bucket_start
             AND ec.device_id = b.device_id
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'energy'
                  AND (
                        topic = format('sensors/%%s/energy', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/energy', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at <= b.bucket_start
                ORDER BY received_at DESC
                LIMIT 1
            ) AS start_prev ON TRUE
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'energy'
                  AND (
                        topic = format('sensors/%%s/energy', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/energy', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at >= b.bucket_start
                ORDER BY received_at ASC
                LIMIT 1
            ) AS start_next ON TRUE
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'energy'
                  AND (
                        topic = format('sensors/%%s/energy', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/energy', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at <= b.bucket_end
                ORDER BY received_at DESC
                LIMIT 1
            ) AS end_prev ON TRUE
            LEFT JOIN LATERAL (
                SELECT received_at, numeric_value
                FROM mqtt_ingest.messages
                WHERE device_id = b.device_id
                  AND metric_name = 'energy'
                  AND (
                        topic = format('sensors/%%s/energy', b.device_id)
                     OR topic = format('shellies/%%s/relay/0/energy', b.device_id)
                  )
                  AND numeric_value IS NOT NULL
                  AND received_at >= b.bucket_end
                ORDER BY received_at ASC
                LIMIT 1
            ) AS end_next ON TRUE
        ),
        energy_rows AS (
            SELECT
                bucket_start,
                bucket_end,
                device_id,
                energy_topic,
                energy_numeric_count,
                CASE
                    WHEN start_prev_received_at IS NOT NULL
                    THEN start_prev_numeric_value
                    ELSE NULL
                END AS energy_locf_value_at_bucket_start,
                CASE
                    WHEN end_prev_received_at IS NOT NULL
                     AND end_next_received_at IS NOT NULL
                    THEN end_prev_numeric_value
                    ELSE NULL
                END AS energy_locf_value_at_bucket_end,
                CASE
                    WHEN start_prev_received_at IS NOT NULL
                     AND start_next_received_at IS NOT NULL
                    THEN CASE
                        WHEN start_prev_received_at = start_next_received_at
                        THEN start_prev_numeric_value
                        ELSE start_prev_numeric_value
                            + (start_next_numeric_value - start_prev_numeric_value)
                                * (
                                    EXTRACT(EPOCH FROM (bucket_start - start_prev_received_at))
                                    / NULLIF(EXTRACT(EPOCH FROM (start_next_received_at - start_prev_received_at)), 0)
                                )
                    END
                    ELSE NULL
                END AS energy_linear_value_at_bucket_start,
                CASE
                    WHEN end_prev_received_at IS NOT NULL
                     AND end_next_received_at IS NOT NULL
                    THEN CASE
                        WHEN end_prev_received_at = end_next_received_at
                        THEN end_prev_numeric_value
                        ELSE end_prev_numeric_value
                            + (end_next_numeric_value - end_prev_numeric_value)
                                * (
                                    EXTRACT(EPOCH FROM (bucket_end - end_prev_received_at))
                                    / NULLIF(EXTRACT(EPOCH FROM (end_next_received_at - end_prev_received_at)), 0)
                                )
                    END
                    ELSE NULL
                END AS energy_linear_value_at_bucket_end
            FROM energy_boundaries
            WHERE energy_numeric_count IS NOT NULL
        ),
        relay_event_counts AS (
            SELECT
                b.bucket_start,
                b.device_id,
                COUNT(r.event_at) AS relay_event_count
            FROM bucket_devices b
            LEFT JOIN mqtt_ingest.relay_state_events r
              ON r.device_id = b.device_id
             AND r.relay_index = 0
             AND r.event_at >= b.bucket_start
             AND r.event_at < b.bucket_end
            GROUP BY
                b.bucket_start,
                b.device_id
        ),
        relay_segments AS (
            SELECT
                segment_rows.bucket_start,
                segment_rows.bucket_end,
                segment_rows.device_id,
                segment_rows.segment_start,
                LEAD(
                    segment_rows.segment_start,
                    1,
                    segment_rows.bucket_end
                ) OVER (
                    PARTITION BY segment_rows.bucket_start, segment_rows.device_id
                    ORDER BY segment_rows.segment_start, segment_rows.sort_order
                ) AS segment_end,
                segment_rows.is_on
            FROM (
                SELECT
                    b.bucket_start,
                    b.bucket_end,
                    b.device_id,
                    s.segment_start,
                    s.is_on,
                    s.sort_order
                FROM bucket_devices b
                CROSS JOIN LATERAL (
                    SELECT
                        b.bucket_start AS segment_start,
                        COALESCE((
                            SELECT r.is_on
                            FROM mqtt_ingest.relay_state_events r
                            WHERE r.device_id = b.device_id
                              AND r.relay_index = 0
                              AND r.event_at <= b.bucket_start
                            ORDER BY r.event_at DESC
                            LIMIT 1
                        ), TRUE) AS is_on,
                        0 AS sort_order
                    UNION ALL
                    SELECT
                        r.event_at AS segment_start,
                        r.is_on,
                        1 AS sort_order
                    FROM mqtt_ingest.relay_state_events r
                    WHERE r.device_id = b.device_id
                      AND r.relay_index = 0
                      AND r.event_at > b.bucket_start
                      AND r.event_at < b.bucket_end
                ) AS s
            ) AS segment_rows
        ),
        relay_coverage AS (
            SELECT
                rs.bucket_start,
                rs.bucket_end,
                rs.device_id,
                SUM(
                    CASE
                        WHEN rs.is_on
                        THEN GREATEST(EXTRACT(EPOCH FROM (rs.segment_end - rs.segment_start)), 0)
                        ELSE 0
                    END
                ) AS relay_on_seconds,
                SUM(
                    CASE
                        WHEN NOT rs.is_on
                        THEN GREATEST(EXTRACT(EPOCH FROM (rs.segment_end - rs.segment_start)), 0)
                        ELSE 0
                    END
                ) AS relay_off_seconds
            FROM relay_segments rs
            GROUP BY
                rs.bucket_start,
                rs.bucket_end,
                rs.device_id
        ),
        final_rows AS (
            SELECT
                b.bucket_start,
                b.bucket_end,
                b.device_id,
                p.power_topic,
                e.energy_topic,
                p.power_numeric_count,
                e.energy_numeric_count,
                p.power_locf_avg_w,
                p.power_linear_avg_w,
                CASE
                    WHEN p.power_locf_avg_w IS NOT NULL
                    THEN p.power_locf_avg_w * EXTRACT(EPOCH FROM %L::INTERVAL)
                    ELSE NULL
                END AS power_locf_integral_ws,
                CASE
                    WHEN p.power_linear_avg_w IS NOT NULL
                    THEN p.power_linear_avg_w * EXTRACT(EPOCH FROM %L::INTERVAL)
                    ELSE NULL
                END AS power_linear_integral_ws,
                e.energy_locf_value_at_bucket_start,
                e.energy_locf_value_at_bucket_end,
                e.energy_linear_value_at_bucket_start,
                e.energy_linear_value_at_bucket_end,
                CASE
                    WHEN e.energy_locf_value_at_bucket_start IS NOT NULL
                     AND e.energy_locf_value_at_bucket_end IS NOT NULL
                    THEN e.energy_locf_value_at_bucket_end - e.energy_locf_value_at_bucket_start
                    ELSE NULL
                END AS energy_locf_delta_ws,
                CASE
                    WHEN e.energy_linear_value_at_bucket_start IS NOT NULL
                     AND e.energy_linear_value_at_bucket_end IS NOT NULL
                    THEN e.energy_linear_value_at_bucket_end - e.energy_linear_value_at_bucket_start
                    ELSE NULL
                END AS energy_linear_delta_ws,
                rc.relay_on_seconds,
                rc.relay_off_seconds,
                (rc.relay_on_seconds / EXTRACT(EPOCH FROM %L::INTERVAL)) * 100.0 AS relay_on_pct,
                (rc.relay_off_seconds / EXTRACT(EPOCH FROM %L::INTERVAL)) * 100.0 AS relay_off_pct,
                COALESCE(rec.relay_event_count, 0) AS relay_event_count,
                TRUE AS relay_state_known,
                CASE
                    WHEN b.bucket_end <= date_trunc('minute', $3)
                    THEN 'aggregated'
                    ELSE 'tba'
                END AS status,
                now() AS refreshed_at
            FROM bucket_devices b
            LEFT JOIN power_rows p
              ON p.bucket_start = b.bucket_start
             AND p.device_id = b.device_id
            LEFT JOIN energy_rows e
              ON e.bucket_start = b.bucket_start
             AND e.device_id = b.device_id
            LEFT JOIN relay_coverage rc
              ON rc.bucket_start = b.bucket_start
             AND rc.device_id = b.device_id
            LEFT JOIN relay_event_counts rec
              ON rec.bucket_start = b.bucket_start
             AND rec.device_id = b.device_id
        )
        SELECT
            bucket_start,
            bucket_end,
            device_id,
            power_topic,
            energy_topic,
            power_numeric_count,
            energy_numeric_count,
            power_locf_avg_w,
            power_linear_avg_w,
            power_locf_integral_ws,
            power_linear_integral_ws,
            energy_locf_value_at_bucket_start,
            energy_locf_value_at_bucket_end,
            energy_linear_value_at_bucket_start,
            energy_linear_value_at_bucket_end,
            energy_locf_delta_ws,
            energy_linear_delta_ws,
            CASE
                WHEN power_locf_integral_ws IS NOT NULL
                 AND energy_locf_delta_ws IS NOT NULL
                THEN power_locf_integral_ws - energy_locf_delta_ws
                ELSE NULL
            END AS drift_locf_signed_ws,
            CASE
                WHEN power_locf_integral_ws IS NOT NULL
                 AND energy_locf_delta_ws IS NOT NULL
                THEN ABS(power_locf_integral_ws - energy_locf_delta_ws)
                ELSE NULL
            END AS drift_locf_abs_ws,
            CASE
                WHEN power_locf_integral_ws IS NOT NULL
                 AND energy_locf_delta_ws IS NOT NULL
                 AND energy_locf_delta_ws <> 0
                THEN ((power_locf_integral_ws - energy_locf_delta_ws) / energy_locf_delta_ws) * 100.0
                ELSE NULL
            END AS drift_locf_pct,
            CASE
                WHEN power_linear_integral_ws IS NOT NULL
                 AND energy_linear_delta_ws IS NOT NULL
                THEN power_linear_integral_ws - energy_linear_delta_ws
                ELSE NULL
            END AS drift_linear_signed_ws,
            CASE
                WHEN power_linear_integral_ws IS NOT NULL
                 AND energy_linear_delta_ws IS NOT NULL
                THEN ABS(power_linear_integral_ws - energy_linear_delta_ws)
                ELSE NULL
            END AS drift_linear_abs_ws,
            CASE
                WHEN power_linear_integral_ws IS NOT NULL
                 AND energy_linear_delta_ws IS NOT NULL
                 AND energy_linear_delta_ws <> 0
                THEN ((power_linear_integral_ws - energy_linear_delta_ws) / energy_linear_delta_ws) * 100.0
                ELSE NULL
            END AS drift_linear_pct,
            relay_on_seconds,
            relay_off_seconds,
            relay_on_pct,
            relay_off_pct,
            relay_event_count,
            relay_state_known,
            status,
            refreshed_at
        FROM final_rows
        ON CONFLICT (bucket_start, device_id) DO UPDATE SET
            bucket_end = EXCLUDED.bucket_end,
            power_topic = EXCLUDED.power_topic,
            energy_topic = EXCLUDED.energy_topic,
            power_numeric_count = EXCLUDED.power_numeric_count,
            energy_numeric_count = EXCLUDED.energy_numeric_count,
            power_locf_avg_w = EXCLUDED.power_locf_avg_w,
            power_linear_avg_w = EXCLUDED.power_linear_avg_w,
            power_locf_integral_ws = EXCLUDED.power_locf_integral_ws,
            power_linear_integral_ws = EXCLUDED.power_linear_integral_ws,
            energy_locf_value_at_bucket_start = EXCLUDED.energy_locf_value_at_bucket_start,
            energy_locf_value_at_bucket_end = EXCLUDED.energy_locf_value_at_bucket_end,
            energy_linear_value_at_bucket_start = EXCLUDED.energy_linear_value_at_bucket_start,
            energy_linear_value_at_bucket_end = EXCLUDED.energy_linear_value_at_bucket_end,
            energy_locf_delta_ws = EXCLUDED.energy_locf_delta_ws,
            energy_linear_delta_ws = EXCLUDED.energy_linear_delta_ws,
            drift_locf_signed_ws = EXCLUDED.drift_locf_signed_ws,
            drift_locf_abs_ws = EXCLUDED.drift_locf_abs_ws,
            drift_locf_pct = EXCLUDED.drift_locf_pct,
            drift_linear_signed_ws = EXCLUDED.drift_linear_signed_ws,
            drift_linear_abs_ws = EXCLUDED.drift_linear_abs_ws,
            drift_linear_pct = EXCLUDED.drift_linear_pct,
            relay_on_seconds = EXCLUDED.relay_on_seconds,
            relay_off_seconds = EXCLUDED.relay_off_seconds,
            relay_on_pct = EXCLUDED.relay_on_pct,
            relay_off_pct = EXCLUDED.relay_off_pct,
            relay_event_count = EXCLUDED.relay_event_count,
            relay_state_known = EXCLUDED.relay_state_known,
            status = EXCLUDED.status,
            refreshed_at = EXCLUDED.refreshed_at
        $sql$,
        qualified_table,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text,
        bucket_width_text
    )
    USING refresh_from, refresh_to, reference_time;
END;
$$;

CREATE OR REPLACE PROCEDURE mqtt_ingest.run_power_energy_reconciliation_job(
    table_suffix TEXT,
    bucket_width INTERVAL
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM mqtt_ingest.refresh_power_energy_reconciliation(
        table_suffix,
        bucket_width,
        NULL,
        NULL,
        date_trunc('minute', now())
    );
END;
$$;

CREATE OR REPLACE PROCEDURE mqtt_ingest.ensure_power_energy_reconciliation_job(
    procedure_name TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'mqtt_ingest'
          AND proc_name = procedure_name
    ) THEN
        PERFORM add_job(
            format('mqtt_ingest.%I', procedure_name)::REGPROC,
            INTERVAL '1 minute'
        );
    END IF;
END;
$$;
