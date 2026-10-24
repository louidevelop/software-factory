#!/usr/bin/env bash
# github-setup — the GitHub side of the factory for one repo. Runs as the OWNER (not the
# machine user). Without --apply it only prints what it would change.
#   factory github-setup [--machine-user <login>] [--apply]
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require gh jq

APPLY=0
MACHINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --machine-user)
      MACHINE=${2:?--machine-user needs a login}
      shift
      ;;
    *) die "usage: factory github-setup [--machine-user <login>] [--apply]" ;;
  esac
  shift
done

cd "$(factory_root)" || exit 1
SLUG=$(factory_repo_slug)
[ -n "$SLUG" ] || die "no GitHub repo for $(pwd)"
BASE=$(factory_base_branch)

# name|color|description
LABELS=(
  "agent-task|1d76db|A ticket an agent completes without asking questions"
  "in-progress|fbca04|An agent run holds this ticket (also the lock)"
  "blocked|d93f0b|Needs a human: see the latest comment for the question"
  "risk:low|0e8a16|Factory gate: low impact, merges when green"
  "risk:high|b60205|Factory gate: needs owner approval"
  "feature|5319e7|Parent issue tracking a feature spec"
)
REPO_SETTINGS='{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true,"allow_update_branch":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
# Required checks: the project's own check workflow job and the factory gate.
PROTECTION=$(jq -cn '{
  required_status_checks: {strict: true, contexts: ["check", "gate / gate"]},
  enforce_admins: true,
  required_pull_request_reviews: null,
  restrictions: null,
  allow_force_pushes: false,
  allow_deletions: false
}')

echo "factory github-setup for $SLUG (base branch: $BASE)"
echo "  labels: $(printf '%s ' "${LABELS[@]%%|*}")"
echo "  merge settings: squash only, delete branch on merge, allow update branch"
[ -n "$MACHINE" ] && echo "  collaborator: $MACHINE with write (push) access — can push and open PRs; the gate decides merges"
echo "  branch protection on $BASE: required checks 'check' + 'gate / gate', up to date before merge, no force push, admins included"
if [ "$APPLY" -ne 1 ]; then
  echo
  echo "dry run — re-run with --apply to make these changes"
  exit 0
fi

for l in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<<"$l"
  gh label create "$name" -R "$SLUG" --color "$color" --description "$desc" --force >/dev/null && say "label $name"
done
gh api -X PATCH "repos/$SLUG" --input - <<<"$REPO_SETTINGS" >/dev/null && say "merge settings applied"
if [ -n "$MACHINE" ]; then
  gh api -X PUT "repos/$SLUG/collaborators/$MACHINE" -f permission=push >/dev/null &&
    say "invited $MACHINE with write access (they must accept the invitation)"
fi
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
