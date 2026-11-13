# 安全模型

[← 返回 README](../README.md)

## 1. 客户端护栏 aws-ops-guard（默认开启）

核心思路：**bash 默认不带 AWS 凭证**，AWS 访问只通过可审查的通道进行；无法静态确认为只读的调用一律要求人工确认。

| 通道 | 行为 |
|---|---|
| AWS MCP `aws___run_script`（跨区域 / 批量查询） | 静态分析代码：每个 AWS 调用都是 `call_boto3(operation_name="完整字面量")` 的读操作时直接执行；写操作、敏感读取、别名 / `exec` / 动态操作名 / `boto3` / 子进程需确认；Athena / Redshift Data / DynamoDB PartiQL 仅当该次调用的 SQL 是完整字面量只读语句时放行 |
| 其他 AWS MCP 工具 | 文档 / skills / 区域查询 / 任务状态等已知只读工具放行；`get_presigned_url` 的 upload 及未知工具需确认 |
| bash：普通命令 | **剥离全部 AWS 凭证后执行**（`unset` 凭证变量、禁用共享配置与 IMDS），无需确认——即使分析漏判也无法访问 AWS |
| bash：简单只读 `aws` 命令（续） | aws 进程读取的是**执行时生成的 `~/.aws` 白名单快照**（作为该进程的 HOME，结束后删除）：config / credentials 按 = 或 : 分隔、任意换行符宽松解析后，只按规范格式写出白名单内的键（region、凭证、sso_*、role_arn 等），`credential_process`、`*endpoint_url`、`ca_bundle`、`ec2_metadata_service_endpoint`、`cli_pager`、`[plugins]`、`[services]` 及所有嵌套设置一律丢弃；只信任当前用户不可写的 aws 可执行文件（含所有上级目录）。依赖 config 中 `ca_bundle` 的环境请改用 `AWS_CA_BUNDLE` 环境变量 |
| bash：简单只读 `aws` 命令 | 严格白名单（单条 `aws <service> <读操作>`，可接 `jq/grep/head/tail/sort/uniq/wc/cut/column/tr` 与写到当前目录或 `/tmp` 的重定向）**自动执行**：护栏不执行原文，而是用校验后的参数重建命令，**只有 aws 进程获得凭证**（过滤器无凭证）；拒绝 `;` `$` 循环 子 shell、`--endpoint-url/--profile/--debug/--ca-bundle` 及其任意前缀缩写、`file://` 参数、会写本地文件的操作（如 `s3api get-object`）、过滤器的文件参数与危险选项 |
| bash：其他需要 AWS 的命令 | 循环 / 多命令 / 脚本 / IaC（`cdk deploy`、`terraform apply` ...）/ 写操作：弹窗展示命令与识别出的操作，批准后本条命令带凭证执行 |
| 敏感读取 | `GetSecretValue`、`GetParameter*`、`GetSessionToken`、`ecr get-login-password`、`eks get-token`、`GetFunctionConfiguration` 等返回凭证 / 密钥的操作；读取 `/proc/*/environ`、容器凭证端点、`~/.aws` 下的缓存 |
| 受保护位置（写入） | `~/.pi`（护栏、`mcp.json`、`settings.json`、`AGENTS.md`、其他扩展）、项目级 `.pi/`、`~/.local/share/pi-bedrock`、`~/.local/bin`、`~/.aws`、shell 启动文件（`.bashrc*`、`.bash_*`、`.zsh*`、`.profile` ...）；路径先规范化（`..`、`//`、相对路径、符号链接均无效）；`pip install --user`、`crontab` 等持久化操作 |
| read / grep / find / ls | 读取 `~/.aws`、`~/.pi/agent/auth.json`、`/proc/*/environ`，或 grep 递归范围包含 `~/.aws` 时需确认 |

- **交互模式**：弹窗列出原因与命令/代码，选择"执行一次"才执行
- **非交互模式**（`pi -p`、脚本、CI）：需要确认的操作一律拒绝
- **只读模式**：`/aws-guard readonly`（持久化，`/reload` 后保留）或启动前 `export PI_AWS_OPS_GUARD=readonly`
- **审计日志**：`~/.pi/agent/aws-ops-guard.log`（JSON Lines：时间、决策、工具、原因、是否授予凭证、命令预览、工作目录）
- **文件只读**：护栏扩展、包装器与运行时脚本安装为只读
- pi 的 codemode 嵌套工具调用同样经过护栏

