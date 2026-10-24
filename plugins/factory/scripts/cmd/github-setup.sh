#!/usr/bin/env bash
# github-setup — the GitHub side of the factory for one repo. Runs as the OWNER. Without
# --apply it only prints what it would change.
#   factory github-setup [--apply]
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require gh jq

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    *) die "usage: factory github-setup [--apply]" ;;
  esac
  shift
done

cd "$(factory_root)" || exit 1
SLUG=$(factory_repo_slug)
[ -n "$SLUG" ] || die "no GitHub repo for $(pwd)"
BASE=$(factory_base_branch)

REPO_SETTINGS='{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"allow_update_branch":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
# Required checks: the project's own check workflow job and the factory gate. Not "up to date
# before merge" (strict): a PR may be behind, because the gate checks it combined with the current
# base right before merging, and strict would block the gate's own merge of a behind PR.
PROTECTION=$(jq -cn '{
  required_status_checks: {strict: false, contexts: ["check", "gate"]},
  enforce_admins: true,
  required_pull_request_reviews: null,
  restrictions: null,
  allow_force_pushes: false,
  allow_deletions: false
}')

echo "factory github-setup for $SLUG (base branch: $BASE)"
echo "  labels: $(printf '%s ' "${FACTORY_LABELS[@]%%|*}")"
echo "  merge settings: squash only, delete branch on merge, allow update branch"
echo "  branch protection on $BASE: required checks 'check' + 'gate', no force push, admins included"
if [ "$APPLY" -ne 1 ]; then
  echo
  echo "dry run — re-run with --apply to make these changes"
  exit 0
fi

for l in "${FACTORY_LABELS[@]}"; do
  IFS='|' read -r name color desc <<<"$l"
  # Create, or update the label that already exists (REST has no upsert).
  { factory_api labels -f name="$name" -f color="$color" -f description="$desc" >/dev/null 2>&1 ||
    factory_api "labels/$name" -X PATCH -f color="$color" -f description="$desc" >/dev/null; } &&
    say "label $name" || warn "could not create label $name"
done
gh api -X PATCH "repos/$SLUG" --input - <<<"$REPO_SETTINGS" >/dev/null && say "merge settings applied"
if OUT=$(gh api -X PUT "repos/$SLUG/branches/$BASE/protection" --input - <<<"$PROTECTION" 2>&1); then
  say "branch protection applied on $BASE"
else
  case "$OUT" in
    *"Upgrade to GitHub Pro"*)
      warn "branch protection is unavailable for private repos on the free plan."
      warn "The factory gate still decides and performs every merge, and agents are blocked from merging,"
      warn "but GitHub itself does not enforce it. Upgrade to Pro (or make the repo public) for hard enforcement."
      ;;
    *) warn "branch protection failed: $OUT" ;;
  esac
fi
