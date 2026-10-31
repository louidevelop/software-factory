import assert from "node:assert/strict";
import { test } from "node:test";
import { validateConfig } from "./config.mjs";

const MIN = { version: 1, owners: ["owner"], check: "make check" };

test("a minimal config is valid", () => assert.deepEqual(validateConfig(MIN), []));

test("autoMerge is low or medium, never high", () => {
  for (const autoMerge of ["low", "medium"]) assert.deepEqual(validateConfig({ ...MIN, autoMerge }), [], autoMerge);
  for (const autoMerge of ["high", "all", true]) assert.equal(validateConfig({ ...MIN, autoMerge }).length, 1, String(autoMerge));
});
