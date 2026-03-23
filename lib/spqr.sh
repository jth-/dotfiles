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

# ── Theme Helpers ──────────────────────────────────────────────────

edictum() {
  printf "${SPQR_GOLD}${SPQR_BOLD}  EDICTVM ▸${SPQR_RESET} ${SPQR_GOLD}%s${SPQR_RESET}\n" "$*"
}

nota() {
  printf "${SPQR_DIM}           %s${SPQR_RESET}\n" "$*"
}

triumphus() {
  printf "${SPQR_LAUREL}${SPQR_BOLD}  ☽ TRIVMPHVS ▸${SPQR_RESET} ${SPQR_LAUREL}%s${SPQR_RESET}\n" "$*"
}

perfidia() {
  printf "${SPQR_CRIMSON}${SPQR_BOLD}  PERFIDIA!${SPQR_RESET} ${SPQR_CRIMSON}%s${SPQR_RESET}\n" "$*" >&2
  return 1
}

caveat() {
  printf "${SPQR_BRONZE}${SPQR_BOLD}  CAVEAT ▸${SPQR_RESET} ${SPQR_BRONZE}%s${SPQR_RESET}\n" "$*"
}

spqr_banner() {
  local script_name="${1:-S.P.Q.R.}"
  printf "\n"
  printf "${SPQR_GOLD}${SPQR_BOLD}"
  printf "  ┌────────────────────────────────────────────┐\n"
  printf "  │           S · P · Q · R                    │\n"
  printf "  │   Senatus Populusque Romanus               │\n"
  printf "  │                                            │\n"
  printf "  │   %-40s │\n" "$script_name"
  printf "  └────────────────────────────────────────────┘\n"
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
