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
SHELL_FILES=$(git ls-files --cached --others --exclude-standard '*.sh' 'plugins/factory/scripts/factory')
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

if [ -d classifier ]; then
  step "classifier tests"
  node --test classifier/ || fail "classifier tests"
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
  claude plugin validate --strict . >/dev/null || fail "marketplace manifest (claude plugin validate --strict .)"
  claude plugin validate --strict plugins/factory >/dev/null || fail "plugin (claude plugin validate --strict plugins/factory)"
else
  echo "claude CLI not installed; skipping manifest validation"
fi

[ "$FAIL" -eq 0 ] && echo "check: green" || echo "check: RED"
exit "$FAIL"
