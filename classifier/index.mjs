// The factory gate, run as a GitHub Action on every pull_request event (and when the `merge`
// label is added): classify → label + one sticky comment → wait for the other checks → decide →
// ask the owner (high impact) or check the PR on the current base → merge → start the routine.
// Fails CLOSED: any error rates the PR high and fails the gate.
// On an issue labelled `blocked` it only mentions the owners (mentionBlocked).
import { readFileSync } from "node:fs";
import { validateConfig } from "./config.mjs";
import { gate, MERGE_LABEL } from "./gate.mjs";
import { client } from "./github.mjs";
import { mergeCheck } from "./mergecheck.mjs";
import {
  activeTicket, BLOCK_MARKER, BLOCKED_LABEL, fireRequest, fireRoutine, liveReason, mentionBody, needsBlockMention, needsRework, openAttempt,
  REWORK_LABEL,
} from "./notify.mjs";
import { classify, linkedIssue } from "./rules.mjs";

const MARKER = "<!-- factory:gate -->";
const ASK_MARKER = "<!-- factory:ask-owner -->";
const SELF = process.env.FACTORY_GATE_CHECK_NAME || "gate";
// The gate workflow's other job, skipped on every PR: not one of the project's checks.
const SIBLING = "blocked-ticket";
const WAIT_MS = Number(process.env.FACTORY_GATE_WAIT_MS || 25 * 60 * 1000);
const MERGE_CHECK_MS = Number(process.env.FACTORY_GATE_MERGE_CHECK_MS || 25 * 60 * 1000);
const POLL_MS = 15_000;

const token = process.env["INPUT_GITHUB-TOKEN"] || process.env.GITHUB_TOKEN;
const repo = process.env.GITHUB_REPOSITORY;
const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
const number = event.pull_request?.number;
const R = `/repos/${repo}`;

const log = (...a) => console.log("[factory gate]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const gh = client({ token, api: process.env.GITHUB_API_URL, repo, log });
const routine = { url: process.env["INPUT_ROUTINE-URL"], token: process.env["INPUT_ROUTINE-TOKEN"] };

// The attempt that is live in this repository, if any (see liveReason): why it is, or null.
async function liveAttempt(staleMinutes) {
  const tickets = (await gh.paginate(`${R}/issues?labels=agent-task&state=open`)).filter(activeTicket);
  for (const t of tickets) {
    const attempt = openAttempt(await gh.paginate(`${R}/issues/${t.number}/comments`));
    if (!attempt) continue;
    let why = liveReason({ ticket: t.number, attempt, staleMinutes });
    if (!why && attempt.branch) {
      const branch = await gh.get(`${R}/branches/${attempt.branch.split("/").map(encodeURIComponent).join("/")}`).catch(() => null);
      why = liveReason({ ticket: t.number, attempt, branchCommitAt: branch?.commit?.commit?.committer?.date, staleMinutes });
    }
    if (why) return why;
  }
  return null;
}

// Start the cloud routine's next run, unless an attempt is live: that attempt's own PR starts the
// next run when it merges or starts waiting for an owner, and the hourly schedule covers an attempt
// that ends without one. A failed look starts the run anyway; at worst it finds the repository busy.
async function fire(text, staleMinutes) {
  if (fireRequest({ ...routine, text })) {
    const busy = await liveAttempt(staleMinutes).catch((err) => log(`could not look for a live attempt: ${err.message}`));
    if (busy) return log(`routine not started: ${busy}; a run is already working`);
  }
  await fireRoutine({ ...routine, text, log });
}

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
  const head = result.risk === "high" ? `### Factory gate: 🔴 high impact — needs an owner's \`${MERGE_LABEL}\` label` : "### Factory gate: 🟢 low impact";
  const lines = result.reasons.map((r) => {
    const files = r.files.length ? `: ${r.files.slice(0, 8).map((f) => `\`${f}\``).join(", ")}${r.files.length > 8 ? ` (+${r.files.length - 8} more)` : ""}` : "";
    return `- **${r.rule}** — ${r.detail}${files}`;
  });
  return [head, "", ...(lines.length ? lines : ["No impact rule fired."]), "", `**Gate:** ${decision}`].join("\n");
}

// Mentions only notify in a newly posted comment, never in an edited one (the sticky gate comment),
// and GitHub does not notify you about a PR you opened yourself, which is every PR when the owner
// and the agents share an account. So the gate assigns the owners and posts its own comment.
async function mentionOwners(owners, text) {
  if (!owners.length) return;
  await gh.post(`${R}/issues/${number}/assignees`, { assignees: owners }).catch((err) => log(`could not assign: ${err.message}`));
  await gh.post(`${R}/issues/${number}/comments`, { body: mentionBody(ASK_MARKER, owners, text) });
}

// Ask once per PR; later pushes that drop the label ask again on their own. The PR now waits for
// the owner, so the routine is started too: its run's notification reaches the owner's phone, and
// the run can take on other work meanwhile.
async function askOwners(owners, base, staleMinutes) {
  const comments = await gh.paginate(`${R}/issues/${number}/comments`);
  if (comments.some((c) => c.body?.startsWith(ASK_MARKER))) return;
  await mentionOwners(owners, `this PR is high impact and its checks are green. Review it, then add the \`${MERGE_LABEL}\` label: the gate checks it against the current \`${base}\` and merges it. The gate comment says why it is high impact.`);
  await fire(`PR #${number} is high impact and waits for an owner's \`${MERGE_LABEL}\` label`, staleMinutes);
}

