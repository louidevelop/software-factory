#!/usr/bin/env bash
# thin-layer.test.sh — the files `factory sync` installs in a project (.factory/bin/{fetch,hook,factory},
# the hooks in .claude/settings.json, the agent and skill stubs) and how a session loads the factory
# through them. Offline: the factory is fetched from a local git repo built from this working tree.
set -u
TESTS="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TESTS/../plugins/factory" && pwd)"
FACTORY="$PLUGIN/scripts/factory"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  echo "FAIL $1"
  FAIL=$((FAIL + 1))
}
G() { git -c user.name=t -c user.email=t@example.com "$@"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
unset FACTORY_HOME FACTORY_SOURCE
export HOME="$W/home" # doctor reads ~/.claude/settings.json
mkdir -p "$HOME"

# The factory to fetch: main of a local repo holding this working tree's plugin.
SRC="$W/factory"
mkdir -p "$SRC/plugins"
cp -R "$PLUGIN" "$SRC/plugins/factory"
(cd "$SRC" && git init -q -b main && git add -A && G commit -qm factory)

# A project that loads the factory as a plugin today, with its own permissions.
P="$W/project"
mkdir -p "$P/.factory" "$P/.claude"
cd "$P" || exit 1
git init -q -b main && G commit -q --allow-empty -m init
echo '{"version":1,"owners":["o"],"check":"true"}' >.factory/config.json
cat >.claude/settings.json <<'JSON'
{
  "extraKnownMarketplaces": {"software-factory": {"source": {"source": "github", "repo": "louidevelop/software-factory"}}},
  "enabledPlugins": {"factory@software-factory": true},
  "permissions": {"allow": ["Bash(make test)"], "deny": ["Read(./.env)"]},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "old"}]}]}
}
JSON
export CLAUDE_PROJECT_DIR="$P"

# ---------- sync installs the thin layer ----------
"$FACTORY" sync >"$W/out" 2>&1
[ $? -eq 10 ] && ok || no "sync reports the thin layer as behind"
for f in .factory/bin/fetch .factory/bin/hook .claude/settings.json .claude/agents/factory-reviewer.md .claude/skills/start-ticket/SKILL.md; do
  grep -qF "$f" "$W/out" && ok || no "sync reports $f"
done
"$FACTORY" sync --apply >/dev/null 2>&1 && ok || no "sync --apply succeeds"
"$FACTORY" sync >/dev/null 2>&1 && ok || no "sync is current after apply"
for f in factory fetch hook; do [ -x ".factory/bin/$f" ] && ok || no ".factory/bin/$f installed and executable"; done

S=.claude/settings.json
jq -e '.permissions == {"allow": ["Bash(make test)"], "deny": ["Read(./.env)"]}' $S >/dev/null && ok || no "the project's permissions survive"
jq -e 'has("enabledPlugins") or has("extraKnownMarketplaces") | not' $S >/dev/null && ok || no "sync removes the plugin keys"
jq -e --slurpfile t "$PLUGIN/templates/settings-hooks.json" '.hooks == $t[0].hooks' $S >/dev/null && ok || no "sync owns the hooks key"
jq -e '.hooks.SessionStart[0].hooks[0].command | test("\\.factory/bin/fetch$")' $S >/dev/null && ok || no "SessionStart runs the fetch"
# Same matchers and timeouts as the plugin's hooks.json, each through .factory/bin/hook.
shape() { jq -S '.hooks | del(.SessionStart) | map_values(map({matcher, hooks: (.hooks | map({timeout, name: (.command | capture("(hooks/|hook )(?<n>[a-z-]+)") .n)}))}))' "$1"; }
[ "$(shape "$PLUGIN/hooks/hooks.json")" = "$(shape $S)" ] && ok || no "the thin layer's hooks match the plugin's hooks.json"
jq -c . $S >"$W/s" && mv "$W/s" $S
"$FACTORY" sync >/dev/null 2>&1 && ok || no "a reformatted settings.json is still current"
jq '.hooks.Stop[0].hooks[0].timeout = 1' $S >"$W/s" && mv "$W/s" $S
"$FACTORY" sync >/dev/null 2>&1
[ $? -eq 10 ] && ok || no "a changed factory hook is behind"
"$FACTORY" sync --apply >/dev/null 2>&1

