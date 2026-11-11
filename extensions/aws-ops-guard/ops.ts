// AWS API 操作名分类：读操作白名单（动词前缀），其余一律视为写；获取凭证 / 密钥的"读"视为敏感，需要确认。

export type OperationKind = "read" | "write";

// 前缀后必须紧跟大写字母、数字或结尾，避免 "Getaway" 之类误判
const READ_PREFIX = /^(Get|List|Describe|Search|Lookup|BatchGet|Query|Scan|Select|Filter|Estimate|Preview|Validate|Simulate|Head|View|Download|Detect|Retrieve)(?=[A-Z0-9]|$)/;

// 名称像写操作、实际只读的例外（CloudWatch Logs Insights / Live Tail）
const READ_EXACT: ReadonlySet<string> = new Set(["StartQuery", "StopQuery", "StartLiveTail"]);

// 会签发凭证或返回密钥明文的"读"操作：结果进入模型上下文与会话记录，必须人工确认
const SENSITIVE: ReadonlySet<string> = new Set([
  "GetParameter", "GetParameters", "GetParametersByPath", "GetParameterHistory",
  "GetFunction", "GetFunctionConfiguration", "GetConnection", "GetConnections",
  "GetId", "DownloadDefaultKeyPair", "GetSecretValue", "BatchGetSecretValue",
]);
// 名称中包含这些词的操作通常返回凭证、令牌、密码或私钥
const SENSITIVE_WORDS = /Credential|Password|Token|Secret|AccessDetails|KeyPair|ApiKey|PrivateKey|LoginProfile/;

export function toPascal(name: string): string {
  if (!/^[a-z0-9_-]+$/.test(name)) return name;
  return name
    .split(/[_-]/)
    .filter((part) => part.length > 0)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
}

export function isSensitiveOperation(operation: string): boolean {
  const pascal = toPascal(operation);
  return SENSITIVE.has(pascal) || (READ_PREFIX.test(pascal) && SENSITIVE_WORDS.test(pascal));
}

// 敏感读取也返回 "write"，以触发确认
export function classifyOperation(operation: string): OperationKind {
  const pascal = toPascal(operation);
  if (isSensitiveOperation(pascal)) return "write";
  return READ_EXACT.has(pascal) || READ_PREFIX.test(pascal) ? "read" : "write";
}

const SQL_READ_START = /^[\s(]*(SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN)\b/i;
// REPLACE 不在列表中：SELECT 中的 REPLACE() 字符串函数很常见；以 REPLACE 开头的语句会被 SQL_READ_START 拒绝
const SQL_MUTATING = /\b(CREATE|INSERT|DROP|ALTER|DELETE|UNLOAD|MERGE|UPDATE|MSCK|OPTIMIZE|VACUUM|TRUNCATE|GRANT|REVOKE|INTO|CALL|COPY|ANALYZE|EXECUTE|PREPARE)\b/i;

// Athena / Redshift Data / DynamoDB PartiQL 查询：单条只读 SQL 视为读（CUR 成本分析的常见场景）
export function isReadOnlySql(sql: string): boolean {
  const multipleStatements = /;\s*\S/.test(sql);
  return SQL_READ_START.test(sql) && !SQL_MUTATING.test(sql) && !multipleStatements;
}

// 需要结合 SQL 判断读写的查询类操作
export const SQL_QUERY_OPERATIONS: ReadonlySet<string> = new Set(["StartQueryExecution", "ExecuteStatement", "BatchExecuteStatement"]);
// 各服务携带 SQL 的参数名（Athena QueryString、Redshift Data Sql/Sqls、DynamoDB PartiQL Statement）
export const SQL_PARAM_KEYS = ["QueryString", "Sql", "Sqls", "Statement", "Statements"];
