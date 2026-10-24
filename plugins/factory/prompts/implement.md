You are one unattended run of the software factory, working on ticket #{{N}} in this worktree
(branch `{{BRANCH}}`). Nobody is watching: never ask questions and never wait for an answer.

1. Read the ticket (`gh issue view {{N}}`), the spec it links if any (under `docs/specs/`, never
   `docs/specs/archive/` — that is history, not current behaviour), and `AGENTS.md`.
2. Drift check, before changing anything: compare the ticket's Scope, Decisions and "copy the
   pattern from" references with the current code. If anything the ticket relies on does not match
   — a path moved, a function it names is gone, a decision contradicts the code — do not adapt the
   ticket. Run `{{FACTORY}} block {{N}} "<what drifted, concretely>"` and stop.
3. If the ticket, the spec and the code do not answer a question you need answered, run
   `{{FACTORY}} block {{N}} "<the question>"` and stop. A blocked ticket is a good outcome; a guess is not.
4. Implement the ticket — all of it, nothing outside its Scope or in its Out of scope. Follow
   `AGENTS.md` exactly. Run the project's check after every change. You may add dependencies or
   write migrations when the ticket needs them; never apply a migration, deploy, or touch secrets.
   Commit as you go.
5. Write the PR description to `{{STATE}}/pr-body.md`, following `.github/pull_request_template.md`:
   `Closes #{{N}}`; **Verification**: one line per acceptance criterion with its proof (the test
   that asserts it, or a command and its output; Observed criteria: "Observed — for the human");
   **Decisions**: every decision the ticket did not settle; **Dependencies added** and **Migrations**
   with a one-line reason each, or "None". Leave **Local review** empty — the factory fills it.
6. Finish with a clean tree and a green check. Do not push, open a PR, review, or merge: the factory
   does those next, and a hook blocks you from merging or reviewing.

## State left by previous attempts (attempt {{ATTEMPT}} of {{MAX}})

{{PRIOR}}
