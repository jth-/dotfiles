#!/usr/bin/env bash
# S.P.Q.R. Agent Container Entrypoint
# Bootstraps the workspace database and hands off to CMD.
set -euo pipefail

# ── Database Bootstrap ───────────────────────────────────────────
if [[ -n "${DATABASE_URL:-}" && -n "${SPQR_DB_NAME:-}" ]]; then
  # Parse host/port from the infrastructure Postgres URL
  PG_HOST="${PGHOST:-postgres}"
  PG_PORT="${PGPORT:-5432}"
  PG_USER="${PGUSER:-spqr}"

  # Wait for Postgres to be ready (up to 30s)
  for i in $(seq 1 30); do
    if pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -q 2>/dev/null; then
      break
    fi
    sleep 1
  done

  # Create the workspace database if it doesn't exist
  if psql "postgresql://${PG_USER}:${PGPASSWORD:-spqr}@${PG_HOST}:${PG_PORT}/postgres" \
       -tc "SELECT 1 FROM pg_database WHERE datname = '${SPQR_DB_NAME}'" 2>/dev/null | grep -q 1; then
    echo "[spqr] Database ${SPQR_DB_NAME} already exists"
  else
    createdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" "$SPQR_DB_NAME" 2>/dev/null && \
      echo "[spqr] Created database ${SPQR_DB_NAME}" || \
      echo "[spqr] Warning: Could not create database ${SPQR_DB_NAME}"
  fi

  # Run seed script if the project provides one
  if [[ -f /workspace/db/seed.sql ]]; then
    psql "$DATABASE_URL" -f /workspace/db/seed.sql 2>/dev/null && \
      echo "[spqr] Ran db/seed.sql" || \
      echo "[spqr] Warning: db/seed.sql failed"
  fi
fi

exec "$@"
