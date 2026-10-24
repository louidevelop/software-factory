#!/usr/bin/env bash
# attempt — start one attempt at one ticket and print the implementation prompt. Local runs
# (`factory run`) and cloud routine runs both start here; the session ends with `factory finish`
# (or `factory block`), and the Stop hook keeps it from ending before one of them ran.
#   factory attempt [<issue> | next] [--parent <n>] [--in-place | --worktree]
# Without an issue it picks, in this order:
#   1. a ticket labelled `rework` (its PR went red or conflicts with the base);
#   2. one of our in-progress tickets whose last attempt ended unfinished or went stale (no
#      recent attempt start or push: a crashed run), and that has no open PR;
#   3. the next ready ticket (`tickets next`).
# In place (the default in Claude's cloud, where CLAUDE_CODE_REMOTE=true) the ticket's branch is
# checked out in this clone; otherwise it gets a worktree, as `factory start` does.
# Exit codes: 0 started (stdout: the prompt), 3 nothing to do, 4 base branch red, 5 the named
#             ticket is blocked, 6 busy (another attempt is live), 1 error.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq
factory_require_config

WHICH=next
PARENT=""
IN_PLACE=0
[ "${CLAUDE_CODE_REMOTE:-}" = true ] && IN_PLACE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)
      PARENT=${2:?--parent needs an issue number}
      shift
      ;;
    --in-place) IN_PLACE=1 ;;
    --worktree) IN_PLACE=0 ;;
    next | [0-9]*) WHICH=$1 ;;
    *) die "usage: factory attempt [<issue> | next] [--parent <n>] [--in-place | --worktree]" ;;
  esac
  shift
done

MAX=$(factory_cfg '.run.maxAttempts')
MAX=${MAX:-3}
STALE=$(factory_cfg '.run.staleMinutes')
STALE=${STALE:-120}
BASE=$(factory_base_branch)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The attempt record (see "Attempts" in common.sh), read from a ticket's comments.
# Attempts since the ticket last finished one or was blocked: an owner's answer, or a PR sent
# back for rework, starts a fresh budget.
ATTEMPTS_USED='reduce .[].body as $b (0;
  if ($b | test("<!-- factory:attempt-end [0-9]+ finished")) or ($b | startswith("**Blocked** (factory)")) then 0
  elif ($b | test("<!-- factory:attempt [0-9]+")) then . + 1 else . end)'
LAST_ATTEMPT='[.[] | select(.body | test("<!-- factory:attempt [0-9]+"))] | last // empty'

comments() { # comments <n> — cached: selection and counting read them more than once
  [ -f "$TMP/c$1" ] || factory_api_list "issues/$1/comments?per_page=100" >"$TMP/c$1" || {
    rm -f "$TMP/c$1"
    return 1
  }
  cat "$TMP/c$1"
}

# live <n> — succeeds when the ticket's last attempt has not ended and is recent: it started
# within run.staleMinutes, or its branch got a commit within them. (A commit's time, not the push's:
# git has no push time, and an attempt pushes its work only when it ends.) Prints a reason.
live() {
  local last b age tip
  last=$(comments "$1" | jq -c "$LAST_ATTEMPT") || return 1
  [ -n "$last" ] || return 1
  jq -e '.body | test("<!-- factory:attempt-end ")' <<<"$last" >/dev/null && return 1
  age=$(jq -r '(now - (.created_at | fromdateiso8601)) / 60 | floor' <<<"$last")
  if [ "$age" -lt "$STALE" ]; then
    echo "#$1's attempt started $age min ago"
    return 0
  fi
  b=$(attempt_branch "$last")
  if [ -n "$b" ] && git fetch -q origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null; then
    tip=$(($(date +%s) - $(git log -1 --format=%ct "origin/$b")))
    if [ "$tip" -lt $((STALE * 60)) ]; then
      echo "#$1's branch $b got a commit $((tip / 60)) min ago"
      return 0
    fi
  fi
  return 1
}
attempt_branch() { jq -r '.body | capture("<!-- factory:attempt [0-9]+ branch=(?<b>[^ ]+) -->").b // empty' <<<"$1"; }

