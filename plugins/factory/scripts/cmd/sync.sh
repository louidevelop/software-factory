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
# in this factory version is skipped. The .factory/bin scripts are the thin layer every session
# loads the factory through (see templates/bin/).
MANAGED_FILES=(
  "github/ISSUE_TEMPLATE/agent-task.md .github/ISSUE_TEMPLATE/agent-task.md"
  "github/pull_request_template.md .github/pull_request_template.md"
  "github/factory-gate.yml .github/workflows/factory-gate.yml"
  "bin/factory.sh .factory/bin/factory"
  "bin/fetch.sh .factory/bin/fetch"
  "bin/hook.sh .factory/bin/hook"
)
SETTINGS=.claude/settings.json

# stub <instruction file> — its frontmatter, and a body that loads the instructions from the
# runtime. The frontmatter stays in the project because Claude Code reads it before anything
# runs: an agent's name and tools, a skill's description (what triggers it).
stub() {
  local name
  name=$(basename "$1" .md)
  [ "$name" = SKILL ] && name=$(basename "$(dirname "$1")")
  awk 'NR == 1 && $0 == "---" { fm = 1; print; next } fm { print } fm && $0 == "---" { exit }' "$1"
  printf '\n%s\n' "Run \`.factory/bin/factory prompt $name\` and follow its output exactly: it is the factory's full, current instructions for this."
}

# stage <dir> — write every managed file, as it should be in this checkout, under <dir>.
stage() {
  local entry src dst f
  for entry in "${MANAGED_FILES[@]}"; do
    src=${entry%% *}
    dst=${entry#* }
    [ -f "$T/$src" ] || continue
    mkdir -p "$1/$(dirname "$dst")"
    cp "$T/$src" "$1/$dst"
  done
  mkdir -p "$1/.claude/agents"
  for f in "$FACTORY_PLUGIN"/agents/*.md; do stub "$f" >"$1/.claude/agents/$(basename "$f")"; done
  for f in "$FACTORY_PLUGIN"/skills/*/SKILL.md; do
    mkdir -p "$1/.claude/skills/$(basename "$(dirname "$f")")"
    stub "$f" >"$1/.claude/skills/$(basename "$(dirname "$f")")/SKILL.md"
  done
  # settings.json: sync owns only the `hooks` key (replaced whole), so the project's permissions
  # and everything else survive. The plugin keys go: the thin layer replaces the plugin, and both
  # at once would run every hook twice.
  if [ -f "$SETTINGS" ]; then cat "$SETTINGS"; else echo '{}'; fi |
    jq --slurpfile h "$T/settings-hooks.json" '.hooks = $h[0].hooks | del(.enabledPlugins, .extraKnownMarketplaces)' \
      >"$1/$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON; fix it, then sync again"
}

# same <staged> <project file> — JSON compares by content, so a reformatted settings.json is current.
same() {
  case "$2" in
    *.json) [ -f "$2" ] && [ "$(jq -S . "$1")" = "$(jq -S . "$2" 2>/dev/null)" ] ;;
    *) cmp -s "$1" "$2" ;;
  esac
}

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
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
stage "$STAGE"
while IFS= read -r f; do
  same "$STAGE/$f" "$f" || BEHIND+=("$f")
done < <(cd "$STAGE" && find . -type f | sed 's#^\./##' | sort)

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
  OPEN_HEADS=$(factory_api_list "pulls?state=open&per_page=100") || die "cannot list open PRs"
  if jq -r '.[].head.ref' <<<"$OPEN_HEADS" | grep -q '^factory-sync'; then
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
# Staged again here: in a sync PR's worktree, settings.json is the base branch's, not the checkout's.
rm -rf "$STAGE" && mkdir -p "$STAGE" && stage "$STAGE"
while IFS= read -r f; do
  same "$STAGE/$f" "$f" && continue
  mkdir -p "$(dirname "$f")"
  cp "$STAGE/$f" "$f"
  case "$f" in .factory/bin/*) chmod +x "$f" ;; esac
done < <(cd "$STAGE" && find . -type f | sed 's#^\./##' | sort)
say "wrote: ${BEHIND[*]}"

if [ "$MODE" = pr ]; then
  git add -A
  git commit -qm "factory sync: update factory-managed files" -m "Updated: ${BEHIND[*]}" ||
    die "nothing to commit after sync"
  git push -q -u origin "$BRANCH"
  factory_pr_create "$BASE" "$BRANCH" "factory sync" "$(
    cat <<BODY
Updates the files the software factory manages in this project to the latest factory \`main\`.

Updated: ${BEHIND[*]}

Sessions load the factory through \`.factory/bin/\`: every session start fetches factory \`main\`
into the git directory, and the hooks, agents and skills run from that copy. This replaces the
factory plugin, so its keys leave \`.claude/settings.json\`. If the plugin is still enabled in your
user settings, disable it for this project, or every factory hook runs twice (\`factory doctor\` checks).

This PR touches guardrail files, so the gate always routes it to a human. It carries no ticket
on purpose: a sync is never mixed into ticket work.
BODY
  )"
  cd "$ROOT" && git worktree remove --force "$WT" >/dev/null 2>&1
fi
