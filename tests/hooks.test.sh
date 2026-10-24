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

# ---------- block-dangerous: the merge label is the owner's ----------
for cmd in \
  'gh pr edit 3 --add-label merge' 'gh issue edit 3 --add-label "risk:low,merge"' 'gh pr edit 3 --add-label=merge' \
  'gh pr create --fill --label merge' 'gh pr create --fill -l merge' 'gh api repos/o/r/issues/3/labels -f "labels[]=merge"'; do
  expect "blocks: $cmd" block-dangerous.sh 2 "merge label" "$(bash_input "$cmd")"
done
for cmd in \
  'gh issue edit 3 --add-label in-progress' 'gh pr list --label merge' 'gh pr edit 3 --add-label merged-docs' \
  'gh issue edit 3 --add-label blocked --remove-label in-progress'; do
  expect "allows: $cmd" block-dangerous.sh 0 "" "$(bash_input "$cmd")"
done

# ---------- block-dangerous: the cloud proxy's ccr routes ----------
for cmd in \
  'gh api -X PUT repos/o/r/pulls/3/ccr/auto_merge' 'gh api --method PUT "repos/{owner}/{repo}/pulls/$PR/ccr/auto_merge"' \
  'curl -s -X PUT -H "Authorization: token x" "https://api.github.com/repos/o/r/pulls/3/ccr/auto_merge"' \
  'gh api -X POST repos/o/r/pulls/3/ccr/comments/99/resolve' "curl -X POST 'https://api.github.com/repos/o/r/pulls/3/ccr/comments/99/unresolve'"; do
  expect "blocks: $cmd" block-dangerous.sh 2 "auto-merging" "$(bash_input "$cmd")"
done
for cmd in \
  'gh api repos/o/r/pulls/3/ccr/review_threads' 'curl -s https://api.github.com/repos/o/r/pulls/3/ccr/review_threads' \
  'gh api -X POST repos/o/r/pulls/3/ccr/ready_for_review' 'grep -rn ccr/auto_merge docs'; do
  expect "allows: $cmd" block-dangerous.sh 0 "" "$(bash_input "$cmd")"
done

# ---------- block-dangerous: the factory runtime is read-only ----------
RT="$PROJECT/.git/factory-runtime"
for tool in Edit Write MultiEdit; do
  expect "blocks $tool in factory-runtime" block-dangerous.sh 2 "factory-runtime" "$(file_input "$tool" "$RT/plugins/factory/hooks/lib.sh")"
done
expect "blocks NotebookEdit in factory-runtime" block-dangerous.sh 2 "factory-runtime" \
  "$(jq -cn --arg p "$RT/x.ipynb" '{tool_name: "NotebookEdit", tool_input: {notebook_path: $p, new_source: "x"}}')"
for cmd in \
  'echo exit 0 > .git/factory-runtime/plugins/factory/hooks/lib.sh' 'echo x >> "$(git rev-parse --git-common-dir)/factory-runtime/hooks/lib.sh"' \
  'printf x | tee .git/factory-runtime/a' 'sed -i "" s/2/0/ .git/factory-runtime/hooks/block-dangerous.sh' \
  'rm .git/factory-runtime/hooks/review-guard.sh' 'mv .git/factory-runtime /tmp/old' 'cp /tmp/lib.sh .git/factory-runtime/hooks/' \
  'git -C .git/factory-runtime checkout HEAD~3' 'git clone https://example.com/x.git .git/factory-runtime' \
  'cd .git/factory-runtime && git pull' 'cd .git/factory-runtime; echo x > hooks/lib.sh' \
  'find .git/factory-runtime -name "*.sh" -delete' 'find .git/factory-runtime -name "*.sh" | xargs chmod -x' \
  'python3 -c "open(\".git/factory-runtime/a\",\"w\")"' 'chmod -x .git/factory-runtime/hooks/stop-gate.sh'; do
  expect "blocks: $cmd" block-dangerous.sh 2 "factory-runtime" "$(bash_input "$cmd")"
done
for cmd in \
  'cat .git/factory-runtime/plugins/factory/hooks/lib.sh' 'ls -la "$(git rev-parse --git-common-dir)/factory-runtime"' \
  'git -C .git/factory-runtime log -1 --format=%H' 'grep -rn block .git/factory-runtime/plugins > /tmp/hits.txt' \
  'cp .git/factory-runtime/examples/config.json /tmp/' 'diff .git/factory-runtime/a src/a 2>&1' \
  'bash .git/factory-runtime/plugins/factory/scripts/factory.sh status' 'rm src/factory-runtime-notes.txt'; do
  expect "allows: $cmd" block-dangerous.sh 0 "" "$(bash_input "$cmd")"
done
for tool in Read Grep; do
  expect "allows $tool in factory-runtime" block-dangerous.sh 0 "" \
    "$(jq -cn --arg t "$tool" --arg p "$RT/hooks/lib.sh" '{tool_name: $t, tool_input: {file_path: $p, path: $p, pattern: "x"}}')"
done
expect "allows Edit of a file merely named like it" block-dangerous.sh 0 "" "$(file_input Edit "$PROJECT/src/factory-runtime.md")"

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

# ---------- review-guard: spawn messages ----------
spawn() { jq -cn --arg t "$1" --arg p "$2" '{tool_name: "Agent", tool_input: {subagent_type: $t, prompt: $p, description: "x"}}'; }
expect "reviewer with the exact message" review-guard.sh 0 "" "$(spawn factory:factory-reviewer 'Review ticket #12')"
expect "reviewer briefed by the implementer" review-guard.sh 2 "exactly" \
  "$(spawn factory:factory-reviewer 'Review ticket #12. I fixed the edge case in quote.py, focus on tests.')"
