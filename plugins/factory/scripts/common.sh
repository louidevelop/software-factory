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

# GitHub --------------------------------------------------------------------
# Every GitHub call goes through REST (`gh api`). Claude's cloud sessions reach GitHub through a
# proxy that answers every GraphQL call with 403, and `gh issue`, `gh pr`, `gh repo view` and
# `gh label` all use GraphQL.

# owner/repo, read from the origin remote (no API call): git@github.com:o/r.git,
# https://github.com/o/r(.git), and the cloud proxy's http://…/git/o/r all end in o/r.
factory_repo_slug() {
  local url slug
  url=$(git remote get-url origin 2>/dev/null) || url=$(git remote get-url "$(git remote | head -n1)" 2>/dev/null) || return 1
  url=${url%/}
  url=${url%.git}
  slug=$(sed -E 's#^.*[:/]([^/:]+/[^/:]+)$#\1#' <<<"$url")
  [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s' "$slug"
}

# factory_api <path under repos/owner/repo/> [gh api args...]
factory_api() {
  local slug
  slug=$(factory_repo_slug) || {
    echo "factory: no GitHub remote for $(pwd)" >&2
    return 1
  }
  gh api "repos/$slug/$1" "${@:2}"
}

# A paginated list endpoint as one JSON array (each page is its own array on stdout).
factory_api_list() {
  local out
  out=$(factory_api "$@" --paginate) || return 1
  jq -s 'add // []' <<<"$out"
}

factory_label_add() { factory_api "issues/$1/labels" -f "labels[]=$2" >/dev/null; }
# Removing a label the issue does not have is a 404; that is fine.
factory_label_remove() { factory_api "issues/$1/labels/$2" -X DELETE >/dev/null 2>&1 || true; }
factory_comment() { factory_api "issues/$1/comments" -f body="$2" >/dev/null; }

# factory_pr_create <base> <head> <title> <body> — prints the PR's URL.
factory_pr_create() {
  factory_api pulls -f base="$1" -f head="$2" -f title="$3" -f body="$4" -q .html_url
}

# The open PR whose head is <branch> in this repo, if any.
factory_open_pr() {
  local slug
  slug=$(factory_repo_slug) || return 1
  factory_api "pulls?state=open&head=${slug%%/*}:$1" -q '.[0].number // empty'
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

# The issue as REST returns it, with `.comments` replaced by the comments themselves: the owner
# answers a blocked ticket's question in a comment, so a ticket read without them is incomplete.
ticket_json() {
  local issue comments
  issue=$(factory_api "issues/$1") || return 1
  comments=$(factory_api_list "issues/$1/comments?per_page=100") || return 1
  jq -n --argjson i "$issue" --argjson c "$comments" \
    '$i + {comments: [$c[] | {author: .user.login, created_at, body}]}'
}

ticket_has_label() {
  local labels
  labels=$(factory_api "issues/$1" -q '.labels[].name') || return 1
  grep -qx "$2" <<<"$labels"
}

# The ticket's open blockers ("blocked by" dependencies), space-separated. Fails when they cannot
# be read, and callers treat that as not ready: a ticket never starts past an unknown blocker.
factory_open_blockers() {
  local deps
  deps=$(factory_api_list "issues/$1/dependencies/blocked_by?per_page=100") || return 1
  jq -r '[.[] | select(.state == "open") | .number] | join(" ")' <<<"$deps"
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
  local n=$1 reason=$2 rc=0
  factory_label_add "$n" blocked || rc=1
  factory_label_remove "$n" in-progress
  factory_comment "$n" "**Blocked** (factory): $reason" || rc=1
  if [ "$rc" -eq 0 ]; then warn "#$n blocked: $reason"; else warn "could not block #$n on GitHub (reason: $reason)"; fi
  return "$rc"
}
