#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERIFY_SQL="$ROOT_DIR/docs/sql/verify-postgres-bootstrap.sql"

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

if [ ! -f "$VERIFY_SQL" ]; then
  echo "Verification SQL was not found: $VERIFY_SQL" >&2
  exit 1
fi

failures="$(
  psql_cmd -v ON_ERROR_STOP=1 -At -f "$VERIFY_SQL"
)"

if [ -n "$failures" ]; then
  echo "PostgreSQL bootstrap verification failed." >&2
  echo "$failures" >&2
  exit 1
fi

echo "PostgreSQL bootstrap verification passed."
