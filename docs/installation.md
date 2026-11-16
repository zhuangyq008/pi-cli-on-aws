# 安装、更新与卸载

[← 返回 README](../README.md)

## CloudShell

```bash
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git
bash pi-cli-on-aws/install.sh
source ~/.bashrc
pi-bedrock-doctor
pi
```

安装约 1 分钟、占用约 500 MB（CloudShell `$HOME` 上限 1 GB）。安装完成后可以删除源码目录；所有文件都在 `$HOME` 下，CloudShell 重启后保留（CloudShell 的 `$HOME` 按区域独立，120 天未使用会被清理）。

## 支持的平台

| 平台 | x86_64 | arm64 | 入口 |
|---|---|---|---|
| AWS CloudShell / Linux | ✓ | ✓ | `bash install.sh` |
| macOS（bash 3.2 / zsh） | ✓ Intel | ✓ Apple Silicon | `bash install.sh` |
| Windows 10 / 11、Server 2019+（PowerShell 5.1+） | ✓ | ✓（未在 ARM64 真机上验证） | `install.ps1` |

## 本地安装：macOS / Linux

前提：已安装 [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)，身份有 Bedrock 调用权限。不需要事先配置凭证，安装器会引导配置（见"AWS 凭证引导"）。

```bash
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git
bash pi-cli-on-aws/install.sh
source ~/.zshrc          # bash 用户为 ~/.bashrc
pi-bedrock-doctor
pi
```

- 区域：未设置 `AWS_REGION` 时使用凭证引导中填写的 Region，或 AWS CLI 配置中的默认区域（`aws configure get region`）
- 凭证：pi 使用安装时选定 / 配置的 profile（记录在 env 文件中）。临时改用其他身份可 `export AWS_PROFILE=<name>`（环境变量优先）；pi 需要凭证相关环境变量才会启用 amazon-bedrock，包装器会自动设置 `AWS_PROFILE`

## 本地安装：Windows

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

1. **Git for Windows**：pi 的 bash 工具与安装逻辑运行在 Git Bash 中。已安装则复用；未安装则从 GitHub 下载官方安装包（版本与 SHA256 固定），静默安装到 `C:\Program Files\Git`（需要管理员授权 / UAC）。拒绝 UAC 或无管理员权限时改为**按当前用户**安装到 `%LOCALAPPDATA%\Programs\Git`；这种情况下 bash 中的只读 aws 命令也需逐条确认（见 [安全模型](security.md)）
2. **AWS CLI v2**：未安装时询问是否安装官方 MSI。会先校验 Amazon 的 Authenticode 签名，安装需要管理员授权（UAC）；`-InstallAwsCli` 跳过询问
3. 在 Git Bash 中运行 `install.sh`：凭证引导、私有 Node.js / pi / MCP 代理 / skills / 护栏，与 Linux 相同
4. 生成 `pi.cmd`、`pi-bedrock-doctor.cmd`、`pi-bedrock-login.cmd`，并把 `%USERPROFILE%\.local\bin` 加入**用户** PATH；在 Git Bash 中直接运行 `pi` 同样可用

参数与 `install.sh` 对应：`-Region`、`-NoProbe`、`-Model`、`-Thinking`、`-NoMcp`、`-NoSkills`、`-Skills core|full|none`、`-AllModels`、`-GitBash <bash.exe 路径>`、`-InstallAwsCli`。

Windows 上的差异：

- 推荐使用 Windows Terminal（中文显示、快捷键更完整）；pi 的换行快捷键为 `Ctrl+Enter`
- 自动带凭证的只读 `aws` 命令只信任 AWS CLI 官方 MSI 的安装位置 `C:\Program Files\Amazon\AWSCLIV2\aws.exe`，且要求 Git for Windows 也位于 Program Files（两者都仅管理员可写）；否则 bash 中的 aws 命令一律需要确认
- 公司网络无法访问证书吊销服务器（80 端口）时，Git 自带 curl 的下载会报 `CRYPT_E_REVOCATION_OFFLINE`：安装器对此使用 `--ssl-revoke-best-effort`（吊销服务器不可达时放过，证书已吊销时仍拒绝；下载内容另有 SHA256 校验）
- pi 的可选 `powershell` 工具（默认关闭）无法剥离凭证，启用后每条命令都需要确认
- 用户名包含空格或中文时，安装路径自动使用 8.3 短路径（如 `C:/Users/ZHANGS~1/...`）；如系统禁用了短路径，请设置 `PI_BEDROCK_HOME`、`PI_BIN_DIR`、`PI_CODING_AGENT_DIR` 为不含空格的目录

## AWS 凭证引导（本地安装）

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
- `/model` 默认只显示当前 Bedrock 源区域中可用的模型（见"模型列表"）
- 自动带凭证的只读 `aws` 命令只信任当前用户不可写的 aws 路径：使用官方 pkg 安装的 AWS CLI（`/usr/local/bin/aws`）时可用；Homebrew 安装（`/opt/homebrew/bin` 归当前用户所有）时，bash 中的 `aws` 命令一律需要确认（AWS MCP 不受影响）

