// The gate decision. Pure: gate(input) → { pass, merge, needsOwner, summary }.
// Low impact passes when every other check is green. High impact additionally needs an OWNER's
// go-ahead (config.owners, read from the base branch): the `merge` label, added by an owner.
// Not a review approval: the owner and the agents act as one GitHub account, and GitHub never
// lets the author of a PR approve it. Agents are kept from adding the label by the blocklist
// hook, and a push after the label removes it (index.mjs), so the go-ahead always covers the
// commits the owner looked at.
// Whether the PR is behind its base does not matter here: before merging, the caller checks the
// PR combined with the current base (mergecheck.mjs).
//
// input = { risk, owners, draft, labels: [name], events: [{ event, label, actor, created_at }],
//           checks: { pending: [name], failed: [name], passed: [name] } }

export const MERGE_LABEL = "merge";

// Whoever added the label most recently decides whether it counts.
export function ownerGoAhead(owners, labels, events) {
  if (!labels.includes(MERGE_LABEL)) return { ok: false, why: `waiting for an owner to add the \`${MERGE_LABEL}\` label` };
  const lower = new Set(owners.map((o) => o.toLowerCase()));
  const last = events
    .filter((e) => e.event === "labeled" && e.label === MERGE_LABEL)
    .sort((a, b) => (a.created_at ?? "").localeCompare(b.created_at ?? ""))
    .at(-1);
  if (!last?.actor || !lower.has(last.actor.toLowerCase())) {
    return { ok: false, why: `the \`${MERGE_LABEL}\` label was added by ${last?.actor ?? "an unknown account"}, not an owner` };
  }
  return { ok: true, why: `\`${MERGE_LABEL}\` added by ${last.actor}` };
}

export function gate({ risk, owners, draft, labels, events, checks }) {
  if (checks.failed.length) return { pass: false, merge: false, summary: `checks failed: ${checks.failed.join(", ")}` };
  if (checks.pending.length) return { pass: false, merge: false, summary: `checks still running: ${checks.pending.join(", ")}` };
  if (checks.passed.length === 0) return { pass: false, merge: false, summary: "no check ran on this commit; the project's check workflow must run on pull requests" };
  if (draft) return { pass: true, merge: false, summary: "draft PR — not merged until ready for review" };
  if (risk === "high") {
    const a = ownerGoAhead(owners, labels, events);
    if (!a.ok) return { pass: false, merge: false, needsOwner: true, summary: `high impact — ${a.why}` };
    return { pass: true, merge: true, summary: `high impact, ${a.why} — merging` };
  }
  return { pass: true, merge: true, summary: "low impact, checks green — merging" };
}
