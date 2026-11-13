# pi-cli-on-aws

**一条命令把 [pi](https://pi.dev) coding agent 变成 AWS 云上运维助手**：Amazon Bedrock（Kimi K3.1）作模型，AWS CLI + [AWS MCP Server](https://aws.amazon.com/products/developer-tools/agent-toolkit-for-aws/) 访问账号，写操作逐次人工确认。支持 AWS CloudShell、macOS、Linux、Windows。

适用场景：成本与用量分析、CloudWatch 指标 / 日志 / 告警、故障排查、安全与合规检查。

## 特性

- **免 API Key**：使用 Bedrock `global.moonshotai.kimi-k3.1`，CloudShell 直接用控制台登录身份；本地没有凭证时安装器引导配置（aws login / IAM Identity Center / Access Key / 已有 profile）
- **CLI 优先，按需用 MCP**：例行查询用单条只读 `aws` 命令；跨区域 / 批量查询用 AWS MCP 的 `aws___run_script` 一次完成；官方运维 skills 按需加载。与"MCP + 每次先加载 skill"相比，平均 tokens **-64%**、耗时 **-42%**（[benchmark](docs/benchmark-mcp-vs-cli.md)）
- **写操作护栏** `aws-ops-guard`：bash 默认不带 AWS 凭证；只读查询直接执行，写操作弹窗确认，非交互模式一律拒绝，所有决策写审计日志
- **开箱即用**：自动选择有配额的 Bedrock 源区域、`/model` 只显示当前区域可用的模型、`pi-bedrock-doctor` 端到端自检
- **可复现的供应链**：pi、Node.js、uv、MCP proxy（含全部依赖哈希）、skills 均固定版本并校验

## 快速开始

**AWS CloudShell / macOS / Linux**（本地需要 [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)）：

```bash
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git
bash pi-cli-on-aws/install.sh
source ~/.bashrc          # zsh 用户为 ~/.zshrc
pi-bedrock-doctor         # 端到端自检（约 1 分钟）
pi
```

**Windows**（PowerShell，无需管理员）：

```powershell
Invoke-WebRequest https://github.com/zhuangyq008/pi-cli-on-aws/archive/refs/heads/main.zip -OutFile pi-cli-on-aws.zip
Expand-Archive pi-cli-on-aws.zip -DestinationPath . -Force
powershell -ExecutionPolicy Bypass -File .\pi-cli-on-aws-main\install.ps1
# 重新打开 PowerShell 后：pi-bedrock-doctor; pi
```

CloudShell 的 `$HOME` 只有 1 GB（本工具约占 500 MB），长期使用推荐本地安装。平台差异、凭证引导、安装选项见 [安装文档](docs/installation.md)。

**更新**：拉取最新源码后，用与首次安装相同的参数重新运行 `install.sh` / `install.ps1`（增量更新），然后重启 pi。**卸载**：`bash ~/.local/share/pi-bedrock/uninstall.sh`。详见 [更新](docs/installation.md#更新) 与 [卸载](docs/installation.md#卸载)。

## 示例

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

## 安全

护栏的目标是让 **AI 正常产生的命令在漏判时也不会写入 AWS**，并让所有变更都经过人工确认：

- bash 普通命令**剥离 AWS 凭证**后执行；只有通过严格白名单的单条只读 `aws` 命令自动带凭证，且只有 aws 进程获得凭证
- `aws___run_script` 经静态分析，只读调用直接执行；写操作、敏感读取（`GetSecretValue` 等）、动态操作名需确认
- 写入 `~/.pi`、`~/.aws`、shell 启动文件等受保护位置需确认；`/aws-guard readonly` 切换只读模式

客户端护栏无法替代 IAM：面向客户的生产环境请为运维助手使用**专用的受限角色**，并配合 `aws:ViaAWSMCPService` 条件键。完整规则、边界说明、IAM 示例与所需权限见 [安全模型](docs/security.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [安装、更新与卸载](docs/installation.md) | 各平台安装、AWS 凭证引导、安装选项、环境变量、修改的文件、模型与区域选择 |
| [安全模型](docs/security.md) | 护栏规则、边界说明、IAM 纵深防御、所需权限、供应链 |
| [故障排查](docs/troubleshooting.md) | 常见报错与处理 |
| [Benchmark：MCP vs CLI](docs/benchmark-mcp-vs-cli.md) | 不同工具策略的 token、耗时与费用对比 |
| [开发与测试](docs/development.md) | 测试、端到端模拟、代码结构 |
| [开发复盘与方法论](docs/development-methodology.md) | 流程、踩坑清单、AI 运维 Agent 安全设计原则 |

## License

MIT