## 安装选项

```text
bash install.sh [选项]
  --region REGION     固定 Bedrock 源区域（默认: 自动探测）
  --no-probe          不探测区域，pi 直接使用 AWS_REGION
  --model ID          默认模型（默认: global.moonshotai.kimi-k3.1）
  --thinking LEVEL    默认思考等级 off|minimal|low|medium|high|xhigh|max（默认: medium）
  --pi-version VER    pi 版本（默认: 1.5.2，可设为 latest）
  --node MODE         auto|private|system（默认: auto，复用 PATH 中 >= 22.19 的 Node.js）
  --python MODE       MCP 代理的 Python：auto|managed|system（默认: auto，复用 PATH 中的 3.11–3.14）
  --no-mcp            不安装 AWS MCP Server（节省约 120–230 MB）
  --skills SET        预装的 AWS 运维 skills：core|full|none（默认: core）
  --no-skills         同 --skills none（不装 skills 与规则文件）
  --all-models        /model 显示全部内置模型（默认只启用当前区域可用的模型）
  --no-bashrc         不修改 ~/.bashrc
```

Windows 使用 `install.ps1` 的同名参数（见"本地安装：Windows"；`-Skills core|full|none`）。Windows 上始终使用私有 Node.js、固定版本的 uv 与托管 Python（不复用本机版本）。

### 复用本机已有的 Node.js / uv / Python

| 组件 | auto（默认）的行为 | 强制隔离 |
|---|---|---|
| Node.js | PATH 中的 `node` >= 22.19 且同目录有 `npm` 时复用（含 nvm / Homebrew / volta 等；版本管理器的 shim 会解析为真实路径），否则下载私有 Node.js（约 30 MB 下载，135 MB 磁盘） | `--node private` |
| uv | PATH 中的 `uv` >= 0.5.0 时复用（Linux / macOS；只在安装时运行，依赖始终 `--require-hashes` 校验），否则下载固定版本（约 17 MB） | — |
| Python（MCP 代理） | PATH 中的 `python3.13` / `3.12` / `3.11` / `3.14` / `python3` 版本在 3.11–3.14 时复用（跳过虚拟环境中的 Python 与 macOS 的 `/usr/bin/python3`），否则由 uv 下载托管 Python（约 30 MB 下载，90 MB 磁盘） | `--python managed` |

pi 以复用的 Node.js 运行、MCP 代理以复用的 Python 运行，两者都持有 AWS 凭证。若它们位于**当前用户可写**的目录（nvm、Homebrew、pyenv 等），安装器会把其安装目录记录到 env 文件的 `PI_GUARD_RUNTIME_ROOTS`，aws-ops-guard 对 agent 写入这些目录、以及用版本管理器安装 / 升级 / 卸载运行时（`brew upgrade`、`nvm uninstall`、`pyenv uninstall` 等）的操作要求人工确认（`pi-bedrock-doctor` 会列出这些目录）。这是**尽力而为**的静态检查（覆盖 cp / mv / ln / tee / 重定向 / `sed -i` / 解释器内联代码、`cd` 后的相对路径、简单变量与通配符），无法覆盖任意脚本或复杂展开；客户生产账号或需要与用户环境完全隔离时，使用 `--node private --python managed`（运行时位于 `~/.local/share/pi-bedrock`，护栏对该目录的任何访问都要求确认）。

复用的 Node.js / Python 之后被卸载或升级到其他位置时，`pi` 与 `pi-bedrock-doctor` 会提示重新运行 `install.sh`。

### 运维 skills

