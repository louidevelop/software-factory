#!/usr/bin/env bash
# hooks.test.sh — feeds recorded-shape hook input to each hook and asserts the exit code
# and the reason on stderr. Each case runs against a throwaway project with its own
# .factory/config.json, so nothing here touches a real repo.
set -u
HOOKS="$(cd "$(dirname "$0")/../plugins/factory/hooks" && pwd)"
PASS=0
FAIL=0

PROJECT=$(mktemp -d)
trap 'rm -rf "$PROJECT"' EXIT
mkdir -p "$PROJECT/.factory" "$PROJECT/src"
cat >"$PROJECT/.factory/config.json" <<'JSON'
{
  "version": 1,
  "owners": ["someone"],
  "check": "test ! -f FAIL_CHECK || { echo 'tests: 1 failed'; exit 1; }",
  "fix": [
    { "glob": "*.txt", "command": "grep -q BAD {file} && { echo 'lint: BAD in {file}'; exit 1; } || exit 0" }
  ],
  "block": [{ "pattern": "migrate +--remote", "reason": "remote migrations are applied by a human." }]
}
JSON
export CLAUDE_PROJECT_DIR="$PROJECT"

# expect <name> <hook> <expected exit> <stderr substring or ""> <json>
expect() {
  local name=$1 hook=$2 want=$3 needle=$4 input=$5 err code
  err=$(printf '%s' "$input" | "$HOOKS/$hook" 2>&1 >/dev/null)
  code=$?
  if [ "$code" -ne "$want" ] || { [ -n "$needle" ] && [[ $err != *"$needle"* ]]; }; then
    echo "FAIL $name: exit $code (want $want); stderr: ${err:-<empty>}"
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}
bash_input() { jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
file_input() { jq -cn --arg t "$1" --arg p "$2" '{tool_name: $t, tool_input: {file_path: $p}}'; }

# ---------- block-dangerous: blocked ----------
for cmd in \
  'cat .env' 'source .env.local' 'cp .env /tmp/x' 'grep KEY .env' 'printenv' 'env | grep TOKEN' \
  'echo $OPENAI_API_KEY' 'git push --force origin x' 'git push -f' 'git reset --hard HEAD~1' \
  'git clean -fd' 'git branch -D x' 'rm -rf build' 'rm -fr /' 'sudo ls' 'npm publish' \
  'cargo publish' 'gh pr merge 3 --squash' 'gh pr review 3 --approve' 'gh api -X PUT repos/o/r/pulls/3/merge' 'psql -c "DROP TABLE users"' 'echo "truncate table events"' 'migrate --remote'; do
  expect "blocks: $cmd" block-dangerous.sh 2 "BLOCKED" "$(bash_input "$cmd")"
done
expect "project reason is shown" block-dangerous.sh 2 "applied by a human" "$(bash_input 'migrate --remote')"
for tool in Read Edit Write; do
  expect "blocks $tool .env" block-dangerous.sh 2 "Secrets" "$(file_input "$tool" "$PROJECT/.env")"
done
expect "blocks Grep on .env.production" block-dangerous.sh 2 "Secrets" \
  "$(jq -cn --arg p "$PROJECT/.env.production" '{tool_name: "Grep", tool_input: {pattern: "x", path: $p}}')"

# ---------- block-dangerous: allowed ----------
for cmd in \
  'cat .env.example' 'git push -u origin ticket/12-x' 'git status' 'rm build/out.txt' \
  'npm install left-pad' 'uv add httpx' 'echo environment' 'grep -r env src' 'git checkout -b x' \
  'ls -la' 'migrate --local' 'gh pr create --fill' 'gh pr view 3' 'gh pr update-branch 3'; do
  expect "allows: $cmd" block-dangerous.sh 0 "" "$(bash_input "$cmd")"
done
expect "allows Read .env.example" block-dangerous.sh 0 "" "$(file_input Read "$PROJECT/.env.example")"
expect "allows Read src file" block-dangerous.sh 0 "" "$(file_input Read "$PROJECT/src/a.py")"

# ---------- after-edit ----------
echo "fine" >"$PROJECT/src/ok.txt"
echo "BAD" >"$PROJECT/src/bad.txt"
echo "BAD" >"$PROJECT/src/other.md"
expect "after-edit passes clean file" after-edit.sh 0 "" "$(file_input Edit "$PROJECT/src/ok.txt")"
expect "after-edit returns unfixable problems with exit 2" after-edit.sh 2 "lint: BAD in src/bad.txt" \
  "$(file_input Write "$PROJECT/src/bad.txt")"
expect "after-edit ignores files no glob matches" after-edit.sh 0 "" "$(file_input Edit "$PROJECT/src/other.md")"
expect "after-edit ignores files outside the project" after-edit.sh 0 "" "$(file_input Edit /etc/hosts)"

# ---------- stop-gate ----------
expect "stop-gate passes on green check" stop-gate.sh 0 "" '{"stop_hook_active": false}'
touch "$PROJECT/FAIL_CHECK"
expect "stop-gate blocks on red check" stop-gate.sh 2 "tests: 1 failed" '{"stop_hook_active": false}'
expect "stop-gate lets go once already active" stop-gate.sh 0 "" '{"stop_hook_active": true}'
rm "$PROJECT/FAIL_CHECK"

# ---------- no config: every hook is a no-op ----------
mv "$PROJECT/.factory/config.json" "$PROJECT/.factory/off.json"
expect "no config: Bash not blocked" block-dangerous.sh 0 "" "$(bash_input 'rm -rf build')"
expect "no config: stop not gated" stop-gate.sh 0 "" '{"stop_hook_active": false}'
mv "$PROJECT/.factory/off.json" "$PROJECT/.factory/config.json"

# ---------- glob dialect (shared with the classifier) ----------
. "$HOOKS/lib.sh"
glob_case() {
  if factory_glob_match "$1" "$2"; then got=0; else got=1; fi
  if [ "$got" -eq "$3" ]; then PASS=$((PASS + 1)); else
    echo "FAIL glob: '$1' vs '$2' (want $3)"
    FAIL=$((FAIL + 1))
  fi
}
glob_case src/app/main.py '*.py' 0
glob_case main.py '*.py' 0
glob_case migrations/0001.sql 'migrations/**' 0
glob_case src/db/migrations/1.sql '**/migrations/**' 0
glob_case migrations/1.sql '**/migrations/**' 0
glob_case src/main.ts '*.py' 1
glob_case a.b.c 'a?b?c' 0
glob_case 'docs/specs/001-x.md' 'docs/specs/*' 0
glob_case 'xdocs/specs/1.md' 'docs/specs/*' 1
glob_case src/a.tsx '*.{ts,tsx}' 0
glob_case src/a.ts '*.{ts,tsx}' 0
glob_case src/a.js '*.{ts,tsx}' 1
glob_case 'a,b' 'a,b' 0
glob_case 'pkg/(x).go' 'pkg/(x).go' 0

echo "hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
