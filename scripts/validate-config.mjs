#!/usr/bin/env node
// validate-config.mjs <file> — used by scripts/check.sh on the example configs.
import { readFileSync } from "node:fs";
import { validateConfig } from "../classifier/config.mjs";

const file = process.argv[2];
const problems = validateConfig(JSON.parse(readFileSync(file, "utf8")));
if (problems.length) {
  console.error(`${file}:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
