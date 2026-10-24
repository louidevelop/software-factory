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

# Done criteria (decisions, step 4).
[ -z "$(git status --porcelain)" ] || die "the tree is not clean; commit or discard first"
[ "$(git rev-list --count "origin/$BASE..HEAD")" -gt 0 ] || die "no commits on $BRANCH"
CHECK=$(factory_cfg '.check')
say "running \`$CHECK\`"
(bash -c "$CHECK" >/dev/null 2>&1) || die "\`$CHECK\` is red; a PR never opens red"

DRAFT="$STATE/pr-body.md"
[ -f "$DRAFT" ] || die "no PR description at $DRAFT (fill .github/pull_request_template.md there)"
for s in Verification Decisions; do
  [ -n "$(markdown_section "$(cat "$DRAFT")" "$s" | grep -vE '^\s*(<!--.*-->)?\s*$')" ] || die "PR description: '## $s' is empty"
done

REVIEW="$STATE/review.json"
[ -f "$REVIEW" ] || die "no local review yet: factory review begin $N (then the reviewer and judges, then assemble $N)"
[ "$(jq -r .head "$REVIEW")" = "$(git rev-parse HEAD)" ] ||
  die "the local review is for an older commit: after fixing confirmed findings run factory review resolve-begin $N and assemble $N --resolve; otherwise review again"

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
TITLE=$(gh issue view "$N" --json title -q .title)
EXISTING=$(gh pr list --head "$BRANCH" --state open --json number -q '.[0].number')
if [ -n "$EXISTING" ]; then
  gh pr edit "$EXISTING" --body "$BODY" >/dev/null && say "updated PR #$EXISTING"
else
  gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY"
fi
say "the factory gate now classifies the PR and merges it, or asks the owner"
