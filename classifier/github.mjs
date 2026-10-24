// Minimal GitHub REST client for the action. Zero dependencies (Node 24 fetch).

export function client({ token, api = "https://api.github.com", repo }) {
  async function call(method, path, body) {
    const url = path.startsWith("http") ? path : `${api}${path.replace("{repo}", repo)}`;
    const res = await fetch(url, {
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
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const err = new Error(`${method} ${path} → ${res.status}: ${data?.message ?? text}`);
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