// The PR cannot merge as it stands (conflict, or red on the current base): label its ticket
// `rework` so the next attempt picks it up (see needsRework).
async function reworkTicket(pr, why) {
  const n = linkedIssue(pr.body ?? "");
  if (!n) return;
  const issue = await gh.get(`${R}/issues/${n}`);
  if (!needsRework(issue)) return;
  await gh.post(`${R}/issues/${n}/labels`, { labels: [REWORK_LABEL] });
  await gh.post(`${R}/issues/${n}/comments`, { body: `Sent back for rework by the factory gate: PR #${number} ${why}` });
}

// The owners named in the config on the base branch. An issue has no base of its own, so this
// reads the default branch, then the configured run.baseBranch if that differs.
async function ownersForIssues() {
  const fallback = event.repository?.default_branch ?? "main";
  let config = await readBaseConfig(fallback);
  const base = config.run?.baseBranch;
  if (base && base !== fallback) config = await readBaseConfig(base);
  return config.owners;
}

// An issue was labelled `blocked`: post a new comment mentioning the owners (see needsBlockMention).
async function mentionBlocked() {
  const n = event.issue.number;
  const issue = await gh.get(`${R}/issues/${n}`);
  const events = (await gh.paginate(`${R}/issues/${n}/events`)).map((e) => ({ event: e.event, label: e.label?.name, created_at: e.created_at }));
  const comments = await gh.paginate(`${R}/issues/${n}/comments`);
  if (!needsBlockMention({ issue, events, comments })) return log(`#${n}: no new block to mention`);
  // Without a readable config the repo's owner is the one to tell.
  const owners = await ownersForIssues().catch((err) => {
    log(`could not read the owners: ${err.message}`);
    return [repo.split("/")[0]];
  });
  await gh.post(`${R}/issues/${n}/comments`, {
    body: mentionBody(BLOCK_MARKER, owners, `this ticket is \`${BLOCKED_LABEL}\` on a question for you: the **Blocked** comment says what. Answer it in a comment, then remove the \`${BLOCKED_LABEL}\` label so an agent picks the ticket up again.`),
  });
  log(`#${n}: mentioned ${owners.join(", ")}`);
}

