CREATE OR REPLACE FUNCTION mqtt_ingest.refresh_power_energy_24h_reconciliation(
    from_time TIMESTAMPTZ DEFAULT NULL,
    to_time TIMESTAMPTZ DEFAULT NULL,
    reference_time TIMESTAMPTZ DEFAULT now()
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM mqtt_ingest.refresh_power_energy_reconciliation(
        'power_energy_24h_reconciliation',
        INTERVAL '24 hours',
        from_time,
        to_time,
        reference_time
    );
END;
$$;
