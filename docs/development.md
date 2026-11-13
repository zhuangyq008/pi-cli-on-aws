# 开发与测试

[← 返回 README](../README.md)

```bash
npm install              # 仅安装测试框架 bats
npm run lint             # shellcheck
npm test                 # 117 个 bats + 54 个护栏（含 14 个 Windows 路径）+ 9 个模型筛选 / 配置合并单元测试（含历次安全审查发现的全部绕过样例；无 AWS 调用）
npm run bench            # MCP vs CLI 的 token / 耗时 benchmark（真实 Bedrock / AWS 只读调用，见 docs/benchmark-mcp-vs-cli.md）
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

## 代码结构

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
tests/bench/                    MCP vs CLI benchmark（RPC 驱动 pi，采集 token / 耗时）
```
