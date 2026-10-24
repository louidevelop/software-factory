---
name: start-ticket
description: Work on a factory ticket interactively, end to end — pick it up (lock, prerequisites, fresh worktree), implement it, run the independent local review, fix confirmed findings, and open the PR. Use when the user says "start ticket 12", "work on the next ticket", "pick up #12", or "run the next task here". For running many tickets unattended, use the run-tickets skill instead.
---

# Start a ticket

The same deterministic steps as the unattended loop, with you as the implementer. `FACTORY` below is
`scripts/factory` two directories up from this skill's base directory (or `.factory/bin/factory` in
the project).

## 1. Pick up

```bash
$FACTORY start <issue>        # or: $FACTORY start next [--parent <feature issue>]
```

Exit 3: nothing is ready. Exit 4: the base branch is red — tell the user; nothing starts until it is
fixed. Exit 5: the ticket blocked on unticked prerequisites — tell the user which. On success the
last line is `WORKTREE=<path>`: `cd` there and work ONLY in that worktree for the rest of the ticket
(the hooks follow your working directory).

## 2. Implement

- Read the ticket (`gh issue view <n>`), the spec it links (never `docs/specs/archive/`), `AGENTS.md`.
- Drift check before any change: if the ticket's Scope, Decisions or pattern references do not match
  the code, run `$FACTORY block <n> "<what drifted>"` and stop. Never adapt a ticket yourself.
- A question the ticket, spec and code do not answer → `$FACTORY block <n> "<question>"` and stop.
  In an interactive session you may also ask the user, then record the answer in your PR's Decisions.
- Implement within Scope; run the check after every change; commit as you go.
- Write the PR description to `$(git rev-parse --git-dir)/factory/pr-body.md` from
  `.github/pull_request_template.md` (Verification: one proof line per acceptance criterion;
  Decisions; Dependencies added; Migrations). Leave Local review empty.

## 3. Local review — you trigger it, you never brief it

The reviewer and judges are this plugin's subagents. You start them; they fetch the ticket, the
spec and the diff themselves. A hook blocks any spawn message other than the exact line
`factory review` prints, keeps them read-only, and stops you from writing findings or verdicts.

1. Commit everything, then `$FACTORY review begin <n>` and spawn `factory:factory-reviewer` with
   exactly the line it prints (`Review ticket #<n>`).
2. `$FACTORY review judges` — spawn one `factory:factory-judge` per printed line, all in parallel,
   each with exactly that line.
3. `$FACTORY review assemble`. It prints the confirmed blocking findings: fix exactly those (none of
   the non-blocking ones), commit, then `$FACTORY review resolve-begin`, spawn one
   `factory:factory-resolver` per printed line in parallel, and `$FACTORY review assemble --resolve`.
   What stays unresolved goes to the human in the PR; do not loop on it.

## 4. Open the PR

```bash
$FACTORY open-pr <n>
```

It refuses a dirty tree, a red check, a missing description, or a review of an older commit. The gate
then classifies the PR and merges it or asks the owner. Never merge or approve yourself.
