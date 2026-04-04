#!/usr/bin/env zsh
# S.P.Q.R. — Shared library for the Roman development workflow
# Source this file; do not execute directly.

# ── Roman Color Palette ────────────────────────────────────────────
typeset -g SPQR_GOLD='\033[38;2;255;215;0m'
typeset -g SPQR_CRIMSON='\033[38;2;220;20;60m'
typeset -g SPQR_MARBLE='\033[38;2;240;240;235m'
typeset -g SPQR_LAUREL='\033[38;2;85;170;85m'
typeset -g SPQR_BRONZE='\033[38;2;205;175;100m'
typeset -g SPQR_DIM='\033[2m'
typeset -g SPQR_BOLD='\033[1m'
typeset -g SPQR_RESET='\033[0m'

# ── Resolve SPQR Docker directory ─────────────────────────────────
# Always resolves to the dotfiles/docker/ directory regardless of
# where the scripts are invoked from.
typeset -g SPQR_DOCKER_DIR="${${(%):-%x}:A:h}/../docker"

# ── Theme Helpers ──────────────────────────────────────────────────

edictum() {
  printf "${SPQR_GOLD}${SPQR_BOLD}  EDICTVM \u25b8${SPQR_RESET} ${SPQR_GOLD}%s${SPQR_RESET}\n" "$*"
}

nota() {
  printf "${SPQR_DIM}           %s${SPQR_RESET}\n" "$*"
}

triumphus() {
  printf "${SPQR_LAUREL}${SPQR_BOLD}  \u263d TRIVMPHVS \u25b8${SPQR_RESET} ${SPQR_LAUREL}%s${SPQR_RESET}\n" "$*"
}

perfidia() {
  printf "${SPQR_CRIMSON}${SPQR_BOLD}  PERFIDIA!${SPQR_RESET} ${SPQR_CRIMSON}%s${SPQR_RESET}\n" "$*" >&2
  return 1
}

caveat() {
  printf "${SPQR_BRONZE}${SPQR_BOLD}  CAVEAT \u25b8${SPQR_RESET} ${SPQR_BRONZE}%s${SPQR_RESET}\n" "$*"
}

spqr_banner() {
  local script_name="${1:-S.P.Q.R.}"
  printf "\n"
  printf "${SPQR_GOLD}${SPQR_BOLD}"
  printf "  \u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510\n"
  printf "  \u2502           S \u00b7 P \u00b7 Q \u00b7 R                    \u2502\n"
  printf "  \u2502   Senatus Populusque Romanus               \u2502\n"
  printf "  \u2502                                            \u2502\n"
  printf "  \u2502   %-40s \u2502\n" "$script_name"
  printf "  \u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n"
  printf "${SPQR_RESET}\n"
}

# ── cmux Wrappers ─────────────────────────────────────────────────

spqr_create_workspace() {
  local dir="$1" name="$2"
  local ws_output
  ws_output="$(cmux new-workspace --command "cd $dir && exec $SHELL -l" 2>&1)" || {
    perfidia "Failed to create cmux workspace"
    return 1
  }
  local ws_id="${ws_output#OK }"
  if [[ -z "$ws_id" || "$ws_id" == "$ws_output" ]]; then
    perfidia "Unexpected cmux output: $ws_output"
    return 1
  fi
  cmux rename-workspace --workspace "$ws_id" "$name" >/dev/null 2>&1
  printf "%s" "$ws_id"
}

spqr_add_split() {
  local ws_id="$1" direction="${2:-right}"
  local split_output
  split_output="$(cmux new-split "$direction" --workspace "$ws_id" 2>&1)" || {
    perfidia "Failed to create split in workspace $ws_id"
    return 1
  }
  if [[ "$split_output" =~ (surface:[0-9]+) ]]; then
    printf "%s" "${match[1]}"
  else
    perfidia "Could not parse surface ref from: $split_output"
    return 1
  fi
}

spqr_send() {
  local ws_id="$1" surface="$2" cmd="$3"
  if [[ -n "$surface" ]]; then
    cmux send --workspace "$ws_id" --surface "$surface" "$cmd"
    cmux send-key --workspace "$ws_id" --surface "$surface" enter
  else
    cmux send --workspace "$ws_id" "$cmd"
    cmux send-key --workspace "$ws_id" enter
  fi
}

spqr_find_workspace() {
  local title="$1"
  local ws_json
  ws_json="$(cmux --json list-workspaces 2>/dev/null)" || return 1
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for ws in data.get('workspaces', []):
    if ws.get('title') == sys.argv[1]:
        print(ws['ref'])
        break
" "$title" <<< "$ws_json" 2>/dev/null
}

