---
name: feature-spec
description: Write a feature spec for a factory project by interviewing the user, then open the spec PR (always human-reviewed) and its tracking issue. Use when the user wants to spec, design, plan, or describe a feature that needs more than one PR or changes architecture — "spec out X", "new feature: X", "let's design X". For small work that fits one PR with no design, use create-tickets directly instead.
---

# Feature spec

When PRs auto-merge, the spec is where the human's intent enters the pipeline: a low-impact PR
merges exactly what its ticket said, and the ticket says what the spec said. A vague spec becomes
vague code with no human in between. So this skill does not draft until every question is answered.

Plugin paths (`templates/…`, `scripts/factory`) are two directories up from this skill's base directory.

## 1. Is a spec needed?

A ticket is enough when the work fits one PR and needs no design section. Say so and switch to
the create-tickets skill instead.

## 2. Read before asking

Read `AGENTS.md`, the code the feature touches, the closest existing example of the pattern, and
any ACTIVE spec in `docs/specs/` that overlaps. Never treat `docs/specs/archive/` as current
behaviour — it is history; the code is the truth.

## 3. Interview — one batch

List every question an engineer who has read `AGENTS.md` and the code, but never spoken to the
user, would need answered: product behaviour, edge cases, naming, what to reuse, what is out of
scope, which behaviour must be seen running (Observed) rather than asserted (Tested), and what only
a human can provide (keys, recorded fixtures, accounts). Not how to build it.

Ask them all in ONE message. Ask follow-ups only for answers that opened new questions. Do not draft
until the list is empty.

## 4. Draft `docs/specs/NNN-<slug>.md`

`NNN` = one more than the highest number in `docs/specs/` and `docs/specs/archive/`, zero-padded.
Fill `templates/spec.md`:

- **Behaviour** as scenarios; **Decisions** one line per answer — what the user gets, never how
  the code does it.
- **Design** only when architecture changes (new layer, external service, data model). Propose it
  yourself, grounded in `AGENTS.md`; the human approves it in the PR. Otherwise delete the section.
- **Verification**: split Tested / Observed honestly. Every Observed line will make its ticket's
  PR high impact — that is intended, a human must look.
- Nothing may depend on this conversation: the reader has only the repo and the spec.

## 5. Open the spec PR and the tracking issue

```bash
git checkout -b spec/NNN-<slug> origin/<base>   # from a fresh base
git add docs/specs/NNN-<slug>.md && git commit -m "Spec NNN: <feature>"
git push -u origin spec/NNN-<slug>
PARENT=$(scripts/factory tickets feature docs/specs/NNN-<slug>.md "<feature>")
```

Then replace `#{{PARENT}}` in the spec with the parent number, commit, push, and open the PR:
`gh api "repos/$(scripts/factory repo)/pulls" -f base=<base> -f head=spec/NNN-<slug> -f title="Spec NNN: <feature>" -f body="Spec for #$PARENT. The spec PR is the human's approval of behaviour, decisions and design; tickets are created from it afterwards." -q .html_url`
(REST: `gh pr create` uses GraphQL, which fails in cloud sessions).

The PR touches `docs/specs/`, so the gate always routes it to the owner. Report the PR and parent
URLs and the decisions folded in. Tickets are created later, when the user asks (create-tickets),
against the merged spec.
