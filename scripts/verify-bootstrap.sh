#!/usr/bin/env bash
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

result="$(
  docker compose -f "$COMPOSE_FILE" exec -T timescaledb \
    psql -U postgres -d mqtt -At -c \
    "WITH retention_policies AS (
         SELECT
           h.schema_name AS hypertable_schema,
           h.table_name AS hypertable_name,
           (j.config ->> 'drop_after')::INTERVAL AS drop_after,
           j.schedule_interval
         FROM timescaledb_information.jobs j
         JOIN _timescaledb_catalog.hypertable h
           ON h.id = (j.config ->> 'hypertable_id')::INTEGER
         WHERE j.proc_name = 'policy_retention'
           AND j.config ? 'hypertable_id'
       )
       SELECT to_regclass('mqtt_ingest.messages') IS NOT NULL
         AND to_regclass('mqtt_ingest.topic_overview') IS NOT NULL
         AND to_regclass('mqtt_ingest.relay_state_events') IS NOT NULL
         AND to_regclass('mqtt_ingest.message_3m_aggregates') IS NOT NULL
         AND to_regclass('mqtt_ingest.power_energy_3m_reconciliation') IS NOT NULL
         AND to_regprocedure('mqtt_ingest.ingest_message(text,text,timestamp with time zone,jsonb)') IS NOT NULL
         AND to_regprocedure('mqtt_ingest.ingest_topics(text,text,timestamp with time zone,jsonb)') IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM retention_policies
           WHERE hypertable_schema = 'mqtt_ingest'
             AND hypertable_name = 'messages'
             AND drop_after = INTERVAL '12 months'
             AND schedule_interval = INTERVAL '1 day'
         )
         AND EXISTS (
           SELECT 1
           FROM retention_policies
           WHERE hypertable_schema = 'mqtt_ingest'
             AND hypertable_name = 'relay_state_events'
             AND drop_after = INTERVAL '12 months'
             AND schedule_interval = INTERVAL '1 day'
         );"
)"

if [ "$result" != "t" ]; then
  echo "Bootstrap verification failed." >&2
  exit 1
fi

echo "Bootstrap verification passed."
