#!/usr/bin/env bash
# review — the local review, before the PR exists. Run from the ticket's worktree.
#   factory review <issue>            reviewer → one judge per blocking finding (parallel)
#   factory review <issue> --resolve  after fixes: one judge per confirmed finding checks it is resolved
#
# The reviewer is never briefed by the implementer: this script starts it with a FIXED prompt
# that carries only the ticket number, branch, base and check command; it gathers its own context.
# Reviewer and judges are read-only (dontAsk mode with an allow-list) and see none of each
# other's reasoning. Result: <git dir>/factory/review.json, which open-pr turns into the PR's
# "Local review" section. Unverifiable means unresolved: a judge that fails keeps its finding.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git jq
factory_require_config
CLAUDE=${FACTORY_CLAUDE:-claude} # tests substitute a fake
command -v "$CLAUDE" >/dev/null 2>&1 || die "missing prerequisite: $CLAUDE"

STATE=$(factory_state_dir)
N=${1:-$(cat "$STATE/ticket" 2>/dev/null)}
[ -n "$N" ] || die "usage: factory review <issue> [--resolve]"
MODE=${2:-review}
BRANCH=$(git rev-parse --abbrev-ref HEAD)
BASE=$(factory_base_branch)
CHECK=$(factory_cfg '.check')
MODEL=$(factory_cfg '.review.model')
MODEL=${MODEL:-opus}
HEAD=$(git rev-parse HEAD)
WORK="$STATE/review-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"

READ_ONLY=(
  --permission-mode dontAsk
  --allowedTools Read Grep Glob "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)"
  "Bash(git status:*)" "Bash(gh issue view:*)" "Bash(ls:*)" "Bash($CHECK)"
  --disallowedTools Edit Write MultiEdit NotebookEdit
  --model "$MODEL"
  --output-format json
)
[ -n "${FACTORY_HOME:-}" ] && READ_ONLY+=(--plugin-dir "$FACTORY_HOME")

