# pi-cli-on-aws：CloudShell 上的 AWS 云上运维助手

在 **AWS CloudShell** 中一条命令安装 [pi](https://pi.dev) coding agent，开箱即用：

- **模型**：默认 Amazon Bedrock `global.moonshotai.kimi-k3.1`（Kimi K3.1），直接使用 CloudShell 控制台登录身份，无需 API Key
- **AWS MCP Server**：集成 [Agent Toolkit for AWS](https://aws.amazon.com/products/developer-tools/agent-toolkit-for-aws/) 的托管 MCP（SigV4），可调用 300+ 服务的 AWS API
- **运维 skills 与规则**：预装成本计费、可观测、排障、安全、IAM、Well-Architected、operations、resilience 等官方 skills，以及中文运维规则
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
凭证：CloudShell 容器凭证端点（控制台登录身份）——Bedrock、MCP、bash 中的 aws CLI 共用
```

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
| AWS MCP `aws___run_script`（推荐） | 静态分析代码：每个 AWS 调用都是 `call_boto3(operation_name="完整字面量")` 的读操作时直接执行；写操作、敏感读取、别名 / `exec` / 动态操作名 / `boto3` / 子进程需确认；Athena / Redshift Data / DynamoDB PartiQL 仅当该次调用的 SQL 是完整字面量只读语句时放行 |
| 其他 AWS MCP 工具 | 文档 / skills / 区域查询 / 任务状态等已知只读工具放行；`get_presigned_url` 的 upload 及未知工具需确认 |
| bash：普通命令 | **剥离全部 AWS 凭证后执行**（`unset` 凭证变量、禁用共享配置与 IMDS），无需确认——即使分析漏判也无法访问 AWS |
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

> 边界说明：CloudShell 中用户拥有 sudo，且 pi 进程本身持有凭证，同一用户下无法做到进程级隔离；刻意规避的行为（例如通过调试器读取 pi 进程内存）仍可能获取凭证。护栏的目标是让 **AI 正常产生的命令在漏判时也不会写入 AWS**，并让变更都经过人工确认。面向客户的生产环境请务必配合下面的 IAM 控制。

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
| Node.js | 24.22.2（固定，仅当系统 Node < 22.19 或位于 `$HOME` 时安装） | SHA256 内置在 `lib/node.sh` |
| uv | 0.13.7（固定） | SHA256 内置在 `lib/mcp.sh` |
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
  --no-bashrc         不修改 ~/.bashrc
```

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
| `~/.pi/agent/settings.json` | `defaultProvider` / `defaultModel` / `defaultThinkingLevel` / `shellCommandPrefix` / `selfUpdateCommand` | 恢复安装前的原值（安装后被用户改过的保留） |
| `~/.pi/agent/mcp.json` | `aws-mcp` 条目（不覆盖用户自建的同名条目） | 删除该条目 |
| `~/.pi/agent/AGENTS.md` | 托管段落（段落外的用户内容不受影响） | 删除该段落 |
| `~/.pi/agent/skills/aws-agent-toolkit/` | 官方 skills | 删除 |
| `~/.pi/agent/extensions/aws-ops-guard/` | 写操作护栏（只读；原有同名目录备份到 `~/.pi/agent/.pi-bedrock-backup/`） | 删除并恢复备份 |
| `~/.bashrc` | 托管段落：把 `~/.local/bin` 加到 PATH | 删除该段落 |

修改 JSON 文件前会备份为 `*.pi-bedrock.bak`；JSON 不合法时拒绝修改。

### 卸载

```bash
bash ~/.local/share/pi-bedrock/uninstall.sh
```

会话、`auth.json` 等用户数据保留在 `~/.pi/agent`。

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
| 写操作总被拒绝 | 是否处于非交互模式或只读模式（`/aws-guard` 查看） |
| 无法修改 `~/.local/share/pi-bedrock/lib` 或护栏文件 | 这些文件安装为只读；如需调整请修改源码后重新运行 `install.sh` |
| skills 提示"内容校验失败" | 上游内容与固定哈希不一致，已跳过安装（不影响其他功能）；审阅后可设置 `PI_AWS_SKILLS_SHA256` 重新安装 |

---

## 开发与测试

```bash
npm install              # 仅安装测试框架 bats
npm run lint             # shellcheck
npm test                 # 70 个 bats 单元测试 + 36 个护栏测试（含三轮安全审查发现的全部绕过样例；无 AWS 调用）
npm run test:e2e         # 在本机模拟 CloudShell 的端到端测试（会产生少量真实 Bedrock / AWS 只读调用）
```

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
tests/                          bats、护栏单元测试、CloudShell 端到端模拟
```
