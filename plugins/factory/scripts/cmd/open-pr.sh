#!/usr/bin/env bash
# open-pr — push the ticket branch and open its PR, with the local review attached.
# Run from the ticket's worktree after `factory review` (and `--resolve` when it asked for fixes).
#   factory open-pr [<issue>]
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq
factory_require_config

N=${1:-$(cat "$(factory_state_dir)/ticket" 2>/dev/null)}
[[ $N =~ ^[0-9]+$ ]] || die "usage: factory open-pr <issue>"
WT=$(factory_ticket_worktree "$N")
[ -n "$WT" ] || die "no checkout of ticket #$N: factory start $N first"
cd "$WT" || exit 1
STATE=$(factory_state_dir)
BASE=$(factory_base_branch)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
case "$BRANCH" in ticket/"$N"-*) ;; *) die "branch $BRANCH is not ticket #$N's branch" ;; esac

# Done criteria, the check included: a PR never opens red.
say "checking the done criteria (with \`$(factory_cfg '.check')\`)"
PROBLEMS=$(factory_done_problems)
[ -z "$PROBLEMS" ] || die "not ready for a PR:"$'\n'"$PROBLEMS"
DRAFT="$STATE/pr-body.md"
REVIEW="$STATE/review.json"

# The draft's own "## Local review" (template placeholder) is replaced by the real one.
BODY=$(awk '/^## Local review/ { exit } { print }' "$DRAFT")
grep -qiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?) #'"$N"'\b' <<<"$BODY" || BODY="Closes #$N"$'\n\n'"$BODY"
BODY+=$'\n'"$(jq -r '
  def item: "- **\(.title)** (`\(.file // "?"):\(.line // "?")`) — \(.detail)";
  def list(xs): if (xs | length) == 0 then "- None" else (xs | map(item) | join("\n")) end;
  "## Local review\n\n" +
  "Unresolved blocking findings: \(.unresolved | length)\n\n" +
  "Reviewer and judges ran as unbriefed, read-only subagents on \(.head[0:7]) (model: \(.model)).\n\n" +
  "**Confirmed blocking, fixed:**\n" + list(.fixed) + "\n\n" +
  (if (.unresolved | length) > 0 then "**Confirmed blocking, NOT resolved — the human decides:**\n" + list(.unresolved) + "\n\n" else "" end) +
  "**Non-blocking (unverified, not fixed):**\n" + list(.nonblocking) + "\n\n" +
  "<details><summary>Rejected by the judges (\(.rejected | length))</summary>\n\n" + list(.rejected) + "\n\n</details>"
' "$REVIEW")"

git push -q -u origin "$BRANCH" || die "push failed"
TITLE=$(factory_api "issues/$N" -q .title) || die "cannot read issue #$N"
EXISTING=$(factory_open_pr "$BRANCH") || die "cannot list the open PRs for $BRANCH"
if [ -n "$EXISTING" ]; then
  factory_api "pulls/$EXISTING" -X PATCH -f body="$BODY" >/dev/null || die "could not update PR #$EXISTING"
  say "updated PR #$EXISTING"
else
  factory_pr_create "$BASE" "$BRANCH" "$TITLE" "$BODY" || die "could not open the PR"
fi
say "the factory gate now classifies the PR and merges it, or asks the owner"
