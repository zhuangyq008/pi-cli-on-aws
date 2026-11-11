// aws-ops-guard 分类逻辑入口（纯函数）：识别需要人工确认的 AWS 写操作。
// 原则：失败即拦截——无法静态确认为只读的调用一律要求确认。真正的安全边界仍是 IAM 权限。
export { classifyOperation, isReadOnlySql, isSensitiveOperation } from "./ops.ts";
export type { OperationKind } from "./ops.ts";
export { analyzeRunScript, localScriptFindings } from "./script.ts";
export type { ScriptAnalysis } from "./script.ts";
export { analyzeBashCommand, assessBashCommand, tokenize } from "./shell.ts";
export type { BashAssessment, ShellOptions } from "./shell.ts";
export { parseStrictReadOnlyAws } from "./strict.ts";
export type { StrictAwsCommand } from "./strict.ts";
export { buildStrictCommand, decideBash, STRIP_AWS_CREDENTIALS, withoutAwsCredentials } from "./policy.ts";
export type { BashDecision, PolicyOptions } from "./policy.ts";
export { isCredentialPath, isProtectedPath, searchesCredentialTree } from "./paths.ts";
export { redact } from "./redact.ts";
export { awsConfigIssues, sanitizeAwsConfig } from "./awsconfig.mjs";
export type { PathOptions } from "./paths.ts";

// AWS MCP Server 中确定只读的工具；run_script / get_presigned_url 由专门的分析函数处理
const AWS_MCP_READ_TOOLS: ReadonlySet<string> = new Set([
  "search_documentation", "read_documentation", "retrieve_skill", "list_regions", "get_regional_availability", "get_tasks",
  "suggest_aws_commands", "recommend",
]);

export function classifyMcpTool(toolName: string): "read" | "write" | "other" {
  const match = /(?:^|__)aws___([a-z0-9_]+)$/.exec(toolName);
  if (!match) return "other";
  return AWS_MCP_READ_TOOLS.has(match[1]) ? "read" : "write";
}

export function analyzePresignedUrl(input: unknown): string[] {
  const requests = (input as { requests?: unknown } | null)?.requests;
  if (!Array.isArray(requests)) return [];
  return requests
    .filter((r): r is { operation: string; bucket?: unknown; key?: unknown } => (r as { operation?: unknown })?.operation !== "download")
    .map((r) => `s3 upload s3://${String(r.bucket ?? "?")}/${String(r.key ?? "?")}`);
}
