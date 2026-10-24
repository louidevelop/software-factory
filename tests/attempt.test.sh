#!/usr/bin/env bash
# attempt.test.sh — `factory attempt` and `factory finish`, offline. GitHub is tests/fake-gh/gh
# (canned REST replies, every call recorded); origin is a local bare repo whose path ends in o/r,
# so the slug reads as on GitHub and branches really push and fetch.
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
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
unset CLAUDE_CODE_REMOTE CLAUDE_PROJECT_DIR FACTORY_SOURCE
export FACTORY_HOME="$PLUGIN" # start skips `claude plugin update`
export HOME="$W/home"
mkdir -p "$HOME"

ORIGIN="$W/remote/o/r.git"
git init -q --bare -b main "$ORIGIN"
P="$W/p"
git clone -q "$ORIGIN" "$P" 2>/dev/null
cd "$P" || exit 1
mkdir -p .factory
echo '{"version":1,"owners":["o"],"check":"test ! -f RED || { echo check-is-red; exit 1; }","run":{"maxAttempts":3,"staleMinutes":60}}' >.factory/config.json
"$FACTORY" sync --apply >/dev/null 2>&1
G add -A && G commit -qm init && G push -q origin main
"$FACTORY" sync >/dev/null 2>&1 && ok || no "the project is in sync (start would open a sync PR)"

export FAKE_GH_DIR="$W/gh" PATH="$TESTS/fake-gh:$PATH"
mkdir -p "$FAKE_GH_DIR/replies"
reply() { printf '%s' "$3" >"$FAKE_GH_DIR/replies/$1 ${2//\//%}"; }
fresh_calls() { : >"$FAKE_GH_DIR/calls"; }
called() { jq -e --arg m "$1" --arg p "$2" --arg f "${3:-}" 'select(.method == $m and .path == $p and ($f == "" or any(.fields[]; contains($f))))' \
  "$FAKE_GH_DIR/calls" >/dev/null; }
label() { jq -cn '[$ARGS.positional[] | {name: .}]' --args "$@"; }
I=repos/o/r/issues
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD=2026-01-01T00:00:00Z

# issue <n> <labels...> — the issue itself, with no blockers.
issue() {
  local n=$1
  shift
  reply GET "$I/$n" "{\"number\": $n, \"title\": \"Ticket $n\", \"state\": \"open\", \"body\": \"## Goal\\nDo $n.\",
    \"html_url\": \"https://github.com/o/r/issues/$n\", \"labels\": $(label "$@")}"
  reply GET "$I/$n/dependencies/blocked_by?per_page=100" '[]'
  reply POST "$I/$n/labels" '[]'
  reply POST "$I/$n/comments" "{\"id\": ${n}00}"
  reply PATCH "$I/comments/${n}00" '{}'
  reply DELETE "$I/$n/labels/in-progress" '{}'
  reply DELETE "$I/$n/labels/rework" '{}'
  comments "$n"
}
# att <k> <created_at> [<end outcome>] [<branch>] — one attempt comment.
att() {
  jq -cn --arg k "$1" --arg t "$2" --arg e "${3:-}" --arg b "${4:-ticket/0-x}" '{id: 1, user: {login: "o"}, created_at: $t,
    body: ("<!-- factory:attempt \($k) branch=\($b) -->\n**Factory attempt \($k) of 3** started." +
      (if $e == "" then "" else "\n\n<!-- factory:attempt-end \($k) \($e) -->\n**Ended: \($e).**\n\nMissing for the PR:\n\n- The check-marker-\($k)." end))}'
}
blocked_comment() { jq -cn '{id: 2, user: {login: "o"}, created_at: "2026-01-02T00:00:00Z", body: "**Blocked** (factory): why?"}'; }
comments() { # comments <n> [<comment json>...]
  local n=$1
  shift
  reply GET "$I/$n/comments?per_page=100" "$(jq -cs . <<<"${*:-}")"
}
list() { # list <issue json>... — the open agent-task issues
  reply GET "$I?labels=agent-task&state=open&sort=created&direction=asc&per_page=100" "$(jq -cs . <<<"$*")"
}
li() { jq -cn --argjson n "$1" --argjson l "$(label "${@:2}")" '{number: $n, state: "open", labels: $l}'; }
reply GET "$I?labels=feature&state=open&per_page=100" '[]'
for b in ticket/1-ticket-1 ticket/2-ticket-2 ticket/3-ticket-3 ticket/4-ticket-4 ticket/2-old-title; do
  reply GET "repos/o/r/pulls?state=open&head=o:$b" '[]'
done
state() { jq -r ".$2" "$1/.git/factory/attempt.json" 2>/dev/null || jq -r ".$2" "$(git -C "$1" rev-parse --absolute-git-dir)/factory/attempt.json"; }
attempt() { "$FACTORY" attempt "$@" 2>"$W/err"; }

