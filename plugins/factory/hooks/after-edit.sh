#!/usr/bin/env bash
# after-edit.sh — PostToolUse on Edit|Write|MultiEdit.
# Runs the project's fix command for the edited file only, so feedback is immediate.
# Whatever the fix command cannot fix is returned with exit 2: for PostToolUse that is
# the channel that reaches the model (stdout on exit 0 only reaches the transcript).
set -u
. "$(dirname "$0")/lib.sh"

INPUT=$(cat)
factory_require_jq
CONFIG=$(factory_config)
[ -f "$CONFIG" ] || exit 0

ROOT=$(factory_root)
FILE=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0
case "$FILE" in
  "$ROOT"/*) REL=${FILE#"$ROOT"/} ;;
  /*) exit 0 ;; # outside the project
  *) REL=$FILE ;;
esac

STATUS=0
OUTPUT=""
while IFS=$'\t' read -r glob command; do
  [ -n "$glob" ] || continue
  factory_glob_match "$REL" "$glob" || continue
  quoted=$(printf '%q' "$REL")
  cmd=${command//\{file\}/$quoted}
  if ! out=$(cd "$ROOT" && bash -c "$cmd" 2>&1); then
    STATUS=1
    OUTPUT+="\$ $cmd"$'\n'"$out"$'\n'
  fi
done < <(jq -r '.fix[]? | [.glob, .command] | @tsv' "$CONFIG")

if [ $STATUS -ne 0 ]; then
  {
    echo "factory after-edit: the fix command left problems in $REL that it could not fix automatically:"
    printf '%s' "$OUTPUT" | tail -40
  } >&2
  exit 2
fi
exit 0
