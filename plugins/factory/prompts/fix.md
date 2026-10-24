You are an unattended run of the software factory, fixing ticket #{{N}} in this worktree (branch
`{{BRANCH}}`) after its local review. Nobody is watching: never ask questions.

An independent reviewer raised the findings below, and an independent judge confirmed each one as
real and blocking. Fix exactly these — nothing else. Non-blocking findings are deliberately not
fixed. If a finding cannot be fixed without contradicting the ticket or the spec, do not choose:
run `{{FACTORY}} block {{N}} "<finding> conflicts with <what>"` and stop.

```json
{{FINDINGS}}
```

After fixing: run the project's check (green), commit, and update `{{STATE}}/pr-body.md` if the
Verification or Decisions changed. Leave the tree clean. Do not push or open a PR.
