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

spqr_query_linear_graphql() {
  # Generalized Linear GraphQL caller
  # Usage: spqr_query_linear_graphql <query> <variables_json>
  local query="$1" variables="${2:-{\}}"
  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    caveat "LINEAR_API_KEY not set — skipping Linear query"
    return 1
  fi

  curl -sS --fail-with-body \
    -X POST https://api.linear.app/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: $LINEAR_API_KEY" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({'query': sys.argv[1], 'variables': json.loads(sys.argv[2])}))
" "$query" "$variables")" 2>/dev/null || {
    return 1
  }
}

spqr_query_linear() {
  local issue_id="$1"
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
  spqr_query_linear_graphql "$query" "{\"id\": \"$issue_id\"}" || {
    caveat "Linear API query failed for $issue_id"
    return 1
  }
}

# ── fzf / Interactive Helpers ─────────────────────────────────────

spqr_require_fzf() {
  if ! command -v fzf &>/dev/null; then
    caveat "fzf not found — interactive selection unavailable"
    return 1
  fi
}

spqr_fzf_theme() {
  # Return fzf color arguments matching the Roman palette
  printf "%s" "--color=fg:#f0f0eb,hl:#ffd700,fg+:#f0f0eb,bg+:#2a2a2a,hl+:#ffd700,info:#55aa55,prompt:#ffd700,pointer:#dc143c,marker:#dc143c,header:#cdaf64,border:#cdaf64 --border=rounded --margin=1,2"
}

spqr_linear_viewer_id() {
  # Get the current Linear user's ID (cached for the session)
  if [[ -n "${SPQR_LINEAR_VIEWER_ID:-}" ]]; then
    printf "%s" "$SPQR_LINEAR_VIEWER_ID"
    return
  fi

  local result
  result="$(spqr_query_linear_graphql '{ viewer { id } }' '{}')" || return 1

  SPQR_LINEAR_VIEWER_ID="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
print(data.get('data', {}).get('viewer', {}).get('id', ''))
" <<< "$result")"

  if [[ -z "$SPQR_LINEAR_VIEWER_ID" ]]; then
    return 1
  fi
  typeset -g SPQR_LINEAR_VIEWER_ID
  printf "%s" "$SPQR_LINEAR_VIEWER_ID"
}

spqr_linear_my_issues() {
  # Fetch ~25 open issues assigned to the current user
  # Output: TSV lines of IDENTIFIER<tab>STATE<tab>TITLE
  local viewer_id
  viewer_id="$(spqr_linear_viewer_id)" || return 1

  local query='query($userId: ID!) {
    issues(
      filter: {
        assignee: { id: { eq: $userId } }
        state: { type: { nin: ["canceled", "completed"] } }
      }
      orderBy: updatedAt
      first: 25
    ) {
      nodes {
        identifier
        title
        state { name }
      }
    }
  }'

  local result
  result="$(spqr_query_linear_graphql "$query" "{\"userId\": \"$viewer_id\"}")" || return 1

  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for node in data.get('data', {}).get('issues', {}).get('nodes', []):
    ident = node.get('identifier', '')
    title = node.get('title', '')
    state = node.get('state', {}).get('name', '')
    print(f'{ident}\t{state}\t{title}')
" <<< "$result"
}

spqr_linear_search() {
  # Full-text search across Linear issues
  # Usage: spqr_linear_search <query>
  local search_term="$1"
  if [[ -z "$search_term" ]]; then
    spqr_linear_my_issues
    return
  fi

  local query='query($q: String!) {
    searchIssues(query: $q, first: 25) {
      nodes {
        identifier
        title
        state { name }
      }
    }
  }'

  local result
  result="$(spqr_query_linear_graphql "$query" "{\"q\": \"$search_term\"}")" || return 1

  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for node in data.get('data', {}).get('searchIssues', {}).get('nodes', []):
    ident = node.get('identifier', '')
    title = node.get('title', '')
    state = node.get('state', {}).get('name', '')
    print(f'{ident}\t{state}\t{title}')
" <<< "$result"
}

