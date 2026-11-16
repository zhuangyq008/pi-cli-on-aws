// 复用的、当前用户可写的 Node.js / Python 运行时目录（PI_GUARD_RUNTIME_ROOTS：nvm、Homebrew、pyenv 等）。
// pi 以复用的 Node 运行、AWS MCP 代理以复用的 Python 运行，都持有 AWS 凭证：替换其中的解释器即可窃取凭证，
// 因此 bash 中写入这些目录、或用版本管理器安装 / 升级 / 卸载运行时，需要人工确认。
// 判定基于 tokenize 后的命令段（引号内文字不会误触发），默认拒绝：除只读命令外，任何参数（含重定向目标）
// 解析为绝对路径（展开 ~、$HOME、同一命令中的简单变量赋值，跟踪 cd 后的当前目录，并解析符号链接，
// 如 Homebrew 的 /opt/homebrew/opt/node → Cellar）后位于运行时目录内，都需要确认。
// 这是尽力而为的静态检查（无法覆盖任意解释器代码、复杂的变量展开等）；需要强隔离时安装使用 --node private --python managed。
import { posix } from "node:path";

export interface RuntimeOptions {
  readonly roots: readonly string[];
  readonly home: string;
  readonly cwd: string;
  /** 解析符号链接（路径不存在时返回 undefined） */
  readonly realpath?: (abs: string) => string | undefined;
}

