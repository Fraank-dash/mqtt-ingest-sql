SELECT mqtt_ingest.ensure_power_energy_reconciliation_table(
    'power_energy_60m_reconciliation',
    INTERVAL '60 minutes'
);
