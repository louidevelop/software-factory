# Worked example: outfit-assistant (Expo + Supabase + AI, TypeScript)

How a mobile TypeScript app fills the factory contract. Proven in the real repo
(`~/code/outfit-assistant`); copy pieces when a new project is on the same stack, not as a default.

| Slot | Choice | Notes |
|---|---|---|
| `check` | `tsc --noEmit && biome check . && sh scripts/check-class-tokens.sh && npm run -s test && sh scripts/check-deno.sh` | Edge Functions are Deno; `check-deno.sh` type-checks them with `--config` per function (Deno resolves config from CWD, not the entrypoint). |
| `fix` | `biome check --write {file}` | Sub-second on one file. |
| Types | `tsc` strict | |
| Architecture fences | Biome `noRestrictedImports` overrides per directory: `src/lib` + `src/schemas` may not import React; screens/components may not import Supabase or any `src/lib/services/*`; screens may not import `react-native` | Biome does not merge `noRestrictedImports` across overrides — the LAST matching override wins, so each directory's override carries its full list. |
| Grep fences | `check-class-tokens.sh`: Tailwind arbitrary values (`bg-[#fff]`) banned | Biome cannot lint inside class strings. |
| Tests | Vitest, colocated `foo.test.ts`, `TZ=UTC`, fake timers | AI evals in `evals/` run by hand, never in `check`. |
| Toolchain | `.nvmrc`, `.dvmrc` (Deno), `.npmrc` `save-exact=true`, lockfile | |

UI fences worth reusing on any project that builds its own components: design tokens in exactly
one place with the default palette disabled; a kit of components with variant props (no
`className` passthrough); a11y labels inside kit components; screens compose kit components only;
all user-facing strings in one module.

AI contracts worth reusing: every model reply is schema-parsed; malformed → retry, never patch or
clamp; numeric bounds live in the schema and are stated in the prompt as prose.

`factory-config.json` here is what its `.factory/config.json` would be.
