---
name: create-tickets
description: Create GitHub tickets (issues) an autonomous agent run can complete without asking questions — either all tickets for a merged feature spec the user references, or one standalone ticket for small work. Use whenever the user wants a ticket, issue, task, or work item for an agent — "make tickets for spec 003", "make an issue for X", "next task is X", "queue up X". Never create agent tickets without this skill.
---

# Create tickets

A ticket is the agent's whole world: it has the repo, `AGENTS.md`, the active spec, and the ticket
— nothing from this conversation. One ticket = one PR = one concern.

Plugin paths (`templates/…`, `scripts/factory`) are two directories up from this skill's base directory.

## Mode A — from a spec (user references a spec)

1. The spec must be merged on the base branch and ACTIVE (`docs/specs/`, not `archive/`). If its PR
   is still open, stop: tickets are written against the approved spec.
2. Read the spec, `AGENTS.md`, and the code each part touches.
3. Split the spec into tickets. Each fits one PR and one concern; order them so each builds on
   merged earlier work. Record real dependencies only (B needs A's code), not mere order.
4. Questions: the spec answered the product questions. If splitting surfaces one it does not answer,
   ask the user (all at once) — and say the spec should have covered it; fold the answer into the
   ticket's Decisions.
5. For each ticket, write the body (below) to a temp file and run:
   `scripts/factory tickets create "<imperative title>" <body-file> --parent <spec parent> [--blocked-by <n>]...`
   Create them in order so `--blocked-by` can reference earlier numbers.
6. Update the spec's **Ticket breakdown** with `#N — title (blocked by #M)` lines in a small PR
   (`docs/specs/` → owner-reviewed). Report every ticket URL.

## Mode B — standalone (small work, no spec)

1. Read the files the task touches and the closest existing example of the pattern. If it does not
   fit one PR, it needs a spec — say so (feature-spec skill).
2. List every question an engineer who read `AGENTS.md` and the code but never spoke to the user
   would need answered: product behaviour, naming, what to reuse, edge cases. Not how to build it.
   Ask all at once. Answering them is the approval: the ticket is ready as soon as it is created.
3. Write the body and run `scripts/factory tickets create "<title>" <body-file>`.

## The ticket body

Fill `templates/github/ISSUE_TEMPLATE/agent-task.md` (it is also the repo's issue template):

- **Goal** — what and why, 2–3 sentences. **Spec:** the spec path and section, or `none`.
- **Acceptance criteria** — *Tested*: input → expected output, one line each; `None` if the ticket
  adds no logic. *Observed*: what the user does → what they see; `None` if nothing must be seen
  running. A real Observed line makes the PR high impact — use it only when a human must look.
  Every line states what is asserted or observed; "handles bad data" is a wish.
- **Scope** — real paths or globs. For paths that exist now, verify them:
  `for p in <paths>; do ls -d $p >/dev/null || echo "missing: $p"; done`. Paths an earlier ticket
  will create are fine; say so.
- **Decisions** — every answer, plus the file to copy the pattern from. What the user gets, never
  how the code does it.
- **Prerequisites** — unticked checkboxes for what only a human provides (keys, fixtures). The human
  ticks them; the run blocks while any is unticked. Delete the section when none.
- **Out of scope** — explicit.

No implementation steps. Nothing that restates `AGENTS.md`. Nothing that depends on this conversation.
