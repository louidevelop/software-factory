// What the gate tells others besides the PR: the cloud routine (start its next run), the ticket
// (send it back for rework) and the owners (a ticket is blocked on them). Pure decisions, plus
// the one fire call, which takes its fetch as an argument so the tests can fake it.

export const REWORK_LABEL = "rework";
export const BLOCKED_LABEL = "blocked";
export const BLOCK_MARKER = "<!-- factory:blocked -->";

const has = (issue, name) => (issue.labels ?? []).some((l) => (l.name ?? l) === name);

// Mentions only notify in a newly posted comment; the marker lets the gate find its own.
export const mentionBody = (marker, owners, text) => `${marker}\n${owners.map((o) => `@${o}`).join(" ")} ${text}`;

// A PR that cannot merge as it stands (conflict, or red on the current base) sends its ticket
// back for rework, which the next attempt picks first. Not `blocked`: that is a question for the
// owner, and this is work for an agent. Once per ticket.
export function needsRework(issue) {
  return issue.state === "open" && !has(issue, REWORK_LABEL);
}

// Every block is made under the owner's own account (`factory block` runs as them), and GitHub
// never notifies you about your own actions, so the gate mentions the owners as the bot. Once per
// block: only when the ticket is still blocked and the gate has not mentioned them since the label
// was last added. events = [{ event, label, created_at }], comments = [{ body, created_at }].
export function needsBlockMention({ issue, events, comments }) {
  if (issue.state !== "open" || !has(issue, BLOCKED_LABEL)) return false;
  const since = events
    .filter((e) => e.event === "labeled" && e.label === BLOCKED_LABEL)
    .map((e) => e.created_at ?? "")
    .sort()
    .at(-1);
  if (since === undefined) return false;
  return !comments.some((c) => c.body?.startsWith(BLOCK_MARKER) && (c.created_at ?? "") >= since);
}

// The cloud routine's /fire endpoint. A routine's own "PR merged" trigger never fires for a merge
// made with GITHUB_TOKEN, which is how the gate merges, so the gate starts the next run itself.
// Only when the project set both FACTORY_ROUTINE_URL and FACTORY_ROUTINE_TOKEN; null otherwise.
export function fireRequest({ url, token, text }) {
  if (!url || !token) return null;
  return {
    url,
    init: {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "anthropic-beta": "experimental-cc-routine-2026-04-01",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({ text }),
    },
  };
}

// Never throws and never fails the gate: a missed fire is logged, and the routine's hourly
// schedule is the backstop. Never logs the token. → true when the routine accepted the run.
export async function fireRoutine({ url, token, text, fetch = globalThis.fetch, log = () => {}, timeoutMs = 15_000 }) {
  const req = fireRequest({ url, token, text });
  if (!req) {
    if (url || token) log(`routine not started: set both FACTORY_ROUTINE_URL and FACTORY_ROUTINE_TOKEN (only the ${url ? "URL" : "token"} is set)`);
    else log("routine not started: the project has no FACTORY_ROUTINE_URL / FACTORY_ROUTINE_TOKEN");
    return false;
  }
  if (!/^https:\/\//i.test(url)) {
    log("routine not started: FACTORY_ROUTINE_URL must be https, or the token would travel in clear text");
    return false;
  }
  try {
    const res = await fetch(req.url, { ...req.init, signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok) {
      log(`routine not started: /fire answered HTTP ${res.status}; the hourly schedule picks the work up`);
      return false;
    }
    log(`routine started: ${text}`);
    return true;
  } catch (err) {
    log(`routine not started: ${String(err?.message ?? err).replaceAll(token, "***")}; the hourly schedule picks the work up`);
    return false;
  }
}
