#!/usr/bin/env bash
# .factory/bin/hook <name> — managed by the software factory (factory sync). Do not edit.
# Runs the factory runtime's hooks/<name>.sh with this hook's input on stdin. The project's
# .claude/settings.json calls every factory hook through here (.factory/bin/fetch keeps the runtime
# current).
#
# Hooks fail closed: with no runtime this exits 2, which blocks the tool call and tells the model
# why. The one call let through is running .factory/bin/fetch, so a session whose start-up fetch
# failed can still recover. A Stop that was already blocked once is let go, so a session without
# a runtime can still end.
set -u
NAME=${1:-}
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)

runtime() {
  local d
  if [ -n "${FACTORY_HOME:-}" ]; then
    for d in "$FACTORY_HOME" "$FACTORY_HOME/plugins/factory"; do
      [ -x "$d/scripts/factory" ] && printf '%s' "$d" && return 0
    done
    return 1
  fi
  d=$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)/factory-runtime/plugins/factory
  [ -x "$d/scripts/factory" ] && printf '%s' "$d"
}

[[ $NAME =~ ^[a-z][a-z-]*$ ]] || {
  echo "factory: .factory/bin/hook needs a hook name, got '$NAME'. Blocking." >&2
  exit 2
}
if RT=$(runtime) && [ -f "$RT/hooks/$NAME.sh" ]; then
  exec bash "$RT/hooks/$NAME.sh"
fi

INPUT=$(cat)
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" = true ] && exit 0
  CMD=$(jq -r 'select(.tool_name == "Bash") | .tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
  [[ $CMD =~ ^[[:space:]]*([^[:space:]]*/)?\.factory/bin/fetch[[:space:]]*$ ]] && exit 0
fi
if [ -n "${RT:-}" ]; then
  echo "factory: the factory runtime at $RT has no hooks/$NAME.sh. Blocking." >&2
else
  echo "factory: no factory runtime in this project's git directory, so the factory's hooks cannot run and every tool call is blocked. Run \`.factory/bin/fetch\` (the one command allowed until it succeeds); it needs network access to the factory repo." >&2
fi
exit 2
