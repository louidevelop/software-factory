#!/usr/bin/env bash
# .factory/bin/factory — managed by the software factory (factory sync). Do not edit.
# Finds the installed factory plugin and runs its `factory` command, so a terminal (or the
# unattended loop) uses exactly the plugin version Claude Code sessions load.
#   FACTORY_HOME=/path/to/software-factory/plugins/factory  overrides (factory development)
set -u
if [ -n "${FACTORY_HOME:-}" ]; then
  exec "$FACTORY_HOME/scripts/factory" "$@"
fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
INSTALLED="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$INSTALLED" ] && command -v jq >/dev/null 2>&1; then
  # Prefer the install scoped to this project, then the user-wide one.
  DIR=$(jq -r --arg p "$ROOT" '
    .plugins["factory@software-factory"] // [] |
    ((map(select(.projectPath == $p)) + map(select(.scope == "user"))) | first | .installPath) // empty
  ' "$INSTALLED")
  if [ -n "$DIR" ] && [ -x "$DIR/scripts/factory" ]; then
    exec "$DIR/scripts/factory" "$@"
  fi
fi
MARKET="$HOME/.claude/plugins/marketplaces/software-factory/plugins/factory/scripts/factory"
[ -x "$MARKET" ] && exec "$MARKET" "$@"
echo "factory plugin not found. In Claude Code: /plugin marketplace add louidevelop/software-factory, then install factory@software-factory." >&2
exit 1