# ---------- selection order: rework, then an unfinished attempt, then the next ready ticket ----------
issue 1 agent-task
issue 2 agent-task in-progress
comments 2 "$(att 1 "$OLD" unfinished ticket/2-ticket-2)"
issue 3 agent-task in-progress rework
comments 3 "$(att 1 "$OLD" finished ticket/3-ticket-3)"
list "$(li 1 agent-task)" "$(li 2 agent-task in-progress)" "$(li 3 agent-task in-progress rework)"
fresh_calls
OUT=$(attempt)
[ $? -eq 0 ] && ok || no "attempt starts ($(cat "$W/err"))"
WT3="$P/.factory/worktrees/ticket-3"
[ "$(state "$WT3" ticket)" = 3 ] && ok || no "rework comes first"
[[ $OUT == *"ticket #3"* && $OUT == *'labelled `rework`'* ]] && ok || no "the prompt names #3 and its rework"
[ "$(state "$WT3" attempt)" = 1 ] && ok || no "a finished attempt resets the count (rework starts a fresh budget)"
called POST "$I/3/comments" "<!-- factory:attempt 1 branch=ticket/3-ticket-3 -->" && ok || no "the attempt is counted in a ticket comment"
called POST "$I/3/labels" && no "a resumed ticket is not locked again" || ok
[ "$(git -C "$WT3" rev-parse --abbrev-ref HEAD)" = ticket/3-ticket-3 ] && ok || no "worktree on the ticket branch"
[ "$(cat "$P/.git/factory/last-attempt")" = "$(cd "$WT3" && pwd -P)" ] && ok || no "last-attempt points at the checkout"
[[ $OUT == *'F finish 3'* ]] && ok || no "the prompt ends with factory finish"
[[ $OUT != *'{{'* ]] && ok || no "every placeholder is filled"

list "$(li 1 agent-task)" "$(li 2 agent-task in-progress)"
OUT=$(attempt)
[ "$(state "$P/.factory/worktrees/ticket-2" ticket)" = 2 ] && ok || no "an unfinished attempt comes second ($(cat "$W/err"))"
[ "$(state "$P/.factory/worktrees/ticket-2" attempt)" = 2 ] && ok || no "the second attempt is attempt 2"
[[ $OUT == *"check-marker-1"* ]] && ok || no "the prompt carries the previous attempt's report"

reply GET "repos/o/r/pulls?state=open&head=o:ticket/2-ticket-2" '[{"number": 9}]'
fresh_calls
OUT=$(attempt)
[ "$(state "$P/.factory/worktrees/ticket-1" ticket)" = 1 ] && ok || no "then the next ready ticket ($(cat "$W/err"))"
called POST "$I/1/labels" "labels[]=in-progress" && ok || no "a fresh ticket is locked"
reply GET "repos/o/r/pulls?state=open&head=o:ticket/2-ticket-2" '[]'

# An in-progress ticket without attempts was locked by an interactive `factory start`: not ours.
issue 4 agent-task in-progress
list "$(li 4 agent-task in-progress)"
attempt >/dev/null
[ $? -eq 3 ] && ok || no "nothing to do: another session's lock is left alone"

# ---------- busy: one live attempt anywhere refuses another ----------
comments 2 "$(att 1 "$NOW" "" ticket/2-ticket-2)"
list "$(li 1 agent-task)" "$(li 2 agent-task in-progress)"
attempt >/dev/null
[ $? -eq 6 ] && ok || no "busy while another attempt is live"
grep -q "busy: #2" "$W/err" && ok || no "busy names the live ticket"
attempt 1 >/dev/null
[ $? -eq 6 ] && ok || no "busy even for a named ticket"

# ---------- stale: an attempt that never ended counts as crashed after run.staleMinutes ----------
comments 2 "$(att 1 "$OLD" "" ticket/2-ticket-2)"
attempt >/dev/null
[ $? -eq 0 ] && [ "$(state "$P/.factory/worktrees/ticket-2" attempt)" = 2 ] && ok || no "a stale attempt is resumed ($(cat "$W/err"))"
# … unless its branch got a commit recently.
O="$W/other"
git clone -q "$ORIGIN" "$O" 2>/dev/null
(cd "$O" && git checkout -q -b ticket/2-ticket-2 && echo wip >wip.txt && G add wip.txt && G commit -qm wip && G push -q origin ticket/2-ticket-2)
attempt >/dev/null
[ $? -eq 6 ] && ok || no "an old attempt with a recent commit on its branch is live"
comments 2 "$(att 1 "$OLD" unfinished ticket/2-ticket-2)"
attempt >/dev/null
[ $? -eq 0 ] && ok || no "an ended attempt is not live, whatever its branch ($(cat "$W/err"))"
[ -f "$P/.factory/worktrees/ticket-2/wip.txt" ] && ok || no "the worktree catches up with the branch pushed elsewhere"