skills 内置在本仓库的 `vendor/agent-toolkit-for-aws/`（[aws/agent-toolkit-for-aws](https://github.com/aws/agent-toolkit-for-aws) 固定 commit，Apache-2.0），安装时不联网。每个 skill 的描述都会进入每轮请求的 system prompt，因此默认只装日常运维需要的 core 集合；其余 skill 可由模型通过 AWS MCP 的 `aws___retrieve_skill` 在线获取。

| 集合 | skills |
|---|---|
| `core`（默认，9 个） | aws-billing-and-cost-management、aws-observability、aws-investigation、aws-iam、operations-skills（CloudWatch 可观测、告警通知、CloudTrail 多区域、网络监控、应用故障排查） |
| `full`（19 个） | core + aws-security、aws-well-architected-review、resilience-skills（Resilience Hub、ARC、FIS 等 7 个） |
| `none` | 不装 skills 与运维规则 |

也可以用 `PI_AWS_SKILLS="core-skills/aws-iam specialized-skills/operations-skills"` 指定 `vendor/agent-toolkit-for-aws/skills/` 下的任意目录组合。

安装器是幂等的：重复运行会跳过已安装组件、重新探测区域并刷新配置；重新运行时加 `--no-mcp` / `--skills none` 会移除之前安装的对应组件，切换 `--skills` 集合会整体替换已装的 skills。

Bedrock 区域探测、MCP 代理安装（uv / Python / 依赖）与 Node.js / pi 安装在后台并行进行，后台任务的日志在完成后统一显示。使用自定义 `PI_BEDROCK_HOME` / `PI_BIN_DIR` / `PI_CODING_AGENT_DIR` 时，路径会记录在 env 文件中，卸载时自动沿用。

## 运行时环境变量

| 变量 | 说明 |
|---|---|
| `PI_BEDROCK_REGION` | 覆盖 Bedrock 源区域（优先于 `~/.local/share/pi-bedrock/env`） |
| `PI_OPS_AWS_REGION` | 覆盖运维区域（AWS MCP 默认操作区域） |
| `PI_AWS_MCP_ENDPOINT_REGION` | 覆盖 AWS MCP Server endpoint 区域（默认按运维区域就近选择 8 个支持区域之一） |
| `PI_AWS_OPS_GUARD` | `confirm`（默认）/ `readonly` / `off` |

## 修改了哪些文件

| 路径 | 内容 | 卸载时 |
|---|---|---|
| `~/.local/bin/pi`、`pi-bedrock-doctor` | 包装器与自检脚本 | 删除（若安装前有同名文件则恢复） |
| `~/.local/share/pi-bedrock/` | pi、MCP proxy、env 配置、`settings.orig.json`（安装前的原值）；未复用本机版本时还有私有 Node、uv、托管 Python | 删除（复用的本机 Node / uv / Python 不受影响） |
| `~/.pi/agent/settings.json` | `defaultProvider` / `defaultModel` / `defaultThinkingLevel` / `enabledModels` / `shellCommandPrefix` / `selfUpdateCommand` | 恢复安装前的原值（安装后被用户改过的保留） |
| `~/.pi/agent/mcp.json` | `aws-mcp` 条目（不覆盖用户自建的同名条目） | 删除该条目 |
| `~/.pi/agent/AGENTS.md` | 托管段落（段落外的用户内容不受影响） | 删除该段落 |
| `~/.pi/agent/skills/aws-agent-toolkit/` | 官方 skills（`--skills` 选择的集合） | 删除 |
| `~/.pi/agent/extensions/aws-ops-guard/` | 写操作护栏（只读；原有同名目录备份到 `~/.pi/agent/.pi-bedrock-backup/`） | 删除并恢复备份 |
| `~/.bashrc` | 托管段落：把 `~/.local/bin` 加到 PATH | 删除该段落 |
| `~/.aws/credentials`、`~/.aws/config` | 仅在凭证引导中选择 1 / 2 / 3 时写入 `[pi-bedrock]` profile | **保留**（可用 `aws configure` 管理） |
| `~/.local/bin/*.cmd`（Windows） | pi / doctor / login 的 cmd shim | 删除 |
| 用户 PATH（Windows，`HKCU\Environment`） | 加入 `%USERPROFILE%\.local\bin` | 移除 |
| `settings.json` 的 `shellPath`（Windows） | 指向安装时使用的 Git Bash | 恢复安装前的原值 |

修改 JSON 文件前会备份为 `*.pi-bedrock.bak`；JSON 不合法时拒绝修改。

## 更新

获取最新源码后重新运行安装器即可，过程是增量的：已安装的 Node.js、pi、MCP proxy 会跳过，skills 按 `--skills` 重新复制（本地复制，不联网），运维规则（`~/.pi/agent/AGENTS.md` 托管段落）、护栏扩展、包装器与 settings 会更新为新版本。请使用**与首次安装相同的参数**（例如首次用了 `--no-mcp`，更新时也要带上，否则会重新安装 MCP）。

CloudShell / macOS / Linux：

```bash
# 源码目录还在：git -C pi-cli-on-aws pull；已删除则重新 clone
git clone https://github.com/zhuangyq008/pi-cli-on-aws.git 2>/dev/null || git -C pi-cli-on-aws pull
bash pi-cli-on-aws/install.sh
```

Windows（PowerShell）：重新下载 zip 并解压（见"本地安装：Windows"），然后运行 `powershell -ExecutionPolicy Bypass -File .\pi-cli-on-aws-main\install.ps1`。

更新后需要**重新启动 pi**（已打开的会话仍使用旧规则）。可以运行 `pi-bedrock-doctor` 自检，或用 `grep -c 工具选择 ~/.pi/agent/AGENTS.md` 确认新规则已生效（输出 1）。

## 卸载

```bash
bash ~/.local/share/pi-bedrock/uninstall.sh
```

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\.local\share\pi-bedrock\uninstall.ps1
```

会话、`auth.json` 等用户数据保留在 `~/.pi/agent`，`~/.aws` 中的凭证保留；Windows 上不会卸载 Git for Windows 与 AWS CLI。

---

## 模型与区域

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
