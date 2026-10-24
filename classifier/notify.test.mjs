import assert from "node:assert/strict";
import { test } from "node:test";
import { activeTicket, BLOCK_MARKER, fireRequest, fireRoutine, liveReason, mentionBody, needsBlockMention, needsRework, openAttempt } from "./notify.mjs";

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

const ticket = (...labels) => ({ number: 7, state: "open", labels: ["agent-task", ...labels].map((name) => ({ name })) });

test("live attempt: only open, in-progress or rework, unblocked agent tickets", () => {
  assert.equal(activeTicket(ticket("in-progress")), true);
  assert.equal(activeTicket(ticket("rework")), true);
  assert.equal(activeTicket(ticket()), false, "ready, not started");
  assert.equal(activeTicket(ticket("in-progress", "blocked")), false);
  assert.equal(activeTicket({ ...ticket("in-progress"), state: "closed" }), false);
  assert.equal(activeTicket({ ...ticket("in-progress"), pull_request: {} }), false, "a PR is not a ticket");
  assert.equal(activeTicket({ ...ticket("in-progress"), labels: [{ name: "in-progress" }] }), false, "not an agent task");
});

const started = (k, created_at, branch = "ticket/7-x") => ({ body: `<!-- factory:attempt ${k} branch=${branch} -->\n**Factory attempt ${k} of 3** started`, created_at });
const ended = (c, k, outcome) => ({ ...c, body: `${c.body}\n\n<!-- factory:attempt-end ${k} ${outcome} -->\n**Ended: ${outcome}.**` });

test("live attempt: the last attempt record, while it has not ended", () => {
  assert.equal(openAttempt([]), null);
  assert.equal(openAttempt([{ body: "a comment" }]), null);
  assert.deepEqual(openAttempt([started(1, T1)]), { branch: "ticket/7-x", startedAt: T1 });
  assert.equal(openAttempt([started(1, T1), { body: "later chatter" }]).startedAt, T1, "other comments do not count");
  for (const outcome of ["finished", "unfinished", "blocked"]) assert.equal(openAttempt([ended(started(1, T1), 1, outcome)]), null, outcome);
  assert.deepEqual(openAttempt([ended(started(1, T1), 1, "unfinished"), started(2, T2)]), { branch: "ticket/7-x", startedAt: T2 });
});

test("live attempt: started, or got a commit, within run.staleMinutes", () => {
  const now = Date.parse(T3);
  const attempt = { branch: "ticket/7-x", startedAt: T2 }; // 60 min before T3
  assert.match(liveReason({ ticket: 7, attempt, now }), /#7's attempt started 60 min ago/, "default: 120 min");
  assert.equal(liveReason({ ticket: 7, attempt, now, staleMinutes: 60 }), null, "stale exactly at the limit");
  assert.equal(liveReason({ ticket: 7, attempt: { ...attempt, startedAt: T1 }, now, staleMinutes: 90 }), null);
  assert.match(liveReason({ ticket: 7, attempt: { ...attempt, startedAt: T1 }, branchCommitAt: "2026-01-01T11:50:00Z", now, staleMinutes: 90 }),
    /branch ticket\/7-x got a commit 10 min ago/);
  assert.equal(liveReason({ ticket: 7, attempt: { ...attempt, startedAt: undefined }, now }), null, "no time, not live");
});
