#!/usr/bin/env bash
# sync — keep the factory-managed files in a project identical to the latest factory.
#   factory sync          report what is behind (exit 10 if anything is)
#   factory sync --apply  write the managed files in place (bootstrap uses this)
#   factory sync --pr     open a "factory sync" PR; never mixed into a ticket PR
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git jq

MODE="report"
case "${1:-}" in
  --apply) MODE="apply" ;;
  --pr) MODE="pr" ;; # quoted: `pr` is also a command (SC2209)
  "") ;;
  *) die "usage: factory sync [--apply | --pr]" ;;
esac

ROOT=$(factory_root)
cd "$ROOT" || exit 1
T="$FACTORY_PLUGIN/templates"

sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-12; }

# Managed whole files: "<template> <project path>". A template that does not exist yet
# in this factory version is skipped.
MANAGED_FILES=(
  "github/ISSUE_TEMPLATE/agent-task.md .github/ISSUE_TEMPLATE/agent-task.md"
  "github/pull_request_template.md .github/pull_request_template.md"
  "github/factory-gate.yml .github/workflows/factory-gate.yml"
  "factory-shim.sh .factory/bin/factory"
)

BLOCK_SHA=$(sha <"$T/agents-block.md")
BEGIN_RE='^<!-- factory:begin'
END_LINE='<!-- factory:end -->'

block_status() {
  [ -f AGENTS.md ] || {
    echo missing
    return
  }
  grep -q "$BEGIN_RE" AGENTS.md || {
    echo missing
    return
  }
  # Current means the marker names the template's hash AND the content between the markers
  # still is that template: a hand edit inside the block counts as behind.
  local inside
  inside=$(awk -v end="$END_LINE" '/^<!-- factory:begin/ { on = 1; next } on && $0 == end { exit } on { print }' AGENTS.md | sha)
  if grep -q "^<!-- factory:begin sha=$BLOCK_SHA -->$" AGENTS.md && [ "$inside" = "$BLOCK_SHA" ]; then
    echo current
  else
    echo behind
  fi
}

write_block() {
  [ -f AGENTS.md ] || printf '# Rules for agents\n\n%s\n%s\n' '<!-- factory:begin -->' "$END_LINE" >AGENTS.md
  grep -q "$BEGIN_RE" AGENTS.md || printf '\n%s\n%s\n' '<!-- factory:begin -->' "$END_LINE" >>AGENTS.md
  local tmp
  tmp=$(mktemp)
  awk -v begin="<!-- factory:begin sha=$BLOCK_SHA -->" -v end="$END_LINE" -v body="$T/agents-block.md" '
    /^<!-- factory:begin/ { print begin; while ((getline line < body) > 0) print line; skip = 1; next }
    skip && $0 == end { print; skip = 0; next }
    !skip { print }
  ' AGENTS.md >"$tmp" && mv "$tmp" AGENTS.md
}

BEHIND=()
[ "$(block_status)" = current ] || BEHIND+=("AGENTS.md (factory block)")
for entry in "${MANAGED_FILES[@]}"; do
  src=${entry%% *}
  dst=${entry#* }
  [ -f "$T/$src" ] || continue
  cmp -s "$T/$src" "$dst" 2>/dev/null || BEHIND+=("$dst")
done

if [ ${#BEHIND[@]} -eq 0 ]; then
  say "factory-managed files are current"
  exit 0
fi

if [ "$MODE" = report ]; then
  say "behind the factory: ${BEHIND[*]}"
  exit 10
fi

if [ "$MODE" = pr ]; then
  factory_require gh
  if gh pr list --state open --json headRefName -q '.[].headRefName' | grep -q '^factory-sync'; then
    say "a factory sync PR is already open; leaving it for review"
    exit 0
  fi
  BASE=$(factory_base_branch)
  BRANCH="factory-sync-$BLOCK_SHA-$(date +%Y%m%d%H%M%S)"
  [ -z "$(git status --porcelain)" ] || die "working tree is dirty; a sync PR starts from a clean tree"
  git fetch -q origin "$BASE"
  WT=$(mktemp -d)/sync
  git worktree add -q -b "$BRANCH" "$WT" "origin/$BASE" || die "could not create sync worktree"
  cd "$WT" || exit 1
fi

write_block
for entry in "${MANAGED_FILES[@]}"; do
  src=${entry%% *}
  dst=${entry#* }
  [ -f "$T/$src" ] || continue
  mkdir -p "$(dirname "$dst")"
  cp "$T/$src" "$dst"
  case "$dst" in .factory/bin/*) chmod +x "$dst" ;; esac
done
say "wrote: ${BEHIND[*]}"

if [ "$MODE" = pr ]; then
  git add -A
  git commit -qm "factory sync: update factory-managed files" -m "Updated: ${BEHIND[*]}" ||
    die "nothing to commit after sync"
  git push -q -u origin "$BRANCH"
  gh pr create --base "$BASE" --head "$BRANCH" --title "factory sync" --body "$(
    cat <<BODY
Updates the files the software factory manages in this project to the latest factory \`main\`.

Updated: ${BEHIND[*]}

This PR touches guardrail files, so the gate always routes it to a human. It carries no ticket
on purpose: a sync is never mixed into ticket work.
BODY
  )"
  cd "$ROOT" && git worktree remove --force "$WT" >/dev/null 2>&1
fi
