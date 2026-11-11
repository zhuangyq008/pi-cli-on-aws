// bash 命令评估。安全模型（由 index.ts 执行）：
//   - bash 默认【不带 AWS 凭证】执行（护栏在命令前 unset 凭证变量）——分析漏判的命令也无法访问 AWS
//   - autoApprove：严格白名单内的只读 aws CLI（单条命令 + 只读过滤器，无 ; $ 循环 子 shell 等）直接带凭证执行
//   - awsLabels 非空：命令需要 AWS 凭证，人工确认后才带凭证执行
//   - guardFindings 非空：篡改护栏 / 读取凭证 / 持久化安装等，无论是否带凭证都需要人工确认
// 本文件的启发式分析只影响"是否提示"与提示文案；凭证默认剥离保证了漏判时的安全。
import { posix } from "node:path";
import { parseAwsInvocation, READ_SUFFIX } from "./awscli.ts";
import { credentialTextPattern, protectedTextPattern, windowsKey } from "./paths.ts";
import { localScriptFindings } from "./script.ts";
import { parseStrictReadOnlyAws } from "./strict.ts";
import type { StrictAwsCommand } from "./strict.ts";

export type { StrictAwsCommand } from "./strict.ts";

export interface ShellOptions {
  /** 读取脚本文件内容（绝对路径）；无法读取时返回 undefined */
  readonly readFile?: (absPath: string) => string | undefined;
  /** 解析符号链接（重定向目标校验用） */
  readonly realpath?: (absPath: string) => string | undefined;
  readonly cwd?: string;
  readonly home?: string;
  readonly depth?: number;
  /** 默认 process.platform（测试中可指定 win32） */
  readonly platform?: string;
  /** Windows：当前用户可写的 Git for Windows 根目录（改写其中的 bash.exe / env.exe 可劫持 bash 工具） */
  readonly windowsGitRoot?: string;
}

export interface BashAssessment {
  readonly guardFindings: readonly string[];
  readonly awsLabels: readonly string[];
  /** 严格白名单内的只读 aws 命令：自动以"仅 aws 进程带凭证"的方式重建执行 */
  readonly autoApprove: boolean;
  readonly strict?: StrictAwsCommand;
}

const MAX_DEPTH = 3;
const SDK_TEXT = /\b(boto3|botocore|awscli|aws-sdk|aws_sdk)\b|@aws-sdk/;

const RESERVED_WORDS: ReadonlySet<string> = new Set([
  "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "case", "esac", "{", "}", "!", "function", "select", "coproc", "[[", "]]",
]);
const WRAPPERS: ReadonlySet<string> = new Set(["sudo", "env", "time", "nohup", "nice", "timeout", "command", "builtin", "exec", "stdbuf", "xargs", "setsid", "flock", "watch", "parallel"]);
const WRAPPER_FLAGS_WITH_VALUE: ReadonlySet<string> = new Set(["-n", "-I", "-P", "-L", "-d", "-s", "-a", "-E", "-u", "-g", "-k", "-o", "-i", "-e"]);
const SHELLS: ReadonlySet<string> = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
const NODE_LIKE: ReadonlySet<string> = new Set(["node", "deno", "bun", "tsx", "ts-node"]);
const USER_INSTALLERS = /\b(pip3?|python3?\s+-m\s+pip)\s+install\b|\bpipx\s+install\b|\bnpm\s+(i|install)\s+(-g|--global)\b|\buv\s+tool\s+install\b|\b(cargo|go)\s+install\b|\bcrontab\b/;

const IAC_COMMANDS: Readonly<Record<string, ReadonlySet<string>>> = {
  cdk: new Set(["deploy", "destroy", "bootstrap", "import", "migrate", "watch"]),
  cdktf: new Set(["deploy", "destroy"]),
  terraform: new Set(["apply", "destroy", "import"]),
  tofu: new Set(["apply", "destroy", "import"]),
  terragrunt: new Set(["apply", "destroy", "import", "run-all"]),
  sam: new Set(["deploy", "delete", "sync"]),
  pulumi: new Set(["up", "destroy", "refresh", "import"]),
  eksctl: new Set(["create", "delete", "upgrade", "scale", "drain", "set", "unset", "enable"]),
  serverless: new Set(["deploy", "remove"]),
  sls: new Set(["deploy", "remove"]),
  copilot: new Set(["deploy", "delete", "init"]),
  amplify: new Set(["push", "publish", "delete"]),
};
const IAC_LOOKAHEAD = 8;

