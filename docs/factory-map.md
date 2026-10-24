# Software factory — current state (2026-10-24)

Sources: `~/code/outfit-assistant` (OA), `~/code/byggtalk` (BT), handoff docs in
`~/Downloads/files/` and `~/Downloads/byggtalk-handoff.md`, `~/code/agentic-platform-notes.md`.

There is no factory repo yet. The factory exists as a set of files copied from OA into BT
(BT handoff §11: "carried over from the outfit-assistant project"), then each copy evolved on its own.

Core principle (BT handoff §11): *instructions are probabilistic; lint rules and hooks are guaranteed.*
Everything a lint rule can express becomes a lint rule. Everything that must always happen becomes a hook.
`AGENTS.md` holds only judgment calls, silent failures, and process.

---

## The layers

| # | Layer | What it is | OA | BT |
|---|---|---|---|---|
| 0 | **Spec** | Handoff doc: what to build, stack decided, architecture, data model, build order, agentic setup | outside the repo (`~/Downloads/files/outfit-assistant-handoff.md` + `-ui-handoff.md`) | `docs/byggtalk-handoff.md` (§11 = factory setup, §12 = milestones) |
| 1 | **Rules** | `AGENTS.md` is the only rules file; `CLAUDE.md` = `@AGENTS.md`. Rule placement: a file-local rule goes in a comment in that file | ✅ | ✅ + "AGENTS wins on *how*, handoff wins on *what*" |
| 2 | **Static fences** | tsc strict; Biome: kebab-case files, no unused code, `noRestrictedImports` per directory = the one-way architecture, enforced | ✅ (React out of lib, Supabase/services out of screens) | ✅ (+ `noNonNullAssertion`; one provider SDK per module) |
| 3 | **Grep checks** | Rules Biome can't express, as shell scripts inside `check` | `check-class-tokens.sh` (no Tailwind arbitrary values), `check-deno.sh` (Edge Functions + evals) | `check-external-calls.sh` (one module per provider), `check-state-writes.sh` (single `transition()` door) |
| 4 | **One gate** | `npm run check` = local = CI, byte for byte. `.nvmrc`, `save-exact`, `npm ci`, `TZ=UTC` | ✅ (+ `.dvmrc` for Deno), CI on every push | ✅ CI on main + PRs |
| 5 | **Hooks** | PostToolUse → biome on the edited file. Stop → `npm run check`, exit 2, `stop_hook_active` guard | ✅ basic (uses `jq`) | ✅ hardened: `lib.sh` (Node parser, fails closed), skips the gate during early scaffolding, 60-line tail |
| 5b | **Blocklist** | `permissions.deny` + PreToolUse `block-dangerous.sh` (secrets, destructive DB/git/rm, provider curls, deploys, global installs). Rule ladder: deny → Biome → grep → hook regex → AGENTS.md | ❌ none | ✅ |
| 6 | **Test rules** | Colocated tests in the same commit, no network, fake timers + frozen now, no snapshots, never weaken a test | ✅ | ✅ + recorded fixtures only (`test/fixtures/meta/`), pglite e2e |
| 7 | **AI contracts** | Zod-parse every reply; retry, never patch or clamp; numeric bounds in Zod, stated as prose in the prompt; prompts are typed functions in one place | ✅ | ✅ + any prompt/schema change needs an eval fixture |
| 8 | **Evals** | Live-model checks, run by hand, never in `check` or CI | rich: cost per call, prompt hash in the run header, scenario builder, month simulation against baseline pickers | scoreboard (WER + exact fields + amendments), frozen date, scoreboard pasted into the PR |
| 9 | **UI fences** | Tokens only in `@theme`, default palette disabled, arbitrary values grep-banned, kit with variant props (no `className`), a11y inside the kit, screens can't import `react-native` or platform APIs, all strings in `strings.ts`, light mode only | ✅ | n/a (no UI) |
| 10 | **Work intake** | How a task gets specified for an agent | `agent-issue` skill + `.github/ISSUE_TEMPLATE/agent-task.md` (Goal / AC Tested+Observed / Scope / Decisions / Out of scope / "list your decisions in the PR"); you add the `ready-for-agent` label | `docs/milestones.json`: scope, acceptance, `depends_on`, `requires_human_before_start`, `human_review_required` + focus, `proof_log` |
| 11 | **Execution loop** | Unattended runs | `.claude/ralph/ralph.sh`: one fresh `claude -p` per issue, one commit per issue, retries with a description of the state left behind, `--permission-mode auto` + `--disallowedTools`, a `BLOCKED-N.md` escape | `milestone-loop.sh` / `/goal` + `milestone.mjs` CLI (start/done --proof/block); `--dangerously-skip-permissions`, relies on the hooks; stops at human review |
| 12 | **Learning loop** | A failed run turns into a fix where it belongs | `agent-run-review` skill → `docs/agent-context-gaps.md` → fix in template, issue, or rules → discard the branch and rerun | ❌ |
| 13 | **Env plumbing** | Worktrees that can actually run the app | `worktree-setup` skill (copies `.env*.local`, installs deps) | ❌ |
| 14 | **Human gates** | Where automation stops | no deploys, db resets or pushes from the loop; on-device "Observed" criteria | reviewed paths (states, structure, verify, drizzle); deploys and env setup are human steps listed per milestone |
| 15 | **Roadmap** | `agentic-platform-notes.md`: containerized runners → context-engine MCP → k8s. The product repo is a fixed benchmark that never changes for the platform | — | — |

