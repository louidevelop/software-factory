#!/usr/bin/env bash
# scripts.test.sh — the factory command line, offline. GitHub is tests/fake-gh/gh: it serves only
# `gh api` REST replies set up here and records each call, so a GraphQL-backed `gh` command fails.
set -u
TESTS="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TESTS/../plugins/factory" && pwd)"
FACTORY="$PLUGIN/scripts/factory"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  echo "FAIL $1"
  FAIL=$((FAIL + 1))
}

P=$(mktemp -d)
trap 'rm -rf "$P"' EXIT
cd "$P" || exit 1
git init -q -b main
mkdir -p .factory
echo '{"version":1,"owners":["o"],"check":"true"}' >.factory/config.json
printf '# Project rules\n\nMine.\n\n<!-- factory:begin -->\n<!-- factory:end -->\n' >AGENTS.md
export CLAUDE_PROJECT_DIR="$P"

"$FACTORY" sync >/dev/null 2>&1
[ $? -eq 10 ] && ok || no "sync reports behind before apply"
"$FACTORY" sync --apply >/dev/null 2>&1 && ok || no "sync --apply succeeds"
"$FACTORY" sync >/dev/null 2>&1 && ok || no "sync reports current after apply"
grep -q '^Mine\.$' AGENTS.md && ok || no "project rules outside the markers survive"
grep -q '^<!-- factory:begin sha=[0-9a-f]\{12\} -->$' AGENTS.md && ok || no "begin marker carries the block hash"
[ "$(grep -c '^<!-- factory:end -->$' AGENTS.md)" -eq 1 ] && ok || no "exactly one end marker"
[ -x .factory/bin/factory ] && ok || no "shim installed and executable"
"$FACTORY" sync --apply >/dev/null 2>&1
[ "$(grep -c 'factory:begin' AGENTS.md)" -eq 1 ] && ok || no "re-applying does not duplicate the block"
sed -i.bak 's/^- Never guess\./- Guess freely./' AGENTS.md && rm -f AGENTS.md.bak
"$FACTORY" sync >/dev/null 2>&1
[ $? -eq 10 ] && ok || no "sync notices a hand edit inside the block"

# ---------- GitHub through REST only ----------
export FAKE_GH_DIR="$P/.fake-gh" PATH="$TESTS/fake-gh:$PATH"
mkdir -p "$FAKE_GH_DIR/replies"
# reply <METHOD> <path> <body>
reply() { printf '%s' "$3" >"$FAKE_GH_DIR/replies/$1 ${2//\//%}"; }
fresh_calls() { : >"$FAKE_GH_DIR/calls"; }
# called <METHOD> <path> [<field>] — a call was made (with that field, when given).
called() { jq -e --arg m "$1" --arg p "$2" --arg f "${3:-}" 'select(.method == $m and .path == $p and ($f == "" or (.fields | index($f))))' \
  "$FAKE_GH_DIR/calls" >/dev/null; }
label() { jq -cn '[$ARGS.positional[] | {name: .}]' --args "$@"; }

if grep -rnE '(^|[^`a-z-])gh +(issue|pr|repo|label|search|release) ' "$PLUGIN/scripts" "$PLUGIN/prompts" "$PLUGIN/skills" "$PLUGIN/agents"; then
  no "a gh command that uses GraphQL (fails in cloud sessions; use gh api)"
else ok; fi
gh issue view 1 >/dev/null 2>&1 && no "the fake gh refuses GraphQL-backed commands" || ok

for url in git@github.com:o/r.git https://github.com/o/r https://github.com/o/r.git https://github.com/o/r/ \
  ssh://git@github.com/o/r.git http://local_proxy@127.0.0.1:43123/git/o/r; do
  git remote remove origin 2>/dev/null
  git remote add origin "$url"
  [ "$("$FACTORY" repo 2>/dev/null)" = o/r ] && ok || no "slug from $url"
done
git remote set-url origin https://github.com/my-org/my.repo.git
[ "$("$FACTORY" repo 2>/dev/null)" = my-org/my.repo ] && ok || no "slug keeps dots and dashes"
git remote remove origin
"$FACTORY" repo >/dev/null 2>&1 && no "no remote, no slug" || ok
git remote add origin git@github.com:o/r.git

