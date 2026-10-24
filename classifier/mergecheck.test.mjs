import assert from "node:assert/strict";
import { test } from "node:test";
import { mergeCheck, scratchBranch } from "./mergecheck.mjs";

const R = "/repos/o/p";
const SCRATCH = `${R}/git/refs/heads/${scratchBranch(7)}`;

// A fake GitHub: `bases` is what successive reads of the base branch return (the last repeats);
// `conclusions[i]` is the result of the i-th dispatched run (null = the run never appears).
function fake({ bases = ["b1"], behind = 1, conflict = false, conclusions = ["success"], dispatchError = null, pendingPolls = 0 } = {}) {
  const calls = [];
  let reads = 0;
  let combos = 0;
  let dispatches = 0;
  let polls = 0;
  const fail = (status) => Object.assign(new Error(`HTTP ${status}`), { status });
  const route = (method, path, body) => {
    calls.push({ method, path, body });
    if (method === "GET" && path === `${R}/branches/main`) return { commit: { sha: bases[Math.min(reads++, bases.length - 1)] } };
    if (method === "GET" && path.startsWith(`${R}/compare/`)) return { behind_by: behind };
    if (method === "DELETE" && path === SCRATCH) return null;
    if (method === "POST" && path === `${R}/git/refs`) return {};
    if (method === "POST" && path === `${R}/merges`) {
      if (conflict) throw fail(409);
      return { sha: `combo${++combos}` };
    }
    if (method === "POST" && path.endsWith("/dispatches")) {
      if (dispatchError) throw fail(dispatchError);
      dispatches++;
      polls = 0;
      return null;
    }
    if (method === "GET" && path.includes("/runs?")) {
      const sha = new URLSearchParams(path.split("?")[1]).get("head_sha");
      const conclusion = conclusions[dispatches - 1];
      if (conclusion === null) return { workflow_runs: [] };
      const done = polls++ >= pendingPolls;
      return { workflow_runs: [{ head_sha: sha, status: done ? "completed" : "in_progress", conclusion: done ? conclusion : null, html_url: `https://run/${sha}` }] };
    }
    throw new Error(`unexpected ${method} ${path}`);
  };
  const gh = {
    get: async (p) => route("GET", p),
    post: async (p, b) => route("POST", p, b),
    del: async (p) => route("DELETE", p),
  };
  return { gh, calls, dispatched: () => calls.filter((c) => c.path.endsWith("/dispatches")) };
}

function run(f, extra = {}) {
  let t = 0;
  return mergeCheck({
    gh: f.gh, R, number: 7, headSha: "head", baseRef: "main",
    deadline: 60 * 60 * 1000, now: () => t, sleep: async (ms) => { t += ms; }, ...extra,
  });
}

test("up to date: no extra run, the PR's own checks covered it", async () => {
  const f = fake({ behind: 0 });
  assert.deepEqual(await run(f), { ok: true, baseSha: "b1", checked: false });
  assert.equal(f.dispatched().length, 0);
});

test("behind and green on the current base: ok, checked on a scratch branch that is then deleted", async () => {
  const f = fake({ pendingPolls: 2 });
  const r = await run(f);
  assert.deepEqual(r, { ok: true, baseSha: "b1", checked: true, url: "https://run/combo1" });
  assert.deepEqual(f.dispatched()[0].body, { ref: scratchBranch(7) });
  const merge = f.calls.find((c) => c.path === `${R}/merges`);
  assert.deepEqual([merge.body.base, merge.body.head], [scratchBranch(7), "head"]);
  assert.equal(f.calls.at(-1).method, "DELETE", "the scratch branch is removed at the end");
});

test("a merge conflict never merges and never dispatches", async () => {
  const f = fake({ conflict: true });
  const r = await run(f);
  assert.equal(r.ok, false);
  assert.equal(r.why, "conflict");
  assert.equal(f.dispatched().length, 0);
  assert.equal(f.calls.at(-1).method, "DELETE");
});

test("green alone but red combined: no merge, the summary links the run", async () => {
  const f = fake({ conclusions: ["failure"] });
  const r = await run(f);
  assert.equal(r.ok, false);
  assert.equal(r.why, "red");
  assert.match(r.summary, /https:\/\/run\/combo1/);
});

test("the base moved during the check: rebuilt and checked again on the new base", async () => {
  const f = fake({ bases: ["b1", "b2"], conclusions: ["success", "success"] });
  const r = await run(f);
  assert.deepEqual(r, { ok: true, baseSha: "b2", checked: true, url: "https://run/combo2" });
  assert.equal(f.dispatched().length, 2);
});

test("the base moved and the new combination is red: no merge", async () => {
  const f = fake({ bases: ["b1", "b2"], conclusions: ["success", "failure"] });
  assert.equal((await run(f)).why, "red");
});

test("a check workflow without workflow_dispatch fails closed with the fix in the message", async () => {
  const f = fake({ dispatchError: 422 });
  await assert.rejects(run(f), /workflow_dispatch/);
  assert.equal(f.calls.at(-1).method, "DELETE");
});

test("a dispatched run that never appears fails closed", async () => {
  await assert.rejects(run(fake({ conclusions: [null] })), /never started/);
});

test("a run still going at the deadline times out instead of merging", async () => {
  const r = await run(fake({ pendingPolls: 1000 }), { deadline: 10 * 60 * 1000 });
  assert.deepEqual([r.ok, r.why], [false, "timeout"]);
});
