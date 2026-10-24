import assert from "node:assert/strict";
import { test } from "node:test";
import { BLOCK_MARKER, fireRequest, fireRoutine, mentionBody, needsBlockMention, needsRework } from "./notify.mjs";

const URL = "https://api.anthropic.com/v1/claude_code/routines/trig_1/fire";
const TOKEN = "sk-ant-secret-token";

// A fake fetch: records each call and answers with `status`, or throws `error`.
function fakeFetch({ status = 200, error = null } = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    if (error) throw error;
    return { ok: status >= 200 && status < 300, status };
  };
  return { fetch, calls };
}

async function fire(opts, answer) {
  const f = fakeFetch(answer);
  const lines = [];
  const ok = await fireRoutine({ text: "PR #7 merged", fetch: f.fetch, log: (l) => lines.push(l), ...opts });
  return { ok, calls: f.calls, lines };
}

test("fire: POSTs the text to the URL with the routine headers", async () => {
  const { ok, calls } = await fire({ url: URL, token: TOKEN });
  assert.equal(ok, true);
  assert.equal(calls.length, 1);
  const { url, init } = calls[0];
  assert.equal(url, URL);
  assert.equal(init.method, "POST");
  assert.deepEqual(init.headers, {
    authorization: `Bearer ${TOKEN}`,
    "anthropic-beta": "experimental-cc-routine-2026-04-01",
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
  });
  assert.deepEqual(JSON.parse(init.body), { text: "PR #7 merged" });
  assert.ok(init.signal, "a hanging /fire cannot hold the gate");
});

test("fire: never without both the URL and the token, and says which is missing", async () => {
  assert.equal(fireRequest({ url: "", token: "", text: "x" }), null);
  for (const [opts, says] of [[{}, "no FACTORY_ROUTINE_URL"], [{ url: URL }, "only the URL"], [{ token: TOKEN }, "only the token"]]) {
    const { ok, calls, lines } = await fire(opts);
    assert.equal(ok, false);
    assert.equal(calls.length, 0);
    assert.match(lines.join("\n"), new RegExp(says));
  }
});

test("fire: never sends the token over plain http", async () => {
  const { ok, calls } = await fire({ url: "http://example.com/fire", token: TOKEN });
  assert.equal(ok, false);
  assert.equal(calls.length, 0);
});

test("fire: a refused or failed call is logged, never thrown, and never logs the token", async () => {
  const refused = await fire({ url: URL, token: TOKEN }, { status: 401 });
  assert.equal(refused.ok, false);
  assert.match(refused.lines.join("\n"), /HTTP 401/);
  const failed = await fire({ url: URL, token: TOKEN }, { error: new Error(`network down for Bearer ${TOKEN}`) });
  assert.equal(failed.ok, false);
  assert.match(failed.lines.join("\n"), /network down/);
  for (const r of [refused, failed]) assert.ok(!r.lines.join("\n").includes(TOKEN), "the token is never logged");
});

test("rework: once per open ticket", () => {
  assert.equal(needsRework({ state: "open", labels: [{ name: "agent-task" }] }), true);
  assert.equal(needsRework({ state: "open", labels: [{ name: "rework" }] }), false, "already sent back");
  assert.equal(needsRework({ state: "closed", labels: [] }), false);
  assert.equal(needsRework({ state: "open", labels: [{ name: "blocked" }] }), true, "rework is not blocked");
});

const BLOCKED = { state: "open", labels: [{ name: "agent-task" }, { name: "blocked" }] };
const labeled = (created_at, label = "blocked") => ({ event: "labeled", label, created_at });
const mention = (created_at) => ({ body: mentionBody(BLOCK_MARKER, ["owner"], "blocked"), created_at });
const T1 = "2026-01-01T10:00:00Z";
const T2 = "2026-01-01T11:00:00Z";
const T3 = "2026-01-01T12:00:00Z";

test("blocked mention: once per block", () => {
  const needs = (events, comments, issue = BLOCKED) => needsBlockMention({ issue, events, comments });
  assert.equal(needs([labeled(T1)], []), true, "a new block");
  assert.equal(needs([labeled(T1)], [mention(T2)]), false, "already mentioned for this block");
  assert.equal(needs([labeled(T1)], [mention(T1)]), false, "mentioned in the same second");
  assert.equal(needs([labeled(T1), labeled(T3)], [mention(T2)]), true, "blocked again after an unblock");
  assert.equal(needs([labeled(T1)], [{ body: "@owner blocked", created_at: T2 }]), true, "only the gate's own comment counts");
  assert.equal(needs([labeled(T1), labeled(T3, "in-progress")], [mention(T2)]), false, "other labels do not count");
});

test("blocked mention: not once the ticket is unblocked or closed", () => {
  const events = [labeled(T1)];
  assert.equal(needsBlockMention({ issue: { state: "open", labels: [{ name: "agent-task" }] }, events, comments: [] }), false);
  assert.equal(needsBlockMention({ issue: { ...BLOCKED, state: "closed" }, events, comments: [] }), false);
  assert.equal(needsBlockMention({ issue: BLOCKED, events: [], comments: [] }), false, "no labeled event, no block to mention");
});

test("mention body: the marker first, then every owner", () => {
  assert.equal(mentionBody(BLOCK_MARKER, ["a", "b"], "look"), `${BLOCK_MARKER}\n@a @b look`);
});
