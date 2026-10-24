#!/usr/bin/env bash
# fake-claude.sh — stands in for `claude -p` in tests/review.test.sh. Answers by prompt type, in
# the shape `claude -p --output-format json --json-schema` returns. Findings whose title contains
# REAL are confirmed blocking, NIT are downgraded, anything else is rejected; FIXED resolves.
# It also records each prompt, so the test can assert what the reviewer was (not) told.
prompt=$2
log="${FAKE_CLAUDE_LOG:?}"
printf '%s\n----\n' "$prompt" >>"$log"
out() { jq -cn --argjson s "$1" '{type: "result", subtype: "success", structured_output: $s}'; }
case "$prompt" in
  *"You are the local reviewer"*)
    out "${FAKE_FINDINGS:?}"
    ;;
  *"You are a judge in the local review"*)
    case "$prompt" in
      *JUDGE-CRASH*) exit 1 ;;
      *REAL*) out '{"verdict":"confirmed","severity":"blocking","reason":"line 3 proves it"}' ;;
      *NIT*) out '{"verdict":"confirmed","severity":"non-blocking","reason":"real but cosmetic"}' ;;
      *) out '{"verdict":"rejected","severity":"blocking","reason":"the test does assert it"}' ;;
    esac
    ;;
  *"checking ONE confirmed review finding"*)
    case "$prompt" in
      *STILL*) out '{"resolved":false,"reason":"the bug is still there"}' ;;
      *) out '{"resolved":true,"reason":"fixed in the last commit"}' ;;
    esac
    ;;
  *) exit 1 ;;
esac
