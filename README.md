# Software factory

Guardrails and pipeline for agentic coding, shared across projects:
spec → tickets → agent run (local verification loop) → local review → PR → risk classifier → auto-merge or human review.

Tech-general: the factory defines a contract each project fills with its own stack, declared in `.factory/config`.

## Docs

- [`docs/factory-map.md`](docs/factory-map.md): what the factory looked like before this repo, mapped from outfit-assistant and byggtalk.
- [`docs/factory-decisions.md`](docs/factory-decisions.md): the decision log, one section per pipeline step.
- [`docs/factory-build-plan.md`](docs/factory-build-plan.md): build order. Each phase ends with a demo on a sandbox project.

## Working on the factory

Every change lands through a PR the owner reviews. Projects follow `main`, so `main` must always work.
