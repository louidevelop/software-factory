#!/usr/bin/env bash
# lib.sh — shared by every factory hook and script. Sourced, never run.
#
# The factory acts only in projects that opt in with .factory/config.json. Without it
# every hook is a no-op, so enabling the plugin globally changes nothing elsewhere.

# jq is a declared prerequisite. Hooks fail CLOSED without it: a guardrail that cannot
# read its input must block, not silently allow.
factory_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "factory: jq is required to inspect tool calls (brew install jq / apt install jq). Blocking." >&2
    exit 2
  fi
}

# The project root: Claude Code's project dir when set, else the git toplevel, else cwd.
factory_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
  else
    git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

factory_config() {
  printf '%s/.factory/config.json' "$(factory_root)"
}

# factory_cfg <jq filter> — read from the project config; empty output when unset.
factory_cfg() {
  jq -r "$1 // empty" "$(factory_config)" 2>/dev/null
}

# Globs everywhere in the factory share one dialect, the same as the classifier's:
# `*` and `**` match any characters INCLUDING `/`, `**/` also matches zero directories,
# `?` matches one character, `{a,b}` matches either. So `*.py` matches `src/app/main.py`.
factory_glob_to_ere() {
  local glob=$1 out="" i c depth=0
  for ((i = 0; i < ${#glob}; i++)); do
    c=${glob:i:1}
    if [ "$c" = "{" ]; then
      out+="("
      depth=$((depth + 1))
    elif [ "$c" = "}" ] && [ $depth -gt 0 ]; then
      out+=")"
      depth=$((depth - 1))
    elif [ "$c" = "," ] && [ $depth -gt 0 ]; then
      out+="|"
    elif [ "${glob:i:3}" = "**/" ]; then
      out+="(.*/)?"
      i=$((i + 2))
    elif [ "${glob:i:2}" = "**" ]; then
      out+=".*"
      i=$((i + 1))
    elif [ "$c" = "*" ]; then
      out+=".*"
    elif [ "$c" = "?" ]; then
      out+="."
    else
      case "$c" in
        [.\[\]\(\)\{\}\+\^\$\|\\]) out+="\\$c" ;;
        *) out+="$c" ;;
      esac
    fi
  done
  printf '^%s$' "$out"
}

# factory_glob_match <relative path> <glob>
factory_glob_match() {
  local re
  re=$(factory_glob_to_ere "$2")
  [[ $1 =~ $re ]]
}
