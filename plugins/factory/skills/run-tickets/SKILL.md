---
name: run-tickets
description: Run the factory unattended on one ticket — fresh headless Claude sessions that implement it, run the local review, and open a PR the gate merges or routes to the owner. Use when the user says "run the tickets", "run the next ticket unattended", "start the loop", or "run ralph".
---

# Run a ticket unattended

`FACTORY` is `scripts/factory` two directories up from this skill's base directory (or
`.factory/bin/factory` in the project, which also works from a plain terminal).

Before starting, confirm with `$FACTORY doctor` from the project root:
- prerequisites and config are green;
- headless `claude -p` is logged in (`claude -p "say ok"` answers).

Then start the run in the background (one ticket can take an hour or more):

```bash
$FACTORY run [<issue> | next] [--parent <feature parent issue>]
```

It works on **one ticket** and then stops; the user starts the next run. Without an issue,
`factory attempt` picks the work: a ticket labelled `rework` first, then one of the factory's
in-progress tickets whose last attempt ended unfinished or stalled, then the next ready ticket.
Each attempt is one fresh headless session, counted in a ticket comment: it implements, runs the
local review through the reviewer/judge/resolver subagents, fixes confirmed findings, and ends
with `factory finish`, which opens the PR when everything is done, or pushes the work in progress
and records what is missing for the next attempt. A Stop hook keeps a session from ending before
`finish` or `block` ran. After `run.maxAttempts` unfinished attempts the ticket is labelled
`blocked` with the reason.

Exit codes: 0 the PR is open, 3 nothing to do, 4 the base branch is red, 5 the ticket is blocked,
6 busy (another attempt is live: runs go one at a time, and an attempt that never ended counts as
live for `run.staleMinutes`).

Report what it did: the PR it opened (and the gate's risk label on it), or the ticket it blocked
with its question — that question is the user's to answer.
