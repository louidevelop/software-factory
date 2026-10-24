# Software factory — build plan

Decisions: `factory-decisions.md`. Each phase ends with a demo on a throwaway **sandbox** project and lands as a reviewed PR in the factory repo. outfit-assistant and byggtalk are not touched until all phases pass.

The sandbox uses a non-TypeScript stack (e.g. a small Python service), so tech-generality is tested from the start, not assumed.

## Phase 0 — Repo and accounts

- ✅ Created `~/code/software-factory` and the private repo `louidevelop/software-factory`. Seeded `docs/`.
- **Human:** create the machine-user GitHub account and its token. (Agents may not create accounts or handle tokens.)
- Finding (GitHub docs, 2026-10-24): fine-grained tokens list "contributing to repositories where the user is an outside or repository collaborator" as a known gap. So the machine user needs a **classic token with `repo` scope**. Its reach is bounded by which repos it is a collaborator on (write access only). The alternative, if that's too broad later: move project repos into a free organization and use a fine-grained token scoped to it.
- Finding: a private reusable workflow *can* be called from other private repos owned by the same personal account. It requires the factory repo's Actions access setting (Settings → Actions → General → Access) to be set to "Accessible from repositories owned by the user". It is currently `none`; set it in phase 3, when `classify.yml` exists.
- Consequence for the gate (phase 3): the machine user has write access, so its approval would count as an approval. The classifier must accept approvals only from the owner list (in `.factory/config`, read from `main`), never just "any approval".

## Phase 1 — Local loop core (plugin)

- Marketplace + plugin skeleton, `.factory/config` JSON schema.
- Hooks:
  - JSON helper: jq → python3 → node, fails closed
  - after-edit: runs the configured fix command and returns unfixable findings through a channel the model sees. Verify which channel first.
  - end-of-turn gate: configured check command, `stop_hook_active` guard, early-scaffold skip
  - blocklist: universal core + project extras + `permissions.deny`
- The factory's own `check`: hook tests on recorded input, shell lint, schema validation.
- Demo: install the plugin in the sandbox by hand. Lint error → blocked turn; `.env` read → blocked; after-edit feedback reaches the agent.

## Phase 2 — Bootstrap skill

- Interview → tool per slot → scaffold → GitHub setup (shows changes first) → walking skeleton → probes.
- Uses outfit-assistant and byggtalk as worked examples in `examples/`.
- Demo: bootstrap the sandbox from empty. Every local probe passes. The GitHub probes wait for phase 3.

## Phase 3 — Classifier and gate

- `classifier/` with the 10 rules + fail-closed behavior, tested on diff fixtures.
- Reusable `classify.yml`: reads config from `main`, applies the `risk:*` label, keeps one comment up to date, and is a required check that passes when low, or when high + approved.
- Bootstrap's GitHub step gains branch protection, auto-merge and the machine-user collaborator.
- Demo: smoke PRs in the sandbox. A lockfile change → `risk:high`, waits for approval. A trivial change → auto-merges. A push after approval → approval dismissed.

## Phase 4 — Specs and tickets

- `feature-spec` skill (interview → `docs/specs/NNN-*.md` + parent issue). Spec template.
- `create-tickets` skill (generalized `agent-issue`): run on a referenced spec, or standalone for a small ticket. Creates sub-issues + "blocked by" links + labels. Ticket template.
- Demo: spec a small sandbox feature with 2–3 dependent tickets.

## Phase 5 — Pickup and run

- `start-ticket` script + skill:
  1. update the plugin
  2. open a factory sync PR if behind
  3. refuse if `main` is red
  4. pick a ticket and apply the `in-progress` lock
  5. preflight
  6. prerequisite checkboxes
  7. drift check (blocks)
  8. worktree + setup
- PR body template: Verification, decisions, Dependencies, Migrations. Done criteria. Retries (3 → `blocked`).
- `run-tickets`: the unattended loop in auto permission mode, as the machine user.
- Demo: run the phase 4 tickets end to end into PRs.

## Phase 6 — Local review

- `review` script starts the reviewer (fixed prompt: ticket number + branch). The reviewer gathers its own context.
- Judges, one per blocking finding, in parallel and adversarial; they may downgrade but never upgrade.
- Then: fix round → resolution check. Unresolved → PR marked high. "Local review" PR section with collapsed rejected findings.
- Demo: seed a deliberate bug + an out-of-scope change → both caught and fixed; a planted false positive → rejected by the judge.

## Phase 7 — Archive and sync

- Reusable `archive-spec.yml`: when the last sub-issue closes → archive PR with header + "As built".
- Factory sync PR for the `AGENTS.md` block, templates and the CI caller file.
- Demo: finish the sandbox feature → archive PR. Change the factory block → the sandbox gets a sync PR at the next pickup.

## Later

- Learning loop (step 8, designed separately).
- Classifier model pass: shadow mode, then gating.
- Agent browser/simulator verification of Observed criteria.
- Adopt mode for existing projects (outfit-assistant, byggtalk).
- Parallel runs.
