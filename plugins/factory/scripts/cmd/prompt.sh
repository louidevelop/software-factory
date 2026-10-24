#!/usr/bin/env bash
# prompt — print the full instructions of a factory agent or skill from this factory.
#   factory prompt <agent | skill>
# A project's .claude/agents/factory-*.md and .claude/skills/*/SKILL.md are stubs (factory sync
# writes them) that keep only the frontmatter and say to run this, so the instructions themselves
# always come from the runtime the session fetched: factory main.
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"

NAME=${1:-}
P=$FACTORY_PLUGIN
names() { (cd "$P" && ls agents/*.md skills/*/SKILL.md) | sed -E 's#^agents/(.*)\.md$#\1#; s#^skills/(.*)/SKILL\.md$#\1#' | tr '\n' ' '; }
[[ $NAME =~ ^[a-z][a-z-]*$ ]] || die "usage: factory prompt <name>; one of: $(names)"
if [ -f "$P/agents/$NAME.md" ]; then
  FILE="$P/agents/$NAME.md"
elif [ -f "$P/skills/$NAME/SKILL.md" ]; then
  FILE="$P/skills/$NAME/SKILL.md"
  # Skills name factory files relative to the plugin ("two directories up from this skill's base
  # directory"); from a stub that would point into the project's .claude/.
  echo "Factory files this skill names (templates/…, scripts/factory, …) are under $P/; run the factory itself as .factory/bin/factory."
  echo
else
  die "no factory agent or skill named '$NAME'; one of: $(names)"
fi
# The body only: the frontmatter is already in the stub.
awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$FILE"