function unique(items: readonly string[]): string[] {
  return [...new Set(items)];
}

function basename(cmd: string): string {
  return cmd.split("/").pop() ?? cmd;
}

// ---- 分词：按 shell 规则处理引号与反斜杠（a""ws、\aws、aw's' 都还原为 aws），在 ; & | ( ) ` $( 换行处分段 ----
export function tokenize(text: string): string[][] {
  const segments: string[][] = [];
  let words: string[] = [];
  let word = "";
  let inWord = false;
  const endWord = (): void => {
    if (inWord) words.push(word);
    word = "";
    inWord = false;
  };
  const endSegment = (): void => {
    endWord();
    if (words.length > 0) segments.push(words);
    words = [];
  };
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === "\\") {
      if (text[i + 1] !== "\n") {
        word += text[i + 1] ?? "";
        inWord = true;
      }
      i += 1;
    } else if (ch === "'") {
      const end = text.indexOf("'", i + 1);
      const stop = end < 0 ? text.length : end;
      word += text.slice(i + 1, stop);
      inWord = true;
      i = stop;
    } else if (ch === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') {
        if (text[j] === "\\" && j + 1 < text.length) {
          word += text[j + 1];
          j += 2;
        } else {
          word += text[j];
          j += 1;
        }
      }
      inWord = true;
      i = j;
    } else if (ch === "#" && !inWord) {
      const nl = text.indexOf("\n", i);
      i = nl < 0 ? text.length : nl - 1;
    } else if (ch === "$" && text[i + 1] === "(") {
      endSegment();
      i += 1;
    } else if (";&|\n()`".includes(ch)) {
      endSegment();
    } else if (ch === " " || ch === "\t" || ch === "\r") {
      endWord();
    } else if (ch === "<" || ch === ">") {
      endWord();
      let op = ch;
      while (text[i + 1] === "<" || text[i + 1] === ">") {
        i += 1;
        op += text[i];
      }
      words.push(op);
    } else {
      word += ch;
      inWord = true;
    }
  }
  endSegment();
  return segments;
}

// 跳过保留字、变量赋值与包装命令（sudo / env / timeout / xargs ...），返回真正命令所在位置
function commandStart(words: readonly string[]): number {
  let i = 0;
  while (i < words.length) {
    const w = words[i];
    if (RESERVED_WORDS.has(w) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) {
      i += 1;
    } else if (WRAPPERS.has(basename(w)) && i + 1 < words.length) {
      i += 1;
      while (i < words.length && (words[i].startsWith("-") || /^\d+[smhd]?$/.test(words[i]))) {
        i += WRAPPER_FLAGS_WITH_VALUE.has(words[i]) ? 2 : 1;
      }
    } else {
      return i;
    }
  }
  return i;
}

function readScript(path: string, options: ShellOptions): string | undefined {
  const home = options.home ?? "/";
  const expanded = path.startsWith("~/") ? `${home}${path.slice(1)}` : path;
  return options.readFile?.(posix.resolve(options.cwd ?? "/", expanded));
}

function scriptLang(content: string, hint: string): "python" | "node" | "shell" | "other" {
  const shebang = content.startsWith("#!") ? content.split("\n")[0] : "";
  if (/python/.test(shebang) || /\.py$/.test(hint)) return "python";
  if (/node|deno|bun/.test(shebang) || /\.(m?js|ts)$/.test(hint)) return "node";
  if (/sh\b/.test(shebang) || /\.(sh|bash)$/.test(hint) || shebang === "") return "shell";
  return "other";
}

const EMPTY: BashAssessment = { guardFindings: [], awsLabels: [], autoApprove: false };

function splitScriptFindings(findings: readonly string[], name: string): BashAssessment {
  const sdk = findings.filter((f) => f.includes("AWS SDK")).map((f) => `${name}：${f}`);
  const guard = findings.filter((f) => f.includes("受保护") || f.includes("凭证")).map((f) => `${name}：${f}`);
  return { guardFindings: guard, awsLabels: sdk, autoApprove: false };
}

// 脚本文件：读取内容分析（仅用于判断是否需要 AWS 凭证与提示文案；读不到时按无凭证执行）
function assessScriptFile(path: string, options: ShellOptions, forced?: "python" | "node" | "shell"): BashAssessment {
  const content = readScript(path, options);
  if (content === undefined || content.includes("\u0000")) return EMPTY;
  const lang = forced ?? scriptLang(content, path);
  if (lang === "shell") return assessBashCommand(content, { ...options, depth: (options.depth ?? 0) + 1 });
  if (lang === "other") return EMPTY;
  return splitScriptFindings(localScriptFindings(content, lang), path);
}

