SELECT mqtt_ingest.ensure_power_energy_reconciliation_table(
    'power_energy_15m_reconciliation',
    INTERVAL '15 minutes'
);
