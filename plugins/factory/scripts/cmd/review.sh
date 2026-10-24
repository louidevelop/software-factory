#!/usr/bin/env bash
# review — the local review, run as plugin SUBAGENTS spawned by the main agent:
#   factory:factory-reviewer  "Review ticket #<n>"                    → findings
#   factory:factory-judge     "Judge finding <k> of ticket #<n>"      → one verdict per blocking finding
#   factory:factory-resolver  "Check confirmed finding <k> of ticket #<n>" → after the fixes
# The main agent only triggers them, with those exact messages: hooks/review-guard.sh blocks any
# other wording, keeps the subagents read-only, and stops the main agent from writing findings,
# verdicts or resolutions itself. The subagents gather the ticket, spec and diff on their own.
#
# Main agent:   begin <n> → spawn reviewer → judges → spawn judges (parallel) → assemble
#               → fix the confirmed findings, commit → resolve-begin → spawn resolvers → assemble --resolve
# Subagents:    save-findings | show-finding <k> | save-verdict <k> | show-confirmed <k> | save-resolution <k>
# Result: <git dir>/factory/review.json, which open-pr turns into the PR's "Local review" section.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git jq
factory_require_config

STATE=$(factory_state_dir)
CUR="$STATE/review-current"
RES="$STATE/review.json"
HEAD=$(git rev-parse HEAD)
SUB=${1:-}
shift || true

meta() { jq -r ".$1" "$CUR/meta.json"; }
need_review() { [ -f "$CUR/meta.json" ] || die "no review in progress: run factory review begin <n>"; }
same_head() { [ "$(meta head)" = "$HEAD" ] || die "HEAD moved since the review began; the review must see one commit. Run factory review begin again."; }
# read_json <jq validation filter> <what> — stdin must be JSON passing the filter. Call it as
# X=$(read_json …) || exit 1: inside $(…), die only ends the subshell.
read_json() {
  local in
  in=$(cat)
  jq -e "$1" <<<"$in" >/dev/null 2>&1 || die "invalid $2 JSON (see the subagent's instructions for the shape)"
  printf '%s' "$in"
}
model() { local m; m=$(factory_cfg '.review.model'); printf '%s' "${m:-opus}"; }

