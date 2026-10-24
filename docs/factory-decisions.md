# Software factory — decision log

Walkthrough of each factory step before building. One section per step; each decision is one line.
Current-state map: `factory-map.md`.

## Foundations

- The factory lives in its own repo, `~/code/software-factory` (private, `louidevelop`), so it can evolve on its own.
- Projects pull the latest factory before starting a ticket.
- Tech-general: the factory defines a contract (one `check` command, a per-file fix command, architecture fences, grep fences, a pinned toolchain, deterministic tests). Each project fills it with its own stack and declares it in `.factory/config`.
- outfit-assistant and byggtalk are worked examples, not templates.
- GitHub is the system of record: issues for tickets, Actions for the classifier, GitHub auto-merge.
- Guardrails move from "agent may not" to "agent may, the PR routes to a human". Dependencies and migrations are allowed but force human review. The blocklist keeps only actions that can't be undone.
- Changes to guardrail files are always high impact.

## Step 1 — Feature spec

- A feature spec is a file in the repo: `docs/specs/NNN-<feature>.md`, merged via its own PR. Spec PRs are always high impact.
- A parent GitHub issue tracks the feature and links to the spec file.
- Finished specs move to `docs/specs/archive/`, so agents don't mistake a spec for current truth. The archived file also gets a header saying it is history and the code is the truth. (Rule-placement principle: the warning sits in the file the agent is reading.)
- Not every change needs a spec. Small work (one PR, no design section) goes straight to a ticket.
- Spec is written by interview: the skill reads the code and project spec, asks every open question at once, and drafts only when none are left.
- Spec sections: Problem & goal · Behaviour (scenarios) · Decisions · Design (only when architecture changes) · Prerequisites (human-only inputs) · Verification (Tested / Observed) · Out of scope · Ticket breakdown.
- Observed behaviour (seen running, not asserted by tests) is verified by a human for now: a ticket with Observed criteria makes its PR high impact.
- Agent browser/simulator validation is deferred.
- The spec PR is the only human approval. Tickets need no separate approval and do not live in the repo; they are GitHub issues only.

## Step 2 — Tickets

- One ticket = one PR = one concern. Sizing and splitting are left to the skill's judgment; no hard numeric rule.
- Template = outfit-assistant's `agent-issue` template (Goal · Acceptance Tested/Observed · Scope · Decisions · Out of scope · "list your own decisions in the PR"), plus a spec-section link, Prerequisites, and a required Verification section in the PR (one line of proof per acceptance criterion).
- Tickets from a spec are created on demand: the user references a spec, and the skill creates all of its tickets. No automatic creation on spec merge.
- Order and dependencies use GitHub: tickets are sub-issues of the feature's parent issue, linked with "blocked by" relationships. The next ticket is the first open sub-issue with no open blockers.
- State lives in labels: `agent-task` → `in-progress` / `blocked` (with a comment giving the reason) → closed by the PR's `Closes #N`.
- An unanswered question during a run blocks the ticket; the agent never guesses.
- `layer:*` labels are dropped; the classifier reads the diff instead.
- No per-ticket human approval. Spec tickets are approved by the spec PR. For a spec-less ticket, answering the skill's questions counts as approval: it is ready as soon as it is created.
- Overview = labels + sub-issues. No GitHub Projects board for now.

## Step 3 — Picking up a ticket

- Interactive and unattended runs use the same pickup procedure:
  1. Update the factory plugin.
  2. Pick the ticket (named, or the next unblocked sub-issue) and label it `in-progress`; the label doubles as a lock.
  3. Preflight: `gh` logged in, clean tree, fresh `main`.
  4. Check prerequisites.
  5. Check the ticket against the current code.
  6. Set up a worktree + project setup from `.factory/config`.
  7. Load context: ticket, active spec, rules file. Never archived specs.
- One ticket = one branch (`ticket/<N>-<slug>`) = one PR. A ticket blocked by another waits until that one merges, even when it is waiting on human review. No stacked branches.
- One ticket at a time for now; no parallel runs.
- Prerequisites are checkboxes in the ticket. The agent verifies files itself (e.g. a recorded fixture). Secrets are confirmed only by the human ticking the box; no agent tooling inspects env files.
- The agent never edits a ticket. Any drift between the ticket and the current code, even a moved path, blocks the ticket with a comment describing the drift.

