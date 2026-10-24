#!/usr/bin/env bash
# common.sh — sourced by every scripts/cmd/*.sh. Not run directly.
# A command started by an older runtime's scripts/factory, before a fetch replaced the runtime under
# it, has only FACTORY_SCRIPTS (FACTORY_DIR was FACTORY_PLUGIN then).
FACTORY_DIR=${FACTORY_DIR:-$(dirname "$FACTORY_SCRIPTS")}
export FACTORY_DIR
# shellcheck source=../hooks/lib.sh
. "$FACTORY_DIR/hooks/lib.sh"

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

# Every label the factory uses, as name|color|description: github-setup creates them, and doctor
# checks that they exist. One list, so the two cannot drift apart.
# shellcheck disable=SC2034 # read by the commands that source this
FACTORY_LABELS=(
  "agent-task|1d76db|A ticket an agent completes without asking questions"
  "in-progress|fbca04|An agent run holds this ticket (also the lock)"
  "blocked|d93f0b|Needs a human: see the latest comment for the question"
  "rework|e99695|The gate sent the PR back: conflict or red on the current base"
  "risk:low|0e8a16|Factory gate: low impact, merges when green"
  "risk:high|b60205|Factory gate: waits for the owner's merge label"
  "merge|0e8a16|The owner's go-ahead: the gate merges this high-impact PR"
  "feature|5319e7|Parent issue tracking a feature spec"
)

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

# Succeeds when the markdown on stdin says something: HTML comments (the template's hints, which
# span lines) and empty list items do not count.
markdown_filled() {
  awk '{
    line = $0; out = ""
    while (1) {
      if (inc) { i = index(line, "-->"); if (!i) break; line = substr(line, i + 3); inc = 0 }
      i = index(line, "<!--"); if (!i) { out = out line; break }
      out = out substr(line, 1, i - 1); line = substr(line, i + 4); inc = 1
    }
    print out
  }' | grep -qvE '^[[:space:]]*([-*+][[:space:]]*)?$'
}

ticket_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//'
}

factory_block_ticket() {
  local n=$1 reason=$2 rc=0 wt f
  factory_label_add "$n" blocked || rc=1
  factory_label_remove "$n" in-progress
  factory_comment "$n" "**Blocked** (factory): $reason" || rc=1
  if [ "$rc" -eq 0 ]; then warn "#$n blocked: $reason"; else warn "could not block #$n on GitHub (reason: $reason)"; fi
  # A block ends the ticket's open attempt, so the Stop hook lets the session end.
  wt=$(factory_ticket_worktree "$n" 2>/dev/null)
  if [ -n "$wt" ] && f=$(factory_attempt_file "$wt") && [ "$(jq -r .ticket "$f")" = "$n" ] && [ "$(jq -r .status "$f")" = open ]; then
    attempt_end "$f" blocked "$reason"
  fi
  return "$rc"
}

# Done criteria ---------------------------------------------------------------

# factory_done_problems [--no-check] — run inside the ticket's checkout. One markdown bullet per
# unmet done criterion (what open-pr and finish require); no output when the ticket is done.
factory_done_problems() {
  local base state n branch draft s check out
  base=$(factory_base_branch)
  state=$(factory_state_dir)
  n=$(cat "$state/ticket" 2>/dev/null)
  branch=$(git rev-parse --abbrev-ref HEAD)
  [ -z "$(git status --porcelain)" ] || echo "- The tree has uncommitted changes: commit them, or discard what is wrong."
  [ "$(git rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 0)" -gt 0 ] || echo "- No commits on $branch yet."
  draft="$state/pr-body.md"
  if [ -f "$draft" ]; then
    for s in Verification Decisions; do
      markdown_section "$(cat "$draft")" "$s" | markdown_filled ||
        echo "- The PR description's \`## $s\` is empty ($draft)."
    done
  else
    echo "- No PR description at $draft (fill in .github/pull_request_template.md there)."
  fi
  if [ ! -f "$state/review.json" ]; then
    echo "- No local review yet: factory review begin $n, then the reviewer and judges, then factory review assemble $n."
  elif [ "$(jq -r .head "$state/review.json")" != "$(git rev-parse HEAD)" ]; then
    echo "- The local review is for an older commit: after fixing confirmed findings run factory review resolve-begin $n and factory review assemble $n --resolve; otherwise begin the review again."
  fi
  [ "${1:-}" = --no-check ] && return 0
  check=$(factory_cfg '.check')
  out=$(bash -c "$check" 2>&1) ||
    printf -- '- `%s` is red. Last lines:\n```\n%s\n```\n' "$check" "$(tail -40 <<<"$out")"
}

# Attempts --------------------------------------------------------------------
# An attempt is one session's try at one ticket: `factory attempt` … `factory finish`. Its record
# lives on GitHub, because every cloud run starts on a fresh VM: a ticket comment that starts with
# `<!-- factory:attempt <k> branch=<branch> -->` and gains `<!-- factory:attempt-end <k> <outcome> -->`
# when the attempt ends. <git dir>/factory/attempt.json only lets finish, block and the Stop hook
# find the open attempt of a checkout (see factory_attempt_file).

# attempt_end <attempt.json> <finished|unfinished|blocked> [report] — mark the attempt ended,
# here and in its ticket comment.
attempt_end() {
  local f=$1 outcome=$2 report=${3:-} k body
  k=$(jq -r .attempt "$f")
  jq --arg s "$outcome" '.status = $s' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  body="$(jq -r .comment_body "$f")"$'\n\n'"<!-- factory:attempt-end $k $outcome -->"$'\n'"**Ended: $outcome.**"
  [ -z "$report" ] || body+=$'\n\n'"$report"
  factory_api "issues/comments/$(jq -r .comment_id "$f")" -X PATCH -f body="$body" >/dev/null ||
    warn "could not record the end of attempt $k on GitHub"
}
