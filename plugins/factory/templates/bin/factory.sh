#!/usr/bin/env bash
# .factory/bin/factory — managed by the software factory (factory sync). Do not edit.
# Runs the `factory` command of this project's factory runtime, the copy of factory main that
# .factory/bin/fetch keeps in the git directory. Every session start updates it; from a plain
# terminal with no copy yet, this fetches it first.
#   FACTORY_HOME=/path/to/software-factory  a local factory used as-is (factory development)
set -u
BIN=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$BIN/../.." && pwd -P)

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

RT=$(runtime) || {
  "$BIN/fetch" >&2 && RT=$(runtime)
} || {
  echo "factory: no factory runtime; run .factory/bin/fetch once it can reach the factory repo." >&2
  exit 1
}
exec "$RT/scripts/factory" "$@"
