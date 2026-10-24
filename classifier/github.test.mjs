import assert from "node:assert/strict";
import { test } from "node:test";
import { client, RETRY_DELAYS_MS } from "./github.mjs";

// A fake fetch that answers from a script: a number is that status (JSON body), an Error is thrown,
// a [status, headers, body] triple is answered as given. Records every call; sleep records its waits.
function fake(...script) {
  const calls = [];
  const waits = [];
  const fetch = async (url, init) => {
    calls.push({ url, method: init.method });
    const next = script.length > 1 ? script.shift() : script[0];
    if (next instanceof Error) throw next;
    const [status, headers = {}, body = JSON.stringify({ message: `status ${status}` })] = Array.isArray(next) ? next : [next];
    return new Response(status === 204 ? null : body, { status, headers });
  };
  const lines = [];
  const gh = client({ token: "t", repo: "o/r", fetch, sleep: async (ms) => waits.push(ms), log: (l) => lines.push(l) });
  return { gh, calls, waits, lines };
}

test("github: a temporary failure is retried until it succeeds", async () => {
  for (const first of [500, 502, 503, 504, 429, new TypeError("fetch failed")]) {
    const { gh, calls, waits, lines } = fake(first, first, 200);
    assert.deepEqual(await gh.get("/repos/o/r/pulls/1"), { message: "status 200" });
    assert.equal(calls.length, 3);
    assert.deepEqual(waits, RETRY_DELAYS_MS.slice(0, 2));
    assert.match(lines[0], /GET \/repos\/o\/r\/pulls\/1: .*retrying in 2s/);
  }
});

test("github: writes are retried too", async () => {
  const { gh, calls } = fake(503, 201);
  await gh.post("/repos/o/r/issues/1/comments", { body: "x" });
  assert.deepEqual(calls.map((c) => c.method), ["POST", "POST"]);
});

test("github: gives up after the last retry with the status", async () => {
  const { gh, calls } = fake([503, { "content-type": "text/html" }, "<html>Service Unavailable</html>"]);
  await assert.rejects(gh.get("/x"), (err) => err.status === 503 && /→ 503: <html>/.test(err.message));
  assert.equal(calls.length, RETRY_DELAYS_MS.length + 1);
  const down = fake(new TypeError("fetch failed"));
  await assert.rejects(down.gh.get("/x"), /fetch failed/);
  assert.equal(down.calls.length, RETRY_DELAYS_MS.length + 1);
});

test("github: a lasting failure is not retried", async () => {
  for (const status of [400, 401, 404, 409, 422, 403]) {
    const { gh, calls } = fake(status);
    await assert.rejects(gh.get("/x"), (err) => err.status === status);
    assert.equal(calls.length, 1, `HTTP ${status}`);
  }
});

test("github: a rate limit waits as long as Retry-After asks, up to a minute", async () => {
  const limited = fake([403, { "retry-after": "30" }], 200);
  await limited.gh.get("/x");
  assert.deepEqual(limited.waits, [30_000]);
  const long = fake([429, { "retry-after": "3600" }], 200);
  await long.gh.get("/x");
  assert.deepEqual(long.waits, [60_000]);
});

test("github: paginate retries a page without losing the others", async () => {
  const { gh, calls } = fake([200, { link: '<https://api.github.com/x?page=2>; rel="next"' }, "[1]"], 502, [200, {}, "[2]"]);
  assert.deepEqual(await gh.paginate("/x"), [1, 2]);
  assert.equal(calls.length, 3);
});
