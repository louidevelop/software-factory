---
name: factory-bootstrap
description: Set up a NEW project for the software factory — the local verification loop (one check command, per-file fix, architecture fences, grep fences, pinned toolchain, deterministic tests), rules file, CI, GitHub labels/merge settings, and proof that every guardrail fires. Tech-general — works for any language or stack. Use when the user starts a new project, says "bootstrap", "set up the factory", "set up guardrails/linting/the verification loop" for a fresh repo. Not for adopting an existing codebase (that mode does not exist yet — say so).
---

# Factory bootstrap

The factory standardises a **contract**, not a stack. This skill fills each slot with tools that
fit the project's stack, writes them down in `.factory/config.json`, and proves every guardrail
fires. Principle: instructions are probabilistic, lint rules and hooks are guaranteed — anything a
tool can enforce becomes a tool rule; `AGENTS.md` keeps only judgment calls.

Paths below like `templates/…` and `scripts/factory` are relative to this plugin's root: two
directories up from this skill's base directory.

If the repo already has substantial code, stop: adopting an existing project is a separate mode
that does not exist yet. Tell the user.

## 1. Interview — one batch

Read whatever exists (README, manifests). Then ask ALL open questions in one message, and do not
continue until every one is answered:

- What is the product, in one or two sentences?
- Stack: language, framework, runtime, package manager. (Decided once; recorded as "do not revisit".)
- Architecture layers and the allowed dependency direction (e.g. `api → service → domain`). If the
  user has no opinion, propose layers that fit the stack and get a yes.
- External services (each will live behind exactly one module).
- What is sensitive: auth, payments, data deletion, personal data, signature verification, prompts.
  These become `paths.sensitive`.
- Migrations: tool and directory (`paths.migrations`), and the commands that APPLY them to a shared
  database (these go in `block`).
- Deploy commands (these go in `block`).
- UI or not. If yes: where design tokens live, and whether a component kit exists.
- GitHub repo name, and the machine user's login if it exists yet.

## 2. Choose a tool per contract slot — the user confirms

| Slot | Requirement |
|---|---|
| `check` | ONE command: types + lint + fences + grep checks + tests. Identical locally and in CI. Seconds, not minutes. No network. |
| `fix` | Formats and auto-fixes ONE file, fast (sub-second ideally). Exits non-zero when problems remain. |
| Type checking | Strictest mode the stack offers. |
| Architecture fences | A tool that fails when a layer imports a layer it may not (import-linter, depguard, Biome `noRestrictedImports`, eslint-plugin-boundaries, ArchUnit, …). Also: each external SDK importable from exactly one module. |
| Grep fences | `scripts/check-*.sh` for rules the linter cannot express (design tokens, single-writer rules, one module per provider URL). Deliberately crude; tighten the pattern when it false-positives, never work around it in app code. |
| Tests | Deterministic: no network, frozen "now", UTC. Colocated or mirrored, per stack convention. |
| Toolchain pin | Runtime version file (`.nvmrc`, `.python-version`, `go.mod` toolchain, `rust-toolchain.toml`…) + committed lockfile + exact versions. |

For each slot propose one tool with a one-line reason, measured against: fast, single-file capable,
deterministic, configured inside the repo, no global installs. For TypeScript/Node, the worked
examples in `examples/` (outfit-assistant: Expo + Biome; byggtalk: Node backend) show proven choices.
For any other stack, read that ecosystem's current documentation before proposing — never guess
flags or config keys from memory.

## 3. Scaffold

Write, adapting the templates:

- `.factory/config.json` — from `templates/config.example.json`; schema in `templates/config.schema.json`.
  `owners` = the user's GitHub login (never the machine user). Fill `paths.*` from the interview;
  add every linter/fence config and check script to `paths.guardrails`.
- `AGENTS.md` — from `templates/AGENTS.md`: product line, stack, layer chain with one bullet per
  layer, fences, conventions. Keep only judgment calls. Leave the `factory:begin/end` markers.
- `CLAUDE.md` — exactly `@AGENTS.md`.
- Linter/type-checker/fence configs, `scripts/check-*.sh`, the toolchain pin, lockfile.
- `.github/workflows/check.yml` — runs the `check` command and nothing else, on `pull_request` and
  pushes to the base branch, with the job named `check`. Pinned toolchain from the version file.
- `.claude/settings.json` — from `templates/settings.json` (enables the plugin, denies secrets and
  merging). Add a `deny` entry for each `block` command that has a simple prefix.
- `.gitignore` — must cover `.env` and `.env.*` but not `.env.example`. Write `.env.example` with
  key names only.
- `docs/specs/archive/.gitkeep`.
- Then run `scripts/factory sync --apply` from the project root: it writes the factory block into
  `AGENTS.md` and the managed files (issue template, PR template, gate workflow, `.factory/bin/factory`).

## 4. Walking skeleton

One small module per layer, each with one real test, wired along the allowed direction — so fences,
tests and `check` are real from the first commit, not switched on later against existing code.
Run `check`; it must be green.

## 5. GitHub

Create the repo if needed (private by default). Run `scripts/factory github-setup` (dry run), show the
user the output, then `--apply` (add `--machine-user <login>` when known). This runs as the OWNER.
Branch protection fails on private repos without GitHub Pro; the script says so — tell the user what
that means (the gate still merges, GitHub does not hard-enforce it).

Commit the scaffold and skeleton as the first commit on the base branch and push.

## 6. Prove every guardrail — not done until all pass

Report each probe with its actual output. Undo every probe's change afterwards.

1. Lint error (e.g. an unused import) → the Stop hook blocks the turn with the `check` tail.
2. A blocked command from `block` (and `cat .env`) → blocked with the reason.
3. Read `.env` with the Read tool → blocked.
4. Edit a file into a state the fix command cannot repair → the after-edit hook's message reaches you.
5. A throwaway file that imports across a fence → `check` fails naming the fence. Delete it.
6. Push → CI runs `check` and it is green.
7. (Needs the gate, phase 3+) A PR that changes the lockfile → labelled `risk:high`, not merged.
8. (Needs the gate) A trivial PR with a ticket → `risk:low`, merged by the gate.

Probes 1–4 need the hooks loaded: they fire only in a session started after the plugin is enabled.
If this session predates the plugin, say so and have the user run them in a new session.

Finish with `scripts/factory doctor` and show its output.