case "$SUB" in
  begin)
    N=${1:?usage: factory review begin <issue>}
    [ -z "$(git status --porcelain)" ] || die "commit first: the review covers committed work only"
    rm -rf "$CUR"
    mkdir -p "$CUR"
    jq -n --argjson n "$N" --arg head "$HEAD" '{ticket: $n, head: $head}' >"$CUR/meta.json"
    rm -f "$RES"
    say "review of #$N at ${HEAD:0:7} begun"
    echo "Spawn the factory:factory-reviewer subagent with exactly this message and nothing else:"
    echo "Review ticket #$N"
    ;;

  save-findings)
    need_review
    same_head
    IN=$(read_json '(.findings | type == "array") and all(.findings[]; (.title | type == "string") and (.severity == "blocking" or .severity == "non-blocking") and (.detail | type == "string") and (.evidence | type == "string"))' findings) || exit 1
    jq '.findings |= [to_entries[] | .value + {id: (.key + 1)}]' <<<"$IN" >"$CUR/findings.json"
    say "$(jq '.findings | length' "$CUR/findings.json") finding(s) saved, $(jq '[.findings[] | select(.severity == "blocking")] | length' "$CUR/findings.json") blocking"
    ;;

  judges)
    need_review
    [ -f "$CUR/findings.json" ] || die "the reviewer has not saved findings yet"
    N=$(meta ticket)
    IDS=$(jq -r '.findings[] | select(.severity == "blocking") | .id' "$CUR/findings.json")
    if [ -z "$IDS" ]; then
      echo "No blocking findings: nothing to judge. Run: factory review assemble"
    else
      echo "Spawn one factory:factory-judge subagent per line, in parallel, each with exactly that message:"
      for k in $IDS; do echo "Judge finding $k of ticket #$N"; done
    fi
    ;;

  show-finding)
    need_review
    K=${1:?usage: factory review show-finding <k>}
    jq -e --argjson k "$K" '.findings[] | select(.id == $k) | del(.id)' "$CUR/findings.json" || die "no finding $K"
    ;;

  save-verdict)
    need_review
    K=${1:?usage: factory review save-verdict <k>}
    jq -e --argjson k "$K" '.findings[] | select(.id == $k and .severity == "blocking")' "$CUR/findings.json" >/dev/null ||
      die "finding $K is not a blocking finding of this review"
    V=$(read_json '(.verdict == "confirmed" or .verdict == "rejected") and (.severity == "blocking" or .severity == "non-blocking") and (.reason | type == "string")' verdict) || exit 1
    printf '%s\n' "$V" >"$CUR/verdict-$K.json"
    say "verdict for finding $K saved"
    ;;

  show-confirmed)
    [ -f "$RES" ] || die "no assembled review"
    K=${1:?usage: factory review show-confirmed <k>}
    jq -e --argjson i "$((K - 1))" '{reviewed_commit: .head, finding: (.confirmed[$i] // error("no confirmed finding"))}' "$RES" || die "no confirmed finding $K"
    ;;

  save-resolution)
    [ -f "$CUR/resolve.json" ] || die "no resolution check in progress: factory review resolve-begin"
    K=${1:?usage: factory review save-resolution <k>}
    [ "$K" -ge 1 ] && [ "$K" -le "$(jq '.confirmed | length' "$RES")" ] || die "no confirmed finding $K"
    V=$(read_json '(.resolved | type == "boolean") and (.reason | type == "string")' resolution) || exit 1
    printf '%s\n' "$V" >"$CUR/resolution-$K.json"
    say "resolution for finding $K saved"
    ;;

  assemble)
    if [ "${1:-}" = --resolve ]; then
      [ -f "$CUR/resolve.json" ] || die "no resolution check in progress"
      [ "$(jq -r .head "$CUR/resolve.json")" = "$HEAD" ] || die "HEAD moved since resolve-begin; run it again"
      COUNT=$(jq '.confirmed | length' "$RES")
      {
        for k in $(seq 1 "$COUNT"); do
          V=$(cat "$CUR/resolution-$k.json" 2>/dev/null)
          [ -n "$V" ] || V='{"resolved":false,"reason":"no resolver recorded a result; treated as unresolved"}'
          jq -c --argjson i "$((k - 1))" --argjson v "$V" '.confirmed[$i] + {resolution: $v}' "$RES"
        done
      } | jq -s --arg head "$HEAD" --slurpfile r "$RES" '
        $r[0] + {
          head: $head,
          fixed: [.[] | select(.resolution.resolved)],
          unresolved: [.[] | select(.resolution.resolved | not) | .detail += " (still open: \(.resolution.reason))"]
        }' >"$RES.tmp" && mv "$RES.tmp" "$RES"
      say "fixed: $(jq '.fixed | length' "$RES"), still unresolved: $(jq '.unresolved | length' "$RES")"
      echo "Next: factory open-pr $(jq -r .ticket "$RES") (unresolved findings go to the human in the PR)"
      exit 0
    fi
    need_review
    same_head
    [ -f "$CUR/findings.json" ] || die "the reviewer has not saved findings yet"
    {
      for id in $(jq -r '.findings[].id' "$CUR/findings.json"); do
        F=$(jq -c --argjson id "$id" '.findings[] | select(.id == $id)' "$CUR/findings.json")
        V=$(cat "$CUR/verdict-$id.json" 2>/dev/null)
        if [ "$(jq -r .severity <<<"$F")" = blocking ] && [ -z "$V" ]; then
          # Unverifiable means unresolved: a judge that never recorded a verdict keeps its finding.
          V='{"verdict":"confirmed","severity":"blocking","reason":"no judge recorded a verdict, so the finding stands for a human"}'
        fi
        jq -cn --argjson f "$F" --argjson v "${V:-null}" '$f + {verdict: $v}'
      done
    } | jq -s --arg head "$HEAD" --arg model "$(model)" --argjson n "$(meta ticket)" '
      def blocking: .severity == "blocking";
      {
        ticket: $n, head: $head, model: $model,
        confirmed:   [.[] | select(blocking and .verdict.verdict == "confirmed" and .verdict.severity == "blocking")],
        nonblocking: ([.[] | select(blocking | not)] +
                      [.[] | select(blocking and .verdict.verdict == "confirmed" and .verdict.severity == "non-blocking")
                           | .detail += " (judge: real, but not blocking)"]),
        rejected:    [.[] | select(blocking and .verdict.verdict == "rejected") | .detail += " (rejected: \(.verdict.reason))"],
        fixed: []
      } | .unresolved = .confirmed' >"$RES"
    C=$(jq '.confirmed | length' "$RES")
    say "confirmed blocking: $C, non-blocking: $(jq '.nonblocking | length' "$RES"), rejected: $(jq '.rejected | length' "$RES")"
    if [ "$C" -gt 0 ]; then
      echo "Fix exactly these confirmed findings — nothing else, no non-blocking ones — commit, then: factory review resolve-begin"
      jq '.confirmed | map(del(.verdict))' "$RES"
    else
      echo "Next: factory open-pr $(meta ticket)"
    fi
    ;;

  resolve-begin)
    [ -f "$RES" ] || die "no assembled review: factory review assemble"
    [ "$(jq '.confirmed | length' "$RES")" -gt 0 ] || die "no confirmed findings to resolve"
    [ -z "$(git status --porcelain)" ] || die "commit the fixes first"
    [ "$HEAD" != "$(jq -r .head "$RES")" ] || die "no new commits since the review: fix the confirmed findings first"
    mkdir -p "$CUR"
    rm -f "$CUR"/resolution-*.json
    jq -n --arg head "$HEAD" '{head: $head}' >"$CUR/resolve.json"
    N=$(jq -r .ticket "$RES")
    echo "Spawn one factory:factory-resolver subagent per line, in parallel, each with exactly that message:"
    for k in $(seq 1 "$(jq '.confirmed | length' "$RES")"); do echo "Check confirmed finding $k of ticket #$N"; done
    ;;

  *) die "usage: factory review begin <n> | judges | assemble [--resolve] | resolve-begin  (subagents: save-findings | show-finding <k> | save-verdict <k> | show-confirmed <k> | save-resolution <k>)" ;;
esac
