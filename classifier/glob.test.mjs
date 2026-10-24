// Parity: the classifier and the bash hooks must agree on every glob.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { globToRegExp } from "./glob.mjs";

const LIB = fileURLToPath(new URL("../plugins/factory/hooks/lib.sh", import.meta.url));
const CASES = [
  ["src/app/main.py", "*.py"], ["main.py", "*.py"], ["migrations/0001.sql", "migrations/**"],
  ["src/db/migrations/1.sql", "**/migrations/**"], ["migrations/1.sql", "**/migrations/**"],
  ["src/main.ts", "*.py"], ["a.b.c", "a?b?c"], ["docs/specs/001-x.md", "docs/specs/*"],
  ["xdocs/specs/1.md", "docs/specs/*"], ["src/a.tsx", "*.{ts,tsx}"], ["src/a.js", "*.{ts,tsx}"],
  ["a,b", "a,b"], ["pkg/(x).go", "pkg/(x).go"], [".golangci.yml", "**/.golangci.{yml,yaml}"],
  [".golangci.yaml", "**/.golangci.{yml,yaml}"], ["AGENTS.md", "**/AGENTS.md"], ["x/AGENTS.md", "**/AGENTS.md"],
  ["a+b.txt", "a+b.txt"], ["a^b$", "a^b$"],
];

test("JS and bash glob dialects agree", () => {
  const script = CASES.map(([p, g]) => `factory_glob_match '${p}' '${g}' && echo 1 || echo 0`).join("\n");
  const bash = execFileSync("bash", ["-c", `. '${LIB}'\n${script}`], { encoding: "utf8" }).trim().split("\n");
  CASES.forEach(([p, g], i) => {
    assert.equal(globToRegExp(g).test(p) ? "1" : "0", bash[i], `${p} vs ${g}`);
  });
});