# 1. Busy? Runs go one at a time per repository: a live attempt on any ticket refuses this one.
ALL=$(factory_api_list "issues?labels=agent-task&state=open&sort=created&direction=asc&per_page=100") ||
  die "cannot list agent-task issues"
ACTIVE=$(jq -r '.[] | select(.pull_request == null) | select([.labels[].name] | (index("in-progress") or index("rework")) and (index("blocked") | not)) | .number' <<<"$ALL")
for n in $ACTIVE; do
  if WHY=$(live "$n"); then
    warn "busy: $WHY (an attempt counts as live for run.staleMinutes = $STALE)"
    exit 6
  fi
done

# 2. Pick the ticket.
if [ -n "$PARENT" ]; then
  POOL=$(factory_api_list "issues/$PARENT/sub_issues?per_page=100") || die "cannot read #$PARENT's sub-issues"
else
  POOL=$ALL
fi
pool() { # pool <label> — open tickets in the pool with that label, not blocked, in order
  jq -r --arg l "$1" '.[] | select(.state == "open" and .pull_request == null)
    | select([.labels[].name] | index("agent-task") and index($l) and (index("blocked") | not)) | .number' <<<"$POOL"
}
SKIP=" "
pick() {
  local n last
  for n in $(pool rework); do
    [[ $SKIP == *" $n "* ]] || {
      say "#$n needs rework"
      echo "$n"
      return 0
    }
  done
  for n in $(pool in-progress); do
    [[ $SKIP == *" $n "* ]] && continue
    last=$(comments "$n" | jq -c "$LAST_ATTEMPT") || continue
    [ -n "$last" ] || continue # locked by an interactive `factory start`, not by an attempt
    b=$(attempt_branch "$last")
    [ -n "$b" ] && [ -n "$(factory_open_pr "$b")" ] && continue # waiting for the gate or the owner
    say "#$n: resuming its unfinished or stalled attempt"
    echo "$n"
    return 0
  done
  n=$(bash "$FACTORY_SCRIPTS/cmd/tickets.sh" next ${PARENT:+"$PARENT"} 2>/dev/null) || return 3
  [[ $SKIP == *" $n "* ]] && return 3
  echo "$n"
}

# next_or <code> — a named ticket stops here; an automatic pick moves on to the next one.
next_or() {
  [ "$WHICH" = next ] || exit "$1"
  SKIP+="$N "
}
while :; do
  if [ "$WHICH" = next ]; then
    N=$(pick) || {
      bash "$FACTORY_SCRIPTS/cmd/archive-specs.sh" || warn "could not check for finished specs"
      say "nothing to do: no rework, no unfinished attempt, and no ready ticket"
      exit 3
    }
  else
    N=$WHICH
  fi

  if [ "$WHICH" != next ] && ticket_has_label "$N" blocked; then
    warn "#$N is blocked; the owner answers its question first"
    exit 5
  fi

  # 3. Count the attempt; past run.maxAttempts the ticket blocks for the owner.
  C=$(comments "$N") || die "cannot read #$N's comments"
  K=$(($(jq "$ATTEMPTS_USED" <<<"$C") + 1))
  if [ "$K" -gt "$MAX" ]; then
    factory_block_ticket "$N" "$MAX attempts ended without a PR. The last one's report is in its comment above; the work so far is on the ticket's branch."
    next_or 5
    continue
  fi
  LAST=$(jq -c "$LAST_ATTEMPT" <<<"$C")

  # 4. The branch, through `factory start`: a resumed ticket keeps its lock and its branch.
  RESUME=()
  if [ -n "$LAST" ] || ticket_has_label "$N" in-progress || ticket_has_label "$N" rework; then RESUME=(--resume); fi
  MODE=()
  [ "$IN_PLACE" -eq 1 ] && MODE=(--in-place)
  OUT=$(bash "$FACTORY_SCRIPTS/cmd/start.sh" "$N" ${RESUME[@]+"${RESUME[@]}"} ${MODE[@]+"${MODE[@]}"})
  code=$?
  case $code in
    0) break ;;
    4) exit 4 ;;
    5)
      next_or 5
      continue
      ;;
    *) die "start failed for #$N (exit $code)" ;;
  esac
