// AWS CLI 调用解析：识别服务与操作，并判断读 / 写（供 shell.ts 与 strict.ts 使用）
import { classifyOperation, isReadOnlySql, isSensitiveOperation, SQL_QUERY_OPERATIONS, toPascal } from "./ops.ts";

export const READ_SUFFIX = "（只读）";

const CLI_VALUELESS_FLAGS: ReadonlySet<string> = new Set([
  "--debug", "--no-verify-ssl", "--no-paginate", "--no-sign-request", "--no-cli-pager", "--cli-auto-prompt", "--no-cli-auto-prompt",
]);
function skipCliOptions(words: readonly string[], start: number): number {
  let j = start;
  while (j < words.length && words[j].startsWith("-")) {
    j += CLI_VALUELESS_FLAGS.has(words[j]) || words[j].includes("=") ? 1 : 2;
  }
  return j;
}

function optionValue(args: readonly string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

const S3_VALUED_FLAGS: ReadonlySet<string> = new Set([
  "--exclude", "--include", "--acl", "--storage-class", "--sse", "--sse-kms-key-id", "--sse-c", "--sse-c-key", "--content-type",
  "--cache-control", "--content-disposition", "--content-encoding", "--content-language", "--expires", "--metadata",
  "--metadata-directive", "--grants", "--website-redirect", "--source-region", "--region", "--profile", "--output", "--query",
  "--endpoint-url", "--page-size", "--expected-size", "--request-payer", "--checksum-algorithm", "--checksum-mode", "--color",
  "--cli-read-timeout", "--cli-connect-timeout", "--ca-bundle",
]);

// s3 cp / sync：源为 s3:// 且所有目标都不是 s3:// 时视为下载（读）；"-" 表示输出到 stdout
function classifyS3(op: string, rest: readonly string[]): "read" | "write" {
  if (op === "ls" || op === "presign") return "read";
  if (op !== "cp" && op !== "sync") return "write";
  const positional: string[] = [];
  rest.forEach((w, i) => {
    if (w.startsWith("-") && w !== "-") return;
    if (i > 0 && S3_VALUED_FLAGS.has(rest[i - 1])) return;
    positional.push(w);
  });
  return positional.length >= 2 && positional[0].startsWith("s3://") && !positional.slice(1).some((p) => p.startsWith("s3://"))
    ? "read" : "write";
}

function classifyCli(service: string, op: string, rest: readonly string[]): "read" | "write" {
  if (service === "help" || op === "help" || op === "wait") return "read";
  if (service === "s3") return classifyS3(op, rest);
  if (service === "configure") return op === "list" || op === "list-profiles" ? "read" : "write";
  if (service === "logs" && op === "tail") return "read";
  const pascal = toPascal(op);
  if (SQL_QUERY_OPERATIONS.has(pascal)) {
    // CLI 以最后一次出现的参数为准：出现多个 SQL 参数时一律视为写
    const sqlFlags = rest.filter((w) => w === "--query-string" || w === "--sql" || w === "--statement" || w === "--sqls");
    const sql = optionValue(rest, sqlFlags[0] ?? "--query-string");
    return sqlFlags.length === 1 && sql !== undefined && !sql.startsWith("file:") && isReadOnlySql(sql) ? "read" : "write";
  }
  return classifyOperation(pascal);
}

export interface AwsCall {
  readonly label: string;
  readonly kind: "read" | "write";
  readonly service?: string;
  readonly operation?: string;
}

export function parseAwsInvocation(args: readonly string[]): AwsCall | undefined {
  if (args.length === 0 || args.includes("--version") || args[0] === "help") return undefined;
  const s = skipCliOptions(args, 0);
  const service = args[s];
  const o = skipCliOptions(args, s + 1);
  const op = args[o];
  if (!service || !op) return { label: `aws ${args.join(" ")}（无法解析）`, kind: "write" };
  if (service.startsWith("$") || op.startsWith("$")) return { label: `${service} ${op}（动态）`, kind: "write" };
  if (classifyCli(service, op, args.slice(o + 1)) === "read") return { label: `${service} ${op}${READ_SUFFIX}`, kind: "read", service, operation: op };
  return { label: isSensitiveOperation(op) ? `敏感读取 ${service} ${op}` : `${service} ${op}`, kind: "write", service, operation: op };
}
