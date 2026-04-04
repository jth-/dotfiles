#!/usr/bin/env bash
# S.P.Q.R. Agent Container Entrypoint
# Bootstraps dependencies, database, and hands off to CMD.
set -euo pipefail

# ── Dependency Installation ──────────────────────────────────────
if [[ -d /workspace ]]; then
  cd /workspace

  # Node (prefer npm ci for lockfile-based installs)
  if [[ -f package-lock.json && ! -d node_modules ]]; then
    echo "[spqr] Installing Node dependencies (npm ci)..."
    npm ci --no-audit --no-fund 2>&1 | tail -1 || \
      echo "[spqr] Warning: npm ci failed"
  elif [[ -f package.json && ! -d node_modules ]]; then
    echo "[spqr] Installing Node dependencies (npm install)..."
    npm install --no-audit --no-fund 2>&1 | tail -1 || \
      echo "[spqr] Warning: npm install failed"
  fi

  # Python (uv preferred, pip as fallback)
  if [[ -f pyproject.toml && -f uv.lock && ! -d .venv ]]; then
    if command -v uv &>/dev/null; then
      echo "[spqr] Installing Python dependencies (uv sync)..."
      uv sync 2>&1 | tail -1 || \
        echo "[spqr] Warning: uv sync failed"
    elif command -v pip &>/dev/null; then
      echo "[spqr] Installing Python dependencies (pip)..."
      python3 -m venv .venv && .venv/bin/pip install -e . 2>&1 | tail -1 || \
        echo "[spqr] Warning: pip install failed"
    fi
  elif [[ -f requirements.txt && ! -d .venv ]]; then
    echo "[spqr] Installing Python dependencies (requirements.txt)..."
    python3 -m venv .venv && .venv/bin/pip install -r requirements.txt 2>&1 | tail -1 || \
      echo "[spqr] Warning: pip install failed"
  fi
fi

# ── Database Bootstrap ───────────────────────────────────────────
if [[ -n "${DATABASE_URL:-}" && -n "${SPQR_DB_NAME:-}" ]]; then
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

  # Run seed/migration scripts if the project provides them
  if [[ -f /workspace/db/seed.sql ]]; then
    psql "$DATABASE_URL" -f /workspace/db/seed.sql 2>/dev/null && \
      echo "[spqr] Ran db/seed.sql" || \
      echo "[spqr] Warning: db/seed.sql failed"
  fi
fi

exec "$@"
