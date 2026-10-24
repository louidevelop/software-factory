// The merge-time check: right before merging, test the PR combined with the CURRENT base and
// merge only if that combination is green. A PR may be behind its base; it never has to be
// brought up to date first.
//
// Why not "require branches to be up to date": the gate acts with GITHUB_TOKEN, and commits
// pushed with it trigger no workflows, so the gate cannot update a behind PR and re-check it.
// Someone with a real token had to, and PRs sat behind until they did. A workflow_dispatch is
// the one thing GITHUB_TOKEN may start, so the gate builds the combination on a scratch branch
// and dispatches the project's check workflow on it. The PR branch never changes, so an owner's
// approval of the head commit stays valid.
//
// Merges must not interleave: after a green run the base is read again, and if it moved the
// combination is rebuilt and checked again. The merge API cannot pin the base commit, so a merge
// that lands in the moment between that read and the merge call goes unchecked; the caller
// reports it, and `factory start` refuses to start a ticket on a red base.
//
// mergeCheck(opts) → { ok: true, baseSha, checked, url? }
//                  | { ok: false, why: "conflict" | "red" | "timeout", summary }
// Anything unexpected throws; the caller fails closed.

// The project's check workflow (bootstrap writes it; it needs a `workflow_dispatch:` trigger).
export const CHECK_WORKFLOW = "check.yml";
export const scratchBranch = (number) => `factory/merge-check/pr-${number}`;
const START_MS = 3 * 60 * 1000; // a dispatched run that has not appeared by then never will

export async function mergeCheck({
  gh, R, number, headSha, baseRef, deadline, sleep, now = Date.now, pollMs = 15_000, log = () => {},
}) {
  const scratch = scratchBranch(number);
  const dropScratch = () => gh.del(`${R}/git/refs/heads/${scratch}`).catch(() => {});
  const baseHead = async () => (await gh.get(`${R}/branches/${encodeURIComponent(baseRef)}`)).commit.sha;

  try {
    let baseSha = await baseHead();
    for (;;) {
      // Up to date: the PR's own checks, already green, ran on exactly what would land.
      const cmp = await gh.get(`${R}/compare/${baseSha}...${headSha}`);
      if (cmp.behind_by === 0) return { ok: true, baseSha, checked: false };

      await dropScratch();
      await gh.post(`${R}/git/refs`, { ref: `refs/heads/${scratch}`, sha: baseSha });
      let combo;
      try {
        const merged = await gh.post(`${R}/merges`, {
          base: scratch, head: headSha, commit_message: `factory gate: PR #${number} on ${baseRef} ${baseSha.slice(0, 7)}`,
        });
        combo = merged?.sha ?? baseSha; // 204: the base already contains the PR
      } catch (err) {
        if (err.status !== 409) throw err;
        return {
          ok: false, why: "conflict",
          summary: `conflicts with the current \`${baseRef}\` — merge \`${baseRef}\` into the PR branch and resolve it; the gate runs again on that push`,
        };
      }

      log(`checking PR #${number} on ${baseRef} ${baseSha.slice(0, 7)} (${combo.slice(0, 7)})`);
      const run = await runCheck({ gh, R, scratch, sha: combo, deadline, sleep, now, pollMs });
      if (!run) {
        return {
          ok: false, why: "timeout",
          summary: `the check of this PR on the current \`${baseRef}\` did not finish in time — re-run the gate to try again`,
        };
      }
      if (run.conclusion !== "success") {
        return {
          ok: false, why: "red",
          summary: `\`check\` fails on this PR combined with the current \`${baseRef}\` ([run](${run.url})), though each is green alone — merge \`${baseRef}\` into the PR branch and fix it; the gate runs again on that push`,
        };
      }

      const latest = await baseHead();
      if (latest === baseSha) return { ok: true, baseSha, checked: true, url: run.url };
      log(`${baseRef} moved to ${latest.slice(0, 7)} during the check; checking again`);
      baseSha = latest;
    }
  } finally {
    await dropScratch();
  }
}

// Dispatch the check workflow on the scratch branch and wait for its run on `sha`.
// → { conclusion, url }, or null when the deadline passes first.
async function runCheck({ gh, R, scratch, sha, deadline, sleep, now, pollMs }) {
  try {
    await gh.post(`${R}/actions/workflows/${CHECK_WORKFLOW}/dispatches`, { ref: scratch });
  } catch (err) {
    throw new Error(
      `could not run .github/workflows/${CHECK_WORKFLOW} on the PR combined with the base (${err.message}). ` +
        "It needs a `workflow_dispatch:` trigger, and the gate workflow needs `actions: write` (factory sync).",
    );
  }
  const started = now();
  for (;;) {
    const runs = (await gh.get(`${R}/actions/workflows/${CHECK_WORKFLOW}/runs?event=workflow_dispatch&head_sha=${sha}`)).workflow_runs ?? [];
    const run = runs.find((r) => r.head_sha === sha);
    if (run?.status === "completed") return { conclusion: run.conclusion, url: run.html_url };
    if (!run && now() - started > START_MS) throw new Error(`.github/workflows/${CHECK_WORKFLOW} was dispatched but never started a run`);
    if (now() > deadline) return null;
    await sleep(pollMs);
  }
}
