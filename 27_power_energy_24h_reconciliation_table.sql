SELECT mqtt_ingest.ensure_power_energy_reconciliation_table(
    'power_energy_24h_reconciliation',
    INTERVAL '24 hours'
);
