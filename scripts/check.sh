#!/usr/bin/env bash
# check.sh — the factory's own gate. Every project follows factory main, so a red main
# breaks everyone: this runs locally and in CI, and must be green before a PR merges.
set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0
step() { echo "== $1"; }
fail() { echo "FAILED: $1"; FAIL=1; }

step "JSON is valid"
while IFS= read -r f; do
  jq empty "$f" 2>/dev/null || fail "invalid JSON: $f"
done < <(git ls-files --cached --others --exclude-standard '*.json')

step "shell scripts parse"
SHELL_FILES=$(git ls-files --cached --others --exclude-standard '*.sh' 'plugins/factory/scripts/factory' 'tests/fake-gh/gh')
for f in $SHELL_FILES; do
  bash -n "$f" || fail "syntax: $f"
  [ -x "$f" ] || fail "not executable: $f"
done

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086 # word splitting is the point: one argument per file
  shellcheck -x -S warning $SHELL_FILES || fail "shellcheck"
elif [ -n "${CI:-}" ]; then
  fail "shellcheck is required in CI"
else
  echo "shellcheck not installed locally; CI runs it"
fi

step "hook tests"
bash tests/hooks.test.sh || fail "hook tests"

step "script tests"
bash tests/scripts.test.sh || fail "script tests"

step "attempt tests"
bash tests/attempt.test.sh || fail "attempt tests"

step "thin layer tests"
bash tests/thin-layer.test.sh || fail "thin layer tests"

step "review record tests"
bash tests/review.test.sh || fail "review tests"

if [ -d classifier ]; then
  step "classifier tests"
  node --test classifier/*.test.mjs || fail "classifier tests"
fi

if [ -f scripts/validate-config.mjs ]; then
  step "example configs match the schema"
  for f in plugins/factory/templates/config.example.json examples/*/factory-config.json; do
    [ -f "$f" ] || continue
    node scripts/validate-config.mjs "$f" || fail "config: $f"
  done
fi

step "thin layer sources"
# What a project's thin layer points at must exist in the runtime: each hook its settings.json runs
# through .factory/bin/hook, and the frontmatter sync copies into each agent and skill stub (Claude
# Code reads that before anything runs: an agent's name and tools, a skill's description).
F=plugins/factory
while IFS= read -r h; do
  [ -f "$F/hooks/$h.sh" ] || fail "settings-hooks.json runs hook '$h', but $F/hooks/$h.sh does not exist"
done < <(jq -r '.hooks[][].hooks[].command | capture("\\.factory/bin/hook (?<n>[a-z-]+)").n' "$F/templates/settings-hooks.json")
frontmatter() { awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { exit } fm { print }' "$1"; }
for f in "$F"/agents/*.md "$F"/skills/*/SKILL.md; do
  name=$(basename "$f" .md)
  [ "$name" = SKILL ] && name=$(basename "$(dirname "$f")")
  fm=$(frontmatter "$f")
  grep -qx "name: $name" <<<"$fm" || fail "$f: frontmatter needs 'name: $name'"
  grep -q '^description: .' <<<"$fm" || fail "$f: frontmatter needs a description"
  case "$f" in "$F"/agents/*) grep -q '^tools: .' <<<"$fm" || fail "$f: frontmatter needs tools (review agents stay read-only)" ;; esac
done

[ "$FAIL" -eq 0 ] && echo "check: green" || echo "check: RED"
exit "$FAIL"
