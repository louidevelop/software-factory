import assert from "node:assert/strict";
import { test } from "node:test";
import { gate, MERGE_LABEL, ownerGoAhead } from "./gate.mjs";

const GREEN = { pending: [], failed: [], passed: ["check"] };
const base = { risk: "low", owners: ["Owner"], draft: false, labels: [], events: [], checks: GREEN };
const labeled = (actor, created_at, label = MERGE_LABEL) => ({ event: "labeled", label, actor, created_at });

test("low + green merges", () => assert.deepEqual(gate(base).merge, true));

test("red, pending, or missing checks never pass", () => {
  assert.equal(gate({ ...base, checks: { ...GREEN, failed: ["check"] } }).pass, false);
  assert.equal(gate({ ...base, checks: { ...GREEN, pending: ["check"] } }).pass, false);
  assert.equal(gate({ ...base, checks: { pending: [], failed: [], passed: [] } }).pass, false);
});

test("high waits for the owner's merge label and says it needs the owner", () => {
  const high = { ...base, risk: "high" };
  const waiting = gate(high);
  assert.deepEqual([waiting.pass, waiting.merge, waiting.needsOwner], [false, false, true]);
  const go = gate({ ...high, labels: [MERGE_LABEL], events: [labeled("owner", "1")] });
  assert.equal(go.merge, true, "owner login is case-insensitive");
});

test("the label only counts when an owner added it, judged by the latest labeling", () => {
  assert.equal(ownerGoAhead(["Owner"], [MERGE_LABEL], [labeled("someone-else", "1")]).ok, false);
  assert.equal(ownerGoAhead(["Owner"], [MERGE_LABEL], [labeled("Owner", "1"), labeled("someone-else", "2")]).ok, false);
  assert.equal(ownerGoAhead(["Owner"], [MERGE_LABEL], [labeled("someone-else", "1"), labeled("Owner", "2")]).ok, true);
  assert.equal(ownerGoAhead(["Owner"], [MERGE_LABEL], []).ok, false, "a label with no recorded event does not count");
  assert.equal(ownerGoAhead(["Owner"], [], [labeled("Owner", "1")]).ok, false, "a removed label does not count");
  assert.equal(ownerGoAhead(["Owner"], ["risk:high", MERGE_LABEL], [labeled("Owner", "1", "risk:high")]).ok, false, "other labels do not count");
});

test("red checks never ask the owner", () => {
  assert.equal(gate({ ...base, risk: "high", checks: { ...GREEN, failed: ["check"] } }).needsOwner, undefined);
});

test("drafts pass but never merge and never ask the owner", () => {
  const d = gate({ ...base, risk: "high", draft: true });
  assert.deepEqual([d.pass, d.merge, d.needsOwner], [true, false, undefined]);
});
