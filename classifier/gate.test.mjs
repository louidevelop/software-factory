import assert from "node:assert/strict";
import { test } from "node:test";
import { gate, MERGE_LABEL, needsGoAhead, ownerGoAhead } from "./gate.mjs";

const GREEN = { pending: [], failed: [], passed: ["check"] };
const base = { risk: "low", owners: ["Owner"], draft: false, labels: [], events: [], checks: GREEN };
const labeled = (actor, created_at, label = MERGE_LABEL) => ({ event: "labeled", label, actor, created_at });
const PUSHED = "2026-01-01T10:00:00Z";
const AFTER = "2026-01-01T11:00:00Z";
const BEFORE = "2026-01-01T09:00:00Z";

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
  const go = gate({ ...high, labels: [MERGE_LABEL], events: [labeled("owner", AFTER)], headPushedAt: PUSHED });
  assert.equal(go.merge, true, "owner login is case-insensitive");
});

test("medium waits for the owner unless the project's autoMerge is medium", () => {
  const medium = { ...base, risk: "medium" };
  assert.equal(gate(medium).needsOwner, true, "autoMerge defaults to low");
  assert.equal(gate({ ...medium, autoMerge: "low" }).needsOwner, true);
  assert.equal(gate({ ...medium, autoMerge: "medium" }).merge, true);
  assert.equal(gate({ ...base, autoMerge: "medium" }).merge, true, "low still merges");
});

test("high always waits for the owner, and unknown values fail closed", () => {
  for (const autoMerge of [undefined, "low", "medium", "high", "everything"])
    assert.equal(gate({ ...base, risk: "high", autoMerge }).needsOwner, true, String(autoMerge));
  assert.equal(needsGoAhead("bogus", "medium"), true, "an unknown risk counts as high");
  assert.equal(needsGoAhead("medium", "bogus"), true, "an unknown autoMerge counts as low");
});

test("the label only counts when an owner added it, judged by the latest labeling", () => {
  const go = (events, labels = [MERGE_LABEL]) => ownerGoAhead(["Owner"], labels, events, PUSHED).ok;
  assert.equal(go([labeled("someone-else", AFTER)]), false);
  assert.equal(go([labeled("Owner", AFTER), labeled("someone-else", "2026-01-01T12:00:00Z")]), false);
  assert.equal(go([labeled("someone-else", AFTER), labeled("Owner", "2026-01-01T12:00:00Z")]), true);
  assert.equal(go([]), false, "a label with no recorded event does not count");
  assert.equal(go([labeled("Owner", AFTER)], []), false, "a removed label does not count");
  assert.equal(go([labeled("Owner", AFTER, "risk:high")], ["risk:high", MERGE_LABEL]), false, "other labels do not count");
});

test("a label added before the head commit was pushed is stale, whatever event the run is for", () => {
  const stale = gate({ ...base, risk: "high", labels: [MERGE_LABEL], events: [labeled("Owner", BEFORE)], headPushedAt: PUSHED });
  assert.deepEqual([stale.merge, stale.needsOwner, stale.stale], [false, true, true]);
  assert.equal(ownerGoAhead(["Owner"], [MERGE_LABEL], [labeled("Owner", AFTER)], null).ok, false, "unknown push time fails closed");
});

test("red checks never ask the owner", () => {
  assert.equal(gate({ ...base, risk: "high", checks: { ...GREEN, failed: ["check"] } }).needsOwner, undefined);
});

test("drafts pass but never merge and never ask the owner", () => {
  const d = gate({ ...base, risk: "high", draft: true });
  assert.deepEqual([d.pass, d.merge, d.needsOwner], [true, false, undefined]);
});
