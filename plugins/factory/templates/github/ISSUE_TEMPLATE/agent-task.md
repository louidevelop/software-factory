---
name: Agent task
about: A ticket an autonomous agent run completes without asking questions
labels: agent-task
---

## Goal

<!-- What and why, 2–3 sentences. The "why" lets the agent resolve ambiguities you did not
     foresee in the right direction. -->

Spec: <!-- docs/specs/NNN-feature.md § section, or "none" for a standalone ticket -->

## Acceptance criteria

<!-- These define "done"; the project's check green is assumed — do not list it.
     "Handles bad data" is a wish, not a criterion. -->

### Tested

<!-- Asserted by tests: input → expected output. "None" if the ticket adds no logic. -->

- [ ] `<function>` — <input> → <expected>

### Observed

<!-- Seen running by a human. Any real line here makes the PR high impact. "None" otherwise. -->

- [ ] <what the user does> → <what they see>

## Scope

<!-- Real paths or globs that may change. -->

-

## Decisions

<!-- Answers only the human could give: product behaviour, naming, what to reuse.
     A decision says what the user gets, never how the code does it. -->

- Copy the pattern from: `…`

## Prerequisites

<!-- Human-only inputs the agent needs to implement or test this ticket. The human ticks each box;
     the agent checks files itself but never inspects secrets. Unticked → the ticket blocks.
     What only an Observed check needs (a real key for a live run) goes in that Observed line,
     never here. Delete the section when none. -->

- [ ] …

## Out of scope

<!-- Explicit, so the agent does not helpfully do it. -->

-
