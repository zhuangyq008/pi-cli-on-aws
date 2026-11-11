// ~/.aws/config 与 ~/.aws/credentials 的安全处理（纯 JS，供 index.ts 与 snapshot.mjs 共用）。
// 自动执行的 aws 进程只读取"白名单重写"后的快照：用宽松规则解析（= 或 : 分隔、任意换行符、缩进续行），
// 只按规范格式写出白名单内的键，因此无论原文件如何书写，credential_process / endpoint_url 等都不会出现在快照中。

// config 中允许保留的键（不会执行命令、不会改写流量或 TLS 信任）
export const SAFE_CONFIG_KEYS = new Set([
  "region", "output", "aws_access_key_id", "aws_secret_access_key", "aws_session_token", "aws_account_id",
  // 不含 web_identity_token_file：它会把任意本地文件内容发送给 STS（IRSA 使用环境变量，不受影响）
  "role_arn", "source_profile", "credential_source", "role_session_name", "external_id", "duration_seconds",
  "sso_session", "sso_account_id", "sso_role_name", "sso_region", "sso_start_url",
  "sso_registration_scopes", "login_session", "sts_regional_endpoints", "retry_mode", "max_attempts",
  "parameter_validation", "cli_binary_format", "cli_timestamp_format", "use_fips_endpoint", "use_dualstack_endpoint",
  "defaults_mode", "account_id_endpoint_mode",
]);
export const SAFE_CREDENTIAL_KEYS = new Set(["aws_access_key_id", "aws_secret_access_key", "aws_session_token", "aws_security_token", "aws_account_id"]);

// 用于在确认框中提示的危险项（无论是否缩进）
const DENIED_KEYS = new Set([
  "credential_process", "ca_bundle", "cli_pager", "cli_auto_prompt", "cli_legacy_plugin_path",
  "ec2_metadata_service_endpoint", "ec2_metadata_service_endpoint_mode",
]);
const NAME = /^[A-Za-z0-9._@+=,-]{1,128}$/;
const MAX_VALUE = 2048;

// Python configparser 会把 \r\n、\r、\n 都当作换行；分隔符为 = 或 :
function* parseLines(text) {
  for (const line of String(text).split(/\r\n|\r|\n/)) {
    if (/^\s*([#;]|$)/.test(line)) continue;
    const section = /^\s*\[\s*([^\]]*?)\s*\]/.exec(line);
    if (section) {
      yield { section: section[1].replace(/\s+/g, " ") };
      continue;
    }
    const kv = /^(\s*)([^\s=:[\]]+)\s*[=:]\s?(.*)$/.exec(line);
    yield kv ? { indented: kv[1].length > 0, key: kv[2].toLowerCase(), value: kv[3].trim() } : { indented: /^\s/.test(line), other: true };
  }
}

export function awsConfigIssues(text) {
  const issues = [];
  for (const item of parseLines(text)) {
    if (item.section !== undefined) {
      const s = item.section.toLowerCase();
      if (s === "plugins" || s.startsWith("services") || s === "preview") issues.push(`[${item.section}]`);
    } else if (item.key && (DENIED_KEYS.has(item.key) || item.key.includes("endpoint_url"))) {
      issues.push(item.key);
    }
  }
  return [...new Set(issues)];
}

function allowedSection(section, kind) {
  if (kind === "credentials") return NAME.test(section);
  if (section === "default") return true;
  const m = /^(profile|sso-session) (.+)$/.exec(section);
  return Boolean(m && NAME.test(m[2]));
}

// 白名单重写：只输出允许的分区与顶层键（缩进的续行 / 嵌套设置全部丢弃），每个分区与键只保留首次出现
export function sanitizeAwsConfig(text, kind) {
  const keys = kind === "credentials" ? SAFE_CREDENTIAL_KEYS : SAFE_CONFIG_KEYS;
  const out = new Map();
  let current;
  for (const item of parseLines(text)) {
    if (item.section !== undefined) {
      current = allowedSection(item.section, kind) ? item.section : undefined;
      if (current && !out.has(current)) out.set(current, new Map());
    } else if (current && item.key && !item.indented && keys.has(item.key)) {
      const value = item.value.replace(/[\x00-\x1f\x7f]/g, "").slice(0, MAX_VALUE);
      const entries = out.get(current);
      if (!entries.has(item.key)) entries.set(item.key, value);
    }
  }
  return [...out].map(([section, entries]) => [`[${section}]`, ...[...entries].map(([k, v]) => `${k} = ${v}`)].join("\n")).join("\n\n") + "\n";
}
