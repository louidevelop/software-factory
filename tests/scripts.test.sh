#!/usr/bin/env bash
# scripts.test.sh — the offline behaviour of the factory command line (no GitHub calls).
set -u
FACTORY="$(cd "$(dirname "$0")/../plugins/factory" && pwd)/scripts/factory"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
no() {
  echo "FAIL $1"
  FAIL=$((FAIL + 1))
}

P=$(mktemp -d)
trap 'rm -rf "$P"' EXIT
cd "$P" || exit 1
git init -q -b main
mkdir -p .factory
echo '{"version":1,"owners":["o"],"check":"true"}' >.factory/config.json
printf '# Project rules\n\nMine.\n\n<!-- factory:begin -->\n<!-- factory:end -->\n' >AGENTS.md
export CLAUDE_PROJECT_DIR="$P"

"$FACTORY" sync >/dev/null 2>&1
[ $? -eq 10 ] && ok || no "sync reports behind before apply"
"$FACTORY" sync --apply >/dev/null 2>&1 && ok || no "sync --apply succeeds"
"$FACTORY" sync >/dev/null 2>&1 && ok || no "sync reports current after apply"
grep -q '^Mine\.$' AGENTS.md && ok || no "project rules outside the markers survive"
grep -q '^<!-- factory:begin sha=[0-9a-f]\{12\} -->$' AGENTS.md && ok || no "begin marker carries the block hash"
[ "$(grep -c '^<!-- factory:end -->$' AGENTS.md)" -eq 1 ] && ok || no "exactly one end marker"
[ -x .factory/bin/factory ] && ok || no "shim installed and executable"
"$FACTORY" sync --apply >/dev/null 2>&1
[ "$(grep -c 'factory:begin' AGENTS.md)" -eq 1 ] && ok || no "re-applying does not duplicate the block"
sed -i.bak 's/^- Never guess\./- Guess freely./' AGENTS.md && rm -f AGENTS.md.bak
"$FACTORY" sync >/dev/null 2>&1
[ $? -eq 10 ] && ok || no "sync notices a hand edit inside the block"

echo "scripts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
