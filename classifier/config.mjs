// Validates a project's .factory/config.json against the shape in
// plugins/factory/templates/config.schema.json. Hand-written (zero dependencies); keep the two
// in step. Returns a list of problems; empty means valid.

const TOP = ["version", "owners", "autoMerge", "check", "fix", "setup", "block", "paths", "limits", "review", "run"];
const PATHS = ["migrations", "sensitive", "guardrails", "dependencies", "generated", "tests"];

const isStr = (v) => typeof v === "string" && v.length > 0;
const isInt = (v) => Number.isInteger(v) && v >= 1;

export function validateConfig(c) {
  const p = [];
  if (c === null || typeof c !== "object" || Array.isArray(c)) return ["config must be an object"];
  for (const k of Object.keys(c)) if (!TOP.includes(k)) p.push(`unknown key: ${k}`);
  if (c.version !== 1) p.push("version must be 1");
  if (!Array.isArray(c.owners) || c.owners.length === 0 || !c.owners.every(isStr))
    p.push("owners must be a non-empty list of GitHub logins");
  if (c.autoMerge !== undefined && !["low", "medium"].includes(c.autoMerge))
    p.push("autoMerge must be low or medium (high impact always waits for an owner)");
  if (!isStr(c.check)) p.push("check must be a non-empty command");
  if (c.fix !== undefined) {
    if (!Array.isArray(c.fix)) p.push("fix must be a list");
    else
      c.fix.forEach((f, i) => {
        if (!isStr(f?.glob) || !isStr(f?.command)) p.push(`fix[${i}] needs glob and command`);
      });
  }
  if (c.block !== undefined) {
    if (!Array.isArray(c.block)) p.push("block must be a list");
    else
      c.block.forEach((b, i) => {
        if (!isStr(b?.pattern)) p.push(`block[${i}] needs a pattern`);
      });
  }
  if (c.paths !== undefined) {
    for (const k of Object.keys(c.paths)) {
      if (!PATHS.includes(k)) p.push(`unknown paths key: ${k}`);
      else if (!Array.isArray(c.paths[k]) || !c.paths[k].every(isStr))
        p.push(`paths.${k} must be a list of globs`);
    }
  }
  if (c.limits !== undefined) {
    for (const k of ["lines", "files"])
      if (c.limits[k] !== undefined && !isInt(c.limits[k])) p.push(`limits.${k} must be a positive integer`);
  }
  if (c.run?.maxAttempts !== undefined && !isInt(c.run.maxAttempts)) p.push("run.maxAttempts must be a positive integer");
  if (c.run?.maxTurns !== undefined && !isInt(c.run.maxTurns)) p.push("run.maxTurns must be a positive integer");
  if (c.run?.staleMinutes !== undefined && !isInt(c.run.staleMinutes)) p.push("run.staleMinutes must be a positive integer");
  return p;
}
