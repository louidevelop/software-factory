#!/usr/bin/env bash
# review-guard.sh — PreToolUse. Keeps the local review independent of the implementer:
#  1. The main agent may spawn factory-reviewer / -judge / -resolver only with their exact
#     one-line messages ("Review ticket #12"), so it can trigger them but never brief them.
#  2. Inside those subagents (hook input `agent_type`), only read-only commands run, plus the
#     factory's own save-* commands; no file edits.
#  3. Outside them, nobody may write findings, verdicts, resolutions, or the review files.
# Exit 2 + stderr = blocked. A guardrail, not a sandbox: it stops the honest mistakes and makes
# a deliberate bypass visible in the transcript.
set -u
. "$(dirname "$0")/lib.sh"

INPUT=$(cat)
factory_require_jq
export FACTORY_ROOT_HINT # read by factory_root in lib.sh
FACTORY_ROOT_HINT=$(jq -r '.cwd // empty' <<<"$INPUT")
CONFIG=$(factory_config)
[ -f "$CONFIG" ] || exit 0

TOOL=$(jq -r '.tool_name // empty' <<<"$INPUT")
AGENT=$(jq -r '.agent_type // empty' <<<"$INPUT")
REVIEW_AGENT_RE='(^|:)factory-(reviewer|judge|resolver)$'

block() {
  echo "BLOCKED by the factory review guard: $1" >&2
  exit 2
}

in_review_agent() { [[ $AGENT =~ $REVIEW_AGENT_RE ]]; }

# ---------- 1. Spawning a review subagent ----------
if [ "$TOOL" = Agent ] || [ "$TOOL" = Task ]; then
  TYPE=$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT")
  [[ $TYPE =~ $REVIEW_AGENT_RE ]] || exit 0
  MSG=$(jq -r '.tool_input.prompt // empty' <<<"$INPUT" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  case "$TYPE" in
    *factory-reviewer) RE='^Review ticket #[0-9]+\.?$' WANT='Review ticket #<n>' ;;
    *factory-judge) RE='^Judge finding [0-9]+ of ticket #[0-9]+\.?$' WANT='Judge finding <k> of ticket #<n>' ;;
    *) RE='^Check confirmed finding [0-9]+ of ticket #[0-9]+\.?$' WANT='Check confirmed finding <k> of ticket #<n>' ;;
  esac
  [[ $MSG =~ $RE ]] || block "$TYPE must be spawned with exactly \"$WANT\" and nothing else. It gathers the ticket, spec and diff itself; the implementer never briefs it. Use the line \`factory review\` printed."
  exit 0
fi

# ---------- 2. Inside a review subagent: read-only ----------
if in_review_agent; then
  case "$TOOL" in
    Edit | Write | MultiEdit | NotebookEdit) block "$AGENT is read-only; it records results only through .factory/bin/factory review save-*." ;;
    Bash) ;;
    *) exit 0 ;;
  esac
  CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
  FIRST=$(head -n1 <<<"$CMD")
  # The one write: a heredoc into the factory's own save command.
  if [[ $FIRST =~ ^([^[:space:]]*/)?\.factory/bin/factory\ review\ (save-findings\ [0-9]+|save-verdict\ [0-9]+\ [0-9]+|save-resolution\ [0-9]+\ [0-9]+)\ \<\<-?\'?([A-Za-z_]+)\'?[[:space:]]*$ ]]; then
    TERM=${BASH_REMATCH[3]} # [1] optional path, [2] the save command, [3] the heredoc word
    [ "$(tail -n1 <<<"$CMD" | tr -d '[:space:]')" = "$TERM" ] && exit 0
    block "the save command must be a single heredoc ending with $TERM, nothing after it."
  fi
  [ "$(wc -l <<<"$CMD")" -le 1 ] || block "one command per call inside $AGENT (multi-line commands are only allowed for save-* heredocs)."
  CHECK=$(factory_cfg '.check')
  [ -n "$CHECK" ] && [ "$CMD" = "$CHECK" ] && exit 0
  # Writes through redirection are out; harmless redirects are stripped first.
  STRIPPED=$(sed -E 's#[0-9]?>&[0-9]##g; s#[0-9]?>[[:space:]]*/dev/null##g' <<<"$CMD")
  [[ $STRIPPED == *">"* ]] && block "output redirection writes files; $AGENT is read-only."
  ALLOWED='^(git( -C [^ ]+)? (diff|log|show|status|rev-parse|merge-base|blame|ls-files|branch --show-current|worktree list)|gh (issue view|pr view|pr diff)|ls|cat|head|tail|wc|grep|rg|find|jq|sort|uniq|diff|tree|file|stat|basename|dirname|pwd|echo|cd|true|sed -n|awk|([^ ]*/)?\.factory/bin/factory (review (context|show-finding|show-confirmed)|tickets show|prompt [a-z][a-z-]*))( |$)'
  while IFS= read -r seg; do
    seg=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$seg")
    [ -n "$seg" ] || continue
    [ -n "$CHECK" ] && [ "$seg" = "$CHECK" ] && continue
    [[ $seg =~ $ALLOWED ]] || block "\`$seg\` is not a read-only command allowed inside $AGENT."
    [[ $seg =~ ^find\  ]] && [[ $seg =~ -(delete|exec|execdir|ok|fprint) ]] && block "find with an action that writes or runs commands."
  done < <(sed -E 's/(\&\&|\|\||;|\||&|\$\(|`)/\n/g; s/\)/ /g' <<<"$STRIPPED")
  exit 0
fi

# ---------- 3. Everyone else: hands off the review record ----------
case "$TOOL" in
  Edit | Write | MultiEdit | NotebookEdit)
    P=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT")
    [[ $P =~ /factory/(review\.json|review-current/) ]] && block "the review record is written only by the review subagents and \`factory review assemble\`."
    ;;
  Bash)
    CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
    # Harmless redirects (2>/dev/null, 2>&1) are not writes to the record.
    CMD=$(sed -E 's#[0-9]?>&[0-9]##g; s#[0-9]?>[[:space:]]*/dev/null##g' <<<"$CMD")
    [[ $CMD =~ factory\ review\ (save-findings|save-verdict|save-resolution) ]] &&
      block "only the review subagents record findings, verdicts and resolutions."
    if [[ $CMD =~ factory/(review\.json|review-current) ]] && [[ $CMD =~ (\>|tee |cp |mv |rm |sed -i|python|node |perl|ruby) ]]; then
      block "the review record is written only by the review subagents and \`factory review assemble\`."
    fi
    ;;
esac
exit 0
