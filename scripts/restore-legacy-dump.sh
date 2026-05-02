#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: DATABASE_URL=<restore-db-url> ./scripts/restore-legacy-dump.sh <dump.sql>

Restores a legacy SQL dump through the database identified by DATABASE_URL.
For pg_dumpall/cluster dumps that contain CREATE DATABASE and \connect lines,
DATABASE_URL should point at a maintenance database such as postgres.

Set RESET_LEGACY_RESTORE=1 to drop partially restored legacy databases/roles
before restoring again.
EOF
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

dump_path="$1"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must point to the restore database." >&2
  usage
  exit 2
fi

if [ ! -f "$dump_path" ]; then
  echo "Dump file not found: $dump_path" >&2
  exit 2
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required but was not found in PATH" >&2
  exit 1
fi

echo "Restoring $dump_path into DATABASE_URL..."
if [ "${RESET_LEGACY_RESTORE:-}" = "1" ]; then
  echo "Dropping previous legacy restore objects..."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS staging_mqtt;"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS tsdb;"
  if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "SELECT 1 FROM pg_roles WHERE rolname = 'tsdb_user';" | grep -q 1; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -c "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template0' ORDER BY datname;" |
      while IFS= read -r database_name; do
        echo "Dropping objects owned by tsdb_user in database $database_name..."
        psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v database_name="$database_name" <<'SQL'
\connect :database_name
DROP OWNED BY tsdb_user CASCADE;
SQL
      done
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS tsdb_user;"
  fi
fi

if grep -q '^CREATE DATABASE ' "$dump_path" || grep -q '^\\connect ' "$dump_path"; then
  echo "Detected a cluster-style dump. DATABASE_URL should point at a maintenance database, not the target database."
  sanitized_dump="$(mktemp "${TMPDIR:-/tmp}/legacy-dump.XXXXXX.sql")"
  trap 'rm -f "$sanitized_dump"' EXIT
  sed \
    -e '/^GRANT .* GRANTED BY /d' \
    -e '/^SET transaction_timeout = /d' \
    "$dump_path" \
    | awk '
      /^COPY _timescaledb_(catalog|config|internal)\./ {
        skip_copy = 1
        next
      }
      skip_copy && /^\\\.$/ {
        skip_copy = 0
        next
      }
      skip_copy {
        next
      }
      skip_stmt {
        if ($0 ~ /;[[:space:]]*$/) {
          skip_stmt = 0
        }
        next
      }
      /_timescaledb_(catalog|config|internal)\./ &&
        /^(CREATE|ALTER|DROP|COMMENT|GRANT|REVOKE|SELECT pg_catalog\.setval)/ {
        if ($0 !~ /;[[:space:]]*$/) {
          skip_stmt = 1
        }
        next
      }
      /_timescaledb_functions\./ &&
        /^(CREATE|ALTER|DROP|COMMENT|GRANT|REVOKE|SELECT|CREATE TRIGGER)/ {
        if ($0 !~ /;[[:space:]]*$/) {
          skip_stmt = 1
        }
        next
      }
      !skip_copy {
        print
      }
    ' > "$sanitized_dump"
  echo "Filtered pg_dumpall role-membership GRANTED BY lines, PostgreSQL 17-only transaction_timeout settings, and TimescaleDB internal statements/triggers for local restore compatibility."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$sanitized_dump"
else
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$dump_path"
fi
echo "Restore completed."
