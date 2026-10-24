#!/usr/bin/env bash
# stop-gate.sh — Stop hook, the quality gate. The agent may not finish a turn while the
# project's check command is red. Exit 2 blocks the stop and feeds the failure back;
# exit 1 would block nothing.
set -u
. "$(dirname "$0")/lib.sh"

INPUT=$(cat)
factory_require_jq
CONFIG=$(factory_config)
[ -f "$CONFIG" ] || exit 0

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
