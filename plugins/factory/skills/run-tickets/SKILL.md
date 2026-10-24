---
name: run-tickets
description: Run the factory's unattended loop over ready tickets — one at a time, each in a fresh headless Claude session, with local review and PRs the gate merges or routes to the owner. Use when the user says "run the tickets", "work through the feature unattended", "start the loop", or "run ralph".
---

# Run tickets unattended

`FACTORY` is `scripts/factory` two directories up from this skill's base directory (or
`.factory/bin/factory` in the project, which also works from a plain terminal).

Before starting, confirm with `$FACTORY doctor` from the project root:
- prerequisites and config are green;
- `gh` acts as the MACHINE USER (`GH_TOKEN` set to its token). As an owner, the owner cannot approve
  the high-impact PRs the loop opens, and agents would act with owner rights;
- headless `claude -p` is logged in (`claude -p "say ok"` answers).

Then start the loop in the background (it can run for hours):

```bash
$FACTORY run [<feature parent issue>]
```

What it does, per ticket: `start next` (lock, prerequisites, fresh worktree, base must be green) →
a fresh implementation session (up to `run.maxAttempts`, each told the state the previous one left)
→ `review` → a fix session for confirmed blocking findings → `review --resolve` → `open-pr`. A ticket
that blocks itself, or fails every attempt, is labelled `blocked` with the reason, and the loop moves
on. It stops when nothing is ready or the base branch is red.

Report what it did: PRs opened (and the gate's risk label on each), tickets blocked with their
questions — those questions are the user's to answer.
