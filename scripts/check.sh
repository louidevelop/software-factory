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

step "plugin manifests"
if command -v claude >/dev/null 2>&1; then
  # Strict apart from the deliberate missing plugin version (see below).
  strict_except_version() {
    claude plugin validate --json "$1" 2>/dev/null | jq -e '.success
      and ([.manifest.errors[]?, (.contents[]?.errors[]?)] | length == 0)
      and ([.manifest.warnings[]?, (.contents[]?.warnings[]?) | select(.path | test("(^|→ )version$") | not)] | length == 0)' >/dev/null
  }
  strict_except_version . || fail "marketplace manifest (claude plugin validate --json .)"
  # Strict, except the one warning we want: the plugin has NO version on purpose, so Claude Code
  # versions it by git commit and `claude plugin update` always moves projects to factory main.
  # A fixed semver would freeze every project on that version until someone bumps it.
  strict_except_version plugins/factory || fail "plugin (claude plugin validate --json plugins/factory)"
  jq -e '.version == null' plugins/factory/.claude-plugin/plugin.json >/dev/null ||
    fail "plugins/factory/.claude-plugin/plugin.json must not pin a version (projects follow main)"
else
  echo "claude CLI not installed; skipping manifest validation"
fi

[ "$FAIL" -eq 0 ] && echo "check: green" || echo "check: RED"
exit "$FAIL"
