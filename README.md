# pi-cli-on-aws：AWS 云上运维助手（CloudShell / macOS / Linux / Windows）

一条命令安装 [pi](https://pi.dev) coding agent，开箱即用。可以装在 **AWS CloudShell** 上，也可以装在 **macOS / Linux / Windows** 本地：CloudShell 的 `$HOME` 只有 1 GB，长期使用推荐本地安装。

- **模型**：默认 Amazon Bedrock `global.moonshotai.kimi-k3.1`（Kimi K3.1），无需 API Key。CloudShell 上直接使用控制台登录身份；本地没有 AWS 凭证时，安装器会**引导配置**（aws login / IAM Identity Center / Access Key + Secret Key（+ Session Token）/ 已有 profile，Region 必填）
- **AWS MCP Server**：集成 [Agent Toolkit for AWS](https://aws.amazon.com/products/developer-tools/agent-toolkit-for-aws/) 的托管 MCP（SigV4），可调用 300+ 服务的 AWS API
- **运维 skills 与规则**：预装成本计费、可观测、排障、安全、IAM、Well-Architected、operations、resilience 等官方 skills，以及中文运维规则
- **工具选择：CLI 优先**：成本、指标、日志、告警、资源配置等例行查询默认用 bash 中的单条只读 `aws` 命令（自动带凭证、无需确认）；跨区域 / 批量查询用 AWS MCP 的 `aws___run_script` 一次完成；skills 只在写操作、排障或不熟悉的服务时按需加载。依据见 [docs/benchmark-mcp-vs-cli.md](docs/benchmark-mcp-vs-cli.md)：与"MCP + 每次先加载 skill"相比，平均 tokens 降低 64%、耗时降低 42%
- **写操作护栏**：`aws-ops-guard` 扩展——查询直接执行；创建告警、修改预算等写操作逐次人工确认；非交互模式一律拒绝；全部决策写审计日志

适用场景：为客户提供 **成本与用量分析、CloudWatch 可观测、告警配置、故障排查、安全检查** 的智能运维助手。

开发过程复盘与可复用的方法论（流程、踩坑清单、必做清单、AI 运维 Agent 安全设计原则）：[docs/development-methodology.md](docs/development-methodology.md)

---

## 快速开始

在 AWS 控制台打开 CloudShell，执行：

```bash
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git
bash pi-cli-on-aws/install.sh
source ~/.bashrc
pi-bedrock-doctor     # 端到端自检（约 1 分钟）
pi                    # 开始使用
```

安装约 1 分钟、占用约 500 MB（CloudShell `$HOME` 上限 1 GB）。安装完成后源码目录可删除；所有文件都在 `$HOME` 下，CloudShell 重启后保留（CloudShell 的 `$HOME` 按区域独立，且 120 天未使用会被清理）。

### 支持的平台

| 平台 | x86_64 | arm64 | 入口 |
|---|---|---|---|
| AWS CloudShell / Linux | ✓ | ✓ | `bash install.sh` |
| macOS（bash 3.2 / zsh） | ✓ Intel | ✓ Apple Silicon | `bash install.sh` |
| Windows 10 / 11、Server 2019+（PowerShell 5.1+） | ✓ | ✓（未在 ARM64 真机上验证） | `install.ps1` |

### 本地安装：macOS / Linux

前提：已安装 [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)，身份有 Bedrock 调用权限。不需要事先配置凭证，安装器会引导配置（见下文"AWS 凭证引导"）。

```bash
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git
bash pi-cli-on-aws/install.sh
source ~/.zshrc          # bash 用户为 ~/.bashrc
pi-bedrock-doctor
pi
```

- 区域：未设置 `AWS_REGION` 时使用凭证引导中填写的 Region，或 AWS CLI 配置中的默认区域（`aws configure get region`）
- 凭证：pi 使用安装时选定 / 配置的 profile（记录在 env 文件中）。临时改用其他身份可 `export AWS_PROFILE=<name>`（环境变量优先）；pi 需要凭证相关环境变量才会启用 amazon-bedrock，包装器会自动设置 `AWS_PROFILE`

### 本地安装：Windows

在 **PowerShell** 中执行（不需要管理员；没有 git 时用 zip 下载）：

```powershell
Invoke-WebRequest https://github.com/zhuangyq008/pi-cli-on-aws/archive/refs/heads/main.zip -OutFile pi-cli-on-aws.zip
Expand-Archive pi-cli-on-aws.zip -DestinationPath . -Force
powershell -ExecutionPolicy Bypass -File .\pi-cli-on-aws-main\install.ps1
# 重新打开 PowerShell 窗口后：
pi-bedrock-doctor
pi
```

`install.ps1` 的步骤：

1. **Git for Windows**：pi 的 bash 工具与安装逻辑运行在 Git Bash 中。已安装则复用；未安装则从 GitHub 下载官方安装包（版本与 SHA256 固定），静默安装到 `C:\Program Files\Git`（需要管理员授权 / UAC）。拒绝 UAC 或无管理员权限时改为**按当前用户**安装到 `%LOCALAPPDATA%\Programs\Git`；这种情况下 bash 中的只读 aws 命令也需逐条确认（见"安全模型"）
2. **AWS CLI v2**：未安装时询问是否安装官方 MSI。会先校验 Amazon 的 Authenticode 签名，安装需要管理员授权（UAC）；`-InstallAwsCli` 跳过询问
3. 在 Git Bash 中运行 `install.sh`：凭证引导、私有 Node.js / pi / MCP 代理 / skills / 护栏，与 Linux 相同
4. 生成 `pi.cmd`、`pi-bedrock-doctor.cmd`、`pi-bedrock-login.cmd`，并把 `%USERPROFILE%\.local\bin` 加入**用户** PATH；在 Git Bash 中直接运行 `pi` 同样可用

参数与 `install.sh` 对应：`-Region`、`-NoProbe`、`-Model`、`-Thinking`、`-NoMcp`、`-NoSkills`、`-AllModels`、`-GitBash <bash.exe 路径>`、`-InstallAwsCli`。

Windows 上的差异：

- 推荐使用 Windows Terminal（中文显示、快捷键更完整）；pi 的换行快捷键为 `Ctrl+Enter`
- 自动带凭证的只读 `aws` 命令只信任 AWS CLI 官方 MSI 的安装位置 `C:\Program Files\Amazon\AWSCLIV2\aws.exe`，且要求 Git for Windows 也位于 Program Files（两者都仅管理员可写）；否则 bash 中的 aws 命令一律需要确认
- 公司网络无法访问证书吊销服务器（80 端口）时，Git 自带 curl 的下载会报 `CRYPT_E_REVOCATION_OFFLINE`：安装器对此使用 `--ssl-revoke-best-effort`（吊销服务器不可达时放过，证书已吊销时仍拒绝；下载内容另有 SHA256 校验）
- pi 的可选 `powershell` 工具（默认关闭）无法剥离凭证，启用后每条命令都需要确认
- 用户名包含空格或中文时，安装路径自动使用 8.3 短路径（如 `C:/Users/ZHANGS~1/...`）；如系统禁用了短路径，请设置 `PI_BEDROCK_HOME`、`PI_BIN_DIR`、`PI_CODING_AGENT_DIR` 为不含空格的目录

### AWS 凭证引导（本地安装）

安装器先用 `aws sts get-caller-identity` 检测现有凭证（环境变量、`AWS_PROFILE`、default profile 等）。检测不到时进入引导，凭证与 Region 均为必填：

```text
未检测到可用的 AWS 凭证，请选择配置方式：
  1) aws login：浏览器登录 AWS 控制台身份（推荐，需要 AWS CLI 2.32+）
  2) IAM Identity Center（SSO）：aws configure sso
  3) Access Key / Secret Key（可选 Session Token）
  4) 使用已有 profile
请输入 1-4 [1]:
AWS Region（必填，例如 us-east-1、ap-northeast-1） [us-east-1]:
```

- 1 / 2 / 3 写入专用 profile **`pi-bedrock`**，不改动 default 等已有 profile；4 直接使用所选 profile
- Access Key 方式：Secret Key 与 Session Token 输入时不回显，只写入 `~/.aws/credentials`（权限 600），不会出现在命令行参数或日志中。`ASIA` 开头的临时凭证必须提供 Session Token
- 配置后立即用 `sts:GetCallerIdentity` 验证，失败可重试（共 3 次）
- 非交互环境（无终端）检测不到凭证时直接报错并给出指引
- 凭证过期后运行 **`pi-bedrock-login`**：会根据 profile 类型选择 `aws sso login` 或 `aws login`，Access Key 方式则重新引导；`pi-bedrock-login --reconfigure` 可重新选择方式
- `/model` 默认只显示当前 Bedrock 源区域中可用的模型（见下文"模型列表"）
- 自动带凭证的只读 `aws` 命令只信任当前用户不可写的 aws 路径：使用官方 pkg 安装的 AWS CLI（`/usr/local/bin/aws`）时可用；Homebrew 安装（`/opt/homebrew/bin` 归当前用户所有）时，bash 中的 `aws` 命令一律需要确认（AWS MCP 不受影响）

### 示例

```text
> 分析本账号本月至今按服务的成本，与上月同期对比，列出增长最快的 5 项并给出优化建议
> 列出 us-east-1 所有处于 ALARM 状态的 CloudWatch 告警，并分析最近 24 小时相关指标
> 为 EC2 实例 i-0123456789abcdef0 创建 CPU > 80%（5 分钟 x 3 次）的告警，通知到 SNS topic ops-alerts
> 检查 Lambda 函数 order-api 最近 1 小时的错误，定位根因
> /aws-guard            # 查看护栏模式；/aws-guard readonly 切换为只读
```

创建告警这类写操作执行前会弹出确认框，展示即将执行的代码/命令：

```text
⚠️ AWS 写操作需要确认
操作：cloudwatch:PutMetricAlarm
工具：mcp__aws_mcp__aws___run_script
await call_boto3(service_name="cloudwatch", operation_name="PutMetricAlarm", params={...})
是否执行？  > 执行一次   拒绝
```

---

## 架构

```text
CloudShell ($HOME 持久化)
└── pi（包装器 ~/.local/bin/pi）
    ├── 模型：amazon-bedrock / global.moonshotai.kimi-k3.1 ──SigV4──▶ Bedrock Runtime（源区域可自动选择）
    ├── MCP：aws-mcp ── mcp-proxy-for-aws-cli（SigV4）──▶ AWS MCP Server（aws-mcp.<region>.api.aws）
    │        └── aws___run_script：沙箱 Python + call_boto3 ──▶ Cost Explorer / CloudWatch / Budgets / ...
    ├── skills：~/.pi/agent/skills/aws-agent-toolkit（官方 skills，固定 commit）
    ├── 规则：~/.pi/agent/AGENTS.md（托管段落：中文运维规则 + 官方 aws-agent-rules）
    └── 扩展：~/.pi/agent/extensions/aws-ops-guard（写操作人工确认 + 审计日志）
凭证：CloudShell 容器凭证端点（控制台登录身份）；本地为安装时选定的 profile——Bedrock、MCP、bash 中的 aws CLI 共用
Windows：pi.cmd → Git Bash → 包装器 → node.exe；bash 工具与 MCP 启动器都运行在 Git Bash 中
```

### 模型列表

pi 内置的 Bedrock 模型目录约有 200 个模型，其中多数在某个区域并不存在（例如 `us.*` 推理配置文件在 ap-southeast-1 调用会报 `The provided model identifier is invalid`）。安装时会在 Bedrock 源区域做只读查询（`ListInferenceProfiles`、`ListFoundationModels`、`GetFoundationModelAvailability`，**不调用模型**，因此不会触发第三方模型的 Marketplace 自动订阅），只把"区域内存在 + 已授权 + 已开通 + 协议可用"的模型写入 `enabledModels`：

- `/model` 默认只显示这些模型（按 Tab 可切换到 all 查看全部），`Ctrl+P` 也只在这些模型间切换
- 配额为 0 的模型无法通过只读查询识别，仍可能在调用时限流
- 开通新模型或更换区域后，重新运行 `install.sh` 即可刷新；`--all-models` 可关闭筛选

### 两个"区域"

| 概念 | 默认值 | 作用 |
|---|---|---|
| **运维区域** `PI_OPS_AWS_REGION` | CloudShell 当前区域 | AWS MCP 的默认操作区域；agent 在 bash 中执行的 `aws` 命令也使用它 |
| **Bedrock 源区域** `PI_BEDROCK_REGION` | 安装时自动探测 | 只影响 pi 调用 Kimi K3.1 的源区域 |

`global.*` 跨区域推理的 TPM 配额按**源区域**分别计算，有些账号在多数区域默认为 0，此时会一直报 `ThrottlingException`。安装器会先用当前区域做一次极小的探测调用（`maxTokens=16`），失败时并行探测其他区域，选出第一个可用的（同一大洲优先），并**只对 pi 的模型调用**固定该区域；agent 的 bash 工具与 AWS MCP 仍使用 CloudShell 原区域。`global.*` 推理配置文件本身就会在全球商业区域间路由，源区域只决定配额与 CloudWatch 指标的归属。

> 实测中曾遇到账号的 Kimi K3.1 Global 配额只在 `ap-southeast-1` / `eu-north-1` / `sa-east-1` 等少数源区域非 0。长期使用建议在 Service Quotas 中为常用区域申请 *Global cross-region model inference tokens per minute for Moonshot AI Kimi K3.1* 提额，然后重新运行 `install.sh`。

---

## 安全模型

### 1. 客户端护栏 aws-ops-guard（默认开启）

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

### 2. IAM 纵深防御（生产环境必做）

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

### 3. 所需权限

| 功能 | 权限 |
|---|---|
| Kimi K3.1（Global 跨区域推理） | `bedrock:InvokeModel`、`bedrock:InvokeModelWithResponseStream`（推理配置文件与基础模型 ARN）；首次使用第三方模型可能需要 `aws-marketplace:Subscribe` 等权限 |
| AWS MCP Server | 下游服务本身的权限（如 `ce:GetCostAndUsage`、`cloudwatch:DescribeAlarms`、`cloudwatch:PutMetricAlarm`） |
| 区域探测 | 与 Kimi K3.1 相同（每个候选区域一次 `maxTokens=16` 的 Converse 调用） |

### 4. 供应链

| 组件 | 版本 | 校验 |
|---|---|---|
| pi `@earendil-works/pi-coding-agent` | 1.5.2（固定） | npm 完整性校验；pi 发布 `npm-shrinkwrap.json` 锁定传递依赖；`--ignore-scripts` 不执行依赖的 install 脚本 |
| Node.js | 24.22.2（固定，仅当系统 Node < 22.19 或位于 `$HOME` 时安装；Windows 始终安装私有 Node） | SHA256 内置在 `lib/node.sh`（Linux / macOS / Windows × x64 / arm64） |
| uv | 0.13.7（固定） | SHA256 内置在 `lib/mcp.sh` |
| Git for Windows（仅 Windows 且未安装时） | 2.56.1（固定） | SHA256 内置在 `install.ps1` |
| AWS CLI v2（仅 Windows 且用户同意时） | 最新版 MSI | 校验 Amazon 的 Authenticode 签名 |
| mcp-proxy-for-aws-cli | 1.8.0（固定） | `lib/mcp-proxy-requirements.txt` 锁定全部 81 个依赖的 SHA256，`--require-hashes` 安装；Python 3.12 由 uv 下载并校验 |
| Agent Toolkit skills | commit `00840a0`（固定） | 仅复制白名单 skill 目录、删除符号链接；对内容清单做 SHA256 校验（`PI_AWS_SKILLS_SHA256`），不匹配则不安装 |

---

## 安装选项

```text
bash install.sh [选项]
  --region REGION     固定 Bedrock 源区域（默认: 自动探测）
  --no-probe          不探测区域，pi 直接使用 AWS_REGION
  --model ID          默认模型（默认: global.moonshotai.kimi-k3.1）
  --thinking LEVEL    默认思考等级 off|minimal|low|medium|high|xhigh|max（默认: medium）
  --pi-version VER    pi 版本（默认: 1.5.2，可设为 latest）
  --node MODE         auto|private|system（默认: auto）
  --no-mcp            不安装 AWS MCP Server（节省约 220 MB）
  --no-skills         不预装 AWS 运维 skills 与规则文件
  --all-models        /model 显示全部内置模型（默认只启用当前区域可用的模型）
  --no-bashrc         不修改 ~/.bashrc
```

Windows 使用 `install.ps1` 的同名参数（见上文"本地安装：Windows"）。

安装器是幂等的：重复运行会跳过已安装组件、重新探测区域并刷新配置；重新运行时加 `--no-mcp` / `--no-skills` 会移除之前安装的对应组件。使用自定义 `PI_BEDROCK_HOME` / `PI_BIN_DIR` / `PI_CODING_AGENT_DIR` 时，路径会记录在 env 文件中，卸载时自动沿用。

### 运行时环境变量

| 变量 | 说明 |
|---|---|
| `PI_BEDROCK_REGION` | 覆盖 Bedrock 源区域（优先于 `~/.local/share/pi-bedrock/env`） |
| `PI_OPS_AWS_REGION` | 覆盖运维区域（AWS MCP 默认操作区域） |
| `PI_AWS_MCP_ENDPOINT_REGION` | 覆盖 AWS MCP Server endpoint 区域（默认按运维区域就近选择 8 个支持区域之一） |
| `PI_AWS_OPS_GUARD` | `confirm`（默认）/ `readonly` / `off` |

### 修改了哪些文件

| 路径 | 内容 | 卸载时 |
|---|---|---|
| `~/.local/bin/pi`、`pi-bedrock-doctor` | 包装器与自检脚本 | 删除（若安装前有同名文件则恢复） |
| `~/.local/share/pi-bedrock/` | 私有 Node、pi、uv、Python、MCP proxy、env 配置、`settings.orig.json`（安装前的原值） | 删除 |
| `~/.pi/agent/settings.json` | `defaultProvider` / `defaultModel` / `defaultThinkingLevel` / `enabledModels` / `shellCommandPrefix` / `selfUpdateCommand` | 恢复安装前的原值（安装后被用户改过的保留） |
| `~/.pi/agent/mcp.json` | `aws-mcp` 条目（不覆盖用户自建的同名条目） | 删除该条目 |
| `~/.pi/agent/AGENTS.md` | 托管段落（段落外的用户内容不受影响） | 删除该段落 |
| `~/.pi/agent/skills/aws-agent-toolkit/` | 官方 skills | 删除 |
| `~/.pi/agent/extensions/aws-ops-guard/` | 写操作护栏（只读；原有同名目录备份到 `~/.pi/agent/.pi-bedrock-backup/`） | 删除并恢复备份 |
| `~/.bashrc` | 托管段落：把 `~/.local/bin` 加到 PATH | 删除该段落 |
| `~/.aws/credentials`、`~/.aws/config` | 仅在凭证引导中选择 1 / 2 / 3 时写入 `[pi-bedrock]` profile | **保留**（可用 `aws configure` 管理） |
| `~/.local/bin/*.cmd`（Windows） | pi / doctor / login 的 cmd shim | 删除 |
| 用户 PATH（Windows，`HKCU\Environment`） | 加入 `%USERPROFILE%\.local\bin` | 移除 |
| `settings.json` 的 `shellPath`（Windows） | 指向安装时使用的 Git Bash | 恢复安装前的原值 |

修改 JSON 文件前会备份为 `*.pi-bedrock.bak`；JSON 不合法时拒绝修改。

### 更新

获取最新源码后重新运行安装器即可，过程是增量的：已安装的 Node.js、pi、MCP proxy、skills 会跳过，运维规则（`~/.pi/agent/AGENTS.md` 托管段落）、护栏扩展、包装器与 settings 会更新为新版本。请使用**与首次安装相同的参数**（例如首次用了 `--no-mcp`，更新时也要带上，否则会重新安装 MCP）。

CloudShell / macOS / Linux：

```bash
# 源码目录还在：git -C pi-cli-on-aws pull；已删除则重新 clone
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git 2>/dev/null || git -C pi-cli-on-aws pull
bash pi-cli-on-aws/install.sh
```

Windows（PowerShell）：重新下载 zip 并解压（同"本地安装：Windows"），然后运行 `powershell -ExecutionPolicy Bypass -File .\pi-cli-on-aws-main\install.ps1`。

更新后需要**重新启动 pi**（已打开的会话仍使用旧规则）。可以运行 `pi-bedrock-doctor` 自检，或用 `grep -c 工具选择 ~/.pi/agent/AGENTS.md` 确认新规则已生效（输出 1）。

### 卸载

```bash
bash ~/.local/share/pi-bedrock/uninstall.sh
```

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\.local\share\pi-bedrock\uninstall.ps1
```

会话、`auth.json` 等用户数据保留在 `~/.pi/agent`，`~/.aws` 中的凭证保留；Windows 上不会卸载 Git for Windows 与 AWS CLI。

---

## 故障排查

先运行 `pi-bedrock-doctor`，它会检查运行环境、Node/pi、默认模型、AWS 身份、Bedrock 调用、MCP 连接、护栏与 skills，并做一次端到端对话。`pi-bedrock-doctor --quick` 只做本地检查，不产生模型调用。

| 现象 | 原因与处理 |
|---|---|
| `ThrottlingException: Too many tokens` | 源区域 TPM 配额为 0：重新运行 `install.sh` 自动选区，或 `--region <有配额的区域>`，或申请提额 |
| `AccessDeniedException`（Bedrock） | 缺少 `bedrock:InvokeModel*` 权限，或第三方模型未订阅 |
| doctor 提示"未使用 amazon-bedrock" | pi 未检测到 AWS 凭证环境变量而回退到其他 provider。CloudShell 会自动提供 `AWS_CONTAINER_CREDENTIALS_FULL_URI`；在其他环境请设置 `AWS_PROFILE` 或访问密钥 |
| `aws-mcp` 连接失败 | 运行 `pi mcp list` 查看错误；确认凭证有效、时钟准确（SigV4 要求误差 < 5 分钟） |
| `pi -p` 在脚本中卡住 | stdin 不是终端时 pi 会读取 stdin，请加 `</dev/null` |
| `$HOME` 空间不足 | CloudShell 上限 1 GB；可用 `--no-mcp` 节省约 220 MB，或清理 `~/.pi/agent/sessions` |
| `/model` 选择后报 `The provided model identifier is invalid` | 该模型在当前 Bedrock 源区域不存在；重新运行 `install.sh` 刷新可用模型列表（默认只显示可用模型） |
| 写操作总被拒绝 | 是否处于非交互模式或只读模式（`/aws-guard` 查看） |
| 无法修改 `~/.local/share/pi-bedrock/lib` 或护栏文件 | 这些文件安装为只读；如需调整请修改源码后重新运行 `install.sh` |
| 本地安装提示"未检测到可用的 AWS 凭证" | 按引导选择配置方式；SSO / aws login 会话过期后运行 `pi-bedrock-login` |
| Windows：`pi` 不是可识别的命令 | 安装后需重新打开 PowerShell 窗口使用户 PATH 生效；或直接运行 `%USERPROFILE%\.local\bin\pi.cmd` |
| Windows：脚本被执行策略阻止 | 用 `powershell -ExecutionPolicy Bypass -File install.ps1` 运行（只对本次生效，不修改系统策略） |
| Windows：安装 Git for Windows / AWS CLI 失败 | 企业环境可能禁止安装软件：手动安装后重新运行，或用 `-GitBash` 指定已有的 `bin\bash.exe` |
| skills 提示"内容校验失败" | 上游内容与固定哈希不一致，已跳过安装（不影响其他功能）；审阅后可设置 `PI_AWS_SKILLS_SHA256` 重新安装 |

---

## 开发与测试

```bash
npm install              # 仅安装测试框架 bats
npm run lint             # shellcheck
npm test                 # 117 个 bats + 54 个护栏（含 14 个 Windows 路径）+ 9 个模型筛选 / 配置合并单元测试（含历次安全审查发现的全部绕过样例；无 AWS 调用）
npm run test:e2e         # 在本机模拟 CloudShell 的端到端测试（会产生少量真实 Bedrock / AWS 只读调用）
# 在 Linux 上模拟 macOS 用户环境（bash 3.2、无 GNU sha256sum/timeout、profile 凭证、zsh）：
# BASH32=<bash 3.2 可执行文件> bash tests/e2e/macos-like.sh    （bash 3.2 可从 docker 镜像 bash:3.2 获取）
# Windows 真机端到端（临时 Windows Server 2022 EC2，仅 SSM、无入站端口；会产生少量 EC2 费用）：
bash tests/windows/ec2-harness.sh up     # 创建临时 IAM 角色 / 安全组并启动实例
bash tests/windows/ec2-harness.sh run    # 上传代码，经 SSM 执行 tests/windows/e2e.ps1
bash tests/windows/ec2-harness.sh down   # 终止实例，删除 IAM 角色、安全组与 S3 测试文件
```

Windows 端到端测试在干净的 Windows Server 2022（无 Git、无 AWS CLI）上以 SYSTEM 身份运行：`install.ps1` 安装 Git for Windows / AWS CLI → 凭证引导（Access Key + Session Token，使用实例角色的临时凭证，禁用 IMDS）→ `pi.cmd` / `pi-bedrock-doctor.cmd` → bash 工具凭证剥离、只读 aws 自动带凭证（aws.exe + `~/.aws` 快照）、受保护文件与写操作在非交互模式下被拒绝、AWS MCP 只读调用 → Windows 原生运行护栏路径单元测试 → `uninstall.ps1`。

端到端测试模拟了 CloudShell 的关键特征：独立 `$HOME`、`AWS_EXECUTION_ENV=CloudShell`、`AWS_REGION=ap-northeast-1`、仅通过 localhost 容器凭证端点提供凭证（禁用 IMDS）、PATH 中只有低于 22.19 的 Node。覆盖：安装 → Bedrock 对话 → bash 工具区域还原与凭证剥离 → 简单只读 aws 命令自动带凭证 → AWS MCP 只读调用 → 写操作护栏（非交互拒绝 / RPC 交互拒绝）→ doctor → 幂等重装 → 卸载。

```text
install.sh / uninstall.sh       入口
lib/common.sh                   常量、日志、校验
lib/config.sh                   env 文件、区域注入、托管段落（包装器只依赖此文件）
lib/node.sh  lib/pi.sh          私有 Node 与 pi 安装
lib/region.sh                   Bedrock 源区域探测
lib/mcp.sh  lib/mcp-runtime.sh  uv / MCP proxy 安装与 endpoint 选择
lib/skills.sh                   官方 skills 与 AGENTS.md 规则
lib/*.mjs                       settings.json / mcp.json 安全合并
bin/pi  bin/aws-mcp-proxy       pi 包装器、MCP 启动器
bin/pi-bedrock-doctor           自检
extensions/aws-ops-guard/       写操作护栏（pi 扩展）：index.ts 入口；policy.ts 执行策略；
                                shell.ts bash 评估；strict.ts 自动带凭证白名单；awscli.ts CLI 解析；
                                script.ts run_script 分析；ops.ts 操作分类；paths.ts 受保护路径
lib/mcp-proxy-requirements.txt  MCP proxy 依赖哈希锁
templates/ops-rules.md          中文运维规则
install.ps1 / uninstall.ps1     Windows 入口（Git for Windows / AWS CLI 引导，PATH 与 .cmd shim）
lib/credentials.sh              本地 AWS 凭证检测与引导
bin/pi-bedrock-login            重新登录 / 重新选择凭证方式
tests/                          bats、护栏单元测试、CloudShell / macOS 端到端模拟
tests/windows/                  Windows 真机端到端（EC2 + SSM）
```
