// 严格白名单：可以自动带凭证执行的只读 aws 命令（单条 aws 调用 + 只读过滤器 + 可选重定向）
import { posix } from "node:path";
import { parseAwsInvocation } from "./awscli.ts";
import { toPascal } from "./ops.ts";
import { isProtectedPath } from "./paths.ts";
import type { ShellOptions } from "./shell.ts";

// AWS_PAGER 只允许置空：pager 会以命令方式执行（AWS_PAGER=sh 会把输出当作 shell 命令带凭证执行）
const STRICT_ASSIGNMENT = /^(AWS_REGION|AWS_DEFAULT_REGION)=[a-z0-9-]*$|^AWS_PAGER=$|^AWS_DEFAULT_OUTPUT=(json|text|table|yaml|yaml-stream)$/;

// 通过校验的命令不会原样执行：policy.ts 用校验后的 token 重新拼接命令，且只有 aws 进程获得凭证（过滤器无凭证）。
export interface StrictAwsCommand {
  readonly assignments: readonly string[];
  readonly awsArgs: readonly string[];
  readonly mergeStderr: boolean;
  readonly filters: readonly (readonly string[])[];
  readonly redirect?: { readonly append: boolean; readonly target: string };
}

// 危险全局参数：AWS CLI 接受参数前缀缩写（--endpoint 等同 --endpoint-url），因此任何前缀都拒绝
const STRICT_FORBIDDEN_FLAGS = ["--endpoint-url", "--ca-bundle", "--profile", "--debug", "--no-verify-ssl", "--cli-input-json", "--cli-input-yaml"];
// 会把结果写入本地文件（位置参数 outfile）的操作
const OUTFILE_OPERATIONS: ReadonlySet<string> = new Set([
  "GetObject", "SelectObjectContent", "GetObjectTorrent", "GetJobOutput", "GetExport", "GetSdk", "GetMedia",
  "GetMediaForFragmentList", "GetClip", "GetImages",
]);

interface FilterSpec {
  readonly flags: ReadonlySet<string>;
  readonly valued: ReadonlySet<string>;
  readonly maxPositional: number;
}
const spec = (flags: string[], valued: string[], maxPositional: number): FilterSpec => ({ flags: new Set(flags), valued: new Set(valued), maxPositional });
// 过滤器：只允许列出的选项，不允许文件参数（防止读写本地文件或执行命令）
const FILTER_SPECS: Readonly<Record<string, FilterSpec>> = {
  jq: spec(["-r", "-c", "-S", "-e", "-j", "-a", "-M", "-C", "-s", "-n", "--raw-output", "--compact-output", "--sort-keys", "--exit-status", "--join-output", "--slurp", "--null-input", "--tab"], [], 1),
  head: spec(["-q"], ["-n", "-c"], 0),
  tail: spec(["-q"], ["-n", "-c"], 0),
  grep: spec(["-i", "-v", "-c", "-n", "-o", "-E", "-F", "-w", "-x", "-h", "-q", "-s", "--color=never", "--color=auto"], ["-A", "-B", "-C", "-m", "-e"], 1),
  sort: spec(["-n", "-r", "-u", "-h", "-V", "-f", "-b", "-g", "-M", "-s"], ["-k", "-t"], 0),
  uniq: spec(["-c", "-d", "-u", "-i"], ["-f", "-s", "-w"], 0),
  wc: spec(["-l", "-w", "-c", "-m"], [], 0),
  cut: spec(["-s", "--complement"], ["-d", "-f", "-c", "-b"], 0),
  column: spec(["-t"], ["-s"], 0),
  tr: spec(["-d", "-s", "-c", "-C"], [], 2),
};

function validFilter(stage: readonly string[]): boolean {
  const [cmd, ...args] = stage;
  const s = FILTER_SPECS[cmd === "egrep" || cmd === "fgrep" ? "grep" : cmd];
  if (!s) return false;
  let positional = 0;
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (s.valued.has(a)) {
      i += 1;
      if (i >= args.length) return false;
    } else if (s.flags.has(a) || /^-\d+$/.test(a) && (cmd === "head" || cmd === "tail")) {
      continue;
    } else if (/^-[A-Za-z]{2,}$/.test(a) && [...a.slice(1)].every((c) => s.flags.has(`-${c}`))) {
      continue;
    } else if (a.startsWith("-")) {
      return false;
    } else {
      positional += 1;
    }
  }
  if (positional > s.maxPositional) return false;
  // jq 程序不能加载模块文件
  return !(cmd === "jq" && args.some((a) => /\b(import|include)\b/.test(a)));
}

