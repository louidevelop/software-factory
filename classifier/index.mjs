// The factory gate, run as a GitHub Action on every pull_request / pull_request_review event:
// classify → label + one sticky comment → wait for the other checks → decide → check the PR on
// the current base → merge.
// Fails CLOSED: any error rates the PR high and fails the gate.
import { readFileSync } from "node:fs";
import { validateConfig } from "./config.mjs";
import { gate } from "./gate.mjs";
import { client } from "./github.mjs";
import { mergeCheck } from "./mergecheck.mjs";
import { classify, linkedIssue } from "./rules.mjs";

const MARKER = "<!-- factory:gate -->";
const SELF = process.env.FACTORY_GATE_CHECK_NAME || "gate";
const WAIT_MS = Number(process.env.FACTORY_GATE_WAIT_MS || 25 * 60 * 1000);
const MERGE_CHECK_MS = Number(process.env.FACTORY_GATE_MERGE_CHECK_MS || 25 * 60 * 1000);
const POLL_MS = 15_000;

const token = process.env["INPUT_GITHUB-TOKEN"] || process.env.GITHUB_TOKEN;
const repo = process.env.GITHUB_REPOSITORY;
const gh = client({ token, api: process.env.GITHUB_API_URL, repo });
const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
const number = event.pull_request?.number;
const R = `/repos/${repo}`;

const log = (...a) => console.log("[factory gate]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function readBaseConfig(baseRef) {
  const file = await gh.get(`${R}/contents/.factory/config.json?ref=${encodeURIComponent(baseRef)}`);
  const config = JSON.parse(Buffer.from(file.content, "base64").toString("utf8"));
  const problems = validateConfig(config);
  if (problems.length) throw new Error(`.factory/config.json on ${baseRef} is invalid: ${problems.join("; ")}`);
  return config;
}

async function setRiskLabel(risk) {
  const want = `risk:${risk}`;
  const other = risk === "high" ? "risk:low" : "risk:high";
  await gh.post(`${R}/issues/${number}/labels`, { labels: [want] });
  await gh.del(`${R}/issues/${number}/labels/${encodeURIComponent(other)}`).catch(() => {});
}

async function upsertComment(text) {
  const comments = await gh.paginate(`${R}/issues/${number}/comments`);
  const mine = comments.find((c) => c.body?.startsWith(MARKER));
  const body = `${MARKER}\n${text}`;
  if (mine) await gh.patch(`${R}/issues/comments/${mine.id}`, { body });
  else await gh.post(`${R}/issues/${number}/comments`, { body });
}

function render(result, decision) {
  const head = result.risk === "high" ? "### Factory gate: 🔴 high impact — needs owner approval" : "### Factory gate: 🟢 low impact";
  const lines = result.reasons.map((r) => {
    const files = r.files.length ? `: ${r.files.slice(0, 8).map((f) => `\`${f}\``).join(", ")}${r.files.length > 8 ? ` (+${r.files.length - 8} more)` : ""}` : "";
    return `- **${r.rule}** — ${r.detail}${files}`;
  });
  return [head, "", ...(lines.length ? lines : ["No impact rule fired."]), "", `**Gate:** ${decision}`].join("\n");
}

// The PR cannot merge as it stands (conflict, or red on the current base): mark its ticket
// blocked so the human sees it in the ticket list, not only on the PR. Once per ticket.
async function blockTicket(pr, why) {
  const n = linkedIssue(pr.body ?? "");
  if (!n) return;
  const issue = await gh.get(`${R}/issues/${n}`);
  if (issue.labels?.some((l) => l.name === "blocked")) return;
  await gh.post(`${R}/issues/${n}/labels`, { labels: ["blocked"] });
  await gh.post(`${R}/issues/${n}/comments`, { body: `Blocked by the factory gate: PR #${number} ${why}` });
}

async function otherChecks(sha) {
  const runs = await gh.paginate(`${R}/commits/${sha}/check-runs`, "check_runs");
  const statuses = (await gh.get(`${R}/commits/${sha}/status`)).statuses ?? [];
  const latest = new Map();
  for (const r of runs) {
    if (r.name === SELF) continue;
    const seen = latest.get(r.name);
    if (!seen || (r.started_at ?? "") > (seen.started_at ?? "")) latest.set(r.name, r);
  }
  const checks = { pending: [], failed: [], passed: [] };
  for (const r of latest.values()) {
    if (r.status !== "completed") checks.pending.push(r.name);
    else if (["success", "neutral", "skipped"].includes(r.conclusion)) checks.passed.push(r.name);
    else checks.failed.push(r.name);
  }
  for (const s of statuses) {
    if (s.state === "pending") checks.pending.push(s.context);
    else if (s.state === "success") checks.passed.push(s.context);
    else checks.failed.push(s.context);
  }
  return checks;
}

