#!/usr/bin/env bash
# install.sh — set up the software factory in a project.
# Run it from the project's root:
#   curl -fsSL https://raw.githubusercontent.com/louidevelop/software-factory/main/install.sh | bash
#
# It writes only the thin layer, through the factory's own `factory sync --apply`: .factory/bin/,
# the factory's hooks in .claude/settings.json, the agent and skill stubs in .claude/, and the
# factory block in AGENTS.md. The project's config (.factory/config.json) is the
# factory-bootstrap skill's job, so an existing one is never touched. Safe to re-run: a second run
# updates the runtime and re-syncs, and changes nothing that is already current.
#   FACTORY_HOME=/path/to/software-factory  a local factory used as-is, nothing fetched (factory development)
#   FACTORY_SOURCE=<git URL or path>        fetch main from there instead of GitHub (offline tests)
set -u
SOURCE=${FACTORY_SOURCE:-https://github.com/louidevelop/software-factory.git}

say() { printf 'factory: %s\n' "$*"; }
die() {
  printf 'factory: %s\n' "$*" >&2
  exit 1
}

usable() { [ -x "$1/plugins/factory/scripts/factory" ] || [ -x "$1/scripts/factory" ]; }
# The factory directory (plugins/factory) of a factory checkout at <dir> (its root or plugins/factory).
factory_dir() { if [ -x "$1/plugins/factory/scripts/factory" ]; then printf '%s' "$1/plugins/factory"; else printf '%s' "$1"; fi; }

# All of it in one function, called on the last line: under `curl … | bash`, bash reads this script
# from stdin as it runs, so a half-downloaded script must run nothing, and a command that reads
# stdin must not eat the rest of it.
main() {
  # The thin layer's own prerequisites; the factory needs nothing else on a project machine.
  MISSING=()
  for t in bash git gh jq claude; do command -v "$t" >/dev/null 2>&1 || MISSING+=("$t"); done
  [ ${#MISSING[@]} -eq 0 ] || die "missing prerequisites: ${MISSING[*]}. Install them, then run this again."

  # The runtime lives in the git directory, so the project must be a git checkout, and this must be
  # its root: the thin layer's paths are relative to it. A folder that is not a checkout yet is a new
  # project, and becomes one.
  HERE=$(pwd -P)
  if TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
    [ "$(cd "$TOP" && pwd -P)" = "$HERE" ] || die "run this from the project's root, $TOP"
  else
    git init -q || die "could not create a git repository in $HERE"
    say "created a git repository in $HERE"
  fi

  if [ -n "${FACTORY_HOME:-}" ]; then
    usable "$FACTORY_HOME" || die "FACTORY_HOME=$FACTORY_HOME has no scripts/factory."
    FACTORY_DIR=$(factory_dir "$FACTORY_HOME")
    say "using FACTORY_HOME=$FACTORY_HOME as the runtime, as-is"
  else
    COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || die "cannot find the git directory of $HERE"
    RT="$COMMON/factory-runtime"
    # A first clone, only to get .factory/bin/fetch. That script then does the real fetch, the same
    # way every session start does (update, record the SHA, keep the last good copy on failure), so
    # what install leaves behind is exactly what a session would.
    if ! usable "$RT"; then
      SRC=$SOURCE
      # A shallow clone of a local path needs file://; plain `git clone --depth 1 <dir>` ignores --depth.
      [ -d "$SRC" ] && SRC="file://$(cd "$SRC" && pwd -P)"
      rm -rf "$RT.new.$$"
      git clone -q --depth 1 --branch main "$SRC" "$RT.new.$$" && usable "$RT.new.$$" ||
        die "could not fetch the factory from $SOURCE"
      rm -rf "$RT" && mv "$RT.new.$$" "$RT"
    fi
    mkdir -p .factory/bin
    cp "$(factory_dir "$RT")/templates/bin/fetch.sh" .factory/bin/fetch && chmod +x .factory/bin/fetch ||
      die "could not write .factory/bin/fetch"
    .factory/bin/fetch || die "could not fetch the factory from $SOURCE"
    FACTORY_DIR=$(factory_dir "$RT")
  fi

  # The rest of the thin layer comes from the runtime itself, so install never drifts from sync.
  CLAUDE_PROJECT_DIR=$HERE "$FACTORY_DIR/scripts/factory" sync --apply || die "factory sync --apply failed"

  echo
  if [ -f .factory/config.json ]; then
    say "the thin layer is current. Commit it (.factory/bin, .claude, AGENTS.md, .github), then check the project with .factory/bin/factory doctor."
  else
    say "installed. Next: open Claude Code in $HERE and ask for the factory-bootstrap skill. It interviews you, writes .factory/config.json, and proves every guardrail fires."
  fi
}

main "$@" </dev/null
