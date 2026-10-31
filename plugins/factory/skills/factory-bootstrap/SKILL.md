---
name: factory-bootstrap
description: Set up a NEW project for the software factory — the local verification loop (one check command, per-file fix, architecture fences, grep fences, pinned toolchain, deterministic tests), rules file, CI, GitHub labels/merge settings, and proof that every guardrail fires. Tech-general — works for any language or stack. Use when the user starts a new project, says "bootstrap", "set up the factory", "set up guardrails/linting/the verification loop" for a fresh repo. Not for adopting an existing codebase (that mode does not exist yet — say so).
---

# Factory bootstrap

The factory standardises a **contract**, not a stack. This skill fills each slot with tools that
fit the project's stack, writes them down in `.factory/config.json`, and proves every guardrail
fires. Principle: instructions are probabilistic, lint rules and hooks are guaranteed — anything a
tool can enforce becomes a tool rule; `AGENTS.md` keeps only judgment calls.

The factory reaches a project through a thin layer that `install.sh` writes (`.factory/bin/`, the
factory's hooks in `.claude/settings.json`, and the agent and skill stubs in `.claude/`); every
session fetches factory `main` through it. If `.factory/bin/factory` is missing, stop and have the
user run this from the project root, then start a new session:

```bash
curl -fsSL https://raw.githubusercontent.com/louidevelop/software-factory/main/install.sh | bash
```

Paths below like `templates/…` are factory files: the header `factory prompt` printed says where
they are. Run the factory itself as `.factory/bin/factory`.

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
  These become `paths.sensitive`, and a PR touching one always waits for the owner: keep the list
  to what the owner truly wants to see before it merges.
- Migrations: tool and directory (`paths.migrations`), and the commands that APPLY them to a shared
  database (these go in `block`).
- Deploy commands (these go in `block`).
- UI or not. If yes, the **UI approach** (below): decided now, like the stack.
- How much merges without the owner. The gate rates every PR low, medium or high impact;
  `autoMerge` is the highest level it merges alone. `low` (default): every PR a rule fires on
  waits for the owner. `medium`: dependency, spec, size and Observed PRs merge when green too — for
  a hobby project or a prototype, where reviewing every PR costs more than it saves. High impact
  (guardrails, sensitive paths, migrations, weakened tests) always waits.
- GitHub repo name.

### UI approach

Decide it here, never later: switching midway means tickets that rebuild screens, and without a
decision agents hand-roll a component layer one ticket at a time. In the batch, recommend one from
what you know of the product, say what would change your mind, and get a yes:

| | Component library | Own components |
|---|---|---|
| What | A ready-made kit that fits the stack (e.g. daisyUI, shadcn/ui, Mantine, Vuetify, Tamagui), restyled only through its theme | Design tokens plus a small kit the project writes and owns |
| When | Speed over a distinctive look: hobby projects, prototypes, internal tools. The default when the user has no strong view | The look is part of the product, or a designer's design must be matched |
| Agents | Use the library's component for anything it has; never write their own button, input, dialog or card. Look changes go through the theme | Screens compose kit components only; a new kit component is a ticket decision, never added in passing |
| Fences | Tokens only through the theme: a grep fence on raw colour values | The outfit-assistant UI fences in `examples/` (tokens in one place, variant props, no `className` passthrough) |

Ask with it, in the same batch:

- Library: which one. Read its current documentation for the stack before proposing it.
- Own components: where the tokens come from (a designer's file, a brand, or propose a small palette).
- Both: dark mode or not, and which screens or platforms the first features need.

Record the answer in `AGENTS.md`: the library or kit in the stack line, and a UI bullet under
conventions saying what agents use and what they never build. The walking skeleton sets it up
(step 4), so no feature ticket has to.

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
  `owners` = the user's GitHub login, `autoMerge` from the interview. Fill `paths.*` from the interview;
  add every linter/fence config and check script to `paths.guardrails`.
- `AGENTS.md` — from `templates/AGENTS.md`: product line, stack, layer chain with one bullet per
  layer, fences, conventions. Keep only judgment calls. The install already wrote the factory block
  between the `factory:begin/end` markers; write around it and leave the markers.
- `CLAUDE.md` — exactly `@AGENTS.md`.
- Linter/type-checker/fence configs, `scripts/check-*.sh`, the toolchain pin, lockfile.
- `.github/workflows/check.yml` — runs the `check` command and nothing else, on `pull_request`,
  pushes to the base branch and `workflow_dispatch` (the gate dispatches it on the PR combined with
  the current base before merging), with the job named `check`. Pinned toolchain from the version file.
- `.claude/settings.json` — add the `permissions` of `templates/settings.json` (denies secrets and
  merging) to the file the install wrote. Keep its `hooks` key: the sync owns it. Add a `deny`
  entry for each `block` command that has a simple prefix.
- `.gitignore` — must cover `.env` and `.env.*` but not `.env.example`. Write `.env.example` with
  key names only.
- `docs/specs/archive/.gitkeep`.
- Then run `.factory/bin/factory sync --apply` from the project root: it brings the factory block in
  `AGENTS.md` and the managed files (issue template, PR template, gate workflow, the `.factory/bin/`
  scripts, the factory's hooks in `.claude/settings.json`, and the agent and skill stubs in `.claude/`)
  back to current after your edits.

## 4. Walking skeleton

One small module per layer, each with one real test, wired along the allowed direction — so fences,
tests and `check` are real from the first commit, not switched on later against existing code.
With a UI, one screen built the chosen way: the library installed and themed with the project's
tokens, or the first kit component with its tokens. Run `check`; it must be green.

## 5. GitHub

Create the repo if needed (private by default). Run `.factory/bin/factory github-setup` (dry run), show the
user the output, then `--apply`. This runs as the OWNER.
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
7. (Needs the gate) A PR with a ticket that changes `AGENTS.md` → labelled `risk:high`, assigned to
   the owner with a comment mentioning them, not merged until the owner adds the `merge` label.
8. (Needs the gate) A trivial PR with a ticket → `risk:low`, merged by the gate.
9. (Needs the gate) A PR with a ticket that changes the lockfile → `risk:medium`: with `autoMerge`
   `medium` merged by the gate, otherwise waiting for the owner as in probe 7.

Probes 1–4 need the hooks loaded: they fire only in a session started after the install wrote them
into `.claude/settings.json`, and they act only once `.factory/config.json` exists. If this session
predates the install, say so and have the user run them in a new session.

Finish with `.factory/bin/factory doctor` and show its output. Its cloud section is optional; the
next step sets it up.

## 7. Cloud setup — optional

Ask whether the user wants tickets to run in Claude's cloud too, with their computer off: a cloud
routine does one attempt per run, and the gate starts it again after every merge. Without it, the
factory runs locally (`factory run`, one ticket at a time). If yes, walk them through these steps
one at a time and wait for each to be done. Only the owner can do them: they happen in the owner's
GitHub and claude.ai accounts.

1. **Claude GitHub App.** Install it on this repo: github.com/apps/claude, "Only select
   repositories", pick this one. Cloud sessions clone and push through it.
2. **Cloud environment.** At claude.ai/code, create an environment for this project.
   - Network access: **Trusted** (the default) is enough.
   - Setup script: installs the project's toolchain at the pinned version and its dependencies,
     so `check` runs in a fresh cloud machine. Write it for them from the toolchain pin and the
     lockfile chosen in step 2.
   - Secrets: what `setup.copy` copies into local worktrees (for example `.env`) does not exist in
     the cloud. Each value the project needs becomes an environment variable or a network secret
     of this environment. The user types the values; never read or repeat them.
3. **Routine.** At claude.ai/code/routines → New task, on this repo, with that environment.
   - Prompt, one stable line, for example: "Run `.factory/bin/factory attempt` and follow its
     output exactly. If it says there is nothing to do, finish. Send me a push notification when a
     ticket blocks or a feature is done."
   - Triggers: an **API** trigger and a schedule, as often as the user likes: the scheduled runs
     are only the fallback for a missed start. No GitHub trigger: the gate starts the routine
     itself, and a GitHub trigger never fires for the gate's merges anyway (they are made with
     `GITHUB_TOKEN`).
   - Connectors: remove all of them. The factory reaches GitHub with `gh api` and needs nothing else.
   - The API trigger shows a fire URL and a token. The token is shown once.
4. **Variable and secret.** Give the user these two commands, with this repo's `owner/name`
   (`.factory/bin/factory repo`) filled in, to run in their own terminal:

   ```bash
   gh variable set FACTORY_ROUTINE_URL --repo <owner/name> --body '<fire URL>'
   ```

   ```bash
   gh secret set FACTORY_ROUTINE_TOKEN --repo <owner/name>
   ```

   The second prompts for the token without echoing it. Never ask for the token, and never run
   either command yourself: the token goes from the routine page to GitHub without passing through
   this session.

Then run `.factory/bin/factory doctor`: its cloud section must show the variable and the secret.
To try the routine, the user can press "Run now" on it: with no ticket ready, the run says there
is nothing to do and finishes.