async function waitForChecks(sha) {
  const deadline = Date.now() + WAIT_MS;
  let firstEmpty = Date.now();
  for (;;) {
    const checks = await otherChecks(sha);
    const none = checks.pending.length + checks.failed.length + checks.passed.length === 0;
    if (!none) firstEmpty = Date.now();
    const settled = checks.pending.length === 0 && (!none || Date.now() - firstEmpty > 120_000);
    if (settled || Date.now() > deadline) return checks;
    log(`waiting for checks: ${checks.pending.join(", ") || "none started yet"}`);
    await sleep(POLL_MS);
  }
}

async function main() {
  if (!number) throw new Error("not a pull_request event");
  let pr = await gh.get(`${R}/pulls/${number}`);
  if (pr.state !== "open") return log("PR is not open; nothing to do");

  let result;
  try {
    const config = await readBaseConfig(pr.base.ref);
    const files = await gh.paginate(`${R}/pulls/${number}/files`);
    const issue = linkedIssue(pr.body);
    const ticket = issue ? await gh.get(`${R}/issues/${issue}`).then((t) => ({ number: issue, body: t.body ?? "" })).catch(() => null) : null;
    result = classify({ config, files, pr: { body: pr.body ?? "", draft: pr.draft }, ticket });
    result.owners = config.owners;
  } catch (err) {
    result = { risk: "high", reasons: [{ rule: "error", detail: `the classifier failed, so the PR is high impact: ${err.message}`, files: [] }], owners: [] };
  }
  log(`risk: ${result.risk}`, JSON.stringify(result.reasons));
  await setRiskLabel(result.risk);
  await upsertComment(render(result, "waiting for the other checks…"));

  const checks = await waitForChecks(pr.head.sha);
  pr = await gh.get(`${R}/pulls/${number}`); // fresh: the head may have moved while waiting
  const reviews = (await gh.paginate(`${R}/pulls/${number}/reviews`)).map((r) => ({
    user: r.user?.login, state: r.state, commit_id: r.commit_id, submitted_at: r.submitted_at,
  }));
  const decision = gate({ risk: result.risk, owners: result.owners, headSha: pr.head.sha, draft: pr.draft, reviews, checks });
  log(decision.summary);
  if (!decision.merge) {
    await upsertComment(render(result, decision.summary));
    if (!decision.pass) process.exitCode = 1;
    return;
  }

  const base = pr.base.ref;
  await upsertComment(render(result, `${decision.summary} once it is green on the current \`${base}\`…`));
  const mc = await mergeCheck({ gh, R, number, headSha: pr.head.sha, baseRef: base, deadline: Date.now() + MERGE_CHECK_MS, sleep, log });
  if (!mc.ok) {
    log(mc.summary);
    await upsertComment(render(result, `not merged — ${mc.summary}`));
    if (mc.why !== "timeout") await blockTicket(pr, mc.summary).catch((err) => log(`could not block the ticket: ${err.message}`));
    process.exitCode = 1;
    return;
  }

  const merged = await gh.put(`${R}/pulls/${number}/merge`, { merge_method: "squash", sha: pr.head.sha });
  log(`merged #${number}`);
  const issue = linkedIssue(pr.body ?? "");
  if (issue) await gh.del(`${R}/issues/${issue}/labels/blocked`).catch(() => {});
  // The merge API cannot pin the base, so a merge that slipped in after the last read of it
  // means this squash landed on a base the check did not see. Say so; pickup checks the base.
  const parent = merged?.sha ? (await gh.get(`${R}/commits/${merged.sha}`)).parents?.[0]?.sha : mc.baseSha;
  const how = mc.checked ? `checked against \`${base}\` ${mc.baseSha.slice(0, 7)} ([run](${mc.url}))` : `up to date with \`${base}\``;
  const race = parent && parent !== mc.baseSha
    ? `\n\n⚠️ Another merge landed on \`${base}\` between the check and this merge; that combination was not checked. \`factory start\` refuses to start a ticket if \`${base}\` is red.`
    : "";
  await upsertComment(render(result, `merged, ${how}${race}`));
}

main().catch(async (err) => {
  console.error(`[factory gate] ${err.stack ?? err}`);
  try {
    await upsertComment(`### Factory gate: 🔴 error\n\nThe gate failed, so nothing merges: \`${err.message}\``);
  } catch {}
  process.exitCode = 1;
});
