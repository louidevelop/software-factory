// The gate decision. Pure: gate(input) → { pass, merge, needsOwner, summary }.
// Low impact passes when every other check is green. High impact additionally needs an OWNER's
// go-ahead (config.owners, read from the base branch): the `merge` label, added by an owner.
// Not a review approval: the owner and the agents act as one GitHub account, and GitHub never
// lets the author of a PR approve it. Agents are kept from adding the label by the blocklist
// hook. The label only counts when it was added after the head commit was pushed, so it always
// covers the commits the owner looked at; a stale one is removed and the owner asked again.
// (Judged by time, not by the push event: a push followed at once by a description edit cancels
// the push's gate run.)
// Whether the PR is behind its base does not matter here: before merging, the caller checks the
// PR combined with the current base (mergecheck.mjs).
//
// input = { risk, owners, draft, labels: [name], events: [{ event, label, actor, created_at }],
//           headPushedAt,  // when the head commit reached GitHub (ISO time), null if unknown
//           checks: { pending: [name], failed: [name], passed: [name] } }

export const MERGE_LABEL = "merge";

// Whoever added the label most recently decides whether it counts, and only for the commits
// that were there when they added it.
export function ownerGoAhead(owners, labels, events, headPushedAt) {
  if (!labels.includes(MERGE_LABEL)) return { ok: false, why: `waiting for an owner to add the \`${MERGE_LABEL}\` label` };
  const lower = new Set(owners.map((o) => o.toLowerCase()));
  const last = events
    .filter((e) => e.event === "labeled" && e.label === MERGE_LABEL)
    .sort((a, b) => (a.created_at ?? "").localeCompare(b.created_at ?? ""))
    .at(-1);
  if (!last?.actor || !lower.has(last.actor.toLowerCase())) {
    return { ok: false, why: `the \`${MERGE_LABEL}\` label was added by ${last?.actor ?? "an unknown account"}, not an owner` };
  }
  if (!headPushedAt || new Date(last.created_at) < new Date(headPushedAt)) {
    return { ok: false, stale: true, why: `new commits since the \`${MERGE_LABEL}\` label was added; an owner adds it again after reviewing them` };
  }
  return { ok: true, why: `\`${MERGE_LABEL}\` added by ${last.actor}` };
}

export function gate({ risk, owners, draft, labels, events, headPushedAt, checks }) {
  if (checks.failed.length) return { pass: false, merge: false, summary: `checks failed: ${checks.failed.join(", ")}` };
  if (checks.pending.length) return { pass: false, merge: false, summary: `checks still running: ${checks.pending.join(", ")}` };
  if (checks.passed.length === 0) return { pass: false, merge: false, summary: "no check ran on this commit; the project's check workflow must run on pull requests" };
  if (draft) return { pass: true, merge: false, summary: "draft PR — not merged until ready for review" };
  if (risk === "high") {
    const a = ownerGoAhead(owners, labels, events, headPushedAt);
    if (!a.ok) return { pass: false, merge: false, needsOwner: true, stale: a.stale, summary: `high impact — ${a.why}` };
    return { pass: true, merge: true, summary: `high impact, ${a.why} — merging` };
  }
  return { pass: true, merge: true, summary: "low impact, checks green — merging" };
}
