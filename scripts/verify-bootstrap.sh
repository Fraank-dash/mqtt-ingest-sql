#!/usr/bin/env bash
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

docker compose -f "$COMPOSE_FILE" exec -T timescaledb \
  psql -U postgres -d mqtt -At -c \
  "SELECT to_regclass('mqtt_ingest.messages') IS NOT NULL
       AND to_regclass('mqtt_ingest.topic_overview') IS NOT NULL
       AND to_regclass('mqtt_ingest.relay_state_events') IS NOT NULL
       AND to_regclass('mqtt_ingest.message_3m_aggregates') IS NOT NULL
       AND to_regclass('mqtt_ingest.power_energy_3m_reconciliation') IS NOT NULL
       AND to_regprocedure('mqtt_ingest.ingest_message(text,text,timestamp with time zone,jsonb)') IS NOT NULL
       AND to_regprocedure('mqtt_ingest.ingest_topics(text,text,timestamp with time zone,jsonb)') IS NOT NULL;"