function validAwsArgs(args: readonly string[]): boolean {
  return args.every((a) => {
    if (/^(file|fileb|https?):\/\//i.test(a) || /=(file|fileb|https?):\/\//i.test(a)) return false;
    if (!a.startsWith("--")) return true;
    const name = a.split("=")[0];
    return !STRICT_FORBIDDEN_FLAGS.some((f) => f.startsWith(name));
  });
}

// 只允许当前目录或 /tmp 下的普通文件名（不跟随符号链接、不进入 /dev、不含 ..）
function validRedirectTarget(target: string, options: ShellOptions): boolean {
  if (!/^(\/tmp\/)?[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(target)) return false;
  const home = options.home ?? "/";
  const cwd = options.cwd ?? "/";
  if (isProtectedPath(target, home, cwd)) return false;
  const abs = posix.resolve(cwd, target);
  const real = options.realpath?.(abs);
  return real === undefined || real === abs;
}

function strictWords(text: string): string[] | undefined {
  const out: string[] = [];
  let word = "";
  let inWord = false;
  const push = (): void => {
    if (inWord) out.push(word);
    word = "";
    inWord = false;
  };
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === "'" || ch === '"') {
      const end = text.indexOf(ch, i + 1);
      if (end < 0) return undefined;
      const inner = text.slice(i + 1, end);
      if (ch === '"' && /[$`\\!]/.test(inner)) return undefined;
      word += inner;
      inWord = true;
      i = end;
    } else if (ch === " " || ch === "\t") {
      push();
    } else if (ch === "|") {
      if (text[i + 1] === "|") return undefined;
      push();
      out.push("|");
    } else if (ch === ">") {
      // 2> 之类的文件描述符重定向不在白名单内（2>&1 已在调用前单独处理）
      if (inWord && /^\d+$/.test(word)) return undefined;
      push();
      if (text[i + 1] === ">") {
        i += 1;
        out.push(">>");
      } else {
        out.push(">");
      }
    } else if (/[A-Za-z0-9_@%+=:,./-]/.test(ch)) {
      word += ch;
      inWord = true;
    } else {
      return undefined;
    }
  }
  push();
  return out;
}

export function parseStrictReadOnlyAws(text: string, options: ShellOptions = {}): StrictAwsCommand | undefined {
  // 2>&1（stderr 并入 stdout）是常见写法，单独识别
  const mergeStderr = /\s2>&1(?=\s*(\||$))/.test(text);
  const words = strictWords(text.replace(/\s2>&1(?=\s*(\||$))/, " ").trim());
  if (!words || words.length === 0) return undefined;
  const redirectAt = words.findIndex((w) => w === ">" || w === ">>");
  let redirect: StrictAwsCommand["redirect"];
  if (redirectAt >= 0) {
    const target = words[redirectAt + 1];
    if (redirectAt !== words.length - 2 || !target || !validRedirectTarget(target, options)) return undefined;
    redirect = { append: words[redirectAt] === ">>", target };
  }
  const body = redirectAt >= 0 ? words.slice(0, redirectAt) : words;
  const stages: string[][] = [[]];
  for (const w of body) {
    if (w === "|") stages.push([]);
    else stages[stages.length - 1].push(w);
  }
  if (stages.some((s) => s.length === 0)) return undefined;
  const [first, ...filters] = stages;
  let i = 0;
  while (i < first.length && STRICT_ASSIGNMENT.test(first[i])) i += 1;
  if (first[i] !== "aws") return undefined;
  const awsArgs = first.slice(i + 1);
  if (!validAwsArgs(awsArgs)) return undefined;
  const call = parseAwsInvocation(awsArgs);
  if (!call || call.kind !== "read" || !call.service || call.service === "configure") return undefined;
  if (call.service === "s3" && call.operation !== "ls") return undefined;
  if (OUTFILE_OPERATIONS.has(toPascal(call.operation ?? ""))) return undefined;
  if (!filters.every(validFilter)) return undefined;
  return { assignments: first.slice(0, i), awsArgs, mergeStderr, filters, redirect };
}