- **Windows**：路径比较不区分大小写，统一处理 `\` 与 `/`、`C:\` 与 Git Bash 的 `/c/`、`~\`、8.3 短文件名、`\\?\` 前缀、路径段末尾的 `.`、NTFS 备用数据流（`file:stream`）；从 bash 调用 `powershell` / `cmd` / `setx` / `reg` / `wsl` 等无法静态分析的解释器与系统工具需确认。只有 **Git for Windows 与 AWS CLI 都安装在 Program Files**（目录取自 HKLM 注册表，仅管理员可写）时才启用"简单只读 aws 命令自动带凭证"；Git 装在用户目录时，该目录作为受保护位置，bash 中的 aws 命令逐条确认（AWS MCP 只读调用不受影响）。用户目录中的 Git 仍可能被刻意构造的脚本改写（文本检查无法完全覆盖），**建议把 Git for Windows 安装在 Program Files**

> 边界说明：CloudShell 中用户拥有 sudo，且 pi 进程本身持有凭证，同一用户下无法做到进程级隔离；刻意规避的行为（例如通过调试器读取 pi 进程内存、用后台进程在毫秒级窗口内改写临时快照，或用混淆方式改写 `~/.aws/config` 以影响 pi 自身与 AWS MCP 代理读取的配置）仍可能获取凭证。护栏的目标是让 **AI 正常产生的命令在漏判时也不会写入 AWS**，并让变更都经过人工确认。面向客户的生产环境请务必配合下面的 IAM 控制。
>
> **本地安装（macOS / Linux / Windows）的额外边界**：bash 工具以当前用户身份运行，`~/.aws/credentials` 中的长期 Access Key、`~/.aws/sso/cache` 中的 SSO 令牌对同一用户的进程都是可读的。护栏对这些文件的读取是**基于文本的拦截**（常见写法、通配符、变量拼接、Windows 路径变体都会要求确认），无法防御刻意混淆的脚本。因此本地使用时：**优先选择 `aws login` 或 IAM Identity Center（短期凭证，自动过期）而不是长期 Access Key**，并为运维身份配置下文的最小权限与写操作限制。

## 2. IAM 纵深防御（生产环境必做）

**首选：为运维助手使用专用的受限角色。** CloudShell 默认使用控制台登录身份（常常是管理员）。建议为运维场景准备一个角色：

- 以 `ViewOnlyAccess`（不含数据读取）或 `ReadOnlyAccess` 为基础——注意 `ReadOnlyAccess` 包含 `ssm:GetParameter*`、`s3:GetObject` 等数据读取权限
- 只补充运维需要的少量写权限，例如 `cloudwatch:PutMetricAlarm`、`cloudwatch:DeleteAlarms`、`sns:CreateTopic`、`sns:Subscribe`、`budgets:ModifyBudget`，并尽量限定资源 ARN
- 配置 Permissions Boundary，并把会话时长限制在 1 小时
- 在 CloudShell 中 `aws sts assume-role` 后把临时凭证导出为环境变量（`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`），再启动 `pi`——Bedrock、AWS MCP、bash 将统一使用该角色

**补充：限制"经 AWS MCP 发起"的操作。** 条件键 `aws:ViaAWSMCPService`（Bool）只对经 AWS MCP Server 发起的请求生效，**对 agent 在 bash 中直接执行的 `aws` CLI 无效**，因此只能作为补充。例如：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyHighRiskActionsViaAWSMCP",
      "Effect": "Deny",
      "Action": [
        "iam:*", "organizations:*", "sts:AssumeRole", "account:*",
        "ec2:TerminateInstances", "ec2:Delete*", "ec2:RunInstances", "rds:Delete*", "dynamodb:DeleteTable",
        "s3:DeleteBucket", "s3:DeleteObject", "s3:PutBucketPolicy", "s3:PutBucketAcl",
        "lambda:*", "ssm:SendCommand", "cloudformation:*",
        "kms:ScheduleKeyDeletion", "kms:Decrypt", "secretsmanager:GetSecretValue"
      ],
      "Resource": "*",
      "Condition": { "Bool": { "aws:ViaAWSMCPService": "true" } }
    }
  ]
}
```

参考：[Understanding IAM for managed AWS MCP servers](https://aws.amazon.com/blogs/security/understanding-iam-for-managed-aws-mcp-servers/)。所有经 MCP 的调用均记录在 CloudTrail 中，可据此持续收紧策略。

## 3. 所需权限

| 功能 | 权限 |
|---|---|
| Kimi K3.1（Global 跨区域推理） | `bedrock:InvokeModel`、`bedrock:InvokeModelWithResponseStream`（推理配置文件与基础模型 ARN）；首次使用第三方模型可能需要 `aws-marketplace:Subscribe` 等权限 |
| AWS MCP Server | 下游服务本身的权限（如 `ce:GetCostAndUsage`、`cloudwatch:DescribeAlarms`、`cloudwatch:PutMetricAlarm`） |
| 区域探测 | 与 Kimi K3.1 相同（每个候选区域一次 `maxTokens=16` 的 Converse 调用） |

## 4. 供应链

| 组件 | 版本 | 校验 |
|---|---|---|
| pi `@earendil-works/pi-coding-agent` | 1.5.2（固定） | npm 完整性校验；pi 发布 `npm-shrinkwrap.json` 锁定传递依赖；`--ignore-scripts` 不执行依赖的 install 脚本 |
| Node.js | 24.22.2（固定，仅当系统 Node < 22.19 或位于 `$HOME` 时安装；Windows 始终安装私有 Node） | SHA256 内置在 `lib/node.sh`（Linux / macOS / Windows × x64 / arm64） |
| uv | 0.13.7（固定） | SHA256 内置在 `lib/mcp.sh` |
| Git for Windows（仅 Windows 且未安装时） | 2.56.1（固定） | SHA256 内置在 `install.ps1` |
| AWS CLI v2（仅 Windows 且用户同意时） | 最新版 MSI | 校验 Amazon 的 Authenticode 签名 |
| mcp-proxy-for-aws-cli | 1.8.0（固定） | `lib/mcp-proxy-requirements.txt` 锁定全部 81 个依赖的 SHA256，`--require-hashes` 安装；Python 3.12 由 uv 下载并校验 |
| Agent Toolkit skills | commit `00840a0`（固定） | 仅复制白名单 skill 目录、删除符号链接；对内容清单做 SHA256 校验（`PI_AWS_SKILLS_SHA256`），不匹配则不安装 |
