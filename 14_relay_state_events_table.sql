CREATE TABLE IF NOT EXISTS mqtt_ingest.relay_state_events (
    event_at      TIMESTAMPTZ NOT NULL,
    topic         TEXT NOT NULL,
    device_id     TEXT NOT NULL,
    relay_index   INTEGER NOT NULL,
    state         TEXT NOT NULL,
    is_on         BOOLEAN NOT NULL,
    payload       TEXT NOT NULL,
    metadata      JSONB NOT NULL DEFAULT '{}'::JSONB,
    committed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT relay_state_events_state_check
        CHECK (state IN ('on', 'off')),
    CONSTRAINT relay_state_events_relay_index_check
        CHECK (relay_index >= 0)
);

SELECT create_hypertable('mqtt_ingest.relay_state_events', 'event_at', if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS relay_state_events_device_relay_event_at_idx
    ON mqtt_ingest.relay_state_events (device_id, relay_index, event_at DESC);

CREATE INDEX IF NOT EXISTS relay_state_events_event_at_idx
    ON mqtt_ingest.relay_state_events (event_at);

COMMENT ON TABLE mqtt_ingest.relay_state_events IS
    'Raw Shelly relay state changes used to derive per-bucket on/off coverage for power/energy reconciliation.';
COMMENT ON COLUMN mqtt_ingest.relay_state_events.event_at IS
    'Timestamp when the relay state event was received.';
COMMENT ON COLUMN mqtt_ingest.relay_state_events.device_id IS
    'Parsed Shelly device identifier from shellies/<device>/relay/<relay_index> topics.';
COMMENT ON COLUMN mqtt_ingest.relay_state_events.relay_index IS
    'Shelly relay index parsed from the topic. This bootstrap currently writes relay 0.';
COMMENT ON COLUMN mqtt_ingest.relay_state_events.state IS
    'Normalized relay state: on or off.';
COMMENT ON COLUMN mqtt_ingest.relay_state_events.is_on IS
    'Boolean form of the normalized relay state.';
