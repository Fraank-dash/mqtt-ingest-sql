#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LC_ALL=C
export LC_ALL

psql_cmd() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" "$@"
  else
    psql "$@"
  fi
}

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required but was not found in PATH" >&2
  exit 1
fi

echo "Checking PostgreSQL connection..."
psql_cmd -v ON_ERROR_STOP=1 -At -c "SELECT 1;" >/dev/null

echo "Checking required TimescaleDB extensions are available..."
missing_extensions="$(
  psql_cmd -v ON_ERROR_STOP=1 -At -c "
    WITH required(name) AS (
      VALUES ('timescaledb'), ('timescaledb_toolkit')
    )
    SELECT COALESCE(string_agg(required.name, ', ' ORDER BY required.name), '')
    FROM required
    LEFT JOIN pg_available_extensions available
      ON available.name = required.name
    WHERE available.name IS NULL;
  "
)"

if [ -n "$missing_extensions" ]; then
  echo "Required extension(s) are not available on this server: $missing_extensions" >&2
  exit 1
fi

shopt -s nullglob
sql_files=("$ROOT_DIR"/[0-9][0-9]_*.sql)
shopt -u nullglob

if [ "${#sql_files[@]}" -eq 0 ]; then
  echo "No numbered SQL files found in $ROOT_DIR" >&2
  exit 1
fi

echo "Applying ${#sql_files[@]} SQL files..."
for sql_file in "${sql_files[@]}"; do
  echo "Applying $(basename "$sql_file")"
  psql_cmd -v ON_ERROR_STOP=1 -f "$sql_file"
done

echo "SQL bootstrap applied successfully."
