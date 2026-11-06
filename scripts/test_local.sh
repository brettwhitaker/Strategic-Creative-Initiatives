#!/usr/bin/env bash
# Spins up a throwaway local Postgres, applies all migrations + test seed,
# then runs the safety test suite. Never touches your real Supabase project.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
TMP="$(mktemp -d)"
PORT="${PORT:-55432}"
trap '"$PGBIN/pg_ctl" -D "$TMP/data" stop -m fast >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$TMP/data" -o "-p $PORT -k $TMP" -l "$TMP/log" start >/dev/null
PSQL=(psql -h "$TMP" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -t)

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "applying $(basename "$f")"; "${PSQL[@]}" -f "$f"
done
echo "applying seed/test_data.sql"; "${PSQL[@]}" -f "$ROOT/supabase/seed/test_data.sql"
echo; echo "running safety tests"
"${PSQL[@]}" -f "$ROOT/supabase/tests/safety_tests.sql" 2>&1 | sed 's/^psql:[^:]*:[0-9]*: NOTICE:  //'
