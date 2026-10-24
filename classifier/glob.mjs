// The factory's one glob dialect — identical to hooks/lib.sh (factory_glob_to_ere):
// `*` and `**` match any characters INCLUDING `/`, `**/` also matches zero directories,
// `?` matches one character, `{a,b}` matches either. Change both or neither.

const SPECIAL = new Set([".", "[", "]", "(", ")", "+", "^", "$", "|", "\\"]);

export function globToRegExp(glob) {
  let out = "";
  let depth = 0;
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "{") {
      out += "(";
      depth++;
    } else if (c === "}" && depth > 0) {
      out += ")";
      depth--;
    } else if (c === "," && depth > 0) {
      out += "|";
    } else if (glob.startsWith("**/", i)) {
      out += "(.*/)?";
      i += 2;
    } else if (glob.startsWith("**", i)) {
      out += ".*";
      i += 1;
    } else if (c === "*") {
      out += ".*";
    } else if (c === "?") {
      out += ".";
    } else if (SPECIAL.has(c)) {
      out += `\\${c}`;
    } else {
      out += c;
    }
  }
  return new RegExp(`^${out}$`);
}

export function matchesAny(path, globs) {
  return (globs ?? []).some((g) => globToRegExp(g).test(path));
}