// 参数指向运行时目录时仍视为只读的命令（其余命令一律需要确认）
const READ_ONLY_COMMANDS: ReadonlySet<string> = new Set([
  "ls", "cat", "head", "tail", "less", "more", "file", "stat", "which", "type", "echo", "printf", "grep", "egrep", "fgrep", "rg",
  "wc", "du", "df", "readlink", "realpath", "basename", "dirname", "test", "[", "jq", "sort", "uniq", "cut", "diff", "cmp",
  "md5sum", "sha256sum", "shasum", "otool", "ldd", "strings", "od", "xxd", "hexdump", "tree", "export", "true", "false", "find",
]);
// find 的写入 / 执行动作
const FIND_ACTIONS = /^-(delete|exec|execdir|ok|okdir|fprint\w*|fls)$/;
// 内联代码中出现运行时目录即需要确认（eval、sh -c、python -c、node -e、awk 程序等）
const INTERPRETERS = /^(python[\d.]*|node|perl|ruby|php|osascript|bash|sh|zsh|dash|ksh|awk|gawk|mawk|nawk|eval)$/;
// 版本管理器 → 会替换运行时的子命令
const MANAGERS: Readonly<Record<string, ReadonlySet<string>>> = {
  brew: new Set(["install", "reinstall", "upgrade", "uninstall", "remove", "rm", "link", "unlink", "switch", "cleanup", "autoremove", "bundle", "pin", "unpin", "migrate"]),
  nvm: new Set(["install", "uninstall", "alias", "reinstall-packages"]),
  fnm: new Set(["install", "uninstall", "default"]),
  pyenv: new Set(["install", "uninstall", "global"]),
  volta: new Set(["install", "uninstall", "pin", "fetch"]),
  asdf: new Set(["install", "uninstall", "global", "set", "reshim"]),
  mise: new Set(["install", "uninstall", "use", "upgrade", "prune", "global"]),
  n: new Set(["rm", "prune", "latest", "lts", "install", "current", "stable"]),
  corepack: new Set(["enable", "disable", "install", "prepare"]),
};
const PREFIX_COMMANDS: ReadonlySet<string> = new Set(["sudo", "env", "command", "nohup", "nice", "time", "exec", "xargs", "doas"]);
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
const GLOB_OR_VAR = /[*?[{$`]/;

const under = (p: string, root: string): boolean => p === root || p.startsWith(`${root}/`);

// 解析最长的已存在前缀的符号链接，再拼上剩余部分（目标文件可能尚不存在）
function realForm(abs: string, realpath: RuntimeOptions["realpath"]): string | undefined {
  if (!realpath) return undefined;
  let head = abs;
  let tail = "";
  while (head !== "/" && head !== "") {
    const real = realpath(head);
    if (real !== undefined) return tail ? posix.join(real, tail) : real;
    tail = tail ? posix.join(posix.basename(head), tail) : posix.basename(head);
    head = posix.dirname(head);
  }
  return undefined;
}

// 展开 ~、$HOME、${HOME} 与已知变量；无法完全展开时返回 undefined
function expandWord(word: string, home: string, vars: ReadonlyMap<string, string>): string | undefined {
  let w = word === "~" ? home : word.startsWith("~/") ? `${home}${word.slice(1)}` : word;
  w = w.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, name: string) => (name === "HOME" ? home : vars.get(name) ?? m));
  return GLOB_OR_VAR.test(w) ? undefined : w;
}

// 含通配符 / 未知变量的路径：取第一个特殊字符之前的字面前缀
function literalPrefix(word: string, home: string, vars: ReadonlyMap<string, string>): string {
  const partial = word.startsWith("~/") ? `${home}${word.slice(1)}` : word;
  const expanded = partial.replace(/\$\{?(HOME)\}?/g, home).replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, n: string) => vars.get(n) ?? m);
  const idx = expanded.search(GLOB_OR_VAR);
  return idx < 0 ? expanded : expanded.slice(0, idx);
}

function hitsRoot(word: string, cwd: string | undefined, opts: RuntimeOptions, vars: ReadonlyMap<string, string>): boolean {
  if (word === "" || word === "/dev/null" || word.startsWith("-") && !word.includes("=")) return false;
  const value = word.includes("=") && !word.startsWith("/") ? word.slice(word.indexOf("=") + 1) : word; // of=/x、--target=/x
  const expanded = expandWord(value, opts.home, vars);
  if (expanded === undefined) {
    const prefix = literalPrefix(value, opts.home, vars);
    // 前缀太短（$D/bin、*）无法判断，不报；/opt/homebrew/b*/node 这类可以
    if (!prefix.startsWith("/") || prefix.length < 4) return false;
    return opts.roots.some((root) => root.startsWith(prefix) || under(prefix.replace(/\/[^/]*$/, ""), root));
  }
  if (!expanded.startsWith("/") && cwd === undefined) return false;
  const abs = posix.resolve(cwd ?? "/", expanded);
  const real = realForm(abs, opts.realpath);
  return opts.roots.some((root) => under(abs, root) || (real !== undefined && under(real, root)));
}

// 去掉 sudo / env / VAR=... 等前缀，返回命令名所在下标
function commandIndex(words: readonly string[]): number {
  let i = 0;
  while (i < words.length && (PREFIX_COMMANDS.has(words[i] ?? "") || ASSIGNMENT.test(words[i] ?? "") || /^-/.test(words[i] ?? "") && i > 0)) i += 1;
  return i;
}

function segmentWrites(words: readonly string[], cwd: string | undefined, opts: RuntimeOptions, vars: ReadonlyMap<string, string>): boolean {
  // 重定向目标（> / >> / &> 之后的词，或紧贴的 >path）
  for (let i = 0; i < words.length; i += 1) {
    const w = words[i] ?? "";
    if (/^[&\d]*>>?$/.test(w) && hitsRoot(words[i + 1] ?? "", cwd, opts, vars)) return true;
    const glued = /^[&\d]*>>?(.+)$/.exec(w);
    if (glued?.[1] && !glued[1].startsWith("&") && hitsRoot(glued[1], cwd, opts, vars)) return true;
  }
  const at = commandIndex(words);
  const cmd = posix.basename(words[at] ?? "");
  const args = words.slice(at + 1).filter((w) => !/^[&\d]*>>?/.test(w));
  if (INTERPRETERS.test(cmd)) {
    // 内联代码（-c / -e 的参数；eval 与 awk 取全部参数）
    const inline = cmd === "eval" || /awk$/.test(cmd) ? args.join(" ") : args.find((_, j) => /^-[a-zA-Z]*[ce]$/.test(args[j - 1] ?? ""));
    if (inline !== undefined && mentionsRoot(inline, opts)) return true;
  }
  const readOnly = READ_ONLY_COMMANDS.has(cmd) && !(cmd === "find" && args.some((a) => FIND_ACTIONS.test(a)));
  return !readOnly && args.some((a) => hitsRoot(a, cwd, opts, vars));
}

function mentionsRoot(code: string, opts: RuntimeOptions): boolean {
  return opts.roots.some((root) => code.includes(root) ||
    (root.startsWith(`${opts.home}/`) && (code.includes(`~${root.slice(opts.home.length)}`) || code.includes(root.slice(opts.home.length + 1)))));
}

function segmentManager(words: readonly string[]): boolean {
  const at = commandIndex(words);
  const sub = MANAGERS[posix.basename(words[at] ?? "")];
  if (!sub) return false;
  const first = words.slice(at + 1).find((w) => !w.startsWith("-"));
  // n 22 / n 24.1.0：直接按版本号安装并切换
  return first !== undefined && (sub.has(first) || (words[at] === "n" && /^v?\d/.test(first)));
}

export function runtimeFindings(segments: readonly (readonly string[])[], opts: RuntimeOptions): string[] {
  const roots = opts.roots.filter((r) => r.startsWith("/") && r !== "/");
  if (roots.length === 0) return [];
  const o = { ...opts, roots };
  const vars = new Map<string, string>();
  let cwd: string | undefined = opts.cwd;
  let writes = false;
  let manager = false;
  for (const words of segments) {
    const at = commandIndex(words);
    // 仅由赋值组成的段（D=/opt/homebrew、export D=...）记录变量，供后续段展开
    for (const w of words.slice(0, at).concat(words[at] === "export" ? words.slice(at + 1) : [])) {
      const m = ASSIGNMENT.exec(w);
      if (m?.[1] && m[2] !== undefined) {
        const v = expandWord(m[2], opts.home, vars);
        if (v !== undefined) vars.set(m[1], v); else vars.delete(m[1]);
      }
    }
    const cmd = words[at];
    if (cmd === "cd" || cmd === "pushd") {
      const target = words[at + 1];
      const expanded = target === undefined ? opts.home : expandWord(target, opts.home, vars);
      cwd = expanded === undefined || cwd === undefined && !expanded.startsWith("/") ? undefined : posix.resolve(cwd ?? "/", expanded);
      continue;
    }
    writes ||= segmentWrites(words, cwd, o, vars);
    manager ||= segmentManager(words);
  }
  const findings: string[] = [];
  if (writes) findings.push("修改 pi / AWS MCP 代理使用的 Node.js / Python 运行时目录");
  if (manager) findings.push("使用版本管理器安装 / 升级 / 卸载运行时（可能替换 pi 使用的 Node.js / Python）");
  return findings;
}
