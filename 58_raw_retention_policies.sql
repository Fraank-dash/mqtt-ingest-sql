SELECT remove_retention_policy('mqtt_ingest.messages', if_exists => TRUE);

SELECT add_retention_policy(
    'mqtt_ingest.messages',
    drop_after => INTERVAL '12 months',
    schedule_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

SELECT remove_retention_policy('mqtt_ingest.relay_state_events', if_exists => TRUE);

SELECT add_retention_policy(
    'mqtt_ingest.relay_state_events',
    drop_after => INTERVAL '12 months',
    schedule_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);
