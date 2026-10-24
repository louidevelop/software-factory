#!/usr/bin/env bash
# tickets — GitHub-side ticket plumbing. Skills decide WHAT a ticket says; this does the API.
#   factory tickets feature <spec-path> <title>          parent issue for a spec (label: feature)
#   factory tickets create <title> <body-file> [--parent N] [--blocked-by N]...
#                                                        agent-task issue, linked as sub-issue
#   factory tickets next [<parent>]                      the next ticket an agent may start
#   factory tickets list <parent>                        sub-issues with state and blockers
#   factory tickets show <n>                             the ticket with its comments, for agents
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require gh jq
cd "$(factory_root)" || exit 1
factory_repo_slug >/dev/null || die "no GitHub repo for $(pwd)"

issue_id() { factory_api "issues/$1" -q .id; }

cmd=${1:-}
shift || true
case "$cmd" in
  feature)
    SPEC=${1:?usage: factory tickets feature <spec-path> <title>}
    TITLE=${2:?usage: factory tickets feature <spec-path> <title>}
    factory_api issues -f title="Feature: $TITLE" -f "labels[]=feature" -q .number -f body="Tracks the feature specified in \`$SPEC\`.

The spec is the source of truth for behaviour and decisions; its tickets are this issue's
sub-issues, in order. When the last one closes, the spec moves to \`docs/specs/archive/\`."
    ;;

  create)
    TITLE=${1:?usage: factory tickets create <title> <body-file> [--parent N] [--blocked-by N]...}
    BODY=${2:?usage: factory tickets create <title> <body-file> ...}
    shift 2
    PARENT=""
    BLOCKERS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --parent)
          PARENT=${2:?}
          shift
          ;;
        --blocked-by)
          BLOCKERS+=("${2:?}")
          shift
          ;;
        *) die "unknown option $1" ;;
      esac
      shift
    done
    [ -f "$BODY" ] || die "body file not found: $BODY"
    N=$(factory_api issues -f title="$TITLE" -f "labels[]=agent-task" -f body="$(cat "$BODY")" -q .number) ||
      die "issue creation failed"
    [[ $N =~ ^[0-9]+$ ]] || die "issue creation failed"
    if [ -n "$PARENT" ]; then
      factory_api "issues/$PARENT/sub_issues" -X POST -F sub_issue_id="$(issue_id "$N")" >/dev/null ||
        warn "#$N created but not linked under #$PARENT"
    fi
    # bash 3.2 (macOS) treats an empty array as unset under `set -u`, hence the +"…" form.
    for b in ${BLOCKERS[@]+"${BLOCKERS[@]}"}; do
      factory_api "issues/$N/dependencies/blocked_by" -X POST -F issue_id="$(issue_id "$b")" >/dev/null ||
        warn "#$N created but 'blocked by #$b' was not recorded"
    done
    echo "$N"
    ;;

  next)
    PARENT=${1:-}
    # A parent's sub-issues keep their order (the spec's ticket order); otherwise oldest first.
    # Both lists carry each issue's labels, so only the blockers cost a call per ticket.
    if [ -n "$PARENT" ]; then
      ISSUES=$(factory_api_list "issues/$PARENT/sub_issues?per_page=100") || die "cannot read #$PARENT's sub-issues"
    else
      ISSUES=$(factory_api_list "issues?labels=agent-task&state=open&sort=created&direction=asc&per_page=100") ||
        die "cannot list agent-task issues"
    fi
    CANDIDATES=$(jq -r '.[] | select(.state == "open" and .pull_request == null)
      | select([.labels[].name] | index("agent-task") and (index("in-progress") or index("blocked") | not))
      | .number' <<<"$ISSUES")
    for n in $CANDIDATES; do
      b=$(factory_open_blockers "$n") || {
        warn "#$n: cannot read its blockers; skipping it"
        continue
      }
      [ -z "$b" ] || continue
      echo "$n"
      exit 0
    done
    exit 3
    ;;

  list)
    PARENT=${1:?usage: factory tickets list <parent>}
    ISSUES=$(factory_api_list "issues/$PARENT/sub_issues?per_page=100") || die "cannot read #$PARENT's sub-issues"
    while IFS=$'\t' read -r n line; do
      printf '%s' "$line"
      b=$(factory_open_blockers "$n") || b="?"
      [ -n "$b" ] && printf '  (blocked by #%s)' "${b// /, #}"
      echo
    done < <(jq -r '.[] | "\(.number)\t#\(.number) \(.state | ascii_upcase) [\([.labels[].name] | join(","))] \(.title)"' <<<"$ISSUES")
    ;;

  show)
    N=${1:?usage: factory tickets show <n>}
    T=$(ticket_json "$N") || die "cannot read issue #$N"
    jq -r '"#\(.number) \(.title)",
      "\(.state) · labels: \([.labels[].name] | join(", ")) · \(.html_url)",
      "", (.body // ""), "",
      "## Comments (\(.comments | length)), oldest first",
      (.comments[] | "", "--- @\(.author), \(.created_at)", .body)' <<<"$T"
    ;;

  *) die "usage: factory tickets feature|create|next|list|show ..." ;;
esac
