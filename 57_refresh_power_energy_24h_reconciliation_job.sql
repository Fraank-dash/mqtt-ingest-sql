CREATE OR REPLACE PROCEDURE mqtt_ingest.refresh_power_energy_24h_reconciliation_job(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL mqtt_ingest.run_power_energy_reconciliation_job(
        'power_energy_24h_reconciliation',
        INTERVAL '24 hours'
    );
END;
$$;

CALL mqtt_ingest.ensure_power_energy_reconciliation_job('refresh_power_energy_24h_reconciliation_job');
