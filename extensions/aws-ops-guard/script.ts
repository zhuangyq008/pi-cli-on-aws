// aws___run_script 代码分析（失败即拦截）：只有所有 AWS 调用都是"字面量操作名的直接 call_boto3 读调用"时才放行。
// 不剥离注释、不解析字符串：注释/字符串里出现的写操作名会导致多一次确认（误报），但不会漏拦。
import { classifyOperation, isReadOnlySql, SQL_PARAM_KEYS, SQL_QUERY_OPERATIONS, toPascal } from "./ops.ts";
import { CREDENTIAL_TEXT, PROTECTED_TEXT } from "./paths.ts";

export interface ScriptAnalysis {
  readonly reads: readonly string[];
  readonly writes: readonly string[];
}

// 无法可靠静态分析的写法：出现即要求确认
const RISKY_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/(?<![.\w])(exec|eval|compile)\s*\(/, "动态执行代码（exec/eval/compile）"],
  // getattr 已被 run_script 沙箱在服务端禁用，不再重复拦截（避免注释中出现该词导致误报）
  [/\b(__import__|importlib|setattr|delattr)\b|(?<![.\w])(globals|locals|vars)\s*\(/, "反射或动态导入"],
  [/__(?!name__|main__)\w+__/, "反射访问内部属性（__globals__ / __dict__ 等）"],
  [/\bpartial\s*\(|functools\.partial/, "partial 包装调用"],
  [/\b(boto3|botocore|awscli)\b/, "直接使用 boto3/botocore"],
  [/subprocess|\bos\.(system|popen|exec\w*|spawn\w*|posix_spawn\w*)\b|\bpty\.spawn\b|\bpexpect\b/, "启动子进程"],
];

const HELPER_MODULES = ["aws_mcp", "aws_serverless"];
const HELPER_READ_VERBS: ReadonlySet<string> = new Set([
  "get", "list", "describe", "search", "diagnose", "find", "analyze", "lookup", "query", "fetch", "read",
  "check", "inspect", "summarize", "explain", "help", "estimate", "compare", "show", "count", "calculate", "validate",
]);

// 字面量必须是完整的参数值：闭合引号后只能是 "," 或 ")"（拒绝 "List" + x、"A" if c else "B" 等表达式）
const LITERAL_OP = /^operation_name\s*=\s*(["'])([A-Za-z][A-Za-z0-9_]*)\1\s*(?=[,)]|$)/;
// Python 字符串字面量（含三引号）
const PY_STRING = String.raw`(?:"""([\s\S]*?)"""|'''([\s\S]*?)'''|"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')`;

function unique(items: readonly string[]): string[] {
  return [...new Set(items)];
}

// 从 start（"(" 之后）开始，返回配对的 ")" 之前的参数文本及其结束位置
function extractCallArgs(code: string, start: number): { readonly text: string; readonly end: number } {
  let depth = 1;
  let quote: string | null = null;
  for (let i = start; i < code.length; i += 1) {
    const ch = code[i];
    if (quote) {
      if (ch === "\\") i += 1;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') quote = ch;
    else if (ch === "(" || ch === "[" || ch === "{") depth += 1;
    else if (ch === ")" || ch === "]" || ch === "}") {
      depth -= 1;
      if (depth === 0) return { text: code.slice(start, i), end: i };
    }
  }
  return { text: code.slice(start), end: code.length };
}

function literalKwarg(args: string, name: string): string | undefined {
  return new RegExp(`\\b${name}\\s*=\\s*(["'])([A-Za-z0-9_.-]+)\\1\\s*(?=[,)]|$)`).exec(args)?.[2];
}

// SQL 查询类操作：该次调用参数中的每个 SQL 参数都是完整的字面量只读 SQL 时才视为读
// （闭合引号后必须是 , } ) 或换行，拒绝 "SELECT 1" + "; DROP ..." 之类的拼接）
function sqlIsReadOnly(callArgs: string): boolean {
  const keyPattern = SQL_PARAM_KEYS.join("|");
  const keys = [...callArgs.matchAll(new RegExp(`\\b(${keyPattern})\\b`, "g"))].length;
  const literal = new RegExp(`["']?\\b(${keyPattern})\\b["']?\\s*[:=]\\s*${PY_STRING}\\s*(?=[,})\\n]|$)`, "g");
  const values = [...callArgs.matchAll(literal)].map((m) => m[2] ?? m[3] ?? m[4] ?? m[5] ?? "");
  return keys > 0 && values.length === keys && values.every((sql) => isReadOnlySql(sql));
}

function classifyCall(op: string, callArgs: string): "read" | "write" {
  if (SQL_QUERY_OPERATIONS.has(op)) return sqlIsReadOnly(callArgs) ? "read" : "write";
  return classifyOperation(op);
}

function analyzeCalls(code: string): { reads: string[]; writes: string[]; ranges: Array<readonly [number, number]> } {
  const reads: string[] = [];
  const writes: string[] = [];
  const ranges: Array<readonly [number, number]> = [];
  for (const m of code.matchAll(/\bcall_boto3\b(\s*\()?/g)) {
    const index = m.index ?? 0;
    if (!m[1]) {
      writes.push("call_boto3 别名或间接调用");
      continue;
    }
    const { text, end } = extractCallArgs(code, index + m[0].length);
    ranges.push([index, end]);
    const service = literalKwarg(text, "service_name") ?? "?";
    const opMatches = [...text.matchAll(/\boperation_name\b/g)];
    const literal = opMatches.length === 1 ? LITERAL_OP.exec(text.slice(opMatches[0].index)) : null;
    if (!literal || /\*\*/.test(text)) {
      writes.push(`${service}:call_boto3（动态或缺失 operation_name）`);
      continue;
    }
    const op = toPascal(literal[2]);
    (classifyCall(op, text) === "read" ? reads : writes).push(`${service}:${op}`);
  }
  return { reads, writes, ranges };
}

// 调用之外出现的 operation_name（例如参数字典）：非字面量视为动态，字面量写操作同样计入
function analyzeLooseOperationNames(code: string, ranges: ReadonlyArray<readonly [number, number]>): string[] {
  const writes: string[] = [];
  for (const m of code.matchAll(/\boperation_name\b/g)) {
    const index = m.index ?? 0;
    if (ranges.some(([start, end]) => index > start && index < end)) continue;
    const literal = LITERAL_OP.exec(code.slice(index));
    if (!literal) writes.push("operation_name 通过变量或字典传递（动态）");
    else if (classifyOperation(toPascal(literal[2])) === "write") writes.push(`?:${toPascal(literal[2])}`);
  }
  return writes;
}

function analyzeHelpers(code: string): string[] {
  const writes: string[] = [];
  if (/\bfrom\s+aws_\w+\s+import\b|\bimport\s+aws_\w+\s+as\b/.test(code)) writes.push("aws_* 辅助模块别名导入");
  const imported = [...code.matchAll(/\bimport\s+(aws_\w+)/g)].map((m) => m[1]);
  const modules = unique([...HELPER_MODULES, ...imported]).join("|");
  for (const m of code.matchAll(new RegExp(`\\b(${modules})\\b((?:\\.\\w+)*)(\\s*\\()?`, "g"))) {
    const before = code.slice(Math.max(0, (m.index ?? 0) - 7), m.index);
    if (/import\s+$/.test(before)) continue;
    const path = m[2].split(".").filter(Boolean);
    if (path.length === 0 || !m[3]) {
      writes.push(`${m[1]}${m[2]} 别名或间接调用`);
      continue;
    }
    const fn = path[path.length - 1];
    if (!HELPER_READ_VERBS.has(fn.split("_")[0])) writes.push(`${m[1]}${m[2]}`);
  }
  return writes;
}

export function analyzeRunScript(source: string): ScriptAnalysis {
  // Python 会对标识符做 NFKC 规范化（全角 ｃall_boto3 == call_boto3），分析前同样规范化
  const code = source.normalize("NFKC");
  const risky = RISKY_PATTERNS.filter(([pattern]) => pattern.test(code)).map(([, label]) => label);
  const calls = analyzeCalls(code);
  return {
    reads: unique(calls.reads),
    writes: unique([...calls.writes, ...analyzeLooseOperationNames(code, calls.ranges), ...analyzeHelpers(code), ...risky]),
  };
}

// 本地脚本（bash 中通过 python/node 执行）：只要可能触达 AWS 或启动子进程就要求确认
export function localScriptFindings(content: string, lang: "python" | "node" | "other"): string[] {
  const findings: string[] = [];
  if (/\b(boto3|botocore|awscli|aws-sdk|aws_sdk)\b|@aws-sdk/.test(content)) findings.push(`${lang} 脚本使用 AWS SDK`);
  const subprocess = lang === "node"
    ? /child_process|\b(execSync|spawnSync|execFile)\b/
    : /subprocess|\bos\.(system|popen|exec\w*|spawn\w*|posix_spawn\w*)\b|\bpty\.spawn\b|\bpexpect\b|child_process/;
  if (subprocess.test(content)) findings.push(`${lang} 脚本启动子进程`);
  if (PROTECTED_TEXT.test(content)) findings.push(`${lang} 脚本访问受保护位置`);
  if (CREDENTIAL_TEXT.test(content)) findings.push(`${lang} 脚本访问 AWS 凭证`);
  if (lang === "other") findings.push("执行无法识别的脚本");
  return findings;
}
