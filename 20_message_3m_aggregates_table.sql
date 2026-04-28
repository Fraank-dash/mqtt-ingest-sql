SELECT mqtt_ingest.ensure_message_aggregates_table(
    'message_3m_aggregates',
    INTERVAL '3 minutes'
);
