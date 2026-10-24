#!/usr/bin/env bash
# review.test.sh — the review record end to end, playing the subagents' save-* calls by hand:
# numbering, how verdicts combine, a missing judge, HEAD pinning, and --resolve.
set -u
FACTORY="$(cd "$(dirname "$0")/../plugins/factory" && pwd)/scripts/factory"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  echo "FAIL $1"
  FAIL=$((FAIL + 1))
}
eq() { [ "$2" = "$3" ] && ok || no "$1: got '$2', want '$3'"; }
F() { "$FACTORY" "$@" 2>/dev/null; }

P=$(mktemp -d)
trap 'rm -rf "$P"' EXIT
cd "$P" || exit 1
git init -q -b main
mkdir -p .factory
echo '{"version":1,"owners":["o"],"check":"true","review":{"model":"opus"}}' >.factory/config.json
git add -A && git commit -qm init
git checkout -q -b ticket/5-x && echo x >x && git add x && git commit -qm x
export CLAUDE_PROJECT_DIR="$P"
R="$(git rev-parse --git-dir)/factory/review.json"

echo dirty >y
F review begin 5 >/dev/null && no "begin refuses a dirty tree" || ok
rm y
eq "begin prints the exact reviewer message" "$(F review begin 5 | tail -1)" "Review ticket #5"

F review save-findings 5 <<<'{"findings":[{"title":"x","severity":"urgent","detail":"d","evidence":"e"}]}' && no "bad severity rejected" || ok
F review save-findings 5 <<'JSON' || no "save-findings accepts valid JSON"
{"findings":[
  {"title":"real bug","severity":"blocking","detail":"d1","evidence":"e1","file":"x","line":1},
  {"title":"wrong claim","severity":"blocking","detail":"d2","evidence":"e2"},
  {"title":"naming nit","severity":"blocking","detail":"d3","evidence":"e3"},
  {"title":"style","severity":"non-blocking","detail":"d4","evidence":"e4"},
  {"title":"judge never answered","severity":"blocking","detail":"d5","evidence":"e5"}
]}
JSON
eq "judges: one exact line per blocking finding" "$(F review judges 5 | grep -c '^Judge finding [0-9] of ticket #5$')" 4
eq "show-finding returns that finding only" "$(F review show-finding 5 2 | jq -r .title)" "wrong claim"
F review save-verdict 5 4 <<<'{"verdict":"confirmed","severity":"blocking","reason":"r"}' && no "no verdicts for non-blocking findings" || ok
F review save-verdict 5 1 <<<'{"verdict":"confirmed","severity":"blocking","reason":"line 1"}' || no "verdict 1"
F review save-verdict 5 2 <<<'{"verdict":"rejected","severity":"blocking","reason":"the test asserts it"}' || no "verdict 2"
F review save-verdict 5 3 <<<'{"verdict":"confirmed","severity":"non-blocking","reason":"cosmetic"}' || no "verdict 3"
F review assemble 5 >/dev/null || no "assemble"
eq "confirmed" "$(jq -c '[.confirmed[].title]' "$R")" '["real bug","judge never answered"]'
eq "a missing verdict keeps the finding" "$(jq -r '.confirmed[1].verdict.reason' "$R")" "no judge recorded a verdict, so the finding stands for a human"
eq "non-blocking = unjudged + downgraded" "$(jq -c '[.nonblocking[].title] | sort' "$R")" '["naming nit","style"]'
eq "rejected" "$(jq -c '[.rejected[].title]' "$R")" '["wrong claim"]'
eq "unresolved until resolved" "$(jq '.unresolved | length' "$R")" 2
eq "head recorded" "$(jq -r .head "$R")" "$(git rev-parse HEAD)"

F review resolve-begin 5 >/dev/null && no "resolve-begin needs new commits" || ok
echo y >>x && git commit -qam fix
eq "resolver lines" "$(F review resolve-begin 5 | grep -c '^Check confirmed finding [12] of ticket #5$')" 2
eq "show-confirmed names the reviewed commit" "$(F review show-confirmed 5 1 | jq -r .reviewed_commit)" "$(jq -r .head "$R")"
F review save-resolution 5 1 <<<'{"resolved":true,"reason":"fixed"}' || no "resolution 1"
F review save-resolution 5 3 <<<'{"resolved":true,"reason":"x"}' && no "no resolution for a finding that does not exist" || ok
F review assemble 5 --resolve >/dev/null || no "assemble --resolve"
eq "fixed" "$(jq -c '[.fixed[].title]' "$R")" '["real bug"]'
eq "no resolver answer = still unresolved" "$(jq -c '[.unresolved[].title]' "$R")" '["judge never answered"]'
eq "head moves to the fixed commit" "$(jq -r .head "$R")" "$(git rev-parse HEAD)"

F review begin 5 >/dev/null
echo z >>x && git commit -qam moved
F review save-findings 5 <<<'{"findings":[]}' && no "save-findings refuses when HEAD moved" || ok

# Subagents start in the project folder, not the worktree: commands find the ticket's worktree.
git worktree add -q -b ticket/7-y "$P-wt7" main
(cd "$P-wt7" && echo w >w && git add w && git commit -qm w)
eq "begin works from another checkout" "$(cd "$P" && F review begin 7 | tail -1)" "Review ticket #7"
eq "context names the ticket's worktree" "$(F review context 7 | sed -n 's/^worktree: *//p')" "$(cd "$P-wt7" && pwd -P)"
F review save-findings 7 <<<'{"findings":[]}' || no "save-findings for #7 from the main checkout"
F review save-findings 9 <<<'{"findings":[]}' && no "unknown ticket refused" || ok
F review save-findings x <<<'{"findings":[]}' && no "non-numeric ticket refused" || ok
git worktree remove --force "$P-wt7"

echo "review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
