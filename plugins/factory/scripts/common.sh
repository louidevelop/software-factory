#!/usr/bin/env bash
# common.sh — sourced by every scripts/cmd/*.sh. Not run directly.
# shellcheck source=../hooks/lib.sh
. "$FACTORY_PLUGIN/hooks/lib.sh"

say() { printf '\033[1;36m[factory]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[factory]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[factory]\033[0m %s\n' "$*" >&2
  exit 1
}

# The main checkout, even when run from inside a worktree.
factory_main_root() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}'
}

factory_repo_slug() {
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null
}

factory_base_branch() {
  local b
  b=$(factory_cfg '.run.baseBranch')
  printf '%s' "${b:-main}"
}

# Per-worktree run state lives inside the git dir, so it is never committed and never
# shared between worktrees.
factory_state_dir() {
  local d
  d="$(git rev-parse --git-dir)/factory"
  mkdir -p "$d"
  printf '%s' "$d"
}

factory_require() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing prerequisite: $t"
  done
}

factory_require_config() {
  [ -f "$(factory_config)" ] || die "no .factory/config.json in $(factory_root) — run the factory-bootstrap skill first"
}

# Ticket helpers --------------------------------------------------------------

# The checkout (main or a worktree) whose branch is ticket/<n>-…, so commands work from any
# directory of the project — the review subagents start in the project folder, not the worktree.
factory_ticket_worktree() {
  git worktree list --porcelain | awk -v want="refs/heads/ticket/$1-" '
    /^worktree / { path = substr($0, 10) }
    /^branch / && index($2, want) == 1 { print path; exit }
  '
}

ticket_json() {
  gh issue view "$1" --json number,title,body,state,labels,url
}

ticket_has_label() {
  gh issue view "$1" --json labels -q '.labels[].name' | grep -qx "$2"
}

# The body section under "## <name>" up to the next "## " heading.
markdown_section() {
  awk -v want="## $2" '
    $0 == want { on = 1; next }
    on && /^## / { exit }
    on { print }
  ' <<<"$1"
}

ticket_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//'
}

factory_block_ticket() {
  local n=$1 reason=$2
  gh issue edit "$n" --add-label blocked --remove-label in-progress >/dev/null 2>&1 ||
    gh issue edit "$n" --add-label blocked >/dev/null
  gh issue comment "$n" --body "**Blocked** (factory): $reason" >/dev/null
  warn "#$n blocked: $reason"
}
