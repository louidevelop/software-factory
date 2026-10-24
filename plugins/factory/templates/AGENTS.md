# {{PROJECT}} — rules for agents

{{ONE_LINE_DESCRIPTION}}
Stack is decided — do not revisit: {{STACK}}.

This is the only rules file. `CLAUDE.md` is a one-line `@AGENTS.md` import so Claude Code picks
it up; every other agent reads this file directly. Put rules here, never there.

## Architecture — strict one-way dependencies

`{{LAYER_CHAIN}}`

{{LAYERS}}

The fences above are enforced by {{FENCE_TOOL}} (`{{FENCE_CONFIG}}`). Never loosen a fence to
make something compile; propose the change and wait.

## Conventions

{{CONVENTIONS}}

## Tests

- Every new function in {{TESTED_LAYERS}} gets a test in the SAME commit.
- Tests never hit the network — stub external services at the one module that wraps each.
- Time-dependent logic uses a frozen "now"; tests run in UTC.
- No snapshot tests.

<!-- factory:begin -->
<!-- factory:end -->
