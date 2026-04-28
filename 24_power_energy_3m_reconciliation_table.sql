SELECT mqtt_ingest.ensure_power_energy_reconciliation_table(
    'power_energy_3m_reconciliation',
    INTERVAL '3 minutes'
);
