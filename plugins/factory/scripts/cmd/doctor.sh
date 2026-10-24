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
[ -f "$ROOT/.claude/settings.json" ] && jq -e '.enabledPlugins["factory@software-factory"] == true' "$ROOT/.claude/settings.json" >/dev/null 2>&1 &&
  ok ".claude/settings.json enables the factory plugin" || bad ".claude/settings.json does not enable factory@software-factory"
CHECK_YML="$ROOT/.github/workflows/check.yml"
if [ ! -f "$CHECK_YML" ]; then
  bad ".github/workflows/check.yml missing (the gate runs it)"
elif grep -q 'workflow_dispatch' "$CHECK_YML"; then
  ok "check.yml can be dispatched (the gate checks PRs on the current base with it)"
else
  bad "check.yml has no workflow_dispatch: trigger; the gate needs it to check a PR on the current base"
fi
(cd "$ROOT" && bash "$FACTORY_SCRIPTS/cmd/sync.sh" >/dev/null 2>&1) && ok "factory-managed files are current" || note "factory-managed files are behind (factory sync)"

echo "github"
if gh auth status >/dev/null 2>&1; then
  ME=$(gh api user -q .login 2>/dev/null)
  ok "gh authenticated as $ME"
  if [ -f "$CONFIG" ] && jq -e --arg me "$ME" '.owners | index($me)' "$CONFIG" >/dev/null 2>&1; then
    note "gh acts as an owner ($ME). Agent runs must use the machine user: export GH_TOKEN=<machine user token>"
  fi
  SLUG=$(cd "$ROOT" && factory_repo_slug)
  if [ -n "$SLUG" ]; then
    ok "repo $SLUG"
    LABELS=$(gh label list -R "$SLUG" --limit 200 --json name -q '.[].name' 2>/dev/null)
    for l in agent-task in-progress blocked risk:low risk:high; do
      grep -qx "$l" <<<"$LABELS" && ok "label $l" || bad "label $l missing (factory github-setup --apply)"
    done
  else
    bad "no GitHub remote for this repo"
  fi
else
  bad "gh is not authenticated"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "doctor: ready"; else echo "doctor: $FAILS problem(s)"; fi
[ "$FAILS" -eq 0 ]
