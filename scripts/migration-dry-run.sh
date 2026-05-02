#!/usr/bin/env bash
set -euo pipefail

psql_cmd() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" "$@"
  else
    psql "$@"
  fi
}

dump_arg="${1:-legacy-mqtt-dump}"
source_timezone="${SOURCE_TIMEZONE:-}"
from_time="${FROM_TIME:-}"
to_time="${TO_TIME:-}"
dump_name="$dump_arg"
dump_path=""

if [ "$dump_arg" != "legacy-mqtt-dump" ]; then
  case "$dump_arg" in
    *.sql|*/*.sql)
      if [ ! -f "$dump_arg" ]; then
        cat >&2 <<EOF
Dump file not found: $dump_arg

This script does not restore dump files. Restore the dump into the scratch
database first, then run this dry run against that database. If the dump is
already restored, pass a plain name instead of a file path.
EOF
        exit 2
      fi

      dump_path="$(CDPATH= cd -- "$(dirname -- "$dump_arg")" && pwd)/$(basename -- "$dump_arg")"
      dump_name="$(basename -- "$dump_arg")"
      ;;
  esac
fi

legacy_table_count="$(
  psql_cmd -v ON_ERROR_STOP=1 -At -c "
    SELECT COUNT(*)
    FROM (
      VALUES
        ('public.mqtt_power'),
        ('public.mqtt_energy'),
        ('public.mqtt_status'),
        ('public.mqtt_switch'),
        ('public.mqtt_online'),
        ('public.mqtt_infos'),
        ('public.mqtt_announcements'),
        ('public.mqtt_dump'),
        ('public.mqtt_topics')
    ) AS expected(table_name)
    WHERE to_regclass(expected.table_name) IS NOT NULL;
  "
)"

if [ "$legacy_table_count" -eq 0 ]; then
  cat >&2 <<EOF
No legacy public.mqtt_* tables were found in the target database.

Restore the dump into a scratch database first, apply this repository's SQL
bootstrap to that database, then rerun this dry run with DATABASE_URL pointing
at the scratch database.
EOF
  exit 2
fi

batch_id="$(
  psql_cmd -v ON_ERROR_STOP=1 -At \
    -v dump_name="$dump_name" \
    -v source_timezone="$source_timezone" \
    -v dump_path="$dump_path" <<'SQL'
SELECT mqtt_migration.create_import_batch(:'dump_name', NULLIF(:'source_timezone', ''), jsonb_build_object('dump_path', NULLIF(:'dump_path', '')));
SQL
)"

echo "Created migration batch $batch_id"

psql_cmd -v ON_ERROR_STOP=1 \
  -v batch_id="$batch_id" \
  -v from_time="$from_time" \
  -v to_time="$to_time" <<'SQL'
SELECT * FROM mqtt_migration.stage_legacy_mqtt(:'batch_id'::BIGINT, NULLIF(:'from_time', '')::TIMESTAMP, NULLIF(:'to_time', '')::TIMESTAMP);
SQL

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

echo
echo "After changing topic mappings, rerun scripts/migration-remap-report.sh $batch_id."
echo "Use scripts/migration-load.sh $batch_id once the mapping report is acceptable."
