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

spqr_worktree_root() {
  # Central worktree directory, outside of the project repo.
  # Structure: ~/.spqr/worktrees/<repo-basename>/
  local repo="$1"
  local repo_name="${repo:t}"  # basename
  printf "%s" "${HOME}/.spqr/worktrees/${repo_name}"
}

spqr_worktree_dir() {
  # Full path for a specific branch's worktree
  local repo="$1" branch="$2"
  printf "%s/%s" "$(spqr_worktree_root "$repo")" "$branch"
}

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
  local worktree_dir
  worktree_dir="$(spqr_worktree_dir "$repo" "$branch")"

  if [[ -d "$worktree_dir" ]]; then
    nota "Worktree already exists at $worktree_dir"
    printf "%s" "$worktree_dir"
    return 0
  fi

  mkdir -p "$(spqr_worktree_root "$repo")"

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
      [[ "$already" == true ]] && continue
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
      break
    fi
    sleep 1
    ((attempts++))
  done
  (( attempts >= 30 )) && caveat "Postgres may not be ready yet — continuing anyway"

  # Wait for Caddy to be responsive
  attempts=0
  while (( attempts < 15 )); do
    if docker exec spqr-caddy caddy version >/dev/null 2>&1; then
      nota "Caddy ready"
      return 0
    fi
    sleep 1
    ((attempts++))
  done
  caveat "Caddy may not be ready yet — preview sites may need manual reload"
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
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$container_name"; then
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

  # Check for a DB template configuration
  # .spqr/template — single line containing the template database name
  local repo_root
  repo_root="$(cd "$worktree" && git rev-parse --show-toplevel 2>/dev/null || echo "$worktree")"
  local template_name=""
  for tf in "$worktree/.spqr/template" "$repo_root/.spqr/template"; do
    if [[ -f "$tf" ]]; then
      template_name="$(head -1 "$tf" | tr -d '[:space:]')"
      break
    fi
  done
  [[ -n "$template_name" ]] && env_args+=(-e "SPQR_DB_TEMPLATE=$template_name")

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
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$container_name"; then
    nota "Stopping container $container_name..."
    docker rm -f "$container_name" >/dev/null 2>&1
  fi

  # Drop the workspace database
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^spqr-postgres$'; then
    docker exec spqr-postgres \
      psql -U spqr -d postgres -c "DROP DATABASE IF EXISTS \"$db_name\"" >/dev/null 2>&1 && \
      nota "Dropped database $db_name" || true
  fi
}

spqr_exec() {
  # Execute a command inside an agent container (interactive)
  local container_name="$1"
  shift
  docker exec -it "$container_name" "$@"
}

# ── Database Template Management ─────────────────────────────────

