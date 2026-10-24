#!/usr/bin/env bash
# start — pick up a ticket. Interactive sessions and `factory attempt` run this same code.
#   factory start [<issue> | next] [--parent <n>] [--resume] [--in-place]
#   --resume    the ticket may already be in progress (an earlier attempt's, or a rework): its
#               existing branch is picked up, from origin when this clone does not have it
#   --in-place  check the branch out in this clone instead of a worktree (cloud runs: each one
#               is a fresh clone, and the session works where it started)
# Exit codes: 0 started (last line: WORKTREE=<path>, the checkout), 3 nothing to start,
#             4 base branch red, 5 ticket blocked during pickup, 1 error.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq
factory_require_config

WHICH=next
PARENT=""
RESUME=0
IN_PLACE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)
      PARENT=${2:?--parent needs an issue number}
      shift
      ;;
    --resume) RESUME=1 ;;
    --in-place) IN_PLACE=1 ;;
    next | [0-9]*) WHICH=$1 ;;
    *) die "usage: factory start [<issue> | next] [--parent <n>] [--resume] [--in-place]" ;;
  esac
  shift
done

HERE=$(git rev-parse --show-toplevel) || die "not in a git checkout"
MAIN=$(factory_main_root)
cd "$MAIN" || exit 1
CONFIG="$MAIN/.factory/config.json"
BASE=$(factory_base_branch)
SLUG=$(factory_repo_slug)
[ -n "$SLUG" ] || die "no GitHub repo for $MAIN"

# 1. Latest factory. Each new session follows factory main; the running session keeps the
#    plugin it started with. Skipped when developing the factory itself (FACTORY_HOME).
#    No plugin in place (cloud runs load the factory through the thin layer).
if [ -z "${FACTORY_HOME:-}" ] && [ "$IN_PLACE" -eq 0 ] && command -v claude >/dev/null 2>&1; then
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

# 3. Pick the ticket.
if [ "$WHICH" = next ]; then
  N=$(bash "$FACTORY_SCRIPTS/cmd/tickets.sh" next ${PARENT:+"$PARENT"}) || {
    say "no ticket is ready: every open agent-task is in progress, blocked, or waiting on a blocker"
    exit 3
  }
else
  N=$WHICH
fi
T=$(ticket_json "$N") || die "cannot read issue #$N"
[ "$(jq -r .state <<<"$T")" = open ] || die "#$N is not open"
[ "$(jq -r '.pull_request // empty' <<<"$T")" = "" ] || die "#$N is a pull request, not a ticket"
LABELS=$(jq -r '.labels[].name' <<<"$T")
grep -qx agent-task <<<"$LABELS" || die "#$N is not labelled agent-task"
grep -qx blocked <<<"$LABELS" && die "#$N is blocked; a human answers the question first"
if [ "$RESUME" -eq 0 ]; then
  grep -qx in-progress <<<"$LABELS" && die "#$N is already in progress (the label is the lock)"
fi
OPEN_BLOCKERS=$(factory_open_blockers "$N") || die "cannot read #$N's blockers"
[ -z "$OPEN_BLOCKERS" ] || die "#$N waits for #${OPEN_BLOCKERS// /, #} to merge"
TITLE=$(jq -r .title <<<"$T")
BODY=$(jq -r '.body // ""' <<<"$T")

# 4. Lock.
if grep -qx in-progress <<<"$LABELS"; then
  FRESH=0
  say "#$N resumed: $TITLE"
else
  FRESH=1
  factory_label_add "$N" in-progress || die "could not label #$N in-progress"
  say "#$N locked: $TITLE"
fi
# unlock — a failed pickup releases only a lock it took itself.
unlock() { [ "$FRESH" -eq 0 ] || factory_label_remove "$N" in-progress; }

# 5. Prerequisites: unticked boxes block. The human ticks them; secrets are never inspected.
#    A resumed ticket passed them when it was first picked up.
UNTICKED=$(markdown_section "$BODY" Prerequisites | grep -E '^\s*[-*] \[ \]' | sed -E 's/^\s*[-*] \[ \] *//' | grep -vE '^(…|\.\.\.)?$' || true)
if [ "$RESUME" -eq 0 ] && [ -n "$UNTICKED" ]; then
  factory_block_ticket "$N" "prerequisites not confirmed: $(paste -sd ';' <<<"$UNTICKED")"
  exit 5
fi

# 6. The branch: the ticket's existing one (this clone's, else origin's, where an earlier attempt
#    pushed its work), or a fresh one from the base.
git fetch -q origin "$BASE" || die "could not fetch $BASE"
BRANCH=$(git for-each-ref --format='%(refname:short)' "refs/heads/ticket/$N-*" | head -1)
REMOTE=$(git ls-remote --heads origin "refs/heads/ticket/$N-*" 2>/dev/null | awk '{sub("refs/heads/", "", $2); print $2; exit}')
[ -n "$BRANCH" ] || BRANCH=$REMOTE
[ -n "$BRANCH" ] || BRANCH="ticket/$N-$(ticket_slug "$TITLE")"
if [ -n "$REMOTE" ] && [ "$REMOTE" = "$BRANCH" ]; then
  git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "could not fetch $BRANCH"
  say "resuming $BRANCH from origin"
