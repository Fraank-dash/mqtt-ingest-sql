CREATE OR REPLACE FUNCTION mqtt_ingest.refresh_power_energy_3m_reconciliation(
    from_time TIMESTAMPTZ DEFAULT NULL,
    to_time TIMESTAMPTZ DEFAULT NULL,
    reference_time TIMESTAMPTZ DEFAULT now()
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM mqtt_ingest.refresh_power_energy_reconciliation(
        'power_energy_3m_reconciliation',
        INTERVAL '3 minutes',
        from_time,
        to_time,
        reference_time
    );
END;
$$;