---

## Drift and defects found while mapping

1. **No single source.** The shared layers (1–8) exist as divergent copies. `after-write.sh` already differs (jq vs `lib.sh`, extensions handled, skipped paths, missing-biome guard). Every BT hardening is missing from OA, and OA's intake and learning loop are missing from BT.
2. **OA has no blocklist.** No `permissions.deny`, no PreToolUse hook. `.env.local` (real Supabase/AI keys) is readable, and `rm -rf` / `supabase db reset` are only blocked inside `ralph.sh` via `--disallowedTools`, not in interactive sessions.
3. **The agent probably never sees the after-write lint feedback.** Both hooks exit 0. For PostToolUse, Claude Code only passes output to the model on exit 2 (stderr) or through JSON `additionalContext`. OA prints to stdout and BT prints to stderr, so in both repos unfixable lint findings only surface at the Stop gate. BT's comment says "the agent sees them next turn". **Verify with a probe before relying on this.**
4. **BT points at a spec that doesn't exist.** `AGENTS.md`, `build-loop.md` and `milestone-prompt.txt` reference `docs/handoff.md`. The file is `docs/byggtalk-handoff.md`.
5. **OA's spec lives outside the repo.** The handoff and UI-handoff docs are in `~/Downloads/files/`, so agents can't read them. The platform notes assume they ship in-repo.
6. **OA's Ralph loop isn't versioned.** `.claude/ralph/` is in `.git/info/exclude`, and the script hardcodes milestone `#56`.
7. **Two loop designs.** Both have the same purpose but use different state stores (GitHub issues vs JSON), different completion signals (a commit mentioning `#N` vs `done --proof`), and different permission models (auto + disallowed vs skip-permissions + hooks).
8. **"Observed" criteria aren't verified by anything.** The only gaps logged (OA #60) are UI that read wrong once someone saw it on a device. Nothing in the factory takes or checks screenshots.
9. **Leftovers.** `byggtalk-claude-hooks.zip` is committed at the BT root, next to an empty `byggtalk-claude-hooks/` folder.

---

## Factory parts by portability

- **Stack-agnostic core:** single rules file + placement rule; the rule ladder; the single `check` gate + local=CI; the three hooks + blocklist; test rules; "never weaken a check"; intake template; run-review + gaps log; loop with proof and human gates; handoff-doc-first.
- **Per-stack packs:** TS/Biome fences + kebab/one-export conventions; Expo/NativeWind UI pack (layer 9); Deno/Supabase functions; Node backend (Drizzle/pg-boss/state-machine door); AI-contracts + eval harness pattern.
- **Per-project:** the actual fences (which module owns which SDK), grep scripts, reviewed paths, milestones/issues, eval fixtures.
