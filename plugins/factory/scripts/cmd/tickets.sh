#!/usr/bin/env bash
# tickets — GitHub-side ticket plumbing. Skills decide WHAT a ticket says; this does the API.
#   factory tickets feature <spec-path> <title>          parent issue for a spec (label: feature)
#   factory tickets create <title> <body-file> [--parent N] [--blocked-by N]...
#                                                        agent-task issue, linked as sub-issue
#   factory tickets next [<parent>]                      the next ticket an agent may start
#   factory tickets list <parent>                        sub-issues with state and blockers
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require gh jq
cd "$(factory_root)" || exit 1
SLUG=$(factory_repo_slug)
[ -n "$SLUG" ] || die "no GitHub repo for $(pwd)"
R="repos/$SLUG"

issue_id() { gh api "$R/issues/$1" -q .id; }
number_from_url() { grep -oE '[0-9]+$'; }

open_blockers() {
  gh api "$R/issues/$1/dependencies/blocked_by" -q '[.[] | select(.state == "open") | .number] | join(" ")' 2>/dev/null
}

cmd=${1:-}
shift || true
case "$cmd" in
  feature)
    SPEC=${1:?usage: factory tickets feature <spec-path> <title>}
    TITLE=${2:?usage: factory tickets feature <spec-path> <title>}
    gh issue create --title "Feature: $TITLE" --label feature --body "Tracks the feature specified in \`$SPEC\`.

The spec is the source of truth for behaviour and decisions; its tickets are this issue's
sub-issues, in order. When the last one closes, the spec moves to \`docs/specs/archive/\`." | number_from_url
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
    N=$(gh issue create --title "$TITLE" --label agent-task --body-file "$BODY" | number_from_url)
    [ -n "$N" ] || die "issue creation failed"
    if [ -n "$PARENT" ]; then
      gh api -X POST "$R/issues/$PARENT/sub_issues" -F sub_issue_id="$(issue_id "$N")" >/dev/null ||
        warn "#$N created but not linked under #$PARENT"
    fi
    for b in "${BLOCKERS[@]}"; do
      gh api -X POST "$R/issues/$N/dependencies/blocked_by" -F issue_id="$(issue_id "$b")" >/dev/null ||
        warn "#$N created but 'blocked by #$b' was not recorded"
    done
    echo "$N"
    ;;

  next)
    PARENT=${1:-}
    if [ -n "$PARENT" ]; then
      CANDIDATES=$(gh api "$R/issues/$PARENT/sub_issues" -q '.[] | select(.state == "open") | .number')
    else
      CANDIDATES=$(gh issue list --label agent-task --state open --limit 200 --json number -q 'sort_by(.number) | .[].number')
    fi
    for n in $CANDIDATES; do
      LABELS=$(gh issue view "$n" --json labels -q '.labels[].name')
      grep -qx agent-task <<<"$LABELS" || continue
      grep -qxE 'in-progress|blocked' <<<"$LABELS" && continue
      [ -z "$(open_blockers "$n")" ] || continue
      echo "$n"
      exit 0
    done
    exit 3
    ;;

  list)
    PARENT=${1:?usage: factory tickets list <parent>}
    for n in $(gh api "$R/issues/$PARENT/sub_issues" -q '.[].number'); do
      gh issue view "$n" --json number,state,title,labels -q '"#\(.number) \(.state) [\([.labels[].name] | join(","))] \(.title)"' |
        tr -d '\n'
      b=$(open_blockers "$n")
      [ -n "$b" ] && printf '  (blocked by #%s)' "${b// /, #}"
      echo
    done
    ;;

  *) die "usage: factory tickets feature|create|next|list ..." ;;
esac