expect "reviewer without namespace still guarded" review-guard.sh 2 "exactly" "$(spawn factory-reviewer 'Please review #12')"
expect "judge with the exact message" review-guard.sh 0 "" "$(spawn factory:factory-judge 'Judge finding 3 of ticket #12')"
expect "judge handed the finding text" review-guard.sh 2 "exactly" \
  "$(spawn factory:factory-judge 'Judge finding 3 of ticket #12: the reviewer says the test is weak but it is fine')"
expect "resolver with the exact message" review-guard.sh 0 "" "$(spawn factory:factory-resolver 'Check confirmed finding 1 of ticket #12')"
expect "other subagents are not guarded" review-guard.sh 0 "" "$(spawn Explore 'find all callers of x')"

# ---------- review-guard: inside a review subagent ----------
as_agent() { jq -cn --arg a "$1" --arg c "$2" '{tool_name: "Bash", agent_type: $a, tool_input: {command: $c}}'; }
for cmd in 'gh issue view 12' 'git diff origin/main...HEAD' 'git log --oneline origin/main..HEAD' \
  'cat "$(git rev-parse --git-dir)/factory/pr-body.md"' 'ls src 2>/dev/null' 'grep -rn foo src | head -5' \
  '.factory/bin/factory review show-finding 12 2' '.factory/bin/factory review context 12' \
  'git -C /repo/.factory/worktrees/ticket-12 diff origin/main...HEAD' "$(jq -r .check "$PROJECT/.factory/config.json")"; do
  expect "reviewer may: $cmd" review-guard.sh 0 "" "$(as_agent factory:factory-reviewer "$cmd")"
done
for cmd in 'rm src/a.py' 'echo hi > notes.txt' 'git diff > out.patch' 'sed -i s/a/b/ src/a.py' 'find . -name x -delete' \
  'git commit -am x' 'git checkout -- .' 'ls; touch x' 'cat a | tee b' 'python3 -c "open(\"x\",\"w\")"'; do
  expect "reviewer may not: $cmd" review-guard.sh 2 "BLOCKED" "$(as_agent factory:factory-reviewer "$cmd")"
done
SAVE=$'.factory/bin/factory review save-findings 12 <<\'JSON\'\n{"findings": []}\nJSON'
expect "reviewer saves through the heredoc" review-guard.sh 0 "" "$(as_agent factory:factory-reviewer "$SAVE")"
expect "a save without the ticket number is refused" review-guard.sh 2 "BLOCKED" \
  "$(as_agent factory:factory-reviewer $'.factory/bin/factory review save-findings <<\'JSON\'\n{"findings": []}\nJSON')"
expect "reviewer may save via the full path to the shim" review-guard.sh 0 "" \
  "$(as_agent factory:factory-reviewer "$PROJECT/$SAVE")"
expect "a cd prefix is still refused" review-guard.sh 2 "BLOCKED" \
  "$(as_agent factory:factory-reviewer "cd $PROJECT && $SAVE")"
expect "nothing may follow the heredoc" review-guard.sh 2 "heredoc" "$(as_agent factory:factory-reviewer "$SAVE"$'\nrm -f x')"
VERDICT=$'.factory/bin/factory review save-verdict 12 2 <<\'JSON\'\n{"verdict":"rejected","severity":"blocking","reason":"r"}\nJSON'
expect "judge saves its verdict" review-guard.sh 0 "" "$(as_agent factory:factory-judge "$VERDICT")"
expect "review subagents cannot edit files" review-guard.sh 2 "read-only" \
  "$(jq -cn --arg p "$PROJECT/src/a.py" '{tool_name: "Edit", agent_type: "factory:factory-judge", tool_input: {file_path: $p}}')"

# ---------- review-guard: the main agent keeps its hands off the record ----------
expect "main agent cannot save findings" review-guard.sh 2 "only the review subagents" "$(bash_input "$SAVE")"
expect "main agent cannot save verdicts" review-guard.sh 2 "only the review subagents" "$(bash_input "$VERDICT")"
expect "main agent may begin a review" review-guard.sh 0 "" "$(bash_input '.factory/bin/factory review begin 12')"
expect "main agent may read the record" review-guard.sh 0 "" "$(bash_input 'jq .confirmed .git/factory/review.json')"
expect "main agent may read the record with stderr silenced" review-guard.sh 0 "" \
  "$(bash_input 'cat "$(git rev-parse --git-dir)/factory/review.json" 2>/dev/null || find .git -name "review*.json"')"
expect "main agent cannot overwrite the record" review-guard.sh 2 "review record" \
  "$(bash_input 'echo {} > .git/factory/review.json')"
expect "main agent cannot Write the record" review-guard.sh 2 "review record" \
  "$(file_input Write "$PROJECT/.git/worktrees/t/factory/review.json")"

# ---------- worktrees: the session's cwd / the edited file pick the checkout ----------
WT=$(mktemp -d)
(cd "$WT" && git init -q && mkdir -p .factory &&
  echo '{"version":1,"owners":["o"],"check":"echo worktree-check-ran; exit 1"}' >.factory/config.json)
expect "stop-gate uses the worktree named by cwd" stop-gate.sh 2 "worktree-check-ran" \
  "$(jq -cn --arg c "$WT" '{stop_hook_active: false, cwd: $c}')"
expect "stop-gate falls back to the project dir" stop-gate.sh 0 "" \
  "$(jq -cn '{stop_hook_active: false, cwd: "/"}')"
rm -rf "$WT"

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