spqr_db_template() {
  # Create or refresh a Postgres template database.
  #
  # Usage:
  #   spqr_db_template create <name> <dump_file>   — load a pg_dump into a template
  #   spqr_db_template create <name> --from <dburl> — copy from an existing database
  #   spqr_db_template use <name>                   — set template for current project
  #   spqr_db_template unuse                        — unset template for current project
  #   spqr_db_template list                         — list available templates
  #   spqr_db_template drop <name>                  — remove a template
  #
  # Templates are regular databases in the spqr-postgres container that
  # the entrypoint uses via CREATE DATABASE ... TEMPLATE.

  local subcmd="${1:-list}"
  shift 2>/dev/null || true

  spqr_ensure_infra

  local pg_exec="docker exec spqr-postgres"
  local psql_cmd="$pg_exec psql -U spqr -d postgres"

  case "$subcmd" in
    create)
      local name="${1:?Template name required}"
      shift

      # Drop existing template to allow refresh
      $psql_cmd -c "DROP DATABASE IF EXISTS \"$name\"" >/dev/null 2>&1
      $psql_cmd -c "CREATE DATABASE \"$name\"" >/dev/null 2>&1 || {
        perfidia "Failed to create template database $name"
        return 1
      }

      if [[ "${1:-}" == "--from" ]]; then
        local source_url="${2:?Source database URL required}"
        nota "Dumping from $source_url into template $name..."
        pg_dump --no-owner --no-privileges "$source_url" | \
          $pg_exec psql -U spqr -d "$name" >/dev/null 2>&1 && \
          triumphus "Template $name created from remote database" || {
          perfidia "Failed to load dump into template $name"
          return 1
        }
      elif [[ -f "${1:-}" ]]; then
        local dump_file="$1"
        nota "Loading $dump_file into template $name..."
        cat "$dump_file" | $pg_exec psql -U spqr -d "$name" >/dev/null 2>&1 && \
          triumphus "Template $name created from $dump_file" || {
          perfidia "Failed to load $dump_file into template $name"
          return 1
        }
      else
        triumphus "Empty template $name created"
        nota "Load data with: pg_dump ... | docker exec -i spqr-postgres psql -U spqr -d $name"
      fi

      # Mark as template so Postgres disallows connections by default
      $psql_cmd -c "ALTER DATABASE \"$name\" IS_TEMPLATE = true" >/dev/null 2>&1

      # Offer to link to current project
      local repo
      repo="$(spqr_detect_repo 2>/dev/null)" || true
      if [[ -n "$repo" ]]; then
        printf "${SPQR_BRONZE}  Use template '$name' for $(basename "$repo")? [Y/n] ${SPQR_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Nn]$ ]]; then
          mkdir -p "$repo/.spqr"
          printf "%s\n" "$name" > "$repo/.spqr/template"
          triumphus "Template $name linked to $(basename "$repo")"
        fi
      fi
      ;;

    list)
      edictum "Available templates:"
      $pg_exec psql -U spqr -d postgres \
        -c "SELECT datname AS template, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate = true AND datname NOT LIKE 'template%'" \
        --no-align --tuples-only 2>/dev/null | while IFS='|' read -r name size; do
        nota "$name ($size)"
      done
      ;;

    use)
      local name="${1:-}"
      local repo
      repo="$(spqr_detect_repo 2>/dev/null)" || {
        perfidia "Not in a git repository — cd into a project first"
        return 1
      }

      # If no name given, show available templates in fzf
      if [[ -z "$name" ]]; then
        local templates
        templates="$($pg_exec psql -U spqr -d postgres \
          -c "SELECT datname || E'\t' || pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = true AND datname NOT LIKE 'template%'" \
          --no-align --tuples-only 2>/dev/null)"

        if [[ -z "$templates" ]]; then
          perfidia "No templates available — create one first with: spqr template create <name>"
          return 1
        fi

        if command -v fzf &>/dev/null; then
          local selection
          selection="$(printf "%s" "$templates" | fzf \
            --header="Select a template for $(basename "$repo")" \
            --prompt="Template \u25b8 " \
            --delimiter=$'\t' \
            --with-nth=1,2 \
            --no-multi \
            ${(z)$(spqr_fzf_theme)})" || {
            nota "Selection cancelled"
            return 0
          }
          name="${selection%%$'\t'*}"
        else
          edictum "Available templates:"
          printf "%s\n" "$templates" | while IFS=$'\t' read -r tname tsize; do
            nota "$tname ($tsize)"
          done
          printf "${SPQR_GOLD}${SPQR_BOLD}  Template name: ${SPQR_RESET}"
          read -r name
          [[ -z "$name" ]] && return 0
        fi
      fi

      mkdir -p "$repo/.spqr"
      printf "%s\n" "$name" > "$repo/.spqr/template"
      triumphus "Template $name linked to $(basename "$repo")"
      nota "New workspaces will clone this template for their database"
      ;;

    unuse)
      local repo
      repo="$(spqr_detect_repo 2>/dev/null)" || {
        perfidia "Not in a git repository — cd into a project first"
        return 1
      }
      if [[ -f "$repo/.spqr/template" ]]; then
        local old_name
        old_name="$(head -1 "$repo/.spqr/template" | tr -d '[:space:]')"
        rm -f "$repo/.spqr/template"
        triumphus "Unlinked template $old_name from $(basename "$repo")"
        nota "New workspaces will use empty databases (+ db/seed.sql if present)"
      else
        nota "No template configured for $(basename "$repo")"
      fi
      ;;

    status)
      local repo
      repo="$(spqr_detect_repo 2>/dev/null)" || {
        perfidia "Not in a git repository — cd into a project first"
        return 1
      }
      if [[ -f "$repo/.spqr/template" ]]; then
        local current_name
        current_name="$(head -1 "$repo/.spqr/template" | tr -d '[:space:]')"
        edictum "$(basename "$repo") uses template: $current_name"
      else
        nota "No template configured for $(basename "$repo")"
      fi
      ;;

    drop)
      local name="${1:?Template name required}"
      # Un-mark as template first (required before DROP)
      $psql_cmd -c "ALTER DATABASE \"$name\" IS_TEMPLATE = false" >/dev/null 2>&1
      $psql_cmd -c "DROP DATABASE IF EXISTS \"$name\"" >/dev/null 2>&1 && \
        triumphus "Template $name dropped" || \
        perfidia "Failed to drop template $name"
      ;;

    *)
      perfidia "Unknown subcommand: $subcmd (use create, list, use, unuse, status, or drop)"
      return 1
      ;;
  esac
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

  # Reload Caddy config (retry up to 3 times if Caddy isn't ready yet)
  local reload_ok=false
  for _attempt in 1 2 3; do
    if docker exec spqr-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
      reload_ok=true
      break
    fi
    sleep 1
  done
  if [[ "$reload_ok" == true ]]; then
    nota "Registered preview: http://${slug}.localhost:4000"
  else
    caveat "Could not reload Caddy — preview may not work until next restart"
  fi
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

