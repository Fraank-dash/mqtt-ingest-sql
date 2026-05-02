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

psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" <<'SQL'
SELECT * FROM mqtt_migration.apply_topic_mappings(:'batch_id'::BIGINT);
SQL

echo
echo "Batch summary"
psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" \
  -x <<'SQL'
SELECT * FROM mqtt_migration.batch_summary WHERE batch_id = :'batch_id'::BIGINT;
SQL

echo
echo "Top unmapped topics"
psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" <<'SQL'
SELECT source_table, source_topic, row_count, first_seen_at, last_seen_at
FROM mqtt_migration.top_unmapped_topics
WHERE batch_id = :'batch_id'::BIGINT
ORDER BY row_count DESC, source_topic
LIMIT 50;
SQL
