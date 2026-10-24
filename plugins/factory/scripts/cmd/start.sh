#!/usr/bin/env bash
# start — pick up a ticket. Interactive sessions and the unattended loop run this same code.
#   factory start [<issue> | next] [--parent <n>]
# Exit codes: 0 started (last line: WORKTREE=<path>), 3 nothing to start, 4 base branch red,
#             5 ticket blocked during pickup, 1 error.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq
factory_require_config

WHICH=next
PARENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)
      PARENT=${2:?--parent needs an issue number}
      shift
      ;;
    next | [0-9]*) WHICH=$1 ;;
    *) die "usage: factory start [<issue> | next] [--parent <n>]" ;;
  esac
  shift
done

MAIN=$(factory_main_root)
cd "$MAIN" || exit 1
CONFIG="$MAIN/.factory/config.json"
BASE=$(factory_base_branch)
SLUG=$(factory_repo_slug)
[ -n "$SLUG" ] || die "no GitHub repo for $MAIN"

# 1. Latest factory. Each new session follows factory main; the running session keeps the
#    plugin it started with. Skipped when developing the factory itself (FACTORY_HOME).
if [ -z "${FACTORY_HOME:-}" ] && command -v claude >/dev/null 2>&1; then
  say "updating the factory plugin"
  claude plugin marketplace update software-factory >/dev/null 2>&1 || warn "could not update the software-factory marketplace"
  claude plugin update factory@software-factory >/dev/null 2>&1 || warn "could not update factory@software-factory"
fi

# 2. Factory-managed files behind? Open (or keep) a sync PR; the ticket continues meanwhile.
if ! bash "$FACTORY_SCRIPTS/cmd/sync.sh" >/dev/null 2>&1; then
  bash "$FACTORY_SCRIPTS/cmd/sync.sh" --pr || warn "could not open the factory sync PR"
fi

# 2b. Features whose tickets are all closed get their "Archive spec" PR.
bash "$FACTORY_SCRIPTS/cmd/archive-specs.sh" || warn "could not check for finished specs"