function firstFileArg(args: readonly string[]): string | undefined {
  return args.find((w) => w === "-" || (!w.startsWith("-") && !/^\d*[<>]/.test(w)));
}

function assessInterpreter(base: string, args: readonly string[], whole: string, options: ShellOptions): BashAssessment {
  const lang = NODE_LIKE.has(base) ? "node" : "python";
  const inlineFlags = lang === "python" ? ["-c"] : ["-e", "--eval", "-p", "--print"];
  const inline = args.findIndex((w) => inlineFlags.includes(w));
  if (inline >= 0) return splitScriptFindings(localScriptFindings(args.slice(inline + 1).join(" "), lang), `${base} 内联脚本`);
  if (lang === "python" && args[0] === "-m") return EMPTY;
  const file = firstFileArg(args);
  if (file === undefined || file === "-") return splitScriptFindings(localScriptFindings(whole, lang), `${base} 标准输入脚本`);
  return assessScriptFile(file, options, lang);
}

function merge(parts: readonly BashAssessment[]): BashAssessment {
  return {
    guardFindings: unique(parts.flatMap((p) => p.guardFindings)),
    awsLabels: unique(parts.flatMap((p) => p.awsLabels)),
    autoApprove: false,
  };
}

// Windows 上可以绕过 bash 文本检查的解释器与系统工具：字符串拼接（'.a'+'ws'）、^ 转义、-EncodedCommand、
// 修改用户环境变量（setx / reg，可改写 ProgramFiles 等）。从 bash 中调用时一律需要确认
const WINDOWS_ESCAPES: ReadonlySet<string> = new Set([
  "powershell", "pwsh", "powershell_ise", "cmd", "wscript", "cscript", "mshta", "certutil", "reg", "regedit", "setx",
  "rundll32", "regsvr32", "bitsadmin", "schtasks", "wmic", "msiexec", "start", "runas", "forfiles", "bash", "wsl",
]);

function windowsCommandName(cmd: string): string {
  return (cmd.split(/[\\/]/).pop() ?? "").toLowerCase().replace(/\.(exe|com|bat|cmd)$/, "");
}

function assessCommandWord(cmd: string, args: readonly string[], whole: string, options: ShellOptions): BashAssessment {
  const base = basename(cmd);
  const guard: string[] = [];
  if ((options.platform ?? process.platform) === "win32") {
    const name = windowsCommandName(cmd);
    // 当前 Git Bash 内的 bash 由下方的 SHELLS 分支递归分析；带路径或 .exe 后缀的 bash 可能是其他 shell（如 WSL）
    if (WINDOWS_ESCAPES.has(name) && !(name === "bash" && cmd === "bash")) guard.push(`调用 Windows 命令解释器 / 系统工具 ${name}（无法静态分析）`);
  }
  const aws: string[] = [];
  const iac = IAC_COMMANDS[base];
  if (iac) {
    const hit = args.slice(0, IAC_LOOKAHEAD).find((w) => iac.has(w));
    aws.push(hit ? `${base} ${hit}` : `${base} ${args.find((w) => !w.startsWith("-")) ?? ""}`.trim() + READ_SUFFIX);
  }
  if (base === "pi") guard.push("嵌套启动 pi");
  if (base === "ps" && args.some((a) => !a.startsWith("-") && a.includes("e"))) guard.push("ps e 显示进程环境变量（可能包含凭证）");
  let nested: BashAssessment = EMPTY;
  if (SHELLS.has(base)) {
    const inline = args.indexOf("-c");
    const file = firstFileArg(args);
    if (inline >= 0) nested = assessBashCommand(args.slice(inline + 1).join(" "), { ...options, depth: (options.depth ?? 0) + 1 });
    else if (file) nested = assessScriptFile(file, options, "shell");
  } else if (base === "source" || base === ".") {
    if (args[0]) nested = assessScriptFile(args[0], options, "shell");
  } else if (/^python(\d+(\.\d+)?)?$/.test(base) || NODE_LIKE.has(base)) {
    nested = assessInterpreter(base, args, whole, options);
  } else if (/^(\.{1,2}|~)?\//.test(cmd) && !/^\/(usr|bin|sbin)\//.test(cmd)) {
    nested = assessScriptFile(cmd, options);
  }
  return merge([{ guardFindings: guard, awsLabels: aws, autoApprove: false }, nested]);
}

