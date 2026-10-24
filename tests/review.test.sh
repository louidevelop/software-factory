#!/usr/bin/env bash
# review.test.sh — factory review end to end with a fake claude: who is told what, how verdicts
# combine, and how --resolve splits fixed from unresolved.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FACTORY="$HERE/../plugins/factory/scripts/factory"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  echo "FAIL $1"
  FAIL=$((FAIL + 1))
}
eq() { [ "$2" = "$3" ] && ok || no "$1: got '$2', want '$3'"; }

P=$(mktemp -d)
trap 'rm -rf "$P"' EXIT
cd "$P" || exit 1
git init -q -b main
mkdir -p .factory
echo '{"version":1,"owners":["o"],"check":"true","review":{"model":"opus"}}' >.factory/config.json
git add -A && git commit -qm init && git update-ref refs/remotes/origin/main HEAD
git checkout -q -b ticket/5-x && echo x >x && git add x && git commit -qm x
export CLAUDE_PROJECT_DIR="$P" FACTORY_CLAUDE="$HERE/fake-claude.sh" FAKE_CLAUDE_LOG="$P/prompts.log"
STATE="$(git rev-parse --git-dir)/factory"
mkdir -p "$STATE" && echo "SECRET IMPLEMENTER FRAMING" >"$STATE/pr-body.md"

export FAKE_FINDINGS='{"findings":[
  {"title":"REAL bug","severity":"blocking","detail":"d1","evidence":"e1","file":"x","line":1},
  {"title":"wrong claim","severity":"blocking","detail":"d2","evidence":"e2"},
  {"title":"NIT naming","severity":"blocking","detail":"d3","evidence":"e3"},
  {"title":"style","severity":"non-blocking","detail":"d4","evidence":"e4"},
  {"title":"REAL STILL JUDGE-CRASH","severity":"blocking","detail":"d5","evidence":"e5"}
]}'
"$FACTORY" review 5 >/dev/null 2>&1 || no "review exits 0"
R="$STATE/review.json"
eq "confirmed" "$(jq -c '[.confirmed[].title]' "$R")" '["REAL bug","REAL STILL JUDGE-CRASH"]'
eq "a crashed judge keeps the finding" "$(jq -r '.confirmed[1].verdict.reason' "$R")" "the judge failed, so the finding stands for a human"
eq "non-blocking = unjudged + downgraded" "$(jq -c '[.nonblocking[].title] | sort' "$R")" '["NIT naming","style"]'
eq "rejected" "$(jq -c '[.rejected[].title]' "$R")" '["wrong claim"]'
eq "unresolved until --resolve" "$(jq '.unresolved | length' "$R")" 2
eq "head recorded" "$(jq -r .head "$R")" "$(git rev-parse HEAD)"
eq "judges run only for blocking findings" "$(grep -c 'You are a judge in the local review' prompts.log)" 4
grep -q 'SECRET IMPLEMENTER FRAMING' prompts.log && no "the implementer's description leaked into a prompt" || ok
grep -q "gh issue view 5" prompts.log && ok || no "reviewer is told to fetch the ticket itself"
JUDGE_PROMPT=$(awk '/You are a judge/{on=1} on{print} /^----$/{if(on)exit}' prompts.log)
grep -q 'wrong claim' <<<"$JUDGE_PROMPT$(cat prompts.log)" && ok || no "judge sees its finding"
grep -q '"title":"style"' <<<"$JUDGE_PROMPT" && no "a judge saw another finding" || ok

echo y >>x && git commit -qam fix
"$FACTORY" review 5 --resolve >/dev/null 2>&1 || no "resolve exits 0"
eq "fixed after resolve" "$(jq -c '[.fixed[].title]' "$R")" '["REAL bug"]'
eq "still unresolved" "$(jq -c '[.unresolved[].title]' "$R")" '["REAL STILL JUDGE-CRASH"]'
eq "head moves to the fixed commit" "$(jq -r .head "$R")" "$(git rev-parse HEAD)"

echo "review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