fill() {
  local out kv
  out=$(cat "$FACTORY_PLUGIN/prompts/$1")
  shift
  for kv in "$@"; do out=${out//"{{${kv%%=*}}}"/${kv#*=}}; done
  printf '%s' "$out"
}

# ask <prompt> <json schema> <out file> — one fresh, read-only session; structured output only.
ask() {
  "$CLAUDE" -p "$1" "${READ_ONLY[@]}" --json-schema "$2" </dev/null 2>"$3.err" |
    jq -c '.structured_output // (.result | fromjson?) // empty' >"$3" 2>>"$3.err"
  [ -s "$3" ]
}

FINDINGS_SCHEMA='{"type":"object","required":["findings"],"properties":{"findings":{"type":"array","items":{"type":"object","required":["title","severity","detail","evidence"],"properties":{"title":{"type":"string"},"severity":{"enum":["blocking","non-blocking"]},"category":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"},"detail":{"type":"string"},"evidence":{"type":"string"}}}}}}'
VERDICT_SCHEMA='{"type":"object","required":["verdict","severity","reason"],"properties":{"verdict":{"enum":["confirmed","rejected"]},"severity":{"enum":["blocking","non-blocking"]},"reason":{"type":"string"},"evidence":{"type":"string"}}}'
RESOLVED_SCHEMA='{"type":"object","required":["resolved","reason"],"properties":{"resolved":{"type":"boolean"},"reason":{"type":"string"}}}'

if [ "$MODE" = --resolve ]; then
  [ -f "$STATE/review.json" ] || die "no review to resolve: run factory review $N first"
  REVIEWED=$(jq -r .head "$STATE/review.json")
  COUNT=$(jq '.confirmed | length' "$STATE/review.json")
  say "resolution check: $COUNT confirmed finding(s) since ${REVIEWED:0:7}"
  for i in $(seq 0 $((COUNT - 1))); do
    F=$(jq -c ".confirmed[$i]" "$STATE/review.json")
    ask "$(fill resolve.md N="$N" BRANCH="$BRANCH" CHECK="$CHECK" FINDING="$F" REVIEWED="$REVIEWED")" \
      "$RESOLVED_SCHEMA" "$WORK/resolve-$i.json" &
  done
  wait
  # Assemble: resolved → fixed; anything else (unresolved or a judge that failed) → unresolved.
  {
    for i in $(seq 0 $((COUNT - 1))); do
      F=$(jq -c ".confirmed[$i]" "$STATE/review.json")
      V=$(cat "$WORK/resolve-$i.json" 2>/dev/null)
      [ -n "$V" ] || V='{"resolved":false,"reason":"the resolution judge failed; treated as unresolved"}'
      jq -cn --argjson f "$F" --argjson v "$V" '$f + {resolution: $v}'
    done
  } | jq -s --arg head "$HEAD" --slurpfile r "$STATE/review.json" '
    $r[0] + {
      head: $head,
      fixed: [.[] | select(.resolution.resolved)],
      unresolved: [.[] | select(.resolution.resolved | not) | .detail += " (still open: \(.resolution.reason))"]
    }' >"$WORK/review.json"
  mv "$WORK/review.json" "$STATE/review.json"
  say "fixed: $(jq '.fixed | length' "$STATE/review.json"), unresolved: $(jq '.unresolved | length' "$STATE/review.json")"
  exit 0
fi

say "reviewer: fresh context, model $MODEL, ticket #$N on $BRANCH"
ask "$(fill reviewer.md N="$N" BRANCH="$BRANCH" BASE="$BASE" CHECK="$CHECK" STATE="$STATE")" \
  "$FINDINGS_SCHEMA" "$WORK/findings.json" || die "the reviewer produced no findings JSON (see $WORK/findings.json.err)"
jq '.findings |= [to_entries[] | .value + {id: .key}]' "$WORK/findings.json" >"$WORK/numbered.json"

BLOCKING=$(jq -c '[.findings[] | select(.severity == "blocking")]' "$WORK/numbered.json")
say "$(jq '.findings | length' "$WORK/numbered.json") finding(s), $(jq length <<<"$BLOCKING") blocking — one judge each"
for id in $(jq -r '.[].id' <<<"$BLOCKING"); do
  F=$(jq -c --argjson id "$id" '.findings[] | select(.id == $id) | del(.id)' "$WORK/numbered.json")
  ask "$(fill judge.md N="$N" BRANCH="$BRANCH" BASE="$BASE" CHECK="$CHECK" FINDING="$F")" \
    "$VERDICT_SCHEMA" "$WORK/verdict-$id.json" &
done
wait

{
  for id in $(jq -r '.findings[].id' "$WORK/numbered.json"); do
    F=$(jq -c --argjson id "$id" '.findings[] | select(.id == $id)' "$WORK/numbered.json")
    V=$(cat "$WORK/verdict-$id.json" 2>/dev/null)
    if [ "$(jq -r .severity <<<"$F")" = blocking ] && [ -z "$V" ]; then
      V='{"verdict":"confirmed","severity":"blocking","reason":"the judge failed, so the finding stands for a human"}'
    fi
    jq -cn --argjson f "$F" --argjson v "${V:-null}" '$f + {verdict: $v}'
  done
} | jq -s --arg head "$HEAD" --arg model "$MODEL" --argjson n "$N" '
  def blocking: .severity == "blocking";
  {
    ticket: $n, head: $head, model: $model,
    confirmed:   [.[] | select(blocking and .verdict.verdict == "confirmed" and .verdict.severity == "blocking")],
    nonblocking: ([.[] | select(blocking | not)] +
                  [.[] | select(blocking and .verdict.verdict == "confirmed" and .verdict.severity == "non-blocking")
                       | .detail += " (judge: real, but not blocking)"]),
    rejected:    [.[] | select(blocking and .verdict.verdict == "rejected") | .detail += " (rejected: \(.verdict.reason))"],
    fixed: []
  } | .unresolved = .confirmed' >"$STATE/review.json"

say "confirmed blocking: $(jq '.confirmed | length' "$STATE/review.json"), non-blocking: $(jq '.nonblocking | length' "$STATE/review.json"), rejected: $(jq '.rejected | length' "$STATE/review.json")"
if [ "$(jq '.confirmed | length' "$STATE/review.json")" -gt 0 ]; then
  say "fix exactly the confirmed findings (jq .confirmed $STATE/review.json), commit, then: factory review $N --resolve"
fi
