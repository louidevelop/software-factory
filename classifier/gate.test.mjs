import assert from "node:assert/strict";
import { test } from "node:test";
import { gate, ownerApproval } from "./gate.mjs";

const GREEN = { pending: [], failed: [], passed: ["check"] };
const base = { risk: "low", owners: ["Owner"], headSha: "h2", draft: false, reviews: [], checks: GREEN };
const review = (user, state, commit_id, submitted_at) => ({ user, state, commit_id, submitted_at });

test("low + green merges", () => assert.deepEqual(gate(base).merge, true));

test("red, pending, or missing checks never pass", () => {
  assert.equal(gate({ ...base, checks: { ...GREEN, failed: ["check"] } }).pass, false);
  assert.equal(gate({ ...base, checks: { ...GREEN, pending: ["check"] } }).pass, false);
  assert.equal(gate({ ...base, checks: { pending: [], failed: [], passed: [] } }).pass, false);
});

test("high waits for an owner approval on the head commit", () => {
  const high = { ...base, risk: "high" };
  assert.equal(gate(high).pass, false);
  assert.equal(gate({ ...high, reviews: [review("owner", "APPROVED", "h2", "2")] }).merge, true, "owner login is case-insensitive");
  assert.equal(gate({ ...high, reviews: [review("Owner", "APPROVED", "h1", "1")] }).pass, false, "stale approval");
  assert.equal(gate({ ...high, reviews: [review("machine-user", "APPROVED", "h2", "1")] }).pass, false, "non-owner approval does not count");
});

test("an owner's later changes-requested overrides an earlier approval", () => {
  const reviews = [review("Owner", "APPROVED", "h2", "1"), review("Owner", "CHANGES_REQUESTED", "h2", "2")];
  assert.equal(ownerApproval(["Owner"], reviews, "h2").approved, false);
  const later = [review("Owner", "CHANGES_REQUESTED", "h1", "1"), review("Owner", "APPROVED", "h2", "2")];
  assert.equal(ownerApproval(["Owner"], later, "h2").approved, true);
});

test("comments do not reset an approval", () => {
  const reviews = [review("Owner", "APPROVED", "h2", "1"), review("Owner", "COMMENTED", "h2", "2")];
  assert.equal(ownerApproval(["Owner"], reviews, "h2").approved, true);
});

test("drafts pass but never merge", () => {
  assert.deepEqual([gate({ ...base, draft: true }).pass, gate({ ...base, draft: true }).merge], [true, false]);
});