## Step 4 — Agent run

- Carried over unchanged:
  - single rules file + placement principle
  - the rule ladder (deny → linter → grep → hook regex → rules file)
  - the end-of-turn `check` gate with byggtalk's hardening (fails closed, `stop_hook_active` guard, early-scaffold skip)
  - "never weaken a test/check"
  - colocated, network-free, frozen-time tests
- `.factory/config` is JSON. It holds:
  - check command
  - fix command per file glob
  - setup command + env files to copy
  - extra blocked commands
  - migration paths, sensitive paths
- The after-edit hook runs the configured fix command on the edited file and returns unfixable findings through a channel the model actually sees.
- Blocklist = universal core (secrets, `rm -rf`, force push, `reset --hard`, printing env vars) + project extras from config (e.g. applying migrations remotely, deploys).
- Dependencies and migrations are allowed. The PR carries "Dependencies added" / "Migrations" sections with a one-line reason each.
- Factory-wide rules are copied into each project's `AGENTS.md`, not injected by the plugin, so every agent that reads `AGENTS.md` sees them. Drift is handled by sync → see Open.
- Unattended runs use auto permission mode + the hooks: two independent layers.
- No commit-count rules: the agent commits freely and the PR squash-merges.
- Done = `check` green + clean tree + a proof line per acceptance criterion in the PR's Verification section + every unsettled decision listed.
- Retries: a failed run gets a fresh session told the state left behind. After 3 failed attempts the ticket is labelled `blocked`.

## Step 5 — Local review

- Runs after the step 4 done criteria are met, before the PR opens. Interactive and unattended runs alike.
- Reviewer: fresh context window, sees no implementer reasoning. It produces findings, each marked blocking or non-blocking.
- The reviewer gathers its own context: it fetches the ticket (`gh issue view`), the spec it links, `AGENTS.md` and the diff itself. Nothing is summarized or handed over by the main agent, so the implementer cannot frame the review.
- A deterministic factory script starts the reviewer, not the implementer agent. Its fixed prompt carries only the ticket number and branch, so the implementer writes no part of it. In interactive sessions this runs as a skill that calls the script, never as a subagent the main agent briefs.
- The implementer's draft PR description (proof lines, listed decisions) is read last and treated as claims to verify, never as context.
- The reviewer may run read-only commands plus the project's test command, no edits.
- Judge:
  - Verifies each finding. A finding goes back to the implementer only when reviewer and judge agree it holds.
  - One judge per finding, run in parallel. Started by the same script with the finding. It fetches its own context and never sees the reviewer's other findings or reasoning.
  - Adversarial: it rejects unless it can point to evidence (line, criterion, failing case). Same command access as the reviewer.
  - Rules on severity too: it may downgrade blocking → non-blocking, never upgrade.
- Only findings that are confirmed and still blocking go back to the implementer.
- Non-blocking findings are not judged and never fixed. They are listed in the PR marked "unverified".
- Rejected findings are listed in a collapsed PR section, as material for tuning the reviewer.
- Rounds: review → judge → fix, then one narrow pass where a judge only checks that each confirmed finding is resolved. No second full review.
- Anything still unresolved: the PR opens anyway, marked high impact, with the unresolved findings listed.
- Reviewer and judge models are a `.factory/config` setting, defaulting to the strongest model.
- The final review is written into the PR under "Local review".

## Step 6 — PR classifier

- Runs as a reusable workflow from the factory repo on every PR event (opened, push, review). It reads `.factory/config` from `main`, never from the PR branch.
- Any one rule → high impact:
  1. dependency manifest/lockfile changed
  2. migration paths
  3. sensitive paths
  4. guardrail files (`AGENTS.md`, `CLAUDE.md`, `.factory/**`, `.claude/**`, `.github/**`, linter configs, check scripts)
  5. spec files
  6. linked ticket has Observed criteria
  7. unresolved blocking local-review findings
  8. tests deleted or skip markers added
  9. diff above size threshold
  10. no linked ticket or required PR sections missing
  - Classifier error → high.
