# Software factory — rules for agents working on this repo

This repo is the factory itself: a Claude Code plugin marketplace (`plugins/factory/`), a
reusable GitHub workflow + classifier action, and the docs that decided their shape
(`docs/factory-decisions.md` is binding; read it before changing behaviour).

`CLAUDE.md` is a one-line `@AGENTS.md` import. Put rules here, never there.

## The loop

- Run `scripts/check.sh` after every change. It must be green before a PR; CI runs the identical script.
- Every project follows factory `main`: a broken `main` breaks every project on its next session.
  Every change lands through a PR the owner reviews. Never push to `main`.

## Constraints that are easy to break

- **Tech-general.** Nothing in `plugins/factory/` may assume a language or stack. Stack specifics
  come from the project's `.factory/config.json`; examples live in `examples/`.
- **Local prerequisites are bash, git, gh, jq, claude.** Hooks and scripts may not need Node,
  Python, or anything else on a project machine. Node is allowed only in `classifier/` (CI only)
  and in this repo's own dev scripts.
- **Hooks fail closed.** A hook that cannot read its input exits 2. Exit 2 + stderr is the only
  channel that reaches the model; exit 1 blocks nothing.
- **One glob dialect.** `*`/`**` match across `/`, `**/` also matches zero dirs. Bash
  (`hooks/lib.sh`) and the classifier implement it identically; change both or neither.
- **The classifier only escalates.** No rule, input, or PR content may lower a rating. Errors → high.
  Config is read from the base branch, never from the PR.
- **The reviewer is never briefed by the implementer.** Its prompt is fixed and carries only the
  ticket number and branch; it gathers its own context.

## Tests

- Every hook behaviour has a case in `tests/hooks.test.sh`; every classifier rule has fixtures in
  `classifier/*.test.mjs`. Add the case in the same change as the behaviour.
- Never weaken or delete a test to make `check` pass.