spqr_close_workspace() {
  local ws_ref="$1"
  [[ -z "$ws_ref" ]] && return 0
  cmux close-workspace --workspace "$ws_ref" 2>/dev/null
}

# ── Repo / Worktree Helpers ───────────────────────────────────────

spqr_detect_repo() {
  if [[ -n "${SPQR_REPO:-}" ]]; then
    printf "%s" "$SPQR_REPO"
    return
  fi
  git rev-parse --show-toplevel 2>/dev/null || {
    # If in a worktree, get the main repo
    local common_dir
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || {
      perfidia "Not in a git repository and SPQR_REPO is not set"
      return 1
    }
    (cd "$common_dir/.." && pwd)
  }
}

spqr_create_worktree() {
  local repo="$1" branch="$2"
  local worktree_dir="$repo/.worktrees/$branch"

  if [[ -d "$worktree_dir" ]]; then
    nota "Worktree already exists at $worktree_dir"
    printf "%s" "$worktree_dir"
    return 0
  fi

  mkdir -p "$repo/.worktrees"

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add "$worktree_dir" "$branch" >&2 || {
      perfidia "Failed to create worktree for existing branch $branch"
      return 1
    }
  else
    # Try to check out from remote tracking branch
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$repo" worktree add --track -b "$branch" "$worktree_dir" "origin/$branch" >&2 || {
        perfidia "Failed to create worktree tracking origin/$branch"
        return 1
      }
    else
      git -C "$repo" worktree add -b "$branch" "$worktree_dir" >&2 || {
        perfidia "Failed to create worktree with new branch $branch"
        return 1
      }
    fi
  fi

  printf "%s" "$worktree_dir"
}

spqr_link_deps() {
  local repo="$1" worktree="$2"
  for f in .envrc .env .direnv .venv node_modules CLAUDE.local.md .claude; do
    if [[ -e "$repo/$f" && ! -e "$worktree/$f" ]]; then
      ln -s "$repo/$f" "$worktree/$f"
    fi
  done
  if [[ -f "$worktree/.envrc" ]] && command -v direnv &>/dev/null; then
    direnv allow "$worktree" 2>/dev/null
  fi
}

# ── Linear API ────────────────────────────────────────────────────

spqr_query_linear() {
  local issue_id="$1"
  if [[ -z "$LINEAR_API_KEY" ]]; then
    caveat "LINEAR_API_KEY not set — skipping Linear query"
    return 1
  fi

  local query='query($id: String!) {
    issue(id: $id) {
      identifier
      title
      description
      branchName
      url
      state { name }
      parent { identifier title description }
      project { name description }
      labels { nodes { name } }
    }
  }'

  curl -sS --fail-with-body \
    -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $LINEAR_API_KEY" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({'query': sys.argv[1], 'variables': {'id': sys.argv[2]}}))
" "$query" "$issue_id")" 2>/dev/null || {
    caveat "Linear API query failed for $issue_id"
    return 1
  }
}

# ── Docker / Container Helpers ────────────────────────────────────

spqr_ensure_infra() {
  # Start Caddy + Postgres infrastructure if not already running
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^spqr-postgres$'; then
    return 0
  fi

  edictum "Starting S.P.Q.R. infrastructure (Postgres + Caddy)..."
  docker compose -f "$SPQR_DOCKER_DIR/docker-compose.infra.yml" up -d 2>&1 | while read -r line; do
    nota "$line"
  done

  # Wait for Postgres to be healthy
  local attempts=0
  while (( attempts < 30 )); do
    if docker exec spqr-postgres pg_isready -U spqr -q 2>/dev/null; then
      nota "Postgres ready"
      return 0
    fi
    sleep 1
    ((attempts++))
  done
  caveat "Postgres may not be ready yet — continuing anyway"
}

spqr_ensure_image() {
  # Build the agent image if it doesn't exist or if Dockerfile is newer
  local dockerfile="$SPQR_DOCKER_DIR/Dockerfile"
  local image_id

  image_id="$(docker images -q spqr-agent:latest 2>/dev/null)"

  if [[ -z "$image_id" ]]; then
    edictum "Building S.P.Q.R. agent image..."
    docker build -t spqr-agent:latest "$SPQR_DOCKER_DIR" 2>&1 | tail -5 | while read -r line; do
      nota "$line"
    done
  fi
}

spqr_ensure_project_image() {
  # If the project has a .spqr/Dockerfile, build a project-specific image
  local repo="$1" project_tag="$2"

  if [[ -f "$repo/.spqr/Dockerfile" ]]; then
    nota "Building project-specific image: spqr-agent:$project_tag..."
    docker build -t "spqr-agent:$project_tag" -f "$repo/.spqr/Dockerfile" "$repo/.spqr" 2>&1 | tail -3 | while read -r line; do
      nota "$line"
    done
    printf "spqr-agent:%s" "$project_tag"
  else
    printf "spqr-agent:latest"
  fi
}

