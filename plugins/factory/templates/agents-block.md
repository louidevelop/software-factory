## Factory rules (managed — do not edit inside the markers)

This block is installed and kept current by the software factory (`factory sync`). Project
rules go outside the markers. A change here arrives as a "factory sync" PR, never inside a
ticket PR.

### The loop

- Run the project's check command (`check` in `.factory/config.json`) after every change.
  Never finish a turn with it red; a hook enforces this.
- Never delete, skip, or weaken a test, lint rule, fence, or check to make it pass. Fix the
  code, or stop and say what is wrong.
- Rule placement: a rule lives where the agent is looking when it applies. A constraint that
  concerns one file goes in a comment in that file; this file keeps cross-cutting rules only.
- Prefer a deterministic guardrail to prose: permission deny → linter rule → grep check →
  blocklist → classifier path → rules file, in that order.

### Work comes from tickets and specs

- Work comes from a GitHub issue labelled `agent-task`. Its Goal, acceptance criteria, Scope,
  Decisions and Out of scope are binding; nothing else in the conversation is.
- Active feature specs live in `docs/specs/`. `docs/specs/archive/` is history: it describes
  what was planned and built at the time, not how the code behaves now. The code is the truth.
- Never guess. If the ticket, the spec and the code do not answer a question, stop: label the
  ticket `blocked` and comment the question. A blocked ticket is a good outcome; a guess is not.
- Never edit a ticket or a spec during a run.

### Allowed, but routed to a human

- You may add dependencies and write migrations when the ticket needs them. The PR classifier
  sends those PRs to human review; justify each in the PR description.
- Never apply a migration to a shared or remote database, deploy, publish, or touch secrets.
  `.env` files are never read, printed, copied, or sourced by an agent.

### Finishing

- A run is done when: the check is green, the tree is clean, and the PR description has a
  proof line for every acceptance criterion and lists every decision the ticket did not settle.
- Fill every section of the PR template. Use `factory open-pr`; never open, approve, or merge
  a PR by hand. The factory gate merges or asks the human.
