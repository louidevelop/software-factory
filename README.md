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
| `plugins/factory/hooks/` | after-edit (fix + feedback), stop-gate (check must be green), block-dangerous (secrets, history, merging, project extras), review-guard (unbriefed, read-only review subagents) |
| `plugins/factory/skills/` | `factory-bootstrap`, `feature-spec`, `create-tickets`, `start-ticket`, `run-tickets` |
| `plugins/factory/scripts/factory` | the CLI every skill and the loop use: `doctor`, `github-setup`, `sync`, `tickets`, `start`, `review`, `open-pr`, `run`, `block`, `archive-specs` |
| `plugins/factory/agents/` | `factory-reviewer`, `factory-judge`, `factory-resolver` subagents — triggered by the main agent, never briefed by it |
| `plugins/factory/prompts/` | the implementation prompt for unattended runs |
| `plugins/factory/templates/` | config, `AGENTS.md` + managed block, settings, spec, ticket, PR, gate workflow, shim |
| `classifier/` | the gate: impact rules, owner go-ahead (`merge` label), merge-time check, GitHub Action (`uses: louidevelop/software-factory/classifier@main`) |
| `examples/` | outfit-assistant and byggtalk as worked examples of the contract |

## Using it in a project

1. In Claude Code: `/plugin marketplace add louidevelop/software-factory`, install `factory@software-factory`.
2. New project: ask for the **factory-bootstrap** skill. It interviews, picks a tool per slot,
   scaffolds, sets up GitHub, and proves every guardrail fires.
3. Features: **feature-spec** → owner gives the spec PR the `merge` label → **create-tickets** for that spec.
   Small work: **create-tickets** directly.
4. Work: **start-ticket** (interactive) or **run-tickets** (`factory run`, unattended).
5. Review: the gate merges low-impact PRs itself. On a high-impact PR it assigns you and mentions
   you; review it and add the `merge` label, and the gate merges it.

Prerequisites on a project machine: bash (3.2+), git, gh, jq, claude. Agents act through your own
`gh` login; the blocklist keeps them from merging, reviewing, or adding the `merge` label.

## Working on the factory

Commit straight to `main` (no PRs unless the owner asks); projects follow `main`, so run
`scripts/check.sh` before every push (CI runs the same). Rules for agents: `AGENTS.md`.
To try an unmerged factory branch in a project: `export FACTORY_HOME=~/code/software-factory/plugins/factory`.