spqr_linear_issue_preview() {
  # Format a Linear issue for fzf preview pane
  # Usage: spqr_linear_issue_preview <IDENTIFIER>
  local identifier="$1"
  local result
  result="$(spqr_query_linear "$identifier" 2>/dev/null)" || {
    echo "Could not fetch issue $identifier"
    return
  }

  python3 -c "
import json, sys, textwrap
data = json.loads(sys.stdin.read())
issue = data.get('data', {}).get('issue', {})
if not issue:
    print('Issue not found')
    sys.exit()

ident = issue.get('identifier', '')
title = issue.get('title', '')
state = issue.get('state', {}).get('name', '')
labels = ', '.join(l['name'] for l in issue.get('labels', {}).get('nodes', []))
desc = issue.get('description', '') or ''
branch = issue.get('branchName', '') or ''
url = issue.get('url', '') or ''
parent = issue.get('parent')
project = issue.get('project')

print(f'{ident}: {title}')
print(f'State: {state}', end='')
if labels:
    print(f'    Labels: {labels}', end='')
print()
if branch:
    print(f'Branch: {branch}')
if url:
    print(f'URL: {url}')
if parent:
    print(f'Parent: {parent.get(\"identifier\", \"\")}: {parent.get(\"title\", \"\")}')
if project:
    print(f'Project: {project.get(\"name\", \"\")}')
print('─' * 50)
if desc:
    print(textwrap.fill(desc, width=70))
else:
    print('(no description)')
" <<< "$result"
}

spqr_list_workspaces() {
  # List active SPQR workspaces for proscribe interactive mode
  # Merges cmux workspaces (SPQR:/CENSOR:) with orphan spqr-* containers
  # Output: TSV lines of BRANCH<tab>TYPE<tab>STATUS
  local seen=()

  # cmux workspaces
  if command -v cmux &>/dev/null; then
    local ws_json
    ws_json="$(cmux --json list-workspaces 2>/dev/null)" || true
    if [[ -n "$ws_json" ]]; then
      local cmux_lines
      cmux_lines="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for ws in data.get('workspaces', []):
    title = ws.get('title', '')
    for prefix in ('SPQR:', 'CENSOR:'):
        if title.startswith(prefix):
            branch = title[len(prefix):]
            kind = prefix.rstrip(':')
            print(f'{branch}\t{kind}\tWorkspace active')
            break
" <<< "$ws_json" 2>/dev/null)"
      if [[ -n "$cmux_lines" ]]; then
        printf "%s\n" "$cmux_lines"
        while IFS=$'\t' read -r b _rest; do
          seen+=("$b")
        done <<< "$cmux_lines"
      fi
    fi
  fi

  # Orphan Docker containers (not in cmux)
  local containers
  containers="$(docker ps --filter 'name=spqr-' --format '{{.Names}}\t{{.Status}}' 2>/dev/null)" || true
  if [[ -n "$containers" ]]; then
    while IFS=$'\t' read -r cname status; do
      # Skip infrastructure containers
      [[ "$cname" == "spqr-postgres" || "$cname" == "spqr-caddy" ]] && continue
      # Extract branch from container name (strip spqr- prefix)
      local branch="${cname#spqr-}"
      # Skip if already seen from cmux
      local already=false
      for s in "${seen[@]}"; do
        [[ "$(spqr_container_name "$s")" == "$cname" ]] && already=true && break
      done
      $already && continue
      printf "%s\tContainer\t%s\n" "$branch" "$status"
    done <<< "$containers"
  fi
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

  # Pass through ANTHROPIC_API_KEY (required for Claude)
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_args+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")

  # ── Env / Secrets Model ──────────────────────────────────────────
  # .env.spqr  — safe config vars (PORT, NODE_ENV, etc.) passed as env-file
  # .spqr/secrets — allowlist of host env var names to pass through
  # .env is NOT passed automatically (may contain production secrets)

  # Safe config vars
  local repo_root
  repo_root="$(cd "$worktree" && git rev-parse --show-toplevel 2>/dev/null || echo "$worktree")"
  for env_file in "$worktree/.env.spqr" "$repo_root/.env.spqr"; do
    if [[ -f "$env_file" ]]; then
      env_args+=(--env-file "$env_file")
      break
    fi
  done

  # Allowlisted secrets from host environment
  local secrets_file=""
  for sf in "$worktree/.spqr/secrets" "$repo_root/.spqr/secrets"; do
    [[ -f "$sf" ]] && secrets_file="$sf" && break
  done
  if [[ -n "$secrets_file" ]]; then
    while IFS= read -r var_name || [[ -n "$var_name" ]]; do
      # Skip comments and blank lines
      [[ "$var_name" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${var_name// }" ]] && continue
      var_name="${var_name// }"
      if [[ -n "${(P)var_name:-}" ]]; then
        env_args+=(-e "$var_name=${(P)var_name}")
      fi
    done < "$secrets_file"
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

# ── Direct Invocation Dispatch ────────────────────────────────────
# Allows fzf --bind reload(...) to call library functions in a subshell.
# Usage: source spqr.sh --fn <function_name> [args...]
if [[ "${1:-}" == "--fn" ]]; then
  shift
  "$@"
fi
