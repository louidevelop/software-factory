# Software factory

Guardrails and pipeline for agentic coding, shared across projects:

```
feature-spec ─▶ create-tickets ─▶ factory start ─▶ implement (hooks) ─▶ factory review ─▶ factory open-pr ─▶ gate
  spec PR,        sub-issues,       lock, worktree,   check gate, fix     reviewer + one       Local review      classify, label,
  owner: merge    blocked-by        green base        after edit,         judge per finding    attached          merge low / wait
                                                       blocklist                                                  for owner on high
```

Tech-general: the factory defines a contract each project fills with its own stack, declared in
`.factory/config.json` (schema: `plugins/factory/templates/config.schema.json`).

## What's here

| Path | What |
|---|---|
| `install.sh` | sets a project up: checks prerequisites, fetches the runtime, writes the thin layer |
| `plugins/factory/` | the **runtime**: everything below, fetched from `main` by every session (the path is historical; there is no plugin) |
| `plugins/factory/hooks/` | after-edit (fix + feedback), stop-gate (check must be green, attempts must end), block-dangerous (secrets, history, merging, the runtime, project extras), review-guard (unbriefed, read-only review subagents) |
| `plugins/factory/skills/` | `factory-bootstrap`, `feature-spec`, `create-tickets`, `start-ticket`, `run-tickets` |
| `plugins/factory/scripts/factory` | the CLI every skill, hook and run uses: `doctor`, `github-setup`, `sync`, `tickets`, `start`, `attempt`, `finish`, `review`, `open-pr`, `run`, `block`, `prompt`, `archive-specs` |
| `plugins/factory/agents/` | `factory-reviewer`, `factory-judge`, `factory-resolver` subagents — triggered by the main agent, never briefed by it |
| `plugins/factory/prompts/` | the implementation prompt for unattended attempts |
| `plugins/factory/templates/` | the thin layer (`bin/`, `settings-hooks.json`), config, `AGENTS.md` + managed block, permissions, spec, ticket, PR, gate workflow |
| `classifier/` | the gate: impact rules, owner go-ahead (`merge` label), merge-time check, starting the cloud routine, GitHub Action (`uses: louidevelop/software-factory/classifier@main`) |
| `examples/` | outfit-assistant and byggtalk as worked examples of the contract |

## Using it in a project

1. From the project's root (a new, empty project is fine):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/louidevelop/software-factory/main/install.sh | bash
   ```

   It checks the prerequisites and writes the thin layer (below). Safe to re-run; it never touches
   `.factory/config.json`.
2. New project: open Claude Code there and ask for the **factory-bootstrap** skill. It interviews,
   picks a tool per slot, scaffolds, sets up GitHub, and proves every guardrail fires.
3. Features: **feature-spec** → owner gives the spec PR the `merge` label → **create-tickets** for that spec.
   Small work: **create-tickets** directly.
4. Work, one ticket at a time: **start-ticket** (interactive), or **run-tickets** (`factory run`:
   one ticket unattended, in fresh `claude -p` sessions, then it stops; you start the next).
5. Review: the gate merges low-impact PRs itself. On a high-impact PR it assigns you and mentions
   you; review it and add the `merge` label, and the gate merges it.

Prerequisites on a project machine: bash (3.2+), git, gh, jq, claude. Agents act through your own
`gh` login; the blocklist keeps them from merging, reviewing, or adding the `merge` label.
`.factory/bin/factory doctor` checks a project, including whether its runtime fetches and its thin
layer is current.

### How a session loads the factory

A project commits only a **thin layer**, which `factory sync` writes and keeps current:

- `.factory/bin/fetch` brings factory `main` into `.git/factory-runtime` (shared by every
  worktree). The `SessionStart` hook runs it, so every session, local or in the cloud, uses the
  latest `main`; projects never pin a version. When the update fails, the last good copy stays in
  use with a warning.
- `.factory/bin/hook <name>` runs a runtime hook; the factory's hooks in `.claude/settings.json`
  all go through it. With no runtime it blocks every tool call (hooks fail closed).
- `.factory/bin/factory` runs the runtime's CLI, fetching first from a terminal with no copy yet.
- `.claude/agents/factory-*.md` and `.claude/skills/*/SKILL.md` are stubs: their frontmatter, and
  one line that loads the instructions with `.factory/bin/factory prompt <name>`.

When the layer itself changes, the next ticket start opens a "factory sync" PR (`factory sync --pr`).

**In Claude's cloud (optional).** Tickets can also run with your computer off: a cloud routine on
the repo does one attempt per run (`factory attempt`), and the gate starts it again after each
merge and when a PR starts waiting for you, unless another attempt is still running; an hourly
schedule is the backstop. The
factory-bootstrap skill walks you through it: the Claude GitHub App on the repo, a cloud
environment, a routine with an API trigger, and the repo variable `FACTORY_ROUTINE_URL` and secret
`FACTORY_ROUTINE_TOKEN` the gate fires it with.

The factory used to be a Claude Code plugin. That is retired: if `factory@software-factory` is
still installed, remove it (`claude plugin uninstall factory@software-factory`, then
`claude plugin marketplace remove software-factory`), or every hook runs twice. `factory doctor` warns.

## Working on the factory

Commit straight to `main` (no PRs unless the owner asks); projects follow `main`, so run
`scripts/check.sh` before every push (CI runs the same). Rules for agents: `AGENTS.md`.
To try an unpushed factory change in a project: `export FACTORY_HOME=~/code/software-factory`
(the thin layer then uses that folder as-is and fetches nothing). `FACTORY_SOURCE=<git URL or path>`
fetches `main` from somewhere else instead.
