# Software factory — rules for agents working on this repo

This repo is the factory itself: a Claude Code plugin marketplace (`plugins/factory/`), a
reusable GitHub workflow + classifier action. The code is the source of truth: the reason for a
non-obvious choice goes in a comment next to the code it governs.

`CLAUDE.md` is a one-line `@AGENTS.md` import. Put rules here, never there.

## The loop

- Run `scripts/check.sh` after every change. It must be green before every push; CI runs the identical script.
- Every project follows factory `main`: a broken `main` breaks every project on its next session.
  While the factory is young, commit and push straight to `main` — no PRs unless the owner asks
  for one. `scripts/check.sh` green is the bar.

## Constraints that are easy to break

- **Tech-general.** Nothing in `plugins/factory/` may assume a language or stack. Stack specifics
  come from the project's `.factory/config.json`; examples live in `examples/`.
- **Local prerequisites are bash, git, gh, jq, claude.** Hooks and scripts may not need Node,
  Python, or anything else on a project machine. Node is allowed only in `classifier/` (CI only)
  and in this repo's own dev scripts.
- **GitHub through REST only.** Every GitHub call in `plugins/factory/` is `gh api` REST
  (`factory_api` in `scripts/common.sh`), and skills and prompts say the same. Claude's cloud proxy
  answers GraphQL with 403, and `gh issue`, `gh pr`, `gh repo view` and `gh label` all use it.
- **Hooks fail closed.** A hook that cannot read its input exits 2. Exit 2 + stderr is the only
  channel that reaches the model; exit 1 blocks nothing.
- **One glob dialect.** `*`/`**` match across `/`, `**/` also matches zero dirs. Bash
  (`hooks/lib.sh`) and the classifier implement it identically; change both or neither.
- **The classifier only escalates.** No rule, input, or PR content may lower a rating. Errors → high.
  Config is read from the base branch, never from the PR.
- **The thin layer is a contract.** A project commits only what `factory sync` writes:
  `.factory/bin/{fetch,hook,factory}` (from `plugins/factory/templates/bin/`), the `hooks` key of
  `.claude/settings.json`, and the agent and skill stubs in `.claude/`. Every session fetches
  factory `main` through it. `main` may extend the thin layer, but must keep working with every
  thin-layer version a project may still have until its sync PR merges: keep hook names, `factory`
  subcommands and `factory prompt <name>` stable.
- **The reviewer is never briefed by the implementer.** The review runs as plugin subagents
  (`agents/`) that the main agent triggers with an exact one-line message — `hooks/review-guard.sh`
  enforces the wording, keeps them read-only, and keeps everyone else from writing the review record.
  They gather the ticket, spec and diff themselves.

## Tests

- Every hook behaviour has a case in `tests/hooks.test.sh`; every classifier rule has fixtures in
  `classifier/*.test.mjs`; the scripts' GitHub logic is tested in `tests/scripts.test.sh` against
  `tests/fake-gh/gh`, which serves only `gh api` replies; the thin layer (sync, fetch,
  `.factory/bin/hook`, `factory prompt`) in `tests/thin-layer.test.sh`, fetching from a local repo.
  Add the case in the same change as the behaviour.
- Never weaken or delete a test to make `check` pass.
