#!/usr/bin/env bash
# .factory/bin/fetch — managed by the software factory (factory sync). Do not edit.
# Brings this project's copy of the factory (the "runtime": scripts, hooks, prompts) up to factory
# main. Runs at every session start (.claude/settings.json SessionStart). The copy lives in
# $(git rev-parse --git-common-dir)/factory-runtime, shared by every worktree of the project.
#
# It always tries to update: a cloud workspace can carry a stale copy from the environment's
# cached snapshot, so whatever is there is never trusted as current. When the update fails, the
# last good copy stays in use with a warning; with no usable copy at all, it exits 1.
#   FACTORY_HOME=/path/to/software-factory  a local factory used as-is, nothing fetched (factory development)
#   FACTORY_SOURCE=<git URL or path>        fetch main from there instead of GitHub (offline tests)
set -u
SOURCE=${FACTORY_SOURCE:-https://github.com/louidevelop/software-factory.git}
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)

warn() { echo "factory: $*" >&2; }

# A usable copy has the factory command; the scripts and hooks come with it.
usable() { [ -x "$1/plugins/factory/scripts/factory" ] || [ -x "$1/scripts/factory" ]; }

if [ -n "${FACTORY_HOME:-}" ]; then
  usable "$FACTORY_HOME" || {
    warn "FACTORY_HOME=$FACTORY_HOME has no scripts/factory."
    exit 1
  }
  echo "factory runtime: FACTORY_HOME=$FACTORY_HOME (used as-is)"
  exit 0
fi

COMMON=$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || {
  warn "$ROOT is not a git checkout; the factory runtime lives in its git directory."
  exit 1
}
RT="$COMMON/factory-runtime"
# A shallow clone of a local path needs file://; plain `git clone --depth 1 <dir>` ignores --depth.
[ -d "$SOURCE" ] && SOURCE="file://$(cd "$SOURCE" && pwd -P)"

# One fetch at a time: every worktree's session shares this copy. A lock older than the wait is
# left over from a killed fetch and is taken over.
LOCK="$RT.lock"
for _ in $(seq 1 120); do
  mkdir "$LOCK" 2>/dev/null && break
  sleep 0.5
done
mkdir "$LOCK" 2>/dev/null || true
trap 'rm -rf "$LOCK" "$RT.new.$$"' EXIT

updated=0
if [ -d "$RT/.git" ] && git -C "$RT" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  # Shallow histories do not connect, so "fast-forward" is a reset to the fetched main. Nobody
  # edits the copy (the hooks block it), so nothing of value is lost; clean drops stray files.
  if git -C "$RT" fetch -q --depth 1 "$SOURCE" main 2>/dev/null &&
    git -C "$RT" reset -q --hard FETCH_HEAD && git -C "$RT" clean -qffdx; then
    updated=1
  fi
fi
if [ "$updated" = 0 ] && ! usable "$RT"; then
  # No copy, or a broken one: clone fresh beside it and swap, so a failed clone never leaves
  # a half-written runtime behind.
  if git clone -q --depth 1 --branch main "$SOURCE" "$RT.new.$$" 2>/dev/null && usable "$RT.new.$$"; then
    rm -rf "$RT" && mv "$RT.new.$$" "$RT" && updated=1
  fi
fi

usable "$RT" || {
  warn "could not fetch the factory from $SOURCE, and there is no earlier copy. Factory hooks block every tool call until .factory/bin/fetch succeeds."
  exit 1
}
SHA=$(git -C "$RT" rev-parse HEAD 2>/dev/null)
if [ "$updated" = 1 ]; then
  echo "$SHA" >"$RT.sha"
  echo "factory runtime: main at ${SHA:0:12}"
else
  warn "could not update the factory from $SOURCE; using the last good copy (${SHA:0:12})."
fi
exit 0