frontmatter() { awk 'NR == 1 && $0 == "---" { fm = 1; print; next } fm { print } fm && $0 == "---" { exit }' "$1"; }
for a in factory-reviewer factory-judge factory-resolver; do
  f=".claude/agents/$a.md"
  [ "$(frontmatter "$PLUGIN/agents/$a.md")" = "$(frontmatter "$f")" ] &&
    ok || no "$a stub keeps the frontmatter"
  grep -qF ".factory/bin/factory prompt $a\`" "$f" && ok || no "$a stub loads its instructions"
  [ "$(wc -l <"$f")" -le 8 ] && ok || no "$a stub is only frontmatter and one line"
done
for d in "$PLUGIN"/skills/*/; do
  s=$(basename "$d")
  f=".claude/skills/$s/SKILL.md"
  grep -qxF "$(grep -m1 '^description:' "$d/SKILL.md")" "$f" 2>/dev/null && ok || no "$s skill stub keeps the description"
  grep -qF ".factory/bin/factory prompt $s\`" "$f" 2>/dev/null && ok || no "$s skill stub loads its instructions"
done

# ---------- doctor: plugin and thin layer at once ----------
# doctor runs the fetch; from nowhere, so these tests stay offline and the next section still
# starts with no runtime.
export FACTORY_SOURCE="$W/nowhere"
PATH="$TESTS/fake-gh:$PATH" FAKE_GH_DIR="$W/gh" "$FACTORY" doctor >"$W/out" 2>&1
grep -q 'loads through .factory/bin' "$W/out" && ok || no "doctor sees the thin layer"
grep -q 'twice' "$W/out" && no "doctor warns about the plugin when it is off" || ok
mkdir -p "$HOME/.claude"
echo '{"enabledPlugins": {"factory@software-factory": true}}' >"$HOME/.claude/settings.json"
PATH="$TESTS/fake-gh:$PATH" FAKE_GH_DIR="$W/gh" "$FACTORY" doctor >"$W/out" 2>&1
grep -q 'runs twice' "$W/out" && ok || no "doctor warns when the plugin is enabled too"
echo '{"enabledPlugins": {"factory@software-factory": false}}' >.claude/settings.local.json
PATH="$TESTS/fake-gh:$PATH" FAKE_GH_DIR="$W/gh" "$FACTORY" doctor >"$W/out" 2>&1
grep -q 'twice' "$W/out" && no "a project's local settings disable the user's plugin" || ok
rm -f .claude/settings.local.json "$HOME/.claude/settings.json"

# ---------- hook: fails closed without a runtime ----------
RT="$P/.git/factory-runtime"
export FACTORY_SOURCE="$W/nowhere"
# hook_run <name> <json> — exit code; stderr in $W/err
hook_run() {
  printf '%s' "$2" | .factory/bin/hook "$1" >/dev/null 2>"$W/err"
  echo $?
}
LS='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
[ "$(hook_run block-dangerous "$LS")" = 2 ] && grep -q 'no factory runtime' "$W/err" && ok || no "hook blocks with no runtime"
[ "$(hook_run review-guard '{"tool_name":"Edit","tool_input":{"file_path":"x"}}')" = 2 ] && ok || no "hook blocks file tools with no runtime"
[ "$(hook_run block-dangerous '{"tool_name":"Bash","tool_input":{"command":".factory/bin/fetch"}}')" = 0 ] && ok || no "hook lets the fetch through with no runtime"
[ "$(hook_run block-dangerous '{"tool_name":"Bash","tool_input":{"command":".factory/bin/fetch; rm -rf src"}}')" = 2 ] && ok || no "only the bare fetch gets through"
[ "$(hook_run stop-gate '{"stop_hook_active": false}')" = 2 ] && ok || no "hook blocks Stop with no runtime"
[ "$(hook_run stop-gate '{"stop_hook_active": true}')" = 0 ] && ok || no "hook lets an already-blocked Stop go"
[ "$(hook_run 'Bad/name' "$LS")" = 2 ] && ok || no "hook needs a valid name"
.factory/bin/factory prompt factory-judge >/dev/null 2>&1 && no "factory fails with no runtime and no source" || ok

# ---------- fetch ----------
.factory/bin/fetch >/dev/null 2>"$W/err"
[ $? -eq 1 ] && [ ! -e "$RT" ] && grep -q 'no earlier copy' "$W/err" && ok || no "fetch fails with no copy and no source"
export FACTORY_SOURCE="$SRC"
OUT=$(.factory/bin/fetch 2>/dev/null)
[ $? -eq 0 ] && [ -x "$RT/plugins/factory/scripts/factory" ] && ok || no "fetch clones factory main"
SHA1=$(git -C "$SRC" rev-parse HEAD)
[ "$(cat "$RT.sha")" = "$SHA1" ] && [[ $OUT == *"${SHA1:0:12}"* ]] && ok || no "fetch records the SHA"
[ "$(git -C "$RT" rev-list --count HEAD)" = 1 ] && ok || no "the clone is shallow"
echo new >"$SRC/marker" && (cd "$SRC" && git add marker && G commit -qm second)
SHA2=$(git -C "$SRC" rev-parse HEAD)
touch "$RT/stale-from-a-snapshot"
.factory/bin/fetch >/dev/null 2>&1 && ok || no "fetch updates"
[ "$(git -C "$RT" rev-parse HEAD)" = "$SHA2" ] && [ -f "$RT/marker" ] && [ "$(cat "$RT.sha")" = "$SHA2" ] && ok || no "fetch moves to the new main"
[ ! -e "$RT/stale-from-a-snapshot" ] && ok || no "fetch drops files that are not in main"
git worktree add -q "$W/wt"
mkdir -p "$W/wt/.factory/bin" && cp .factory/bin/fetch "$W/wt/.factory/bin/"
(cd "$SRC" && G commit -q --allow-empty -m third)
"$W/wt/.factory/bin/fetch" >/dev/null 2>&1 && [ "$(git -C "$RT" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] &&
  ok || no "a worktree updates the main checkout's runtime"
SHA2=$(git -C "$SRC" rev-parse HEAD)
export FACTORY_SOURCE="$W/nowhere"
.factory/bin/fetch >/dev/null 2>"$W/err"
[ $? -eq 0 ] && grep -q 'last good copy' "$W/err" && [ "$(git -C "$RT" rev-parse HEAD)" = "$SHA2" ] && ok || no "a failed update keeps the last good copy"
FACTORY_HOME="$PLUGIN" .factory/bin/fetch 2>/dev/null | grep -q 'used as-is' && ok || no "FACTORY_HOME is used as-is"
FACTORY_HOME="$W/nowhere" .factory/bin/fetch >/dev/null 2>&1 && no "a FACTORY_HOME without the factory fails" || ok

# ---------- hook and factory with a runtime ----------
[ "$(hook_run block-dangerous '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}')" = 2 ] && grep -q BLOCKED "$W/err" && ok ||
  no "hook runs the runtime's hook with the input"
[ "$(hook_run block-dangerous "$LS")" = 0 ] && ok || no "hook passes an allowed call"
[ "$(hook_run no-such-hook "$LS")" = 2 ] && ok || no "hook blocks a hook the runtime does not have"
OUT=$(.factory/bin/factory prompt factory-reviewer 2>/dev/null)
[[ $OUT == *"You are the local reviewer"* ]] && [[ $OUT != *"name: factory-reviewer"* ]] && ok || no "factory prompt prints an agent's instructions without frontmatter"
OUT=$(.factory/bin/factory prompt start-ticket 2>/dev/null)
[[ $OUT == *"# Start a ticket"* ]] && [[ $OUT == *"$RT/plugins/factory/"* ]] && ok || no "factory prompt prints a skill and where its files are"
.factory/bin/factory prompt nope >/dev/null 2>&1 && no "factory prompt refuses an unknown name" || ok
.factory/bin/factory prompt >/dev/null 2>&1 && no "factory prompt needs a name" || ok
rm -rf "$RT"
export FACTORY_SOURCE="$SRC"
.factory/bin/factory prompt factory-judge 2>/dev/null | grep -q 'judge' && [ -d "$RT" ] && ok || no "factory fetches the runtime when there is none"

echo "thin layer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