# ---------- the attempt counter and run.maxAttempts ----------
comments 2 "$(att 1 "$OLD" unfinished)" "$(att 2 "$OLD" unfinished)"
attempt 2 >/dev/null
[ "$(state "$P/.factory/worktrees/ticket-2" attempt)" = 3 ] && ok || no "attempt 3 after two"
comments 2 "$(att 1 "$OLD" unfinished)" "$(blocked_comment)" "$(att 2 "$OLD" unfinished)"
attempt 2 >/dev/null
[ "$(state "$P/.factory/worktrees/ticket-2" attempt)" = 2 ] && ok || no "a block starts a fresh budget"
comments 2 "$(att 1 "$OLD" unfinished)" "$(att 2 "$OLD" unfinished)" "$(att 3 "$OLD")"
fresh_calls
attempt 2 >/dev/null
[ $? -eq 5 ] && ok || no "past run.maxAttempts the named ticket blocks (exit 5)"
called POST "$I/2/labels" "labels[]=blocked" && ok || no "the ticket is labelled blocked"
called POST "$I/2/comments" "3 attempts ended without a PR" && ok || no "the block says why"
called POST "$I/2/comments" "factory:attempt 4" && no "no attempt 4 is recorded" || ok
# With `next`, a ticket blocked at the maximum makes way for the next one.
list "$(li 1 agent-task)" "$(li 2 agent-task in-progress)"
reply GET "repos/o/r/pulls?state=open&head=o:ticket/0-x" '[]'
attempt >/dev/null
[ $? -eq 0 ] && [ "$(state "$P/.factory/worktrees/ticket-1" ticket)" = 1 ] && ok || no "next moves on past a ticket blocked at the maximum"
comments 2 "$(att 1 "$OLD" unfinished ticket/2-ticket-2)"
issue 5 agent-task blocked
attempt 5 >/dev/null
[ $? -eq 5 ] && ok || no "a named blocked ticket is refused with exit 5"

# ---------- in place: the branch is checked out in this clone (cloud runs) ----------
C="$W/cloud"
git clone -q "$ORIGIN" "$C" 2>/dev/null
cd "$C" || exit 1
git checkout -q -b claude/some-run
mkdir -p .git/factory && echo '{"ticket": 9, "branch": "ticket/9-x", "head": "0000", "status": "open"}' >.git/factory/attempt.json
echo 9 >.git/factory/ticket
list "$(li 2 agent-task in-progress)"
OUT=$(CLAUDE_CODE_REMOTE=true attempt)
[ $? -eq 0 ] && ok || no "in place starts ($(cat "$W/err"))"
[ "$(git rev-parse --abbrev-ref HEAD)" = ticket/2-ticket-2 ] && ok || no "in place: this clone is on the ticket branch"
[ -f wip.txt ] && ok || no "in place: the branch is resumed from origin"
[ ! -d .factory/worktrees ] && ok || no "in place: no worktree"
[ "$(state "$C" ticket)" = 2 ] && [ "$(state "$C" status)" = open ] && ok || no "in place: a leftover state file is replaced"
[[ $OUT == *"in \`$C\`"* || $OUT == *"in \`$(pwd -P)\`"* ]] && ok || no "the prompt names the checkout"
# A different branch than the old state's: a later run on main sees no attempt.
cd "$P" || exit 1

# ---------- finish: not done → work in progress pushed, the attempt ended unfinished ----------
cd "$C" || exit 1
echo more >more.txt
fresh_calls
"$FACTORY" finish 2>"$W/err"
[ $? -eq 7 ] && ok || no "finish exits 7 when not done ($(cat "$W/err"))"
[ "$(state "$C" status)" = unfinished ] && ok || no "the attempt is marked unfinished"
[ -z "$(git status --porcelain)" ] && ok || no "uncommitted work is committed"
[ "$(git rev-parse HEAD)" = "$(git ls-remote "$ORIGIN" refs/heads/ticket/2-ticket-2 | cut -f1)" ] && ok || no "the work in progress is pushed"
called PATCH "$I/comments/200" "<!-- factory:attempt-end 2 unfinished -->" && ok || no "the attempt comment records the end"
called PATCH "$I/comments/200" "Verification" && ok || no "the report says what is missing"
grep -q "No local review" "$W/err" && ok || no "finish prints what is missing"
called POST "repos/o/r/pulls" && no "an unfinished attempt never opens a PR" || ok

