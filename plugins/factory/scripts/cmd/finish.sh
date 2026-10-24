#!/usr/bin/env bash
# finish — end the open attempt (see `factory attempt`). When the ticket is done (a clean tree,
# commits, a green check, a PR description with Verification and Decisions, a local review of
# HEAD) it runs open-pr. Otherwise it commits and pushes the work in progress, never opening a
# PR, and records what is missing in the attempt's ticket comment, where the next attempt (on any
# machine) reads it.
#   factory finish [<issue>]
# Exit codes: 0 finished (the PR is open) or the attempt had already ended, 7 ended unfinished,
#             1 error.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq
factory_require_config

N=${1:-}
if [ -n "$N" ]; then
  [[ $N =~ ^[0-9]+$ ]] || die "usage: factory finish [<issue>]"
  DIR=$(factory_ticket_worktree "$N")
  [ -n "$DIR" ] || die "no checkout of ticket #$N"
else
  DIR=$(git rev-parse --show-toplevel) || die "not in a git checkout"
fi
cd "$DIR" || exit 1
F=$(factory_attempt_file "$DIR") || die "no attempt in $DIR: \`factory attempt\` starts one"
[ -n "$N" ] || N=$(jq -r .ticket "$F")
[ "$(jq -r .ticket "$F")" = "$N" ] || die "the attempt in $DIR is for #$(jq -r .ticket "$F"), not #$N"
K=$(jq -r .attempt "$F")
STATUS=$(jq -r .status "$F")
case "$STATUS" in
  finished | blocked)
    say "#$N attempt $K already ended: $STATUS"
    exit 0
    ;;
esac
BASE=$(factory_base_branch)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if ticket_has_label "$N" blocked; then
  attempt_end "$F" blocked
  say "#$N is blocked; attempt $K ended"
  exit 0
fi

# Done? The cheap criteria first; open-pr runs them again with the check, so it runs once.
git fetch -q origin "$BASE" || warn "could not fetch $BASE; conflicts are judged against the last fetched copy"
PROBLEMS=$(factory_done_problems --no-check)
if [ -z "$PROBLEMS" ]; then
  if OUT=$(bash "$FACTORY_SCRIPTS/cmd/open-pr.sh" "$N" 2>&1); then
    printf '%s\n' "$OUT" >&2
    factory_label_remove "$N" rework
    attempt_end "$F" finished "The PR is open."
    say "#$N attempt $K finished: the PR is open"
    exit 0
  fi
  PROBLEMS="- open-pr refused:"$'\n```\n'"$(tail -40 <<<"$OUT")"$'\n```'
else
  PROBLEMS=$(factory_done_problems)
fi

# Unfinished: keep the work for the next attempt, which may run on a fresh machine.
NOTES=""
if [ -n "$(git status --porcelain)" ]; then
  if git add -A && git commit -qm "factory: work in progress on #$N (attempt $K, unfinished)"; then
    NOTES+=$'\n'"- Uncommitted changes were committed as a work-in-progress commit."
  else
    NOTES+=$'\n'"- Uncommitted changes could not be committed; they stay in $DIR only."
  fi
fi
if [ "$(git rev-list --count "origin/$BASE..HEAD")" -gt 0 ]; then
  if git push -q -u origin "$BRANCH"; then
    NOTES+=$'\n'"- The work in progress is pushed to \`$BRANCH\`."
  else
    NOTES+=$'\n'"- Pushing \`$BRANCH\` failed; the work stays in $DIR only."
  fi
fi
REPORT="Missing for the PR:"$'\n\n'"$PROBLEMS"$'\n'"$NOTES"
attempt_end "$F" unfinished "$REPORT"
warn "#$N attempt $K ended UNFINISHED; the next attempt resumes it."
printf '%s\n' "$REPORT" >&2
echo "Your attempt is over: end the session now." >&2
exit 7
