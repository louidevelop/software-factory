#!/usr/bin/env bash
# doctor — is this project ready for the factory? Prints one line per check; exit 1 if any fail.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"

FAILS=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  FAILS=$((FAILS + 1))
}
note() { printf '  \033[33m!\033[0m %s\n' "$*"; }

echo "prerequisites"
for t in bash git gh jq claude; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not installed"; fi
done

ROOT=$(factory_root)
CONFIG=$(factory_config)
echo "project ($ROOT)"
if [ -f "$CONFIG" ]; then
  if jq empty "$CONFIG" 2>/dev/null; then ok ".factory/config.json is valid JSON"; else bad ".factory/config.json is not valid JSON"; fi
  for key in version owners check; do
    [ -n "$(factory_cfg ".$key")" ] && ok "config: $key" || bad "config: $key missing"
  done
else
  bad "no .factory/config.json (run the factory-bootstrap skill)"
fi
[ -f "$ROOT/AGENTS.md" ] && grep -q '^<!-- factory:begin' "$ROOT/AGENTS.md" && ok "AGENTS.md has the factory block" || bad "AGENTS.md has no factory block (factory sync --apply)"
[ "$(cat "$ROOT/CLAUDE.md" 2>/dev/null)" = "@AGENTS.md" ] && ok "CLAUDE.md imports AGENTS.md" || note "CLAUDE.md is not exactly '@AGENTS.md'"
# The factory loads one of two ways: the thin layer (.claude/settings.json runs .factory/bin/fetch
# and .factory/bin/hook) or, until a project has synced, the Claude Code plugin. The plugin's
# enabled state is the most specific settings file that sets it: user, then project, then local.
PLUGIN=false
for f in "$HOME/.claude/settings.json" "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
  # select, not `// empty`: `//` would treat an explicit false as unset.
  v=$(jq -r '.enabledPlugins["factory@software-factory"] | select(. != null)' "$f" 2>/dev/null)
  [ -n "$v" ] && PLUGIN=$v
done
THIN=false
jq -e '[.hooks[]?[]?.hooks[]?.command] | any(test("\\.factory/bin/fetch")) and any(test("\\.factory/bin/hook "))' \
  "$ROOT/.claude/settings.json" >/dev/null 2>&1 && [ -x "$ROOT/.factory/bin/fetch" ] && [ -x "$ROOT/.factory/bin/hook" ] && THIN=true
if [ "$THIN" = true ] && [ "$PLUGIN" = true ]; then
  ok "the factory loads through .factory/bin (thin layer)"
  note "the factory plugin is enabled too, so every factory hook runs twice: disable factory@software-factory (/plugin) for this project"
elif [ "$THIN" = true ]; then
  ok "the factory loads through .factory/bin (thin layer)"
elif [ "$PLUGIN" = true ]; then
  ok "the factory plugin is enabled"
  note "this project still loads the factory as a plugin; factory sync --pr moves it to the thin layer"
else
  bad "the factory is not loaded: .claude/settings.json has no factory hooks (factory sync --apply)"
fi
CHECK_YML="$ROOT/.github/workflows/check.yml"
if [ ! -f "$CHECK_YML" ]; then
  bad ".github/workflows/check.yml missing (the gate runs it)"
elif grep -q 'workflow_dispatch' "$CHECK_YML"; then
  ok "check.yml can be dispatched (the gate checks PRs on the current base with it)"
else
  bad "check.yml has no workflow_dispatch: trigger; the gate needs it to check a PR on the current base"
fi
# The runtime: fetch it the way every session start does, so a project that cannot reach the
# factory repo shows up here rather than as hooks blocking every tool call.
if [ -x "$ROOT/.factory/bin/fetch" ]; then
  if OUT=$("$ROOT/.factory/bin/fetch" 2>&1); then
    if grep -q 'last good copy' <<<"$OUT"; then
      note "could not update the factory runtime; sessions use the last good copy until .factory/bin/fetch reaches the factory repo"
    else
      ok "$(tail -n1 <<<"$OUT")"
    fi
  else
    bad "the factory runtime does not fetch: $(tail -n1 <<<"$OUT" | sed 's/^factory: //')"
  fi
fi
# A thin layer that is behind still works (main keeps every older layer working), so it is a note:
# the fix is a sync PR, not something to block on.
if BEHIND=$(cd "$ROOT" && bash "$FACTORY_SCRIPTS/cmd/sync.sh" 2>&1); then
  ok "factory-managed files are current"
else
  note "factory-managed files are behind: $(sed -n 's/.*behind the factory: //p' <<<"$BEHIND") (factory sync --pr)"
fi

echo "github"
# REST, like every factory call to GitHub (`gh auth status` is not, in Claude's cloud).
ME=$(gh api user -q .login 2>/dev/null)
if [ -n "$ME" ]; then
  ok "gh authenticated as $ME"
  SLUG=$(cd "$ROOT" && factory_repo_slug)
  if [ -n "$SLUG" ]; then
    ok "repo $SLUG"
    LABELS=$(cd "$ROOT" && factory_api_list "labels?per_page=100" 2>/dev/null | jq -r '.[].name')
    for l in agent-task in-progress blocked risk:low risk:high merge; do
      grep -qx "$l" <<<"$LABELS" && ok "label $l" || bad "label $l missing (factory github-setup --apply)"
    done
  else
    bad "no GitHub remote for this repo"
  fi
else
  bad "gh is not authenticated"
fi

# The cloud routine is optional, so nothing here fails the doctor. The gate starts the routine only
# when the project has both (classifier/, factory-gate.yml). Existence only: nothing a reply holds
# is printed, and GitHub never returns a secret's value anyway. REST rather than `gh variable list` /
# `gh secret list`, which this command may run where only REST reaches GitHub.
echo "cloud (optional: only for running tickets in Claude's cloud)"
if [ -n "${SLUG:-}" ]; then
  CLOUD=0
  for kind in variable:FACTORY_ROUTINE_URL secret:FACTORY_ROUTINE_TOKEN; do
    name=${kind#*:}
    if (cd "$ROOT" && factory_api "actions/${kind%%:*}s/$name" >/dev/null 2>&1); then
      ok "${kind%%:*} $name"
      CLOUD=$((CLOUD + 1))
    else
      note "no ${kind%%:*} $name (see the cloud setup in the factory-bootstrap skill)"
    fi
  done
  case $CLOUD in
    2) ok "the gate starts the cloud routine after merges and while waiting for the owner" ;;
    1) note "the gate needs both FACTORY_ROUTINE_URL and FACTORY_ROUTINE_TOKEN to start the cloud routine" ;;
    *) note "local only: the gate does not start a cloud routine" ;;
  esac
else
  note "skipped: no GitHub repo to read"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "doctor: ready"; else echo "doctor: $FAILS problem(s)"; fi
[ "$FAILS" -eq 0 ]
