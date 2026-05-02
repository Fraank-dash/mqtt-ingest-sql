#!/usr/bin/env bash
set -euo pipefail

psql_cmd() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" "$@"
  else
    psql "$@"
  fi
}

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <batch_id>" >&2
  exit 2
fi

batch_id="$1"

echo "Loading mapped messages for batch $batch_id"
psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" <<'SQL'
SELECT * FROM mqtt_migration.load_mapped_messages(:'batch_id'::BIGINT);
SQL

echo
echo "Loading mapped topic inventory for batch $batch_id"
psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" <<'SQL'
SELECT mqtt_migration.load_mapped_topics(:'batch_id'::BIGINT) AS inserted_topics;
SQL

echo
echo "Refreshing aggregates and power/energy reconciliation for batch $batch_id"
psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" <<'SQL'
SELECT mqtt_migration.refresh_import_batch(:'batch_id'::BIGINT);
SQL

echo
echo "Batch summary"
psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" \
  -x <<'SQL'
SELECT * FROM mqtt_migration.batch_summary WHERE batch_id = :'batch_id'::BIGINT;
SQL
