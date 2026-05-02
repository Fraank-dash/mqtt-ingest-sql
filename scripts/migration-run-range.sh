#!/usr/bin/env bash
set -euo pipefail

psql_cmd() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" "$@"
  else
    psql "$@"
  fi
}

usage() {
  cat >&2 <<'EOF'
Usage:
  DATABASE_URL=<db-url> START_DATE=YYYY-MM-DD END_DATE=YYYY-MM-DD ./scripts/migration-run-range.sh [dump.sql]

Environment:
  START_DATE      inclusive lower bound, required
  END_DATE        exclusive upper bound, required
  MAX_BATCHES     maximum number of batches to create, default 100
  BATCH_DAYS      days per batch, default 1
  SOURCE_TIMEZONE source timezone for timestamp conversion, default database TimeZone
  LOAD_BATCHES    1 to load each batch after mapping, default 0 dry-run only
  INCLUDE_TOPICS  first to stage mqtt_topics in first batch only, all, or none; default first
EOF
}

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required." >&2
  usage
  exit 2
fi

if [ -z "${START_DATE:-}" ] || [ -z "${END_DATE:-}" ]; then
  echo "START_DATE and END_DATE are required." >&2
  usage
  exit 2
fi

dump_arg="${1:-legacy-mqtt-dump}"
source_timezone="${SOURCE_TIMEZONE:-}"
max_batches="${MAX_BATCHES:-100}"
batch_days="${BATCH_DAYS:-1}"
load_batches="${LOAD_BATCHES:-0}"
include_topics_mode="${INCLUDE_TOPICS:-first}"
dump_name="$dump_arg"
dump_path=""

if [ "$dump_arg" != "legacy-mqtt-dump" ]; then
  case "$dump_arg" in
    *.sql|*/*.sql)
      if [ ! -f "$dump_arg" ]; then
        echo "Dump file not found: $dump_arg" >&2
        exit 2
      fi
      dump_path="$(CDPATH= cd -- "$(dirname -- "$dump_arg")" && pwd)/$(basename -- "$dump_arg")"
      dump_name="$(basename -- "$dump_arg")"
      ;;
  esac
fi

case "$include_topics_mode" in
  first|all|none) ;;
  *)
    echo "INCLUDE_TOPICS must be one of: first, all, none" >&2
    exit 2
    ;;
esac

current="$(date -u -d "$START_DATE" '+%Y-%m-%d 00:00:00')"
end_ts="$(date -u -d "$END_DATE" '+%Y-%m-%d 00:00:00')"
batch_index=0

while [ "$current" \< "$end_ts" ] && [ "$batch_index" -lt "$max_batches" ]; do
  next="$(date -u -d "$current + ${batch_days} day" '+%Y-%m-%d %H:%M:%S')"
  if [ "$next" \> "$end_ts" ]; then
    next="$end_ts"
  fi

  include_topics="false"
  if [ "$include_topics_mode" = "all" ]; then
    include_topics="true"
  elif [ "$include_topics_mode" = "first" ] && [ "$batch_index" -eq 0 ]; then
    include_topics="true"
  fi

  echo
  echo "Creating batch for [$current, $next), include_topics=$include_topics"

  batch_id="$(
    psql_cmd -v ON_ERROR_STOP=1 -At \
      -v dump_name="$dump_name" \
      -v source_timezone="$source_timezone" \
      -v dump_path="$dump_path" \
      -v from_time="$current" \
      -v to_time="$next" <<'SQL'
SELECT mqtt_migration.create_import_batch(
    :'dump_name',
    NULLIF(:'source_timezone', ''),
    jsonb_build_object(
        'dump_path', NULLIF(:'dump_path', ''),
        'from_time', :'from_time',
        'to_time', :'to_time',
        'range_runner', true
    )
);
SQL
  )"

  psql_cmd -v ON_ERROR_STOP=1 \
    -v batch_id="$batch_id" \
    -v from_time="$current" \
    -v to_time="$next" \
    -v include_topics="$include_topics" <<'SQL'
SELECT * FROM mqtt_migration.stage_legacy_mqtt(
    :'batch_id'::BIGINT,
    :'from_time'::TIMESTAMP,
    :'to_time'::TIMESTAMP,
    :'include_topics'::BOOLEAN
);
SELECT * FROM mqtt_migration.apply_topic_mappings(:'batch_id'::BIGINT);
SQL

  if [ "$load_batches" = "1" ]; then
    echo "Loading batch $batch_id"
    psql_cmd -v ON_ERROR_STOP=1 -v batch_id="$batch_id" <<'SQL'
SELECT * FROM mqtt_migration.load_mapped_messages(:'batch_id'::BIGINT);
SELECT mqtt_migration.load_mapped_topics(:'batch_id'::BIGINT) AS inserted_topics;
SELECT mqtt_migration.refresh_import_batch(:'batch_id'::BIGINT);
SQL
  fi

  echo "Batch $batch_id summary"
  psql_cmd -v ON_ERROR_STOP=1 -v batch_id="$batch_id" <<'SQL'
SELECT
    batch_id,
    status,
    source_min_at,
    source_max_at,
    staged_row_count,
    mapped_row_count,
    skipped_row_count,
    inserted_row_count,
    message_status_counts,
    topic_status_counts
FROM mqtt_migration.batch_summary
WHERE batch_id = :'batch_id'::BIGINT;
SQL

  current="$next"
  batch_index=$((batch_index + 1))
done

echo
echo "Created $batch_index batch(es)."
if [ "$current" \< "$end_ts" ]; then
  echo "Stopped at $current because MAX_BATCHES=$max_batches."
fi
