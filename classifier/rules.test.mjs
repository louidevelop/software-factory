import assert from "node:assert/strict";
import { test } from "node:test";
import { classify, hasObservedCriteria, linkedIssue, unresolvedBlockingFindings } from "./rules.mjs";

const CONFIG = {
  version: 1,
  owners: ["owner"],
  check: "make check",
  paths: {
    migrations: ["migrations/**"],
    sensitive: ["src/auth/**"],
    guardrails: ["Makefile"],
    generated: ["src/gen/**"],
  },
  limits: { lines: 100, files: 5 },
};
const BODY = "Closes #7\n\n## Verification\n- ok\n\n## Local review\nUnresolved blocking findings: 0\n";
const TICKET = { number: 7, body: "## Goal\nx\n## Acceptance criteria\n### Tested\n- [ ] f(1) → 2\n### Observed\n- [ ] <what the user does> → <what they see>\n" };
const file = (filename, extra = {}) => ({ filename, status: "modified", additions: 1, deletions: 1, patch: "+x", ...extra });
const run = (files, { body = BODY, ticket = TICKET, config = CONFIG } = {}) =>
  classify({ config, files, pr: { body, draft: false }, ticket });
const rules = (r) => r.reasons.map((x) => x.rule);

test("a small change with a ticket and all sections is low", () => {
  const r = run([file("src/app/main.py")]);
  assert.equal(r.risk, "low", JSON.stringify(r.reasons));
});

test("1 dependencies: manifests and lockfiles across ecosystems", () => {
  for (const f of ["package.json", "web/package-lock.json", "uv.lock", "go.sum", "Cargo.toml", "ios/Podfile.lock", "app/build.gradle.kts"]) {
    assert.deepEqual(rules(run([file(f)])), ["dependencies"], f);
  }
  assert.ok(rules(run([file("deno.json")], { config: { ...CONFIG, paths: { dependencies: ["deno.json"] } } })).includes("dependencies"));
});

test("2 migrations, 3 sensitive", () => {
  assert.deepEqual(rules(run([file("migrations/0002_x.sql")])), ["migrations"]);
  assert.deepEqual(rules(run([file("src/auth/session.py")])), ["sensitive"]);
});

test("a rename out of a sensitive path still counts", () => {
  assert.ok(rules(run([file("src/other.py", { status: "renamed", previous_filename: "src/auth/x.py" })])).includes("sensitive"));
});

test("4 guardrails: built-in and configured", () => {
  for (const f of ["AGENTS.md", "pkg/CLAUDE.md", ".factory/config.json", ".github/workflows/check.yml", ".claude/settings.json", "biome.json", "tsconfig.app.json", "ruff.toml", "Makefile"]) {
    assert.ok(rules(run([file(f)])).includes("guardrails"), f);
  }
});

test("5 specs, including archive moves", () => {
  assert.deepEqual(rules(run([file("docs/specs/001-x.md")])), ["specs"]);
  assert.deepEqual(rules(run([file("docs/specs/archive/001-x.md", { status: "renamed", previous_filename: "docs/specs/001-x.md" })])), ["specs"]);
});

test("6 observed criteria in the ticket", () => {
  const ticket = { number: 7, body: TICKET.body.replace("<what the user does> → <what they see>", "open the app → the quote shows") };
  assert.deepEqual(rules(run([file("src/a.py")], { ticket })), ["observed"]);
  assert.equal(hasObservedCriteria(TICKET.body), false, "template placeholder is not a criterion");
  assert.equal(hasObservedCriteria("### Observed\n- None\n"), false);
  assert.equal(hasObservedCriteria("## Goal\nno observed section"), false);
});

test("7 unresolved blocking review findings", () => {
  const body = BODY.replace("findings: 0", "findings: 2");
  assert.deepEqual(rules(run([file("src/a.py")], { body })), ["local-review"]);
  assert.equal(unresolvedBlockingFindings(body), 2);
});

test("8 deleted tests and added skip markers", () => {
  assert.deepEqual(rules(run([file("tests/test_quote.py", { status: "removed" })])), ["tests-deleted"]);
  assert.deepEqual(rules(run([file("src/a.test.ts", { status: "removed" })])), ["tests-deleted"]);
  for (const line of ["+  it.skip('x', () => {})", "+@pytest.mark.skip(reason='x')", "+\tt.Skip(\"flaky\")", "+#[ignore]", "+  xit('x')"]) {
    assert.deepEqual(rules(run([file("tests/test_a.py", { patch: line })])), ["tests-skipped"], line);
  }
  assert.equal(run([file("tests/test_a.py", { patch: "-  it.skip('x')\n+  it('x')" })]).risk, "low", "removing a skip is fine");
  assert.deepEqual(rules(run([file("tests/test_big.py", { patch: undefined })])), ["tests-unreadable"]);
});

test("9 size, excluding lockfiles and generated files", () => {
  assert.deepEqual(rules(run([file("src/a.py", { additions: 80, deletions: 21 })])), ["size"]);
  const many = Array.from({ length: 6 }, (_, i) => file(`src/f${i}.py`));
  assert.deepEqual(rules(run(many)), ["size"]);
  assert.equal(run([file("src/gen/api.py", { additions: 5000 })]).risk, "low");
  assert.ok(!rules(run([file("uv.lock", { additions: 5000 })])).includes("size"));
});

test("10 no ticket, missing sections, missing count", () => {
  assert.deepEqual(rules(run([file("src/a.py")], { ticket: null, body: BODY.replace("Closes #7", "") })), ["no-ticket"]);
  assert.deepEqual(rules(run([file("src/a.py")], { body: "Closes #7\n## Verification\n- ok\n" })), ["pr-sections"]);
  assert.deepEqual(rules(run([file("src/a.py")], { body: "Closes #7\n## Verification\n- ok\n## Local review\nlooked fine\n" })), ["pr-sections"]);
});

test("several rules fire together; nothing lowers", () => {
  const r = run([file("package.json"), file("migrations/1.sql"), file("AGENTS.md")]);
  assert.equal(r.risk, "high");
  assert.deepEqual(rules(r), ["dependencies", "migrations", "guardrails"]);
});

test("linkedIssue parses closing keywords", () => {
  assert.equal(linkedIssue("Closes #12"), 12);
  assert.equal(linkedIssue("this fixes: #3 now"), 3);
  assert.equal(linkedIssue("Resolved #44."), 44);
  assert.equal(linkedIssue("see #12"), null);
});
