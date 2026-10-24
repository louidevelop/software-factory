// The gate decision. Pure: gate(input) → { pass, merge, summary }.
// Low impact passes when every other check is green. High impact additionally needs an
// approval from an OWNER (config.owners, read from the base branch) on the current head
// commit — the machine user has write access, so "any approval" would let it wave its own
// work through. An owner's later "changes requested" overrides their earlier approval.
// Whether the PR is behind its base does not matter here: before merging, the caller checks the
// PR combined with the current base (mergecheck.mjs).
//
// input = { risk, owners, headSha, draft, reviews: [{ user, state, commit_id, submitted_at }],
//           checks: { pending: [name], failed: [name], passed: [name] } }

export function ownerApproval(owners, reviews, headSha) {
  const lower = new Set(owners.map((o) => o.toLowerCase()));
  const latest = new Map();
  for (const r of [...reviews].sort((a, b) => (a.submitted_at ?? "").localeCompare(b.submitted_at ?? ""))) {
    const who = r.user?.toLowerCase();
    if (!who || !lower.has(who)) continue;
    if (r.state === "APPROVED" || r.state === "CHANGES_REQUESTED" || r.state === "DISMISSED") latest.set(who, r);
  }
  const states = [...latest.values()];
  if (states.some((r) => r.state === "CHANGES_REQUESTED")) return { approved: false, why: "an owner requested changes" };
  const fresh = states.find((r) => r.state === "APPROVED" && r.commit_id === headSha);
  if (fresh) return { approved: true, why: `approved by ${fresh.user}` };
  if (states.some((r) => r.state === "APPROVED")) return { approved: false, why: "the owner approval is for an older commit" };
  return { approved: false, why: "waiting for an owner's approval" };
}

export function gate({ risk, owners, headSha, draft, reviews, checks }) {
  if (checks.failed.length) return { pass: false, merge: false, summary: `checks failed: ${checks.failed.join(", ")}` };
  if (checks.pending.length) return { pass: false, merge: false, summary: `checks still running: ${checks.pending.join(", ")}` };
  if (checks.passed.length === 0) return { pass: false, merge: false, summary: "no check ran on this commit; the project's check workflow must run on pull requests" };
  if (risk === "high") {
    const a = ownerApproval(owners, reviews, headSha);
    if (!a.approved) return { pass: false, merge: false, summary: `high impact — ${a.why}` };
  }
  if (draft) return { pass: true, merge: false, summary: "draft PR — not merged until ready for review" };
  return { pass: true, merge: true, summary: risk === "high" ? "high impact, approved by an owner — merging" : "low impact, checks green — merging" };
}
