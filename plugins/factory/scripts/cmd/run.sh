#!/usr/bin/env bash
# run — one ticket, unattended, on this machine: `factory attempt`, then one fresh `claude -p`
# session per attempt (implement, the local review through the factory's reviewer/judge/resolver
# SUBAGENTS, fixes, `factory finish`), until the PR is open or the ticket is blocked. It never
# moves on to another ticket: the owner starts the next run.
#   factory run [<issue> | next] [--parent <n>]
# Each attempt is a brand-new context in auto permission mode with prompts auto-denied; the hooks
# are the second layer: they keep the review subagents unbriefed and read-only, and the Stop hook
# keeps a session from ending before `factory finish` or `factory block`. This is the only part
# of the factory that needs headless claude -p.
# Exit codes: 0 the PR is open, 3 nothing to do, 4 base branch red, 5 the ticket is blocked,
#             6 busy (another attempt is live), 1 error.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq claude
factory_require_config

WHICH=next
PARENT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --parent)
      PARENT=(--parent "${2:?--parent needs an issue number}")
      shift
      ;;
    next | [0-9]*) WHICH=$1 ;;
    *) die "usage: factory run [<issue> | next] [--parent <n>]" ;;
  esac
  shift
done

MODEL=$(factory_cfg '.run.model')
TURNS=$(factory_cfg '.run.maxTurns')
CLAUDE_ARGS=(--permission-mode auto --permission-prompts none)
[ -n "$MODEL" ] && CLAUDE_ARGS+=(--model "$MODEL")
[ -n "$TURNS" ] && claude --help 2>/dev/null | grep -q -- '--max-turns' && CLAUDE_ARGS+=(--max-turns "$TURNS")
COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)

# Each pass is one attempt; `factory attempt` counts them on GitHub and blocks the ticket past
# run.maxAttempts, which is what ends this loop when no attempt finishes.
while :; do
  PROMPT=$(bash "$FACTORY_SCRIPTS/cmd/attempt.sh" "$WHICH" ${PARENT[@]+"${PARENT[@]}"} --worktree)
  code=$?
  case $code in
    0) ;;
    3) exit 3 ;;
    4) die "the base branch is red; fix it before the next run" ;;
    5)
      warn "the ticket is blocked; its question is the owner's to answer"
      exit 5
      ;;
    6) exit 6 ;;
    *) die "attempt failed (exit $code)" ;;
  esac
  DIR=$(cat "$COMMON/factory/last-attempt")
  cd "$DIR" || die "no checkout at $DIR"
  STATE=$(factory_state_dir)
  N=$(jq -r .ticket "$STATE/attempt.json")
  K=$(jq -r .attempt "$STATE/attempt.json")
  WHICH=$N # the next pass resumes this ticket, never another one
  mkdir -p "$STATE/logs"
  LOG="$STATE/logs/attempt-$K-$(date +%Y%m%d-%H%M%S).log"
  say "#$N attempt $K — fresh session (log: $LOG)"
  claude -p "$PROMPT" "${CLAUDE_ARGS[@]}" </dev/null >"$LOG" 2>&1
  # The Stop hook holds a session until it ran finish or block, but a session can still die
  # (max turns, a crash): then finish runs here.
  [ "$(jq -r .status "$STATE/attempt.json")" = open ] && bash "$FACTORY_SCRIPTS/cmd/finish.sh" "$N"
  case "$(jq -r .status "$STATE/attempt.json")" in
    finished)
      say "#$N: the PR is open; the gate takes it from here"
      exit 0
      ;;
    blocked)
      warn "#$N blocked itself; its question is the owner's to answer"
      exit 5
      ;;
  esac
done
