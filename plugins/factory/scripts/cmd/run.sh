#!/usr/bin/env bash
# run — the unattended loop, one ticket at a time:
#   start → one fresh `claude -p` session per attempt (implement, then the local review through
#   the factory's reviewer/judge/resolver SUBAGENTS, fixes, resolve) → open-pr → next
#   factory run [<parent-issue>]
# Each attempt is a brand-new context in auto permission mode with prompts auto-denied; the
# plugin's hooks are the second layer and keep the review subagents unbriefed and read-only.
# Stops when nothing is ready (or the base branch is red). This loop is the only part of the factory that needs headless claude -p.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq claude
factory_require_config

PARENT=${1:-}
MAIN=$(factory_main_root)
CONFIG="$MAIN/.factory/config.json"
MAX=$(jq -r '.run.maxAttempts // 3' "$CONFIG")
MODEL=$(jq -r '.run.model // empty' "$CONFIG")
TURNS=$(jq -r '.run.maxTurns // empty' "$CONFIG")
FACTORY="$FACTORY_SCRIPTS/factory"

CLAUDE_ARGS=(--permission-mode auto --permission-prompts none)
[ -n "$MODEL" ] && CLAUDE_ARGS+=(--model "$MODEL")
[ -n "$TURNS" ] && claude --help 2>/dev/null | grep -q -- '--max-turns' && CLAUDE_ARGS+=(--max-turns "$TURNS")
[ -n "${FACTORY_HOME:-}" ] && CLAUDE_ARGS+=(--plugin-dir "$FACTORY_HOME")

fill() { # fill <template> key=value... — replaces {{KEY}} with value
  local out
  out=$(cat "$FACTORY_PLUGIN/prompts/$1")
  shift
  local kv
  for kv in "$@"; do out=${out//"{{${kv%%=*}}}"/${kv#*=}}; done
  printf '%s' "$out"
}

is_blocked() { ticket_has_label "$1" blocked; }

describe_state() { # what the previous attempt left behind, for the next fresh session
  local base=$1 state=$2 msgs=()
  [ -n "$(git status --porcelain)" ] && msgs+=("UNCOMMITTED work is in the tree. Read \`git status\` and \`git diff\`; keep what is right, fix or discard the rest.")
  [ "$(git rev-list --count "origin/$base..HEAD")" -gt 0 ] && msgs+=("Commits from earlier attempts are on the branch (\`git log origin/$base..HEAD\`). Build on them.")
  [ -f "$state/pr-body.md" ] || msgs+=("No PR description at $state/pr-body.md yet.")
  if [ ! -f "$state/review.json" ]; then
    msgs+=("The local review has not been assembled yet (step 6).")
  elif [ "$(jq -r .head "$state/review.json")" != "$(git rev-parse HEAD)" ]; then
    msgs+=("The local review is for an older commit: if confirmed findings were fixed, run resolve-begin and assemble --resolve; otherwise begin the review again.")
  fi
  [ -n "${CHECK_TAIL:-}" ] && msgs+=("The check is RED. Last lines:"$'\n```\n'"$CHECK_TAIL"$'\n```')
  [ ${#msgs[@]} -eq 0 ] && msgs=("None — fresh start.")
  printf '%s\n\n' "${msgs[@]}"
}

while :; do
  OUT=$(bash "$FACTORY_SCRIPTS/cmd/start.sh" next ${PARENT:+--parent "$PARENT"})
  code=$?
  case $code in
    0) ;;
    3)
      bash "$FACTORY_SCRIPTS/cmd/archive-specs.sh" || warn "could not check for finished specs"
      say "nothing ready to start — loop done"
      exit 0
      ;;
    4) die "the base branch is red; fix it before the loop continues" ;;
    5) continue ;; # blocked at pickup (prerequisites); try the next ticket
    *) die "start failed (exit $code)" ;;
  esac
  WT=$(sed -n 's/^WORKTREE=//p' <<<"$OUT" | tail -1)
  cd "$WT" || die "no worktree"
  STATE=$(factory_state_dir)
  N=$(cat "$STATE/ticket")
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  BASE=$(factory_base_branch)
  CHECK=$(factory_cfg '.check')
  mkdir -p "$STATE/logs"

  DONE=0
  CHECK_TAIL=""
  for ATTEMPT in $(seq 1 "$MAX"); do
    PROMPT=$(fill implement.md N="$N" BRANCH="$BRANCH" STATE="$STATE" FACTORY="$FACTORY" \
      ATTEMPT="$ATTEMPT" MAX="$MAX" PRIOR="$(describe_state "$BASE" "$STATE")")
    LOG="$STATE/logs/implement-$ATTEMPT-$(date +%Y%m%d-%H%M%S).log"
    say "#$N attempt $ATTEMPT/$MAX — fresh session (log: $LOG)"
    claude -p "$PROMPT" "${CLAUDE_ARGS[@]}" </dev/null >"$LOG" 2>&1
    if is_blocked "$N"; then
      warn "#$N blocked itself; moving on"
      DONE=2
      break
    fi
    if [ -z "$(git status --porcelain)" ] && [ "$(git rev-list --count "origin/$BASE..HEAD")" -gt 0 ] && [ -f "$STATE/pr-body.md" ] &&
      [ "$(jq -r .head "$STATE/review.json" 2>/dev/null)" = "$(git rev-parse HEAD)" ]; then
      if CHECK_OUT=$(bash -c "$CHECK" 2>&1); then
        DONE=1
        break
      fi
      CHECK_TAIL=$(tail -40 <<<"$CHECK_OUT")
    fi
  done
  [ "$DONE" -eq 2 ] && continue
  if [ "$DONE" -ne 1 ]; then
    factory_block_ticket "$N" "the run did not finish after $MAX attempts (logs in $STATE/logs on the runner)."
    continue
  fi

  bash "$FACTORY_SCRIPTS/cmd/open-pr.sh" "$N" || factory_block_ticket "$N" "opening the PR failed; see the runner's output."
  cd "$MAIN" || exit 1
done