# tickets next: oldest ready agent-task; skips in-progress, blocked, PRs, open or unreadable blockers.
I=repos/o/r/issues
reply GET "$I?labels=agent-task&state=open&sort=created&direction=asc&per_page=100" "[
  {\"number\": 1, \"state\": \"open\", \"labels\": $(label agent-task in-progress)},
  {\"number\": 2, \"state\": \"open\", \"labels\": $(label agent-task blocked)},
  {\"number\": 3, \"state\": \"open\", \"labels\": $(label agent-task)},
  {\"number\": 4, \"state\": \"open\", \"labels\": $(label agent-task), \"pull_request\": {}},
  {\"number\": 5, \"state\": \"open\", \"labels\": $(label bug agent-task)},
  {\"number\": 6, \"state\": \"open\", \"labels\": $(label agent-task)}]"
for n in 1 2 4 6; do reply GET "$I/$n/dependencies/blocked_by?per_page=100" '[]'; done
reply GET "$I/3/dependencies/blocked_by?per_page=100" '[{"number": 9, "state": "open"}]'
reply GET "$I/5/dependencies/blocked_by?per_page=100" '[{"number": 3, "state": "closed"}]'
fresh_calls
OUT=$("$FACTORY" tickets next 2>/dev/null)
[ $? -eq 0 ] && [ "$OUT" = 5 ] && ok || no "tickets next picks #5 (got '$OUT')"
called GET "$I/1/dependencies/blocked_by?per_page=100" && no "tickets next reads blockers of an in-progress ticket" || ok
# With a parent: its sub-issues in their own order; a ticket whose blockers cannot be read waits.
reply GET "$I/10/sub_issues?per_page=100" "[
  {\"number\": 13, \"state\": \"closed\", \"labels\": $(label agent-task)},
  {\"number\": 12, \"state\": \"open\", \"labels\": $(label agent-task)},
  {\"number\": 11, \"state\": \"open\", \"labels\": $(label agent-task)},
  {\"number\": 7, \"state\": \"open\", \"labels\": $(label agent-task)}]"
reply GET "$I/11/dependencies/blocked_by?per_page=100" '[]'
reply GET "$I/7/dependencies/blocked_by?per_page=100" '[]'
OUT=$("$FACTORY" tickets next 10 2>/dev/null)
[ "$OUT" = 11 ] && ok || no "tickets next 10 follows the sub-issue order and skips unreadable blockers (got '$OUT')"
reply GET "$I/20/sub_issues?per_page=100" '[]'
"$FACTORY" tickets next 20 >/dev/null 2>&1
[ $? -eq 3 ] && ok || no "tickets next exits 3 when nothing is ready"

# factory block: label blocked, drop in-progress, comment the reason.
reply POST "$I/5/labels" "$(label agent-task blocked)"
reply DELETE "$I/5/labels/in-progress" '[]'
reply POST "$I/5/comments" '{"id": 1}'
fresh_calls
"$FACTORY" block 5 "which colour?" 2>/dev/null && ok || no "factory block succeeds"
called POST "$I/5/labels" 'labels[]=blocked' && ok || no "block adds the blocked label"
called DELETE "$I/5/labels/in-progress" && ok || no "block removes in-progress"
called POST "$I/5/comments" 'body=**Blocked** (factory): which colour?' && ok || no "block comments the reason"
reply POST "$I/6/labels" "$(label agent-task blocked)"
reply POST "$I/6/comments" '{"id": 2}'
"$FACTORY" block 6 "why" 2>/dev/null && ok || no "block works when the ticket is not in progress"
"$FACTORY" block 8 "why" >/dev/null 2>&1 && no "block fails when GitHub refuses the label" || ok

# tickets show: the ticket with its comments, oldest first.
reply GET "$I/5" '{"number": 5, "title": "Pick a colour", "state": "open", "body": "## Goal\nPaint it.",
  "html_url": "https://github.com/o/r/issues/5", "comments": 2, "labels": [{"name": "agent-task"}, {"name": "blocked"}]}'
reply GET "$I/5/comments?per_page=100" '[
  {"user": {"login": "factory-bot"}, "created_at": "2026-10-20T10:00:00Z", "body": "**Blocked** (factory): which colour?"},
  {"user": {"login": "owner"}, "created_at": "2026-10-21T10:00:00Z", "body": "Blue, the brand one."}]'
OUT=$("$FACTORY" tickets show 5 2>/dev/null)
for want in "#5 Pick a colour" "Paint it." "blocked" "@owner" "Blue, the brand one." "which colour?"; do
  [[ $OUT == *"$want"* ]] && ok || no "tickets show includes '$want'"
done
[[ $OUT == *"which colour?"*"Blue, the brand one."* ]] && ok || no "tickets show lists comments oldest first"

# tickets create: REST issue, linked under the parent and to its blocker by issue id.
printf '## Goal\nShip it.\n' >"$P/body.md"
reply POST "$I" '{"number": 30, "id": 3000}'
reply GET "$I/30" '{"number": 30, "id": 3000}'
reply GET "$I/29" '{"number": 29, "id": 2900}'
reply POST "$I/10/sub_issues" '{}'
reply POST "$I/30/dependencies/blocked_by" '{}'
fresh_calls
OUT=$("$FACTORY" tickets create "Ship it" "$P/body.md" --parent 10 --blocked-by 29 2>/dev/null)
[ "$OUT" = 30 ] && ok || no "tickets create prints the new number (got '$OUT')"
called POST "$I" 'labels[]=agent-task' && called POST "$I" $'body=## Goal\nShip it.' && ok || no "tickets create sends label and body"
called POST "$I/10/sub_issues" 'sub_issue_id=3000' && ok || no "tickets create links the sub-issue by id"
called POST "$I/30/dependencies/blocked_by" 'issue_id=2900' && ok || no "tickets create records the blocker by id"

echo "scripts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