# 3. Factory PRs that fell behind the base cannot merge (the gate requires up to date).
#    Updating them here, as the machine user, triggers a fresh check + gate run.
for n in $(gh pr list --state open --json number,headRefName -q '.[] | select(.headRefName | startswith("ticket/")) | .number'); do
  head=$(gh pr view "$n" --json headRefOid -q .headRefOid)
  behind=$(gh api "repos/$SLUG/compare/$BASE...$head" -q .behind_by 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then
    gh pr update-branch "$n" >/dev/null 2>&1 && say "updated PR #$n with $BASE" || warn "could not update PR #$n"
  fi
done

# 4. Pick the ticket.
if [ "$WHICH" = next ]; then
  N=$(bash "$FACTORY_SCRIPTS/cmd/tickets.sh" next ${PARENT:+"$PARENT"}) || {
    say "no ticket is ready: every open agent-task is in progress, blocked, or waiting on a blocker"
    exit 3
  }
else
  N=$WHICH
fi
T=$(ticket_json "$N") || die "cannot read issue #$N"
[ "$(jq -r .state <<<"$T")" = OPEN ] || die "#$N is not open"
LABELS=$(jq -r '.labels[].name' <<<"$T")
grep -qx agent-task <<<"$LABELS" || die "#$N is not labelled agent-task"
grep -qx blocked <<<"$LABELS" && die "#$N is blocked; a human answers the question first"
grep -qx in-progress <<<"$LABELS" && die "#$N is already in progress (the label is the lock)"
OPEN_BLOCKERS=$(gh api "repos/$SLUG/issues/$N/dependencies/blocked_by" -q '[.[] | select(.state == "open") | "#\(.number)"] | join(", ")' 2>/dev/null)
[ -z "$OPEN_BLOCKERS" ] || die "#$N waits for $OPEN_BLOCKERS to merge"
TITLE=$(jq -r .title <<<"$T")
BODY=$(jq -r .body <<<"$T")

# 5. Lock.
gh issue edit "$N" --add-label in-progress >/dev/null || die "could not label #$N in-progress"
say "#$N locked: $TITLE"

# 6. Prerequisites: unticked boxes block. The human ticks them; secrets are never inspected.
UNTICKED=$(markdown_section "$BODY" Prerequisites | grep -E '^\s*[-*] \[ \]' | sed -E 's/^\s*[-*] \[ \] *//' | grep -vE '^(…|\.\.\.)?$' || true)
if [ -n "$UNTICKED" ]; then
  factory_block_ticket "$N" "prerequisites not confirmed: $(paste -sd ';' <<<"$UNTICKED")"
  exit 5
fi

# 7. Worktree on a fresh branch from the base.
git fetch -q origin "$BASE" || die "could not fetch $BASE"
BRANCH="ticket/$N-$(ticket_slug "$TITLE")"
# Inside the project, so the session's working directory, file tools and the review subagents
# (which start in the project folder) all reach it. Kept out of git via the local exclude file,
# which the project's tools honour like .gitignore.
WT="$MAIN/.factory/worktrees/ticket-$N"
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
if ! git check-ignore -q "$MAIN/.factory/worktrees/x" 2>/dev/null; then
  mkdir -p "$(dirname "$EXCLUDE")"
  printf '\n# software factory: ticket worktrees\n/.factory/worktrees/\n' >>"$EXCLUDE"
fi
if [ -d "$WT" ]; then
  say "reusing worktree $WT"
else
  mkdir -p "$(dirname "$WT")"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add -q "$WT" "$BRANCH" || die "could not add worktree for $BRANCH"
  else
    git worktree add -q -b "$BRANCH" "$WT" "origin/$BASE" || die "could not create $BRANCH"
  fi
  # Gitignored files the project needs (e.g. .env) are copied by this script, never by an agent.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$MAIN/$f" ] && cp -R "$MAIN/$f" "$WT/$f" && say "copied $f into the worktree"
  done < <(jq -r '.setup.copy[]? // empty' "$CONFIG")
  SETUP=$(jq -r '.setup.command // empty' "$CONFIG")
  if [ -n "$SETUP" ]; then
    say "setup: $SETUP"
    (cd "$WT" && bash -c "$SETUP") || {
      gh issue edit "$N" --remove-label in-progress >/dev/null
      die "setup failed in $WT"
    }
  fi
fi

# 8. The base must be green before the ticket starts; a red base is not the ticket's fault.
#    Only checked on a fresh branch: a reused worktree already carries the ticket's own work.
CHECK=$(jq -r .check "$CONFIG")
if [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse "origin/$BASE")" ]; then
  if ! (cd "$WT" && bash -c "$CHECK" >/dev/null 2>&1); then
    gh issue edit "$N" --remove-label in-progress >/dev/null
    warn "\`$CHECK\` is red on a fresh $BASE. No ticket starts until $BASE is fixed."
    exit 4
  fi
fi

# 9. Run state for the later steps (never committed: it lives in the git dir).
STATE=$(cd "$WT" && factory_state_dir)
printf '%s\n' "$N" >"$STATE/ticket"
# A PR description draft to fill in, from the factory's template (the project may not have its
# own copy yet, e.g. while a factory sync PR is open).
if [ ! -f "$STATE/pr-body.md" ]; then
  sed "s/^Closes #<!-- ticket number -->/Closes #$N/" "$FACTORY_PLUGIN/templates/github/pull_request_template.md" >"$STATE/pr-body.md"
fi
SPEC=$(grep -oE 'docs/specs/[A-Za-z0-9._/-]+\.md' <<<"$BODY" | head -1)
say "ready: $(jq -r .url <<<"$T")"
[ -n "$SPEC" ] && say "spec: $SPEC"
say "branch $BRANCH in $WT"
say "next: cd $WT, implement, fill in $STATE/pr-body.md, commit, then: factory review begin $N"
echo "WORKTREE=$WT"
