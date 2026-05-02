#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: DATABASE_URL=<db-url> $0 <result_export.xlsx> [importer options]" >&2
  exit 2
fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must point to the database containing mqtt_migration.topic_mapping." >&2
  exit 2
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

python3 "$SCRIPT_DIR/import-topic-mapping-xlsx.py" \
  "$1" \
  --database-url "$DATABASE_URL" \
  "${@:2}"
