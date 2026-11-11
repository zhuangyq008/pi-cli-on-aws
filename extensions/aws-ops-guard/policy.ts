// bash 执行策略（纯函数）：根据评估结果决定带 / 不带 AWS 凭证执行，或需要人工确认。
//   - run-with-credentials：严格白名单内的只读 aws 命令。不执行原文，而是用校验后的 token 重新拼接，
//     且只有 aws 进程获得凭证（过滤器、重定向都在无凭证环境中）
//   - run-without-credentials：普通命令，剥离全部 AWS 凭证后执行
//   - confirm：需要人工确认；grantCredentials 表示批准后带凭证执行
import type { BashAssessment } from "./shell.ts";
import type { StrictAwsCommand } from "./strict.ts";

export type BashDecision =
  | { readonly action: "run-with-credentials"; readonly command: string }
  | { readonly action: "run-without-credentials" }
  | { readonly action: "confirm"; readonly reasons: readonly string[]; readonly grantCredentials: boolean };

export interface PolicyOptions {
  /** aws CLI 的绝对路径（当前用户不可写）；未提供时不启用自动带凭证 */
  readonly awsPath?: string;
  /** 在执行时生成 ~/.aws 白名单快照的命令（node 绝对路径 + snapshot.mjs）；未提供时不启用自动带凭证 */
  readonly snapshot?: { readonly node: string; readonly script: string };
  /** ~/.aws 配置中的危险项（credential_process / endpoint_url ...），在确认框中提示 */
  readonly awsConfigWarnings?: readonly string[];
  /** Windows（Git Bash）：AWS CLI 的 ~ 取自 USERPROFILE 而非 HOME */
  readonly windows?: boolean;
}

// 未获授权的 bash 命令执行前清除所有 AWS 凭证来源（环境变量、共享配置 / 凭证文件、IMDS）
const CREDENTIAL_VARS = [
  "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_CONTAINER_AUTHORIZATION_TOKEN",
  "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN",
  "AWS_ACCESS_KEY", "AWS_SECRET_KEY", "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN",
  "AWS_ROLE_SESSION_NAME", "AWS_BEARER_TOKEN_BEDROCK",
];
export const STRIP_AWS_CREDENTIALS =
  `unset ${CREDENTIAL_VARS.join(" ")}; export AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true # aws-ops-guard: 本命令未获授权使用 AWS 凭证`;

// 自动路径中只对 aws 进程恢复的变量：凭证 + IMDS 开关（配置文件改为指向经检查的快照）
const AWS_PROCESS_VARS = [...CREDENTIAL_VARS, "AWS_EC2_METADATA_DISABLED"];

export function withoutAwsCredentials(command: string): string {
  return `${STRIP_AWS_CREDENTIALS}\n${command}`;
}

function shellQuote(token: string): string {
  return `'${token.replace(/'/g, `'\\''`)}'`;
}

// 凭证先保存到未导出的 shell 数组，剥离后只通过 /usr/bin/env 传给 aws 进程（兼容 bash 3.2）。
// aws 进程的 HOME 指向执行时生成的 ~/.aws 白名单快照（不读取真实 ~/.aws 的 alias / models / 未经重写的配置），结束后删除。
// Windows 上 Python 的 expanduser 使用 USERPROFILE（忽略 HOME），sso / login 缓存目录同样需要指向快照。
export function buildStrictCommand(
  strict: StrictAwsCommand,
  awsPath: string,
  snapshot: { readonly node: string; readonly script: string },
  windows = false,
): string {
  const makeSnapshot = `__pi_awshome="$(${shellQuote(snapshot.node)} ${shellQuote(snapshot.script)})" || { echo "aws-ops-guard: 无法创建 ~/.aws 快照" >&2; exit 1; }`;
  const cleanup = `trap 'chmod -R u+w "$__pi_awshome" 2>/dev/null; rm -rf "$__pi_awshome"' EXIT`;
  const capture = `__pi_aws_env=(); for __pi_v in ${AWS_PROCESS_VARS.join(" ")}; do if [ -n "\${!__pi_v:-}" ]; then __pi_aws_env+=("$__pi_v=\${!__pi_v}"); fi; done`;
  const aws = [
    "/usr/bin/env", "-u", "AWS_EC2_METADATA_DISABLED", '"${__pi_aws_env[@]}"',
    '"HOME=$__pi_awshome"', ...(windows ? ['"USERPROFILE=$__pi_awshome"'] : []),
    '"AWS_CONFIG_FILE=$__pi_awshome/.aws/config"', '"AWS_SHARED_CREDENTIALS_FILE=$__pi_awshome/.aws/credentials"',
    ...strict.assignments.map(shellQuote), shellQuote(awsPath), ...strict.awsArgs.map(shellQuote),
  ].join(" ") + (strict.mergeStderr ? " 2>&1" : "");
  const filters = strict.filters.map((stage) => stage.map(shellQuote).join(" "));
  const redirect = strict.redirect ? ` ${strict.redirect.append ? ">>" : ">"} ${shellQuote(strict.redirect.target)}` : "";
  return [makeSnapshot, cleanup, capture, STRIP_AWS_CREDENTIALS, "unset __pi_v; set -o pipefail", `${[aws, ...filters].join(" | ")}${redirect}`].join("\n");
}

export function decideBash(assessment: BashAssessment, options: PolicyOptions = {}): BashDecision {
  const needsAws = assessment.awsLabels.length > 0;
  if (assessment.guardFindings.length === 0 && assessment.strict && options.awsPath && options.snapshot) {
    return { action: "run-with-credentials", command: buildStrictCommand(assessment.strict, options.awsPath, options.snapshot, options.windows) };
  }
  if (assessment.guardFindings.length === 0 && !needsAws) return { action: "run-without-credentials" };
  const awsReasons = assessment.awsLabels.map((label) => `需要 AWS 凭证：${label}`);
  const configReasons = needsAws ? (options.awsConfigWarnings ?? []).map((w) => `⚠️ ~/.aws 配置包含 ${w}（批准后将生效，请确认不是被篡改的）`) : [];
  return { action: "confirm", reasons: [...assessment.guardFindings, ...configReasons, ...awsReasons], grantCredentials: needsAws };
}
