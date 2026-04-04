#!/usr/bin/env zsh
# install.sh — Install S.P.Q.R. scripts into ~/bin/ and build Docker images
set -euo pipefail

SCRIPT_DIR="${${0:A}:h}"
source "$SCRIPT_DIR/lib/spqr.sh"

spqr_banner "Installation"

# ── Verify Prerequisites ─────────────────────────────────────────
edictum "Verifying prerequisites..."

local missing=()

for cmd in git python3 docker; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if (( ${#missing[@]} > 0 )); then
  perfidia "Missing required tools: ${missing[*]}"
  exit 1
fi

# Check Docker is running
if ! docker info &>/dev/null 2>&1; then
  perfidia "Docker is not running — start Docker and try again"
  exit 1
fi

# Optional tools
for cmd in cmux gh direnv claude; do
  if command -v "$cmd" &>/dev/null; then
    nota "$cmd ✓"
  else
    caveat "$cmd not found (optional — some features will be unavailable)"
  fi
done

if [[ -n "${LINEAR_API_KEY:-}" ]]; then
  nota "LINEAR_API_KEY ✓"
else
  caveat "LINEAR_API_KEY not set (Linear integration will be unavailable)"
fi

# ── Create ~/bin/ if needed ───────────────────────────────────────
if [[ ! -d "$HOME/bin" ]]; then
  mkdir -p "$HOME/bin"
  nota "Created ~/bin/"
fi

# ── Symlink Scripts ───────────────────────────────────────────────
edictum "Installing scripts to ~/bin/..."

for script in "$SCRIPT_DIR"/bin/*; do
  local name="${script:t}"
  local target="$HOME/bin/$name"

  chmod +x "$script"

  if [[ -L "$target" ]]; then
    # Already a symlink — update it
    rm "$target"
    ln -s "$script" "$target"
    nota "$name → updated"
  elif [[ -e "$target" ]]; then
    caveat "$name — file already exists at $target, skipping (remove it first)"
  else
    ln -s "$script" "$target"
    nota "$name → installed"
  fi
done

# ── Build Docker Image ───────────────────────────────────────────
edictum "Building S.P.Q.R. agent Docker image..."

docker build -t spqr-agent:latest "$SCRIPT_DIR/docker" 2>&1 | while read -r line; do
  nota "$line"
done

triumphus "Agent image built: spqr-agent:latest"

# ── Create Docker Network ────────────────────────────────────────
if ! docker network inspect spqr &>/dev/null 2>&1; then
  docker network create spqr >/dev/null 2>&1
  nota "Created Docker network: spqr"
else
  nota "Docker network spqr already exists"
fi

# ── Verify PATH ──────────────────────────────────────────────────
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
  caveat "~/bin/ is not in your PATH. Add this to your .zshrc:"
  nota '  export PATH="$HOME/bin:$PATH"'
fi

triumphus "S.P.Q.R. installation complete"
nota "Available commands: consul, senatus, proscribe, censor"
nota ""
nota "Infrastructure (Postgres + Caddy) starts automatically on first use."
nota "To start it manually: docker compose -f $SCRIPT_DIR/docker/docker-compose.infra.yml up -d"
