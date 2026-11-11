// pi-cli-bedrock: aws-ops-guard —— pi 扩展，对 AWS 写操作与凭证访问做人工确认（安装到 ~/.pi/agent/extensions/）。
// 安全模型：
//   - AWS MCP run_script：静态分析，读操作放行，写 / 敏感读取 / 无法判断的写法需确认
//   - bash：默认【不带 AWS 凭证】执行（命令前 unset 凭证变量）；严格白名单内的只读 aws CLI 自动带凭证；
//           其他需要 AWS 的命令经人工确认后才带凭证执行
//   - write / edit：修改护栏、pi 配置、包装器、AWS 配置、shell 启动文件需确认
//   - read / grep / find / ls：读取凭证文件需确认
//   - powershell（Windows 上的可选工具）：无法剥离凭证与静态分析，每次都需确认
//   - 非交互模式（pi -p）下所有需要确认的操作一律拒绝
// 模式：confirm（默认）| readonly（拒绝所有需确认的操作）| off（完全关闭，不推荐）
//       启动前 PI_AWS_OPS_GUARD 优先；否则读取 ~/.pi/agent/aws-ops-guard.mode（/aws-guard 写入，/reload 后保留）
// 审计：每次需确认操作的决策写入 ~/.pi/agent/aws-ops-guard.log（JSON Lines）
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { accessSync, appendFileSync, constants, existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, win32 } from "node:path";
import {
  analyzePresignedUrl, analyzeRunScript, assessBashCommand, awsConfigIssues, classifyMcpTool, decideBash,
  isCredentialPath, isProtectedPath, searchesCredentialTree, withoutAwsCredentials,
} from "./classify.ts";
import { isUnderWindowsDir } from "./paths.ts";
import { redact } from "./redact.ts";

type GuardMode = "confirm" | "readonly" | "off";
type Decision = "approved" | "denied" | "blocked-readonly" | "blocked-noninteractive";

interface Inspection {
  readonly reasons: readonly string[];
  readonly preview: string;
  /** bash：批准后是否带 AWS 凭证执行 */
  readonly grantCredentials: boolean;
  /** bash：放行时是否剥离 AWS 凭证 */
  readonly stripCredentials: boolean;
  /** bash：严格白名单命令的重建版本（仅 aws 进程带凭证） */
  readonly rewrite?: string;
}

const RUN_SCRIPT_TOOL = /(^|__)aws___run_script$/;
const PRESIGNED_URL_TOOL = /(^|__)aws___get_presigned_url$/;
const READ_TOOLS: ReadonlySet<string> = new Set(["read", "grep", "find", "ls"]);
const WINDOWS = process.platform === "win32";
const PREVIEW_MAX_LINES = 40;
const PREVIEW_MAX_CHARS = 4000;
const AUDIT_PREVIEW_CHARS = 500;
const MAX_SCRIPT_BYTES = 1_000_000;
const APPROVE = "执行一次";
const REJECT = "拒绝";

const home = homedir();
const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(home, ".pi", "agent");
const auditFile = join(agentDir, "aws-ops-guard.log");
const modeFile = join(agentDir, "aws-ops-guard.mode");

