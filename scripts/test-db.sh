#!/usr/bin/env bash
# Uji migrasi + alur kritis di PostgreSQL lokal (16+), tanpa Supabase.
# Pemakaian: PGHOST=/tmp PGUSER=postgres ./scripts/test-db.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="${TEST_DB:-sayspack_test}"
psql -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" -c "create database $DB"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$DIR/supabase/tests/00_supabase_stub.sql"
for f in "$DIR"/supabase/migrations/2026102200000{1,2,3}_*.sql; do   # migrasi 4 (storage) khusus Supabase
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done
psql -v ON_ERROR_STOP=1 -q -t -A -d "$DB" -f "$DIR/supabase/tests/01_critical_flows.sql" 2>&1 | grep -E "ok|LOLOS|GAGAL|ERROR|^[0-9]+\." || true
