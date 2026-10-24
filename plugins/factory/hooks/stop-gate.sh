#!/usr/bin/env bash
# stop-gate.sh — Stop hook, the quality gate. Exit 2 blocks the stop and feeds the reason back;
# exit 1 would block nothing.
#   1. While an attempt (`factory attempt`) is open in the session's checkout, the session may
#      not end: it ends through `factory finish` or `factory block`. This is what keeps an
#      unattended run, local or in the cloud, from stopping half-way without a word.
#   2. Otherwise the agent may not finish a turn while the project's check command is red.
set -u
. "$(dirname "$0")/lib.sh"

INPUT=$(cat)
factory_require_jq
export FACTORY_ROOT_HINT # read by factory_root in lib.sh
FACTORY_ROOT_HINT=$(jq -r '.cwd // empty' <<<"$INPUT")
CONFIG=$(factory_config)
[ -f "$CONFIG" ] || exit 0

# Bounds rule 1 instead of the loop guard below: the guard would let the second stop through, so
# the rule would bind only once. A session that ignores it this many times ends anyway; its
# attempt stays open on GitHub and a later attempt resumes it once it is stale.
MAX_STOP_BLOCKS=5
if ATTEMPT=$(factory_attempt_file "$(factory_root)"); then
  [ "$(jq -r .status "$ATTEMPT")" = open ] || exit 0 # ended: it already said what is missing
  N=$(jq -r .ticket "$ATTEMPT")
  BLOCKS=$(jq -r '.stop_blocks // 0' "$ATTEMPT")
  if [ "$BLOCKS" -ge "$MAX_STOP_BLOCKS" ]; then
    echo "factory stop-gate: attempt at #$N is still open after $BLOCKS blocked stops; letting the session end" >&2
    exit 0
  fi
  jq '.stop_blocks = (.stop_blocks // 0) + 1' "$ATTEMPT" >"$ATTEMPT.tmp" && mv "$ATTEMPT.tmp" "$ATTEMPT"
  {
    echo "The factory attempt at ticket #$N is still open, so this session may not end yet."
    echo "End it with \`.factory/bin/factory finish $N\`: it opens the PR when the ticket is done, and otherwise pushes the work in progress and records what is missing for the next attempt."
    echo "If only a human can answer what stops you, run \`.factory/bin/factory block $N \"<the question>\"\` instead."
  } >&2
  exit 2
fi

# Loop guard: if this hook already blocked once this turn, let the turn end. Otherwise a
# check that cannot be fixed traps the agent forever.
[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT")" = "true" ] && exit 0

CHECK=$(factory_cfg '.check')
if [ -z "$CHECK" ]; then
  # Early scaffold: nothing to gate yet. Say so, but do not block.
  echo "factory stop-gate: .factory/config.json has no \"check\" command yet, skipping the gate" >&2
  exit 0
fi

if ! OUT=$(cd "$(factory_root)" && bash -c "$CHECK" 2>&1); then
  {
    echo "\`$CHECK\` FAILED — fix it before finishing the turn. Never skip, weaken, or delete a failing test, lint rule, or check to make it pass."
    echo "--- last 60 lines ---"
    printf '%s\n' "$OUT" | tail -60
  } >&2
  exit 2
fi
exit 0
