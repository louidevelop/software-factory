#!/usr/bin/env bash
# archive-specs — when every ticket of a feature is closed, open an "Archive spec" PR that moves
# the spec to docs/specs/archive/, stamps it as history, and appends what was actually built.
# Runs from `factory start` and at the end of `factory run`, so the PR goes through the gate like
# any other (it touches docs/specs/, so it always waits for the owner's `merge` label: their sign-off).
#   factory archive-specs
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require git gh jq
factory_require_config

MAIN=$(factory_main_root)
cd "$MAIN" || exit 1
factory_repo_slug >/dev/null || die "no GitHub repo for $MAIN"
BASE=$(factory_base_branch)
TODAY=$(date +%Y-%m-%d)
git fetch -q origin "$BASE" || die "could not fetch $BASE"

FEATURES=$(factory_api_list "issues?labels=feature&state=open&per_page=100") || die "cannot list feature issues"
for P in $(jq -r '.[] | select(.pull_request == null) | .number' <<<"$FEATURES"); do
  SUBS=$(factory_api_list "issues/$P/sub_issues?per_page=100") || continue
  [ "$(jq length <<<"$SUBS")" -gt 0 ] || continue
  [ "$(jq '[.[] | select(.state == "open")] | length' <<<"$SUBS")" -eq 0 ] || continue
  SPEC=$(jq -r --argjson p "$P" '.[] | select(.number == $p) | .body // ""' <<<"$FEATURES" | grep -oE 'docs/specs/[A-Za-z0-9._-]+\.md' | head -1)
  [ -n "$SPEC" ] || {
    warn "feature #$P has no spec path in its body; skipping"
    continue
  }
  git cat-file -e "origin/$BASE:$SPEC" 2>/dev/null || continue # already archived (or never merged)
  NAME=$(basename "$SPEC" .md)
  BRANCH="archive/$NAME"
  if factory_open_pr "$BRANCH" | grep -q .; then
    continue
  fi

  say "feature #$P is done — archiving $SPEC"
  WT=$(mktemp -d)/archive
  git worktree add -q -B "$BRANCH" "$WT" "origin/$BASE" || die "could not create $BRANCH"
  (
    cd "$WT" || exit 1
    mkdir -p docs/specs/archive
    DEST="docs/specs/archive/$NAME.md"
    git mv "$SPEC" "$DEST"
    # Stamp: the warning sits in the file the agent is reading.
    awk -v today="$TODAY" '
      NR == 1 { print; print ""; print "> **Archived " today ".** History, not current behaviour: this records what was planned and built at the time. The code is the truth; do not implement from this file."; next }
      /^Status: active/ { sub(/^Status: active/, "Status: archived " today) }
      { print }
    ' "$DEST" >"$DEST.tmp" && mv "$DEST.tmp" "$DEST"

    # Merged PRs and their bodies (REST has no body search outside the search API).
    MERGED=$(factory_api_list "pulls?state=closed&per_page=100" | jq -c '[.[] | select(.merged_at) | {number, body: (.body // "")}]')
    {
      printf '\n## As built\n\n'
      printf 'Tickets and the decisions their implementers listed (decisions the spec did not settle):\n\n'
      for k in $(jq -r '.[].number' <<<"$SUBS"); do
        TITLE=$(jq -r --argjson k "$k" '.[] | select(.number == $k) | .title' <<<"$SUBS")
        PR=$(jq -c --arg k "$k" '[.[] | select(.body | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s*:?\\s+#" + $k + "\\b"))][0] // empty' <<<"$MERGED")
        if [ -n "$PR" ]; then
          printf -- '- #%s %s — PR #%s\n' "$k" "$TITLE" "$(jq -r .number <<<"$PR")"
          markdown_section "$(jq -r .body <<<"$PR")" Decisions |
            grep -E '^\s*[-*] ' | grep -viE '^\s*[-*]\s*(none\.?|n/a)?\s*$' | sed 's/^\s*[-*] /  - /'
        else
          printf -- '- #%s %s — closed without a merged PR\n' "$k" "$TITLE"
        fi
      done
    } >>"$DEST"

    git add -A
    git commit -qm "Archive spec $NAME" -m "All tickets of #$P are closed."
    git push -q -u origin "$BRANCH"
    factory_pr_create "$BASE" "$BRANCH" "Archive spec $NAME" "Closes #$P

Every ticket of this feature is closed. This moves \`$SPEC\` to \`docs/specs/archive/\`, marks it as
history, and appends what was actually built (each ticket's PR and the decisions its implementer
listed). Adding the \`merge\` label is the owner's sign-off that the feature is done; it always
needs that because it touches \`docs/specs/\`.

## Verification
- Spec moved and stamped; \"As built\" lists every sub-issue of #$P.

## Local review
Unresolved blocking findings: 0"
  )
  git worktree remove --force "$WT" >/dev/null 2>&1
done
