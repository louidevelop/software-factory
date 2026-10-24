# Worked example: byggtalk (Node backend: Hono, Drizzle, pg-boss, AI)

How a TypeScript backend fills the factory contract. Proven in the real repo (`~/code/byggtalk`).

| Slot | Choice | Notes |
|---|---|---|
| `check` | `tsc --noEmit && biome check . && scripts/check-external-calls.sh && scripts/check-state-writes.sh && vitest run` | tsconfig: `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`. |
| `fix` | `biome check --write {file}` | |
| Architecture fences | Biome `noRestrictedImports`: `server → queue → pipeline → {whatsapp,transcribe,structure,delivery} → db → schemas`; each provider SDK (`openai`, `ai`, `resend`, `pg-boss`, `drizzle-orm`) importable in exactly one module | Pure modules (`states.ts`, `clarification.ts`) get their own override AFTER the general one — last match wins. Prove a fence change with a throwaway file that imports something forbidden. |
| Grep fences | `check-external-calls.sh`: provider hostnames only in the adapter module. `check-state-writes.sh`: `ata_entries.state` written only by `transition()` | The single-writer grep is the pattern to reuse for any state machine. |
| Tests | Vitest colocated; webhook parsing only against RECORDED payloads in `test/fixtures/`; e2e on pglite | "Never invent a payload shape; ask for a recording" is a good rule for any integration. |
| Toolchain | `.nvmrc`, `.npmrc` `save-exact=true`, lockfile | |

Worth reusing on any backend: the state machine has one door (`transition()` validates the edge and
appends an event row); jobs are idempotent and check state first; retries belong to the queue, never
a loop around a provider call; personal data is never logged.

`factory-config.json` here is what its `.factory/config.json` would be.