// Windows 会忽略路径段末尾的 . 与空格（~/.aws./credentials），":stream" 指向 NTFS 备用数据流（~/.aws:x/credentials）；
// 去掉后再做文本检查
function windowsCanonicalText(text: string): string {
  return text.replace(/(\.[\w-]+)(?::[^\s/:]*|[. ]+)(?=\/|\s|$)/g, "$1");
}

// MSYS 根目录（即 Git for Windows 安装目录）下的系统文件：/usr/bin/env.exe、/bin/bash.exe、/etc/profile ...
const MSYS_ROOT_PATH = /(^|[\s=;|&(<>])\/(usr|bin|etc|ucrt64|mingw64|clangarm64|cmd)(\/|\s|$)/i;
const WRITE_VERBS = /(^|[\s;|&(])(cp|mv|ln|install|tee|rm|rmdir|chmod|dd|truncate|rsync|unzip|tar|curl|wget|touch|mkdir)\b|>|\bsed\s+-\w*i/;

function windowsTextFindings(slashed: string, joined: string, options: ShellOptions): string[] {
  const findings: string[] = [];
  const gitRoot = options.windowsGitRoot ? windowsKey(options.windowsGitRoot) : undefined;
  if (gitRoot) {
    const lower = slashed.toLowerCase();
    const mentionsRoot = lower.includes(gitRoot) || lower.includes("/programs/git") || lower.includes(gitRoot.replace(/^([a-z]):/, "/$1"));
    if (mentionsRoot || (MSYS_ROOT_PATH.test(slashed) && WRITE_VERBS.test(joined))) {
      findings.push("修改 Git for Windows 安装目录（bash 工具运行于其中）");
    }
  }
  return findings;
}

// 用通配符或变量拼出的隐藏目录路径（~/.a*/config、~/$d/config）可能指向受保护位置，文本检查无法覆盖
// （只匹配路径中的隐藏目录：其后还有 "/"，或其前是 "/"；不误伤以 "." 开头的 jq 程序）
const HIDDEN_PATH_PATTERN = /(^|\/)\.[^/\s]*[*?[{][^/\s]*\/|\/\.[^/\s]*[*?[{][^/\s]*$|^(~|\$HOME|\$\{HOME\})\/.*[$*?[{]/;

// Windows：8.3 短文件名（AWS~1、PI~1、BASHRC~1）可指向受保护位置，无论是否带路径前缀；~ 后的数字也可能来自展开
// （分词器会把 $((...)) 切开，留下以 ~ 结尾的词，同样视为命中）
const SHORT_NAME = /(^|[\\/])[^\s\\/~]{1,8}~([\d$`{(]|$)/;
// git 修订写法（HEAD~、HEAD~1、origin/main~3、main~1..HEAD）：整个参数以 ~N 结尾
const GIT_REVISION = /^[\w@{}./^-]*~\d*(\^\d*)?(\.\.\.?[\w@{}./^~-]*)?$/;
// 让 git 读取任意文件或目录的子命令 / 选项：出现时不放行任何 ~N 参数
const GIT_FILE_ACCESS: ReadonlySet<string> = new Set(["--no-index", "--file", "-f", "-C", "--git-dir", "--work-tree", "hash-object", "config", "grep"]);

// 只有 git 命令中、且不涉及任意文件访问时，修订写法的参数才不视为 8.3 短文件名
function isShortNameWord(word: string, isGit: boolean, gitFileAccess: boolean): boolean {
  if (!SHORT_NAME.test(word)) return false;
  return !(isGit && !gitFileAccess && GIT_REVISION.test(word));
}

function windowsSegmentFindings(words: readonly string[], start: number): string[] {
  const findings: string[] = [];
  const cmd = words[start];
  const isGit = cmd !== undefined && windowsCommandName(cmd) === "git";
  const gitFileAccess = isGit && words.slice(start + 1).some((w) => GIT_FILE_ACCESS.has(w) || /^--(file|git-dir|work-tree)=/.test(w));
  if (cmd !== undefined && words.some((w) => isShortNameWord(w, isGit, gitFileAccess))) {
    findings.push("使用 8.3 短文件名（可能指向受保护位置）");
  }
  // 命令名来自变量 / 命令替换 / eval（c=cmd; $c /c ...）时无法判断实际执行的程序
  if (cmd !== undefined && (/[$`]/.test(cmd) || cmd === "eval")) findings.push("命令名由变量、命令替换或 eval 生成（无法静态判断）");
  // 任意位置出现的解释器（find -exec powershell、xargs cmd ...）
  const escape = words.map(windowsCommandName).find((name, i) => WINDOWS_ESCAPES.has(name) && !(name === "bash" && words[i] === "bash"));
  if (escape) findings.push(`调用 Windows 命令解释器 / 系统工具 ${escape}（无法静态分析）`);
  return findings;
}

function assessSegment(words: readonly string[], whole: string, options: ShellOptions): BashAssessment {
  // 任意位置出现的 aws（find -exec aws、for ... do aws ...、/usr/bin/env aws ...）都视为 AWS 调用
  const aws: string[] = [];
  words.forEach((w, i) => {
    // Windows 上也可能写作 aws.exe、C:/Program Files/Amazon/AWSCLIV2/aws.exe
    if (/(^|[/\\])aws(\.exe)?$/i.test(w)) {
      const call = parseAwsInvocation(words.slice(i + 1));
      if (call) aws.push(call.label);
    }
  });
  const start = commandStart(words);
  const cmd = words[start];
  const command = cmd === undefined ? EMPTY : assessCommandWord(cmd, words.slice(start + 1), whole, options);
  const hidden = words.some((w) => HIDDEN_PATH_PATTERN.test(w)) ? ["用通配符或变量访问隐藏目录（可能指向受保护位置）"] : [];
  const windows = (options.platform ?? process.platform) === "win32" ? windowsSegmentFindings(words, start) : [];
  return merge([{ guardFindings: [...hidden, ...windows], awsLabels: aws, autoApprove: false }, command]);
}

export function assessBashCommand(command: string, options: ShellOptions = {}): BashAssessment {
  if ((options.depth ?? 0) > MAX_DEPTH) return { guardFindings: [], awsLabels: ["嵌套层级过深（无法静态判断）"], autoApprove: false };
  const joined = command.replace(/\\\r?\n/g, " ");
  // 去掉引号与反斜杠后再做全文检查，防止 .p"i"、AWS_CONTAINER\_ 之类的拆分；
  // 另检查把反斜杠换成 / 的版本：Windows 路径 'C:\Users\me\.aws\credentials'、%USERPROFILE%\.pi
  const squashed = joined.replace(/["'\\]/g, "");
  const slashed = joined.replace(/["']/g, "").replace(/\\/g, "/");
  const windows = (options.platform ?? process.platform) === "win32";
  const variants = windows ? [squashed, slashed, ...[squashed, slashed].map(windowsCanonicalText)] : [squashed, slashed];
  const protectedText = protectedTextPattern(options.platform);
  const credentialText = credentialTextPattern(options.platform);
  const guard: string[] = [];
  if (variants.some((v) => protectedText.test(v))) guard.push("访问 pi / 护栏 / AWS 配置 / shell 启动文件等受保护位置");
  if (variants.some((v) => credentialText.test(v))) guard.push("访问 AWS 凭证");
  if (windows) guard.push(...windowsTextFindings(slashed, joined, options));
  if (USER_INSTALLERS.test(squashed)) guard.push("安装软件或计划任务到用户环境（可能覆盖 ~/.local/bin 中的命令）");
  const sdk = SDK_TEXT.test(squashed) ? ["使用 AWS SDK（无法静态判断）"] : [];
  const segments = merge(tokenize(joined).map((words) => assessSegment(words, joined, options)));
  const guardFindings = unique([...guard, ...segments.guardFindings]);
  const awsLabels = unique([...sdk, ...segments.awsLabels]);
  const strict = guardFindings.length === 0 && (options.depth ?? 0) === 0 ? parseStrictReadOnlyAws(joined, options) : undefined;
  return { guardFindings, awsLabels, autoApprove: strict !== undefined, ...(strict ? { strict } : {}) };
}

// 兼容入口：返回"带凭证执行时需要确认"的原因（护栏发现 + 非只读的 AWS 操作）
export function analyzeBashCommand(command: string, options: ShellOptions = {}): string[] {
  const { guardFindings, awsLabels } = assessBashCommand(command, options);
  return unique([...guardFindings, ...awsLabels.filter((label) => !label.endsWith(READ_SUFFIX))]);
}