function isWritable(path: string): boolean {
  try {
    accessSync(path, constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

// 路径本身及其所有上级目录都不可被当前用户改写（任一上级可写都能替换路径中的某一级）
function immutablePath(path: string): boolean {
  let current = path;
  for (let i = 0; i < 64; i += 1) {
    if (isWritable(current)) return false;
    const parent = dirname(current);
    if (parent === current) return true;
    current = parent;
  }
  return false;
}

// 自动带凭证执行时使用的 aws 绝对路径：只接受当前用户无法改写的位置（PATH 中的路径、符号链接目标
// 及其所有上级目录都不可写）。例如 Apple Silicon 上 Homebrew 的 /opt/homebrew/bin/aws 归当前用户所有，
// agent 可替换它以窃取凭证，因此不被信任——此时 bash 中的 aws 命令一律需要人工确认。
// Windows：NTFS ACL 无法用 access(W_OK) 判断，只信任 Program Files（仅管理员可写）下的程序。
// 目录取自 HKLM 注册表：用户级环境变量（HKCU\Environment）可以覆盖 ProgramFiles / ProgramW6432
function windowsProgramFilesDirs(): string[] {
  const systemRoot = /^[A-Za-z]:\\Windows$/i.test(process.env.SystemRoot ?? "") ? String(process.env.SystemRoot) : "C:\\Windows";
  const dirs = new Set<string>();
  for (const name of ["ProgramFilesDir", "ProgramW6432Dir"]) {
    try {
      const out = execFileSync(win32.join(systemRoot, "System32", "reg.exe"),
        ["query", "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion", "/v", name], { encoding: "utf8", timeout: 5000, windowsHide: true });
      const match = /REG_(?:EXPAND_)?SZ\s+([A-Za-z]:\\[^\r\n]*?)\s*$/m.exec(out);
      if (match) dirs.add(match[1]);
    } catch {
      // 读取失败时不信任任何目录：bash 中的 aws 命令逐条确认
    }
  }
  return [...dirs];
}

// pi 的 bash 工具实际使用的 Git Bash：项目级 .pi/settings.json 优先，其次全局 settings.json
function readShellPath(file: string): string | undefined {
  const text = readSmallFile(file);
  if (text === undefined) return undefined;
  try {
    const value = (JSON.parse(text) as { shellPath?: unknown }).shellPath;
    return typeof value === "string" ? value : undefined;
  } catch {
    return undefined;
  }
}

// Git for Windows 根目录（...\Git\bin\bash.exe 或 ...\Git\usr\bin\bash.exe）
function windowsGitRoot(cwd: string, trusted: readonly string[]): string | undefined {
  const shell = readShellPath(join(cwd, ".pi", "settings.json")) ?? readShellPath(join(agentDir, "settings.json")) ??
    (trusted[0] ? win32.join(trusted[0], "Git", "bin", "bash.exe") : undefined);
  const match = shell ? /^(.*?)[\\/](usr[\\/])?bin[\\/]bash\.exe$/i.exec(shell) : null;
  return match ? match[1] : undefined;
}

const PROGRAM_FILES = WINDOWS ? windowsProgramFilesDirs() : [];
const isTrustedWindowsPath = (path: string): boolean => PROGRAM_FILES.some((dir) => isUnderWindowsDir(path, dir));

function resolveWindowsAwsPath(): string | undefined {
  for (const dir of PROGRAM_FILES) {
    const candidate = win32.join(dir, "Amazon", "AWSCLIV2", "aws.exe");
    if (existsSync(candidate)) return candidate.replace(/\\/g, "/");
  }
  return undefined;
}

function resolveAwsPath(): string | undefined {
  if (WINDOWS) return resolveWindowsAwsPath();
  for (const dir of (process.env.PATH ?? "").split(":")) {
    if (!dir.startsWith("/") || dir.startsWith(home) || dir.startsWith("/tmp")) continue;
    const candidate = join(dir, "aws");
    try {
      accessSync(candidate, constants.X_OK);
      if (immutablePath(candidate) && immutablePath(realpathSync(candidate))) return candidate;
    } catch {
      // 继续查找下一个 PATH 目录
    }
  }
  return undefined;
}

const awsConfigPaths = (): ReadonlyArray<readonly [string, string]> => [
  ["config", process.env.AWS_CONFIG_FILE ?? join(home, ".aws", "config")],
  ["credentials", process.env.AWS_SHARED_CREDENTIALS_FILE ?? join(home, ".aws", "credentials")],
];

function currentAwsConfigIssues(): string[] {
  return awsConfigPaths().flatMap(([name, path]) => {
    const text = readSmallFile(path);
    return text === undefined ? [] : awsConfigIssues(text).map((issue) => `${name}: ${issue}`);
  });
}

// 自动执行时在命令中调用：生成 ~/.aws 白名单快照（node 使用 pi 自身的绝对路径，脚本位于只读的护栏目录）
// Windows：命令在 Git Bash 中执行，路径使用 C:/... 形式
const toShellPath = (p: string): string => (WINDOWS ? p.replace(/\\/g, "/") : p);
const snapshotRunner = {
  node: toShellPath(process.execPath),
  script: toShellPath(join(agentDir, "extensions", "aws-ops-guard", "snapshot.mjs")),
};
const awsPath = resolveAwsPath();

function parseMode(value: string | undefined): GuardMode | undefined {
  const v = value?.trim().toLowerCase();
  return v === "confirm" || v === "readonly" || v === "off" ? v : undefined;
}

function initialMode(): GuardMode {
  const fromEnv = parseMode(process.env.PI_AWS_OPS_GUARD);
  if (fromEnv) return fromEnv;
  try {
    return (existsSync(modeFile) && parseMode(readFileSync(modeFile, "utf8"))) || "confirm";
  } catch {
    return "confirm";
  }
}

function truncate(text: string): string {
  const lines = text.split("\n");
  const head = lines.slice(0, PREVIEW_MAX_LINES).join("\n").slice(0, PREVIEW_MAX_CHARS);
  return head.length < text.length ? `${head}\n…（已截断，共 ${lines.length} 行）` : head;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function readSmallFile(absPath: string): string | undefined {
  try {
    const stat = statSync(absPath);
    return stat.isFile() && stat.size <= MAX_SCRIPT_BYTES ? readFileSync(absPath, "utf8") : undefined;
  } catch {
    return undefined;
  }
}

// 解析符号链接：文件不存在时解析其最近的已存在父目录。
// Windows 用 realpathSync.native：同时展开 8.3 短文件名（C:\Users\ADMINI~1）与目录联接
const realpathNative = WINDOWS ? realpathSync.native : realpathSync;
function realpathOf(absPath: string): string | undefined {
  let current = absPath;
  const suffix: string[] = [];
  for (let i = 0; i < 64; i += 1) {
    try {
      return join(realpathNative(current), ...suffix);
    } catch {
      const parent = dirname(current);
      if (parent === current) return undefined;
      suffix.unshift(basename(current));
      current = parent;
    }
  }
  return undefined;
}

const PASS: Omit<Inspection, "preview"> = { reasons: [], grantCredentials: false, stripCredentials: false };

// Windows：Git for Windows 安装在当前用户可写的位置（如 %LOCALAPPDATA%\Programs\Git）时，agent 可替换其中的
// bash.exe / env.exe 劫持 bash 工具。此时该目录作为受保护位置，且不启用"只读 aws 自动带凭证"（env.exe 会拿到凭证）
interface WindowsShellTrust {
  readonly writableGitRoot?: string;
  readonly strictAllowed: boolean;
}

function windowsShellTrust(cwd: string): WindowsShellTrust {
  if (!WINDOWS) return { strictAllowed: true };
  const gitRoot = windowsGitRoot(cwd, PROGRAM_FILES);
  const trustedGit = gitRoot !== undefined && isTrustedWindowsPath(gitRoot);
  return { writableGitRoot: trustedGit ? undefined : gitRoot, strictAllowed: trustedGit };
}

function inspectBash(command: string, cwd: string): Inspection {
  const trust = windowsShellTrust(cwd);
  const assessment = assessBashCommand(command, { readFile: readSmallFile, realpath: realpathOf, cwd, home, windowsGitRoot: trust.writableGitRoot });
  const needsAws = assessment.awsLabels.length > 0 || assessment.strict !== undefined;
  const awsConfigWarnings = needsAws ? currentAwsConfigIssues() : [];
  const snapshot = existsSync(snapshotRunner.script) ? snapshotRunner : undefined;
  const decision = decideBash(assessment, { awsPath: trust.strictAllowed ? awsPath : undefined, snapshot, awsConfigWarnings, windows: WINDOWS });
  if (decision.action === "run-with-credentials") return { ...PASS, preview: command, rewrite: decision.command };
  if (decision.action === "run-without-credentials") return { ...PASS, preview: command, stripCredentials: true };
  return { reasons: decision.reasons, preview: command, grantCredentials: decision.grantCredentials, stripCredentials: !decision.grantCredentials };
}

function inspect(toolName: string, input: Record<string, unknown>, cwd: string): Inspection {
  const json = (): string => JSON.stringify(input, null, 2);
  if (RUN_SCRIPT_TOOL.test(toolName)) {
    const code = asString(input.code);
    return { ...PASS, reasons: analyzeRunScript(code).writes, preview: code };
  }
  if (PRESIGNED_URL_TOOL.test(toolName)) return { ...PASS, reasons: analyzePresignedUrl(input), preview: json() };
  if (classifyMcpTool(toolName) === "write") return { ...PASS, reasons: [`AWS MCP 工具 ${toolName}`], preview: json() };
  if (toolName === "bash") return inspectBash(asString(input.command), cwd);
  if (toolName === "powershell") {
    return { ...PASS, reasons: ["PowerShell 命令（护栏无法为其剥离 AWS 凭证或做静态分析）"], preview: asString(input.command) };
  }
  const path = asString(input.path);
  if (toolName === "write" || toolName === "edit") {
    const gitRoot = windowsShellTrust(cwd).writableGitRoot;
    const hit = isProtectedPath(path, home, cwd, { agentDir, realpath: realpathOf, extraRoots: gitRoot ? [gitRoot] : [] });
    return { ...PASS, reasons: hit ? [`修改受保护文件 ${path}`] : [], preview: path };
  }
  if (READ_TOOLS.has(toolName)) {
    const hit = isCredentialPath(path, home, cwd, { agentDir, realpath: realpathOf }) ||
      (toolName === "grep" && searchesCredentialTree(path, home, cwd));
    return { ...PASS, reasons: hit ? [`读取可能包含凭证的位置 ${path || cwd}`] : [], preview: json() };
  }
  return { ...PASS, preview: "" };
}

let lastAuditError: string | undefined;

function audit(tool: string, inspection: Inspection, decision: Decision): void {
  const entry = {
    ts: new Date().toISOString(),
    decision,
    tool,
    reasons: inspection.reasons,
    credentials: inspection.grantCredentials,
    preview: redact(inspection.preview.slice(0, AUDIT_PREVIEW_CHARS)),
    cwd: process.cwd(),
  };
  try {
    mkdirSync(dirname(auditFile), { recursive: true, mode: 0o700 });
    appendFileSync(auditFile, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
    lastAuditError = undefined;
  } catch (error: unknown) {
    // 审计日志失败不阻断运维；记录下来，在 /aws-guard 中提示
    lastAuditError = error instanceof Error ? error.message : String(error);
  }
}

export default function awsOpsGuard(pi: ExtensionAPI): void {
  let mode: GuardMode = initialMode();

  pi.on("tool_call", async (event, ctx) => {
    if (mode === "off") return undefined;
    const input = (event.input ?? {}) as Record<string, unknown>;
    const inspection = inspect(event.toolName, input, ctx.cwd);
    const stripIfNeeded = (): void => {
      // 文档约定：直接修改 event.input 即可改变实际执行的参数
      if (!isToolCallEventType("bash", event)) return;
      if (inspection.rewrite) event.input.command = inspection.rewrite;
      else if (inspection.stripCredentials) event.input.command = withoutAwsCredentials(event.input.command);
    };
    if (inspection.reasons.length === 0) {
      stripIfNeeded();
      return undefined;
    }
    const summary = inspection.reasons.join("；");

    if (mode === "readonly") {
      audit(event.toolName, inspection, "blocked-readonly");
      return { block: true, reason: `aws-ops-guard 处于只读模式，已阻止：${summary}。如需执行，请用户先运行 /aws-guard confirm。` };
    }
    if (!ctx.hasUI) {
      audit(event.toolName, inspection, "blocked-noninteractive");
      return { block: true, reason: `aws-ops-guard：非交互模式下不允许执行需要确认的操作（${summary}）。请在交互式 pi 会话中执行以便人工确认。` };
    }
    const credentialNote = inspection.grantCredentials ? "\n批准后，本条命令将使用当前 AWS 身份的凭证执行。" : "";
    const choice = await ctx.ui.select(
      `⚠️ 需要确认的操作\n\n${inspection.reasons.map((r) => `• ${r}`).join("\n")}\n工具：${event.toolName}${credentialNote}\n\n${truncate(inspection.preview)}\n\n是否执行？`,
      [APPROVE, REJECT],
    );
    if (choice === APPROVE) {
      audit(event.toolName, inspection, "approved");
      stripIfNeeded();
      return undefined;
    }
    audit(event.toolName, inspection, "denied");
    return { block: true, reason: `用户拒绝了该操作（${summary}）。不要换用其他工具或方式绕过，请向用户说明并询问下一步。` };
  });

  pi.registerCommand("aws-guard", {
    description: "查看或切换 AWS 操作护栏：/aws-guard [confirm|readonly]",
    handler: async (args, ctx) => {
      const requested = String(args ?? "").trim().toLowerCase();
      if (requested === "confirm" || requested === "readonly") {
        mode = requested;
        try {
          writeFileSync(modeFile, `${mode}\n`, { mode: 0o600 });
        } catch (error: unknown) {
          ctx.ui.notify(`模式已切换为 ${mode}，但无法持久化：${error instanceof Error ? error.message : String(error)}`, "warning");
        }
      } else if (requested !== "") {
        ctx.ui.notify("用法：/aws-guard [confirm|readonly]（关闭护栏只能在启动前设置 PI_AWS_OPS_GUARD=off）", "warning");
        return;
      }
      const auditNote = lastAuditError ? `；审计日志写入失败：${lastAuditError}` : "";
      ctx.ui.notify(`aws-ops-guard 当前模式：${mode}；审计日志：${auditFile}${auditNote}`, "info");
    },
  });
}
