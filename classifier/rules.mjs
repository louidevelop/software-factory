// The impact rules. Pure: classify(input) → { risk, reasons }. Any one rule firing makes a PR
// high impact; nothing lowers a rating. Callers treat any thrown error as high.
//
// input = {
//   config,            // project .factory/config.json, read from the BASE branch
//   files: [{ filename, status, additions, deletions, patch?, previous_filename? }],
//   pr: { body, draft },
//   ticket: { number, body } | null,   // the issue the PR closes, if any
// }
import { matchesAny } from "./glob.mjs";

export const DEPENDENCY_MANIFESTS = [
  "**/package.json", "**/package-lock.json", "**/npm-shrinkwrap.json", "**/yarn.lock",
  "**/pnpm-lock.yaml", "**/pnpm-workspace.yaml", "**/bun.lock", "**/bun.lockb", "**/.npmrc",
  "**/requirements*.txt", "**/constraints*.txt", "**/pyproject.toml", "**/poetry.lock",
  "**/uv.lock", "**/Pipfile", "**/Pipfile.lock", "**/setup.py", "**/setup.cfg",
  "**/go.mod", "**/go.sum", "**/Cargo.toml", "**/Cargo.lock",
  "**/Gemfile", "**/Gemfile.lock", "**/*.gemspec", "**/composer.json", "**/composer.lock",
  "**/pubspec.yaml", "**/pubspec.lock", "**/Podfile", "**/Podfile.lock",
  "**/Package.swift", "**/Package.resolved", "**/build.gradle", "**/build.gradle.kts",
  "**/settings.gradle", "**/settings.gradle.kts", "**/gradle/libs.versions.toml", "**/pom.xml",
  "**/mix.exs", "**/mix.lock", "**/deno.json", "**/deno.jsonc", "**/deno.lock",
  "**/*.csproj", "**/packages.lock.json", "**/Directory.Packages.props",
];

// Lockfiles never count toward the size limit (the dependency rule already covers them).
export const LOCKFILES = [
  "**/package-lock.json", "**/npm-shrinkwrap.json", "**/yarn.lock", "**/pnpm-lock.yaml",
  "**/bun.lock", "**/bun.lockb", "**/poetry.lock", "**/uv.lock", "**/Pipfile.lock",
  "**/go.sum", "**/Cargo.lock", "**/Gemfile.lock", "**/composer.lock", "**/pubspec.lock",
  "**/Podfile.lock", "**/Package.resolved", "**/mix.lock", "**/deno.lock", "**/packages.lock.json",
];

export const GUARDRAILS = [
  "**/AGENTS.md", "**/CLAUDE.md", ".factory/**", ".claude/**", ".github/**",
  "**/biome.json", "**/biome.jsonc", "**/.eslintrc*", "**/eslint.config.*", "**/.prettierrc*",
  "**/prettier.config.*", "**/tsconfig*.json", "**/ruff.toml", "**/.ruff.toml", "**/mypy.ini",
  "**/.flake8", "**/.importlinter", "**/.golangci.{yml,yaml}", "**/.pre-commit-config.yaml",
  "**/rustfmt.toml", "**/.rustfmt.toml", "**/clippy.toml", "**/.swiftlint.yml",
  "**/detekt.yml", "**/analysis_options.yaml",
];

export const SPECS = ["docs/specs/**"];

export const TEST_FILES = [
  "**/test/**", "**/tests/**", "**/__tests__/**", "**/spec/**", "**/*.test.*", "**/*.spec.*",
  "**/*_test.*", "**/test_*.py", "**/*Test.{java,kt,swift}", "**/*Tests.{java,kt,swift,cs}",
];