else
  REMOTE=""
fi
# catch_up <dir> — fast-forward the checkout to origin's copy of the branch (pushed by an attempt
# that ran elsewhere). Diverged work stays as it is; the agent sees both in the attempt's state.
catch_up() {
  [ -n "$REMOTE" ] || return 0
  git -C "$1" merge -q --ff-only "origin/$BRANCH" 2>/dev/null ||
    git -C "$1" merge-base --is-ancestor "origin/$BRANCH" HEAD || warn "$BRANCH and origin/$BRANCH have diverged"
}
run_setup() {
  local setup
  setup=$(jq -r '.setup.command // empty' "$CONFIG")
  [ -n "$setup" ] || return 0
  say "setup: $setup"
  (cd "$1" && bash -c "$setup") || {
    unlock
    die "setup failed in $1"
  }
}

if [ "$IN_PLACE" -eq 1 ]; then
  WT=$HERE
  cd "$WT" || exit 1
  if [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
    [ -z "$(git status --porcelain)" ] || {
      unlock
      die "$WT has uncommitted changes; an in-place ticket starts from a clean tree"
    }
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git checkout -q "$BRANCH"
    elif [ -n "$REMOTE" ]; then
      git checkout -q -b "$BRANCH" "origin/$BRANCH"
    else
      git checkout -q -b "$BRANCH" "origin/$BASE"
    fi || {
      unlock
      die "could not check out $BRANCH"
    }
  fi
  catch_up "$WT"
  # Every cloud run is a fresh clone, so the project's setup runs every time.
  run_setup "$WT"
else
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
    [ -n "$(git -C "$WT" status --porcelain)" ] || catch_up "$WT"
  else
    mkdir -p "$(dirname "$WT")"
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git worktree add -q "$WT" "$BRANCH" || die "could not add worktree for $BRANCH"
      catch_up "$WT"
    elif [ -n "$REMOTE" ]; then
      git worktree add -q -b "$BRANCH" "$WT" "origin/$BRANCH" || die "could not create $BRANCH"
    else
      git worktree add -q -b "$BRANCH" "$WT" "origin/$BASE" || die "could not create $BRANCH"
    fi
    # Gitignored files the project needs (e.g. .env) are copied by this script, never by an agent.
    while IFS= read -r f; do
      [ -n "$f" ] && [ -e "$MAIN/$f" ] && cp -R "$MAIN/$f" "$WT/$f" && say "copied $f into the worktree"
    done < <(jq -r '.setup.copy[]? // empty' "$CONFIG")
    run_setup "$WT"
  fi
fi

# 7. The base must be green before the ticket starts; a red base is not the ticket's fault.
#    Only checked on a fresh branch: a reused worktree already carries the ticket's own work.
CHECK=$(jq -r .check "$CONFIG")
if [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse "origin/$BASE")" ]; then
  if ! (cd "$WT" && bash -c "$CHECK" >/dev/null 2>&1); then
    unlock
    warn "\`$CHECK\` is red on a fresh $BASE. No ticket starts until $BASE is fixed."
    exit 4
  fi
fi

# 8. Run state for the later steps (never committed: it lives in the git dir). A clone works on
#    one ticket after another in place, so another ticket's leftovers go first.
STATE=$(cd "$WT" && factory_state_dir)
if [ "$(cat "$STATE/ticket" 2>/dev/null)" != "$N" ]; then
  rm -rf "$STATE/pr-body.md" "$STATE/review.json" "$STATE/review-current" "$STATE/attempt.json"
fi
printf '%s\n' "$N" >"$STATE/ticket"
# A PR description draft to fill in, from the factory's template (the project may not have its
# own copy yet, e.g. while a factory sync PR is open).
if [ ! -f "$STATE/pr-body.md" ]; then
  sed "s/^Closes #<!-- ticket number -->/Closes #$N/" "$FACTORY_PLUGIN/templates/github/pull_request_template.md" >"$STATE/pr-body.md"
fi
SPEC=$(grep -oE 'docs/specs/[A-Za-z0-9._/-]+\.md' <<<"$BODY" | head -1)
say "ready: $(jq -r .html_url <<<"$T")"
[ -n "$SPEC" ] && say "spec: $SPEC"
say "branch $BRANCH in $WT"
say "next: cd $WT, implement, fill in $STATE/pr-body.md, commit, then: factory review begin $N"
echo "WORKTREE=$WT"
