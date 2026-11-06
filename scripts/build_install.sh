#!/usr/bin/env bash
# Combines all migrations into ONE file to paste into the Supabase SQL editor.
# (Test data is separate: dist/test_data.sql)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/dist"
{
  echo "-- SCI AI Operating Team — full install. Generated $(date -u +%Y-%m-%d). Run ONCE on a fresh project."
  echo "begin;"
  for f in "$ROOT"/supabase/migrations/*.sql; do echo; echo "-- >>> $(basename "$f")"; cat "$f"; done
  echo; echo "commit;"
} > "$ROOT/dist/install.sql"
cp "$ROOT/supabase/seed/test_data.sql" "$ROOT/dist/test_data.sql"
echo "wrote dist/install.sql and dist/test_data.sql"