done
DIR=$(sed -n 's/^WORKTREE=//p' <<<"$OUT" | tail -1)
cd "$DIR" || die "no checkout for #$N"
STATE=$(factory_state_dir)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 5. Record the attempt: on GitHub, then here for finish, block and the Stop hook.
WHERE=$([ "$IN_PLACE" -eq 1 ] && echo "in place" || echo "in a worktree")
BODY="<!-- factory:attempt $K branch=$BRANCH -->"$'\n'"**Factory attempt $K of $MAX** started $WHERE on \`$BRANCH\`."
ID=$(factory_api "issues/$N/comments" -f body="$BODY" -q .id) && [[ $ID =~ ^[0-9]+$ ]] ||
  die "could not record attempt $K on #$N"
jq -n --argjson n "$N" --arg b "$BRANCH" --arg h "$(git rev-parse HEAD)" --argjson k "$K" --argjson max "$MAX" \
  --argjson id "$ID" --arg body "$BODY" --arg dir "$DIR" \
  '{ticket: $n, branch: $b, head: $h, attempt: $k, max: $max, status: "open", comment_id: $id, comment_body: $body, dir: $dir,
    started: (now | todate)}' >"$STATE/attempt.json"
# Where this attempt runs, for `factory run` (which starts the session in that checkout).
COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
mkdir -p "$COMMON/factory"
printf '%s\n' "$DIR" >"$COMMON/factory/last-attempt"
say "#$N attempt $K of $MAX on $BRANCH in $DIR"

# 6. The prompt, with what earlier attempts left behind.
PRIOR=$(
  if [ -n "$LAST" ] && jq -e '.body | test("<!-- factory:attempt-end [0-9]+ unfinished")' <<<"$LAST" >/dev/null; then
    echo "The previous attempt ended unfinished. Its report:"
    echo
    jq -r '.body | split("<!-- factory:attempt-end ")[1] | split("\n")[2:] | join("\n")' <<<"$LAST"
    echo
  elif [ -n "$LAST" ] && ! jq -e '.body | test("<!-- factory:attempt-end ")' <<<"$LAST" >/dev/null; then
    echo "The previous attempt stopped without ending (a crash or a stall); it left no report."
    echo
  fi
  if ticket_has_label "$N" rework; then
    echo "This ticket is labelled \`rework\`: its open PR is red or conflicts with $BASE. Read the newest ticket and PR comments, merge origin/$BASE into the branch (never rebase or force-push), and fix the conflicts or the check."
    echo
  fi
  [ "$(git rev-list --count "origin/$BASE..HEAD")" -gt 0 ] &&
    echo "Commits from earlier attempts are on the branch (\`git log origin/$BASE..HEAD\`). Build on them; the last may be a work-in-progress commit that \`factory finish\` made from uncommitted changes." && echo
  echo "Still missing for the PR, as of now:"
  echo
  P=$(factory_done_problems --no-check)
  printf '%s\n' "${P:-- Nothing, apart from a green check.}"
)
# fill <text> <key> <value> — every {{key}} replaced, literally (no pattern or `&` semantics).
fill() {
  local s=$1 k="{{$2}}" out=""
  while [[ $s == *"$k"* ]]; do
    out+=${s%%"$k"*}$3
    s=${s#*"$k"}
  done
  printf '%s' "$out$s"
}
out=$(cat "$FACTORY_DIR/prompts/implement.md")
for kv in N="$N" BRANCH="$BRANCH" DIR="$DIR" STATE="$STATE" PRIOR="$PRIOR"; do
  out=$(fill "$out" "${kv%%=*}" "${kv#*=}")
done
printf '%s\n' "$out"