spqr_cleanup_orphans() {
  # Find and stop containers that have no corresponding cmux workspace.
  # Returns the number of orphans cleaned up.
  local cleaned=0

  # Get active workspace branches from cmux
  local ws_branches=()
  if command -v cmux &>/dev/null; then
    local ws_json
    ws_json="$(cmux --json list-workspaces 2>/dev/null)" || true
    if [[ -n "$ws_json" ]]; then
      local branches_raw
      branches_raw="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for ws in data.get('workspaces', []):
    title = ws.get('title', '')
    for prefix in ('SPQR:', 'CENSOR:'):
        if title.startswith(prefix):
            print(title[len(prefix):])
            break
" <<< "$ws_json" 2>/dev/null)"
      while IFS= read -r b; do
        [[ -n "$b" ]] && ws_branches+=("$b")
      done <<< "$branches_raw"
    fi
  fi

  # Check all spqr-* containers
  local containers
  containers="$(docker ps --filter 'name=spqr-' --format '{{.Names}}' 2>/dev/null)" || return 0
  [[ -z "$containers" ]] && return 0

  while IFS= read -r cname; do
    # Skip infrastructure containers
    [[ "$cname" == "spqr-postgres" || "$cname" == "spqr-caddy" ]] && continue

    # Check if any workspace maps to this container
    local has_workspace=false
    for wb in "${ws_branches[@]}"; do
      if [[ "$(spqr_container_name "$wb")" == "$cname" ]]; then
        has_workspace=true
        break
      fi
      # Also check review- prefix
      if [[ "$(spqr_container_name "review-$wb")" == "$cname" ]]; then
        has_workspace=true
        break
      fi
    done

    if [[ "$has_workspace" == false ]]; then
      local branch="${cname#spqr-}"
      nota "Orphan container: $cname (no matching workspace)"
      if [[ "${1:-}" == "--auto" ]]; then
        spqr_stop_container "$branch"
        spqr_unregister_site "$branch"
        ((cleaned++))
      else
        printf "${SPQR_BRONZE}  Stop orphan container $cname? [Y/n] ${SPQR_RESET}"
        read -r response
        if [[ ! "$response" =~ ^[Nn]$ ]]; then
          spqr_stop_container "$branch"
          spqr_unregister_site "$branch"
          ((cleaned++))
        fi
      fi
    fi
  done <<< "$containers"

  return 0
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
# Usage: zsh /path/to/spqr.sh --fn <function_name> [args...]
#
# When invoked this way (not sourced), the file is executed as a script.
# All functions above are defined, then the requested function is called.
# Environment variables (LINEAR_API_KEY, etc.) must be exported by the
# caller for them to propagate into this subshell.
if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" && "${1:-}" == "--fn" ]]; then
  shift
  "$@"
fi
