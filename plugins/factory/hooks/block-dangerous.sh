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

# The factory's own code is fetched per session into .git/factory-runtime/ and runs as these
# hooks; an agent that edits it can switch off any rule. Reading it is fine.
RUNTIME_RE='(^|[ /"'"'"'=])factory-runtime([/ "'"'"';)]|$)'
RUNTIME_WHY="It is the factory's own code, fetched each session; change it in the factory repo."

# ---------- File tools: never read or write secrets ----------
case "$TOOL" in
  Read | Edit | Write | MultiEdit | NotebookEdit | Grep)
    for field in file_path path notebook_path; do
      P=$(jq -r ".tool_input.$field // empty" <<<"$INPUT")
      if [ -n "$P" ] && is_env_file "$P"; then
        block "$TOOL on $(basename "$P"). Secrets are never read or written by an agent; use .env.example for the shape."
      fi
      case "$TOOL" in Read | Grep) continue ;; esac
      if [ -n "$P" ] && printf '%s' "$P" | grep -qE "$RUNTIME_RE"; then
        block "$TOOL on a factory-runtime/ file. $RUNTIME_WHY"
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
# The PR may be any token: 3, $N, {pr}.
if matches '(^|[ ;&|(])gh +pr +(merge|review)\b|gh +api\b.*/pulls/[^/ ]+/(merge|reviews)\b'; then
  block "merging or reviewing a PR. The factory gate merges; the owner gives the go-ahead."
fi
# Cloud sessions reach GitHub through a proxy with its own `ccr` REST routes. Auto-merge merges
# without the gate, and resolving threads can satisfy "conversations resolved" for a reviewer.
# Any client and PR token ($N, {pr}) counts; reading ccr/review_threads stays allowed.
if matches_i '(^|[ ;&|(])(gh +api|curl|wget)\b[^;&|]*/pulls/[^/ ]+/ccr/(auto_merge|comments/[^/ ]+/(resolve|unresolve))\b'; then
  block "auto-merging a PR or resolving its review threads. The factory gate merges; the owner gives the go-ahead."
fi
# The `merge` label is the owner's go-ahead for a PR the gate does not merge alone, and agents act
# as the owner's account, so the gate cannot tell who added it: only this keeps an agent from
# adding it.
# REST sets labels through …/labels and through a `labels[]=` field on an issue or PR.
if matches 'gh +(pr|issue) +(edit|create)\b[^;&|]*(--add-label|--label|-l)( +|=)["'"'"']?([^ "'"'"']*,)?merge(["'"'"', ]|$)' ||
  matches 'gh +api\b[^;&|]*\blabels\b[^;&|]*\bmerge\b'; then
  block "adding the merge label. Only the owner gives a PR the go-ahead."
fi

# ---------- The factory runtime is read-only ----------
# Checked per command segment, so reading the runtime and writing elsewhere stays allowed. A
# `cd` into it makes every later segment count. `$(…)` is kept inline: the runtime path is
# usually `$(git rev-parse --git-common-dir)/factory-runtime`.
if matches "$RUNTIME_RE"; then
  ASSIGN='^([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)*'
  WRITER="${ASSIGN}(rm|rmdir|mv|touch|mkdir|chmod|chown|truncate|unlink|shred|patch|tee|python[0-9.]*|node|deno|ruby|perl)( |$)"
  GIT_WRITE="${ASSIGN}git( +-[Cc] +[^ ]+| +--[a-z-]+(=[^ ]+)?)* +(clone|init|pull|fetch|checkout|switch|reset|restore|clean|merge|rebase|cherry-pick|revert|commit|add|rm|mv|apply|am|stash|update-ref|submodule|worktree)( |$)"
  COPIER="${ASSIGN}(cp|install|rsync|ln)( |$)"
  inside=0
  while IFS= read -r seg; do
    seg=$(sed -E 's/^[ ({!]+|[ })]+$//g' <<<"$seg")
    [ -n "$seg" ] || continue
    here=$inside
    printf '%s' "$seg" | grep -qE "$RUNTIME_RE" && here=1
    if [[ $seg =~ ^(cd|pushd)( |$) ]]; then
      [ "$here" = 1 ] && inside=1
      continue
    fi
    # xargs takes its paths from an earlier segment, which named the runtime.
    [[ $seg =~ ^xargs\  ]] && here=1 && seg=$(sed -E 's/^xargs( +-[^ ]+)* +//' <<<"$seg")
    [ "$here" = 1 ] || continue
    if [[ $seg =~ \>\>?\ ?[^\>]*factory-runtime ]] || { [ "$inside" = 1 ] && [[ $seg == *">"* ]]; } ||
      [[ $seg =~ $WRITER ]] || [[ $seg =~ $GIT_WRITE ]] ||
      [[ $seg =~ ^sed\ (.*\ )?(-[a-zA-Z]*i|--in-place) ]] ||
      [[ $seg =~ ^find\ .*\ -(delete|exec|execdir|ok|okdir)( |$) ]] ||
      [[ $seg =~ ^dd\ .*of= ]] ||
      { [[ $seg =~ $COPIER ]] && { [ "$inside" = 1 ] || [[ ${seg##* } == *factory-runtime* ]]; }; }; then
      block "writing to factory-runtime/. $RUNTIME_WHY"
    fi
  done < <(sed -E 's#[0-9]?>&[0-9]##g; s#[0-9]?> ?/dev/null##g; s/(&&|\|\||;|\||&|`)/\n/g; s/\$\(/ /g' <<<"$NORM")
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
