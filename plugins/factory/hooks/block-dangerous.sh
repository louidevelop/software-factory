#!/usr/bin/env bash
# block-dangerous.sh — PreToolUse on Bash and file tools.
# Exit 2 + stderr = blocked, reason fed back to the agent. Exit 0 = allowed.
#
# Only what cannot be undone belongs here. Adding a dependency or writing a migration is
# allowed; the PR classifier routes those to a human. The universal core lives in this
# file; project-specific commands come from `block` in .factory/config.json.
# This is a backstop behind permissions.deny in the project's .claude/settings.json.
set -u
. "$(dirname "$0")/lib.sh"

INPUT=$(cat)
factory_require_jq
export FACTORY_ROOT_HINT # read by factory_root in lib.sh
FACTORY_ROOT_HINT=$(jq -r '.cwd // empty' <<<"$INPUT")
CONFIG=$(factory_config)
[ -f "$CONFIG" ] || exit 0

TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT")

block() {
  echo "BLOCKED by the factory blocklist: $1" >&2
  echo "If this is genuinely needed, stop and ask the human to do it." >&2
  exit 2
}

is_env_file() {
  case "$(basename "$1")" in
    .env.example | .env.template | .env.sample) return 1 ;;
    .env | .env.*) return 0 ;;
  esac
  return 1
}

# ---------- File tools: never read or write secrets ----------
case "$TOOL" in
  Read | Edit | Write | MultiEdit | Grep)
    for field in file_path path; do
      P=$(jq -r ".tool_input.$field // empty" <<<"$INPUT")
      if [ -n "$P" ] && is_env_file "$P"; then
        block "$TOOL on $(basename "$P"). Secrets are never read or written by an agent; use .env.example for the shape."
      fi
    done
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
[ -n "$CMD" ] || exit 0
NORM=$(printf '%s' "$CMD" | tr -s '[:space:]' ' ')
matches() { printf '%s' "$NORM" | grep -qE "$1"; }
matches_i() { printf '%s' "$NORM" | grep -qiE "$1"; }

# ---------- Secrets ----------
# Any command that mentions a .env file (not .env.example and friends).
if matches '(^|[ /"'"'"'=<>])\.env([ "'"'"';&|)<>]|$|\.(local|production|development|staging|test|prod|dev)\b)'; then
  block "touching a .env file. Secrets are never read, printed, copied, or sourced by an agent."
fi
if matches '(^|[ ;&|(])(printenv|env)( *$| *[;&|>)])|echo +[^;&|]*\$\{?[A-Z_]*(KEY|TOKEN|SECRET|PASSWORD|DATABASE_URL)'; then
  block "printing environment secrets."
fi

# ---------- Git history ----------
if matches 'git +push +[^|;&]*(--force\b|-f\b|--force-with-lease)'; then
  block "force push. History is resolved by a human."
fi
if matches 'git +(reset +--hard|clean +-[a-zA-Z]*f|checkout +-- +\.|restore +[^|;&]*--source|branch +-D|filter-branch|filter-repo)'; then
  block "history-destroying git command."
fi

# ---------- Merging is the gate's job ----------
# An agent never merges, approves, or bypasses the factory gate, whoever it is logged in as.
if matches '(^|[ ;&|(])gh +pr +(merge|review)\b|gh +api\b.*/pulls/[0-9]+/(merge|reviews)\b'; then
  block "merging or reviewing a PR. The factory gate merges; a human approves."
fi

# ---------- Filesystem ----------
if matches '(^|[ ;&|(])(sudo +)?rm +(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|-r +-f|-f +-r|--recursive +--force|--force +--recursive)\b'; then
  block "'rm -rf'. Delete specific files with plain rm, or ask the human."
fi
if matches '(^|[ ;&|(])sudo '; then
  block "sudo. Nothing in a project needs root."
fi

# ---------- Publishing ----------
if matches '(^|[ ;&|(])(npm +publish|yarn +publish|pnpm +publish|cargo +publish|twine +upload|gem +push|uv +publish|poetry +publish)\b'; then
  block "publishing a package."
fi

# ---------- Data ----------
if matches_i '\b(DROP +(TABLE|SCHEMA|DATABASE)|TRUNCATE +(TABLE +)?[a-z_]+)\b'; then
  block "destructive SQL. Schema changes go through migrations, which a human applies."
fi

# ---------- Project extras ----------
while IFS=$'\t' read -r pattern reason; do
  [ -n "$pattern" ] || continue
  if matches "$pattern"; then
    # The default lives in a variable: an apostrophe inside "${reason:-...}" opens a quote.
    fallback="matches the project's blocklist: $pattern"
    block "${reason:-$fallback}"
  fi
done < <(jq -r '.block[]? | [.pattern, (.reason // "")] | @tsv' "$CONFIG")

exit 0