async function otherChecks(sha) {
  const runs = await gh.paginate(`${R}/commits/${sha}/check-runs`, "check_runs");
  const statuses = (await gh.get(`${R}/commits/${sha}/status`)).statuses ?? [];
  const latest = new Map();
  for (const r of runs) {
    if (r.name === SELF || r.name === SIBLING) continue;
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
  if (process.env.GITHUB_EVENT_NAME === "issues") {
    if (event.action === "labeled" && event.label?.name === BLOCKED_LABEL && !event.issue?.pull_request) return mentionBlocked();
    return log(`nothing to do for issues.${event.action}`);
  }
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
    result.staleMinutes = config.run?.staleMinutes;
  } catch (err) {
    // Without a readable config the repo's owner is the one to ask.
    result = { risk: "high", reasons: [{ rule: "error", detail: `the classifier failed, so the PR is high impact: ${err.message}`, files: [] }], owners: [repo.split("/")[0]] };
  }
  log(`risk: ${result.risk}`, JSON.stringify(result.reasons));
  await setRiskLabel(result.risk);
  await upsertComment(render(result, "waiting for the other checks…"));

  const checks = await waitForChecks(pr.head.sha);
  pr = await gh.get(`${R}/pulls/${number}`); // fresh: the head may have moved while waiting
  const labels = (pr.labels ?? []).map((l) => l.name);
  const events = (await gh.paginate(`${R}/issues/${number}/events`)).map((e) => ({
    event: e.event, label: e.label?.name, actor: e.actor?.login, created_at: e.created_at,
  }));
  // The head reached GitHub when its first check suite was created (the agent cannot set that).
  const suites = (await gh.get(`${R}/commits/${pr.head.sha}/check-suites`)).check_suites ?? [];
  const headPushedAt = suites.map((s) => s.created_at).filter(Boolean).sort()[0] ?? null;
  const decision = gate({ risk: result.risk, owners: result.owners, draft: pr.draft, labels, events, headPushedAt, checks });
  log(decision.summary);
  if (!decision.merge) {
    await upsertComment(render(result, decision.summary));
    if (decision.stale) {
      await gh.del(`${R}/issues/${number}/labels/${encodeURIComponent(MERGE_LABEL)}`).catch(() => {});
      await mentionOwners(result.owners, `new commits were pushed after the \`${MERGE_LABEL}\` label was added, so the gate removed it. Review the new commits and add it again to merge.`);
    } else if (decision.needsOwner) {
      await askOwners(result.owners, pr.base.ref, result.staleMinutes);
    }
    if (!decision.pass) process.exitCode = 1;
    return;
  }

  const base = pr.base.ref;
  await upsertComment(render(result, `${decision.summary} once it is green on the current \`${base}\`…`));
  const mc = await mergeCheck({ gh, R, number, headSha: pr.head.sha, baseRef: base, deadline: Date.now() + MERGE_CHECK_MS, sleep, log });
  if (!mc.ok) {
    log(mc.summary);
    await upsertComment(render(result, `not merged — ${mc.summary}`));
    if (mc.why !== "timeout") await reworkTicket(pr, mc.summary).catch((err) => log(`could not send the ticket back for rework: ${err.message}`));
    process.exitCode = 1;
    return;
  }

  const merged = await gh.put(`${R}/pulls/${number}/merge`, { merge_method: "squash", sha: pr.head.sha });
  log(`merged #${number}`);
  // The ticket is done: drop the gate's rework label (and `blocked`, which the gate used to set).
  const issue = linkedIssue(pr.body ?? "");
  for (const label of issue ? [REWORK_LABEL, BLOCKED_LABEL] : []) await gh.del(`${R}/issues/${issue}/labels/${label}`).catch(() => {});
  await fire(`PR #${number} merged${issue ? ` (ticket #${issue})` : ""}`, result.staleMinutes);
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
  if (!number) return void (process.exitCode = 1);
  try {
    await upsertComment(`### Factory gate: 🔴 error\n\nThe gate failed, so nothing merges: \`${err.message}\``);
  } catch {}
  process.exitCode = 1;
});