# ---------- finish: done → open-pr, the attempt finished ----------
CLAUDE_CODE_REMOTE=true attempt 2 >/dev/null
S="$C/.git/factory"
printf '## What\nx\n\n## Verification\n- test proves it\n\n## Decisions\n- None\n\n## Local review\n' >"$S/pr-body.md"
jq -n --arg h "$(git rev-parse HEAD)" '{head: $h, model: "opus", fixed: [], unresolved: [], nonblocking: [], rejected: []}' >"$S/review.json"
reply POST repos/o/r/pulls '{"html_url": "https://github.com/o/r/pull/12"}'
fresh_calls
"$FACTORY" finish 2 2>"$W/err"
[ $? -eq 0 ] && ok || no "finish opens the PR when done ($(cat "$W/err"))"
[ "$(state "$C" status)" = finished ] && ok || no "the attempt is marked finished"
called POST repos/o/r/pulls "head=ticket/2-ticket-2" && ok || no "the PR is opened"
called PATCH "$I/comments/200" "attempt-end 2 finished" && ok || no "the attempt comment records it finished"
called DELETE "$I/2/labels/rework" && ok || no "a finished attempt clears rework"
"$FACTORY" finish 2 >/dev/null 2>&1 && ok || no "finishing twice is harmless"

# A red check keeps it unfinished.
CLAUDE_CODE_REMOTE=true attempt 2 >/dev/null
jq -n --arg h "$(git rev-parse HEAD)" '{head: $h, model: "opus", fixed: [], unresolved: [], nonblocking: [], rejected: []}' >"$S/review.json"
touch RED && echo RED >>.git/info/exclude
"$FACTORY" finish 2 >/dev/null 2>"$W/err"
[ $? -eq 7 ] && grep -q check-is-red "$W/err" && ok || no "a red check: finish ends unfinished with the check's output"
rm RED

# factory block ends the open attempt.
CLAUDE_CODE_REMOTE=true attempt 2 >/dev/null
fresh_calls
"$FACTORY" block 2 "which colour?" 2>/dev/null
[ "$(state "$C" status)" = blocked ] && ok || no "block marks the open attempt blocked"
called PATCH "$I/comments/200" "attempt-end" && ok || no "block records the attempt's end"

# ---------- factory run: one ticket, a fresh `claude -p` per attempt ----------
# The fake claude plays the session: FAKE_CLAUDE=done does the work and stops without finishing
# (run then finishes for it), FAKE_CLAUDE=block blocks the ticket.
mkdir -p "$W/bin"
cat >"$W/bin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -p ] || exit 0
S="$(git rev-parse --absolute-git-dir)/factory"
N=$(cat "$S/ticket")
echo "$*" >"$S/prompt-seen"
case "$FAKE_CLAUDE" in
  done)
    echo "$N" >"done-$N.txt" && git add -A && git commit -qm "ticket $N"
    printf '## Verification\n- proof\n\n## Decisions\n- None\n' >"$S/pr-body.md"
    jq -n --arg h "$(git rev-parse HEAD)" '{head: $h, model: "opus", fixed: [], unresolved: [], nonblocking: [], rejected: []}' >"$S/review.json"
    ;;
  block) "$FACTORY_BIN" block "$N" "a question" ;;
esac
SH
chmod +x "$W/bin/claude"
cd "$P" || exit 1
issue 6 agent-task
issue 7 agent-task
reply GET "repos/o/r/pulls?state=open&head=o:ticket/6-ticket-6" '[]'
list "$(li 6 agent-task)"
fresh_calls
PATH="$W/bin:$PATH" FAKE_CLAUDE="done" FACTORY_BIN="$FACTORY" "$FACTORY" run next >/dev/null 2>"$W/err"
[ $? -eq 0 ] && ok || no "run: exit 0 once the PR is open ($(tail -3 "$W/err"))"
grep -q "ticket #6" "$P/.git/worktrees/ticket-6/factory/prompt-seen" && ok || no "run: the session gets the attempt's prompt"
called POST repos/o/r/pulls "head=ticket/6-ticket-6" && ok || no "run: finish opens the PR when the session did not"
[ "$(state "$P/.factory/worktrees/ticket-6" status)" = finished ] && ok || no "run: the attempt is finished"
list "$(li 7 agent-task)"
PATH="$W/bin:$PATH" FAKE_CLAUDE=block FACTORY_BIN="$FACTORY" "$FACTORY" run 7 >/dev/null 2>"$W/err"
[ $? -eq 5 ] && ok || no "run: exit 5 when the session blocks the ticket ($(tail -3 "$W/err"))"
[ "$(state "$P/.factory/worktrees/ticket-7" status)" = blocked ] && ok || no "run: the attempt is blocked"

echo "attempt: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
