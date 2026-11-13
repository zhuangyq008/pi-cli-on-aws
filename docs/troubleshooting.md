# 故障排查

[← 返回 README](../README.md)

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