const SKIP_MARKERS = [
  /\b(it|test|describe|context)\.(skip|todo)\s*\(/,
  /\b(xit|xdescribe|xtest)\s*\(/,
  /@pytest\.mark\.(skip|skipif|xfail)\b/,
  /\bpytest\.skip\s*\(/,
  /@unittest\.(skip|skipIf|skipUnless|expectedFailure)\b/,
  /\bt\.Skip(Now|f)?\s*\(/,
  /#\[ignore\]/,
  /@(Disabled|Ignore)\b/,
  /\bXCTSkip(If|Unless)?\b/,
];

const CLOSES = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)\b/i;
const REQUIRED_PR_SECTIONS = ["## Verification", "## Local review"];
const PLACEHOLDER = /^(<.*>|none\.?|n\/a|-|…|\.\.\.)$/i;

export function linkedIssue(body) {
  const m = CLOSES.exec(body ?? "");
  return m ? Number(m[1]) : null;
}

// Body text under a markdown heading (any level), up to the next heading of the same or higher level.
export function section(body, title) {
  const lines = (body ?? "").split(/\r?\n/);
  const start = lines.findIndex((l) => new RegExp(`^(#{1,6})\\s+${escape(title)}\\s*$`, "i").test(l));
  if (start === -1) return null;
  const level = lines[start].match(/^#+/)[0].length;
  const out = [];
  for (const l of lines.slice(start + 1)) {
    const h = l.match(/^(#{1,6})\s/);
    if (h && h[1].length <= level) break;
    out.push(l);
  }
  return out.join("\n");
}

function escape(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function hasObservedCriteria(ticketBody) {
  const observed = section(ticketBody, "Observed");
  if (!observed) return false;
  return observed
    .split("\n")
    .map((l) => l.match(/^\s*[-*]\s+(?:\[[ xX]\]\s*)?(.*)$/)?.[1]?.trim())
    .some((t) => t && !PLACEHOLDER.test(t));
}

export function unresolvedBlockingFindings(prBody) {
  const review = section(prBody, "Local review");
  if (review === null) return null;
  const m = review.match(/Unresolved blocking findings:\s*(\d+)/i);
  return m ? Number(m[1]) : null;
}

function addedLines(patch) {
  return (patch ?? "").split("\n").filter((l) => l.startsWith("+") && !l.startsWith("+++"));
}

export function classify({ config, files, pr, ticket }) {
  const paths = config.paths ?? {};
  const reasons = [];
  const fire = (rule, detail, hits = []) => reasons.push({ rule, detail, files: hits });
  const names = (f) => [f.filename, f.previous_filename].filter(Boolean);
  const touching = (globs) =>
    files.filter((f) => names(f).some((n) => matchesAny(n, globs))).map((f) => f.filename);

  const deps = touching([...DEPENDENCY_MANIFESTS, ...(paths.dependencies ?? [])]);
  if (deps.length) fire("dependencies", "dependency manifest or lockfile changed", deps);

  const migrations = touching(paths.migrations ?? []);
  if (migrations.length) fire("migrations", "migration files changed", migrations);

  const sensitive = touching(paths.sensitive ?? []);
  if (sensitive.length) fire("sensitive", "sensitive paths changed", sensitive);

  const guardrails = touching([...GUARDRAILS, ...(paths.guardrails ?? [])]);
  if (guardrails.length) fire("guardrails", "guardrail files changed (rules, config, CI, hooks, linters)", guardrails);

  const specs = touching(SPECS);
  if (specs.length) fire("specs", "spec files changed", specs);

  if (ticket && hasObservedCriteria(ticket.body))
    fire("observed", `ticket #${ticket.number} has Observed criteria; a human verifies them`);

  const unresolved = unresolvedBlockingFindings(pr.body);
  if (unresolved && unresolved > 0)
    fire("local-review", `${unresolved} unresolved blocking finding(s) from local review`);

  const testGlobs = [...TEST_FILES, ...(paths.tests ?? [])];
  const deletedTests = files
    .filter((f) => f.status === "removed" && matchesAny(f.filename, testGlobs))
    .map((f) => f.filename);
  if (deletedTests.length) fire("tests-deleted", "test files deleted", deletedTests);
  const skipped = files
    .filter((f) => addedLines(f.patch).some((l) => SKIP_MARKERS.some((re) => re.test(l))))
    .map((f) => f.filename);
  if (skipped.length) fire("tests-skipped", "skip markers added to tests", skipped);
  const unseen = files.filter((f) => f.patch === undefined && f.status !== "removed" && matchesAny(f.filename, testGlobs));
  if (unseen.length) fire("tests-unreadable", "test file diffs too large to inspect for skip markers", unseen.map((f) => f.filename));

  const limits = { lines: 400, files: 20, ...(config.limits ?? {}) };
  const counted = files.filter((f) => !matchesAny(f.filename, [...LOCKFILES, ...(paths.generated ?? [])]));
  const lines = counted.reduce((n, f) => n + (f.additions ?? 0) + (f.deletions ?? 0), 0);
  if (lines > limits.lines) fire("size", `${lines} changed lines (limit ${limits.lines})`);
  if (counted.length > limits.files) fire("size", `${counted.length} files changed (limit ${limits.files})`);

  if (!ticket) fire("no-ticket", "no linked ticket (`Closes #N`); a human reviews and merges it");
  const missing = REQUIRED_PR_SECTIONS.filter((s) => section(pr.body, s.replace(/^## /, "")) === null);
  if (missing.length) fire("pr-sections", `PR description is missing: ${missing.join(", ")}`);
  else if (unresolved === null) fire("pr-sections", "Local review section does not state `Unresolved blocking findings: N`");

  return { risk: reasons.length ? "high" : "low", reasons };
}