- Size threshold default: more than 400 changed lines or more than 20 files, adjustable in config. Lockfiles and generated files are excluded from the count.
- PRs without a ticket (e.g. opened by hand) are high impact: the human reviews and merges them.
- Output: `risk:low` / `risk:high` label + one comment, kept up to date, listing every rule that fired and the files behind it. Every push re-classifies the full diff.
- Gate: a required status check that passes when low, or when high + human-approved. Auto-merge is enabled on every PR. "Dismiss stale approvals" is on.
- Agent identity: a machine user (second GitHub account) with a fine-grained token: it can push branches, open PRs and comment, but cannot approve or merge. The human is the only approver. Every agent `gh`/git call must use the machine token, interactive sessions included (set up in step 3/10). Can move to a GitHub App later.

- Model pass (an LLM looks for semantic risk the rules miss; can only raise low → high, never lower): not at launch. Rules only.
- Planned path for the model pass: shadow mode (comments only, no effect on the gate) once the pipeline runs end to end, then gating once its escalations match the human's.
- Misses are first fixed with rules (e.g. a missing sensitive path) via the learning loop.

## Step 7 — Merge and after

- Squash merge. `Closes #N` closes the ticket. Required checks (`check` + classifier) are the gate; auto-merge does the rest.
- Branch protection applies to everyone, including the machine user.
- Spec archive:
  - When the last sub-issue of a feature's parent issue closes, a factory workflow opens an "Archive spec NNN" PR.
  - The PR moves the spec to `docs/specs/archive/`, adds the "history, not current truth" header, and appends an "As built" section: links to the feature's PRs + every decision the agents listed in them.
  - The PR is always high impact; approving it is the human's sign-off that the feature is done.
- "Require branches to be up to date before merging" is on (for now), so `check` runs on exactly what lands on `main`.
- Red `main`: pickup refuses to start any ticket and tells the human.
- "One at a time" means one active run. A PR waiting for human review does not block an independent ticket; dependent tickets still wait for the merge.
- Deploys stay manual and outside the factory for now.

## Step 8 — Learning loop

- Deferred: important, but the user will design it separately.
- Until then, blocked tickets and tickets that failed 3 attempts stay `blocked` for the human to handle, and human review comments are handled by hand.
- Inputs already captured for later: outfit-assistant's `agent-run-review` skill + `agent-context-gaps.md`; the new signals (blocked tickets, failed attempts, confirmed/rejected review findings, rejected PRs, classifier misses); project-vs-factory fixes; deterministic fixes first.

## Step 9 — Bootstrap (new projects)

- A tech-general `factory-bootstrap` skill. Steps:
  1. Interview (one batch): product, stack, architecture layers + allowed direction, external services, sensitive areas, migration tooling, UI or not.
  2. Choose a tool per contract slot (check, per-file fix, type checker, architecture fences, grep fences, test runner, toolchain pin, lockfile) against fixed criteria: fast, single-file, deterministic, configured in the repo, no global installs. The user confirms each. outfit-assistant/byggtalk are the worked examples; for a stack without one, the skill reads that ecosystem's current docs rather than guessing.
  3. Scaffold: `.factory/config`, `AGENTS.md` (factory block + project rules: layers, conventions), `CLAUDE.md` → `@AGENTS.md`, linter config with fences, `check` command, toolchain pin, CI (`check` + classifier reusable workflow), agent-task issue template, `docs/specs/archive/`, `.claude/settings.json` enabling the plugin, `.gitignore` for env files.
  4. GitHub setup, automated via `gh` under the human's admin account after showing exactly what will change: labels, branch protection (required checks, up to date, dismiss stale approvals, no bypass), auto-merge on, machine user as collaborator.
  5. Walking skeleton: one module per layer with one test each, so fences, tests and `check` are real from day one.
  6. Proof: not done until every probe passes:
     - lint error → end-of-turn gate blocks
     - blocked command → blocked
     - `.env` read → blocked
     - after-edit feedback reaches the agent
     - fence violation → `check` fails
     - CI runs `check`
     - lockfile smoke PR → `risk:high`
     - trivial smoke PR → auto-merges
