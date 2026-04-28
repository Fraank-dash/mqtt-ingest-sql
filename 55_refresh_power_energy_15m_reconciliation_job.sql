CREATE OR REPLACE PROCEDURE mqtt_ingest.refresh_power_energy_15m_reconciliation_job(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL mqtt_ingest.run_power_energy_reconciliation_job(
        'power_energy_15m_reconciliation',
        INTERVAL '15 minutes'
    );
END;
$$;

CALL mqtt_ingest.ensure_power_energy_reconciliation_job('refresh_power_energy_15m_reconciliation_job');
