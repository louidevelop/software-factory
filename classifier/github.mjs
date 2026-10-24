// Minimal GitHub REST client for the action. Zero dependencies (Node 24 fetch).

// A temporary failure (a 5xx, a rate limit, a dropped connection) is retried after these waits.
// Without that, one 503 fails the gate run, and the PR then waits for its next push: nothing
// else starts the gate again.
export const RETRY_DELAYS_MS = [2_000, 6_000, 18_000, 54_000];
const MAX_WAIT_MS = 60_000;

const temporary = (res) => res.status >= 500 || res.status === 429 || (res.status === 403 && res.headers.has("retry-after"));

export function client({
  token,
  api = "https://api.github.com",
  repo,
  fetch = globalThis.fetch,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  delays = RETRY_DELAYS_MS,
  log = () => {},
}) {
  async function send(method, path, url, init) {
    for (let i = 0; ; i++) {
      let res, why;
      try {
        res = await fetch(url, init);
        if (!temporary(res) || i >= delays.length) return res;
        why = `HTTP ${res.status}`;
      } catch (err) {
        if (i >= delays.length) throw err;
        why = err.message;
      }
      const after = Number(res?.headers.get("retry-after")) * 1000;
      const wait = Math.min(Math.max(delays[i], after || 0), MAX_WAIT_MS);
      log(`${method} ${path}: ${why}; retrying in ${Math.round(wait / 1000)}s`);
      await sleep(wait);
    }
  }

  async function call(method, path, body) {
    const url = path.startsWith("http") ? path : `${api}${path.replace("{repo}", repo)}`;
    const res = await send(method, path, url, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        ...(body ? { "content-type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 204) return { data: null, res };
    const text = await res.text();
    // A proxy's 5xx page is HTML: the error then carries the status, not a JSON parse error.
    const data = text && (res.ok || text.trimStart().startsWith("{")) ? JSON.parse(text) : null;
    if (!res.ok) {
      const err = new Error(`${method} ${path} → ${res.status}: ${data?.message ?? text.slice(0, 200)}`);
      err.status = res.status;
      throw err;
    }
    return { data, res };
  }

  async function paginate(path, key) {
    const out = [];
    let next = `${path}${path.includes("?") ? "&" : "?"}per_page=100`;
    for (let page = 0; next && page < 30; page++) {
      const { data, res } = await call("GET", next);
      out.push(...(key ? data[key] : data));
      next = res.headers.get("link")?.match(/<([^>]+)>;\s*rel="next"/)?.[1] ?? null;
    }
    return out;
  }

  return {
    get: async (p) => (await call("GET", p)).data,
    post: async (p, b) => (await call("POST", p, b)).data,
    put: async (p, b) => (await call("PUT", p, b)).data,
    patch: async (p, b) => (await call("PATCH", p, b)).data,
    del: async (p) => (await call("DELETE", p)).data,
    paginate,
  };
}