- No project-level spec doc. Stack, layers and conventions live in `AGENTS.md`; features are specced individually.
- Adopting existing projects (outfit-assistant, byggtalk) is a separate mode, later.

## Step 10 — The factory itself

- Repo layout:
  - `.claude-plugin/marketplace.json`
  - `plugins/factory/` with `hooks/`, `skills/`, `prompts/`, `scripts/`, `templates/`
  - `.github/workflows/` (reusable `classify.yml`, `archive-spec.yml`)
  - `classifier/` (rules + diff-fixture tests)
  - `examples/` (outfit-assistant, byggtalk)
  - `docs/`
- Projects follow factory `main`, no version pinning: every new session uses the latest.
- Factory `main` is protected by its own `check`:
  - hook scripts tested with recorded hook input → expected exit codes
  - classifier tested against diff fixtures
  - config validated against its schema
  - shell linted
- Repo-resident files (the `AGENTS.md` factory block between `<!-- factory:begin vX -->` / `<!-- factory:end -->` markers, templates, the CI caller file) are synced through a "factory sync" PR. Pickup opens it when a project is behind and the ticket continues meanwhile. A sync is never mixed into a ticket PR, and it is always high impact.
- Local prerequisites: `bash`, `git`, `gh`, `jq`, `claude`; no language runtime required by the factory. The classifier runs only in CI, as a zero-dependency Node script.
- The factory does not run its own pipeline. Factory changes are plain PRs, and the human reviews every one.

## Walkthrough status

Steps 1–7, 9, 10 settled. Step 8 (learning loop) deferred. See `factory-build-plan.md` for build order.

## Build notes — where the build had to differ (2026-10-24)

Each deviation is forced by a platform fact found while building; the decision's intent stands.

- **Free plan, private repos: no branch protection or rulesets** (GitHub returns "Upgrade to GitHub Pro").
  GitHub auto-merge depends on them, so the gate merges itself: the gate action waits for the
  project's other checks, then squash-merges when the gate passes. Agents are blocked from
  `gh pr merge` / `gh pr review` (blocklist + permissions.deny). Without Pro, nothing stops a human
  or a determined token from merging around the gate; `factory github-setup` applies real branch
  protection automatically once the plan allows it.
- **Classifier ships as a GitHub Action, not a reusable workflow.** A reusable workflow from a private
  repo cannot check out the factory's code; an action from it can be `uses:`d once the factory repo's
  Actions access is "user" (set). The managed caller is `.github/workflows/factory-gate.yml`.
- **`.factory/config` is `.factory/config.json`.**
- **Behind-base PRs are updated at pickup, not by the gate.** Commits made with `GITHUB_TOKEN` trigger
  no workflows, so a gate-side branch update would stall the PR. `factory start` updates behind
  `ticket/*` PRs as the machine user, which re-runs check + gate.
- **Red `main` is detected at pickup by running `check` on a fresh base** (gate merges use
  `GITHUB_TOKEN`, so no workflow runs on `main` after a merge; up-to-date + green PR makes `main` green
  by construction).
- **Spec archive PRs are opened by `factory start` / end of `factory run`, not a workflow** — same
  `GITHUB_TOKEN` limit, and an Actions-created PR would not run the gate. The archive PR says
  `Closes #<parent>`, so merging it also closes the feature issue.
- **The factory-sync hash is content-checked**: a hand edit inside the `AGENTS.md` block counts as behind.
- **Hooks follow the ticket's worktree** (the edited file's checkout, or the session cwd) rather than
  the project dir, so a session started in the main checkout still gates the worktree it works in.
- **Scripts target macOS's bash 3.2** (no bash-4 features; empty arrays guarded under `set -u`).
- **Glob dialect** adds `{a,b}`; empty alternatives (`{a,}`) are not allowed (macOS ERE rejects them).