spqr_container_name() {
  # Derive a container name from a branch name
  local branch="$1" prefix="${2:-spqr}"
  local safe="${branch//[^a-zA-Z0-9_-]/-}"
  printf "%s-%s" "$prefix" "$safe"
}

spqr_db_name() {
  # Derive a Postgres database name from a branch name
  local branch="$1"
  local safe="${branch//[^a-zA-Z0-9_]/_}"
  printf "spqr_%s" "$safe"
}

spqr_start_container() {
  # Start an agent container for a workspace
  # Usage: spqr_start_container <branch> <worktree_path> [<image>]
  local branch="$1" worktree="$2" image="${3:-spqr-agent:latest}"
  local container_name
  container_name="$(spqr_container_name "$branch")"
  local db_name
  db_name="$(spqr_db_name "$branch")"

  # Stop existing container if present
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
    nota "Removing existing container $container_name..."
    docker rm -f "$container_name" >/dev/null 2>&1
  fi

  # Collect env vars to pass through
  local env_args=()
  env_args+=(
    -e "DATABASE_URL=postgresql://spqr:spqr@spqr-postgres:5432/$db_name"
    -e "SPQR_DB_NAME=$db_name"
    -e "PGHOST=spqr-postgres"
    -e "PGPORT=5432"
    -e "PGUSER=spqr"
    -e "PGPASSWORD=spqr"
  )

  # Pass through ANTHROPIC_API_KEY if set
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_args+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")

  # Pass through project-specific env vars from .env if it exists in the worktree
  if [[ -f "$worktree/.env" ]]; then
    env_args+=(--env-file "$worktree/.env")
  fi

  docker run -d \
    --name "$container_name" \
    --network spqr \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    -v "$worktree":/workspace \
    -v "${HOME}/.claude:/home/agent/.claude:ro" \
    --tmpfs /tmp:exec \
    --tmpfs /var/tmp \
    "${env_args[@]}" \
    "$image" \
    sleep infinity >/dev/null 2>&1 || {
    perfidia "Failed to start container $container_name"
    return 1
  }

  printf "%s" "$container_name"
}

spqr_stop_container() {
  # Stop and remove an agent container + its database
  local branch="$1"
  local container_name
  container_name="$(spqr_container_name "$branch")"
  local db_name
  db_name="$(spqr_db_name "$branch")"

  # Stop container
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
    nota "Stopping container $container_name..."
    docker rm -f "$container_name" >/dev/null 2>&1
  fi

  # Drop the workspace database
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^spqr-postgres$'; then
    docker exec spqr-postgres \
      psql -U spqr -d postgres -c "DROP DATABASE IF EXISTS $db_name" >/dev/null 2>&1 && \
      nota "Dropped database $db_name" || true
  fi
}

spqr_exec() {
  # Execute a command inside an agent container (interactive)
  local container_name="$1"
  shift
  docker exec -it "$container_name" "$@"
}

# ── Caddy Site Management ─────────────────────────────────────────

spqr_register_site() {
  # Register a preview server hostname for a workspace
  # Usage: spqr_register_site <branch> <container_port>
  local branch="$1" port="${2:-5173}"
  local container_name
  container_name="$(spqr_container_name "$branch")"
  local slug="${branch//[^a-zA-Z0-9_-]/-}"
  local site_file="$SPQR_DOCKER_DIR/caddy/sites/${slug}.caddy"

  cat > "$site_file" <<EOF
http://${slug}.localhost:4000 {
    reverse_proxy ${container_name}:${port}
}
EOF

  # Reload Caddy config
  docker exec spqr-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null && \
    nota "Registered preview: http://${slug}.localhost:4000" || \
    caveat "Could not reload Caddy — preview may not work until next restart"
}

spqr_unregister_site() {
  # Remove a preview server hostname for a workspace
  local branch="$1"
  local slug="${branch//[^a-zA-Z0-9_-]/-}"
  local site_file="$SPQR_DOCKER_DIR/caddy/sites/${slug}.caddy"

  rm -f "$site_file" 2>/dev/null

  # Reload Caddy config
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^spqr-caddy$'; then
    docker exec spqr-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
  fi
}

spqr_slugify() {
  # Convert a string to a URL/branch-safe slug
  local input="$1"
  local slug="${(L)input}"          # lowercase
  slug="${slug//[^a-z0-9]/-}"       # replace non-alphanumeric with hyphens
  slug="${slug##-}"                  # strip leading hyphens
  slug="${slug%%-}"                  # strip trailing hyphens
  slug="${slug//--/-}"               # collapse double hyphens
  printf "%s" "$slug"
}
