#!/usr/bin/env bash
# 在本机模拟 AWS CloudShell 运行环境，对 install.sh → pi → Bedrock 做端到端验证。
# 模拟内容：
#   - 独立 $HOME（CloudShell 只持久化 $HOME）
#   - AWS_EXECUTION_ENV=CloudShell、AWS_REGION/AWS_DEFAULT_REGION=SIM_REGION
#   - 凭证仅来自 localhost 容器凭证端点（与 CloudShell 相同机制），禁用 IMDS
#   - PATH 中只有低于 22.19 的 Node（模拟 CloudShell 自带 Node 版本不足）
# 覆盖：安装 → Bedrock 对话 → bash 工具区域还原 → AWS MCP 只读调用 → 写操作护栏（非交互拒绝 / 交互拒绝）→ doctor → 幂等 → 卸载
# 注意：会产生少量真实 Bedrock 调用与只读 AWS API 调用；写操作应被护栏拦截（若未拦截，测试会删除创建的告警并判定失败）。
# 用法: bash tests/e2e/cloudshell-sim.sh   可选环境变量: SIM_REGION SIM_CREDS_PORT KEEP_WORK=1
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 默认使用 ap-northeast-1：既验证"运维区域经环境变量传给 MCP"（不依赖 us-east-1 默认值），也覆盖 Bedrock 同大洲回退
SIM_REGION="${SIM_REGION:-ap-northeast-1}"
PORT="${SIM_CREDS_PORT:-1338}"
WORK="$(mktemp -d /tmp/pi-cloudshell-sim.XXXXXX)"
SIM_HOME="$WORK/home"
PROJECT="$WORK/project"
mkdir -p "$SIM_HOME" "$PROJECT"

HOST_NODE="$(command -v node)" || { echo "需要宿主机 node 运行凭证端点" >&2; exit 1; }
AWS_BIN_DIR="$(dirname "$(command -v aws)")"
TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ALARM_PREFIX="pi-bedrock-e2e-guard-$(date +%s)"
PASS=0
FAIL=0

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  if [ "${KEEP_WORK:-0}" = 1 ]; then echo "保留工作目录: $WORK"; else chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; fi
}
trap cleanup EXIT

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
creds_hits() { grep -c 'auth=true' "$WORK/creds.log" 2>/dev/null || true; }
guard_log() { cat "$SIM_HOME/.pi/agent/aws-ops-guard.log" 2>/dev/null || true; }
# 护栏失效时的兜底清理：告警若被创建则删除并返回 0（表示"存在过"）
alarm_created() {
  local name="$1" r found=1
  for r in "$SIM_REGION" ${CHOSEN:+"$CHOSEN"}; do
    if [ "$(aws cloudwatch describe-alarms --region "$r" --alarm-names "$name" --query 'length(MetricAlarms)' --output text 2>/dev/null)" != 0 ]; then
      aws cloudwatch delete-alarms --region "$r" --alarm-names "$name" >/dev/null 2>&1 || true
      found=0
    fi
  done
  return "$found"
}

# ---- 启动模拟凭证端点 ----
step "启动模拟 CloudShell 容器凭证端点 localhost:$PORT"
# 凭证经 0600 文件传给模拟端点（不放在进程环境变量中）
(umask 077 && aws configure export-credentials --format process >"$WORK/creds.json")
SIM_CREDS_FILE="$WORK/creds.json" SIM_TOKEN="$TOKEN" SIM_LOG="$WORK/creds.log" \
  "$HOST_NODE" "$REPO_ROOT/tests/e2e/creds-server.mjs" "$PORT" >"$WORK/server.out" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do grep -q ready "$WORK/server.out" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$WORK/server.out" || { cat "$WORK/server.out"; exit 1; }

SIM_ENV=(env -i
  HOME="$SIM_HOME" USER="${USER:-cloudshell-user}" TERM=xterm-256color LANG=C.UTF-8
  PATH="$(dirname "$HOST_NODE"):$AWS_BIN_DIR:/usr/bin:/bin"
  AWS_EXECUTION_ENV=CloudShell AWS_REGION="$SIM_REGION" AWS_DEFAULT_REGION="$SIM_REGION"
  AWS_CONTAINER_CREDENTIALS_FULL_URI="http://localhost:$PORT/latest/meta-data/container/security-credentials"
  AWS_CONTAINER_AUTHORIZATION_TOKEN="$TOKEN"
  AWS_EC2_METADATA_DISABLED=true
)
# 新开 CloudShell 标签页 = 登录 shell 读取 ~/.bashrc
in_shell() { (cd "$PROJECT" && "${SIM_ENV[@]}" bash -c "source ~/.bashrc >/dev/null 2>&1; $1" </dev/null); }

check "凭证仅来自容器端点（模拟环境内 sts 可用）" \
  bash -c "\"\${@}\" aws sts get-caller-identity --query Account --output text >/dev/null" _ "${SIM_ENV[@]}"
echo "  宿主 Node: $("$HOST_NODE" -v)（模拟 CloudShell 自带的旧版 Node）"

# ---- 1. 安装 ----
step "1. 运行 install.sh（CloudShell 区域 $SIM_REGION）"
INSTALL_START=$(date +%s)
if (cd "$PROJECT" && "${SIM_ENV[@]}" bash "$REPO_ROOT/install.sh") >"$WORK/install.log" 2>&1; then
  pass "install.sh 成功（$(($(date +%s) - INSTALL_START)) 秒）"
else
  fail "install.sh 失败"; cat "$WORK/install.log"; exit 1
fi
sed 's/^/    | /' "$WORK/install.log"
check "旧版系统 Node 被识别并安装了私有 Node" grep -q "安装私有 Node.js" "$WORK/install.log"
check "所有文件都在 \$HOME 内" test -x "$SIM_HOME/.local/share/pi-bedrock/npm-global/bin/pi"
check "包装器已安装" grep -q pi-cli-bedrock-wrapper "$SIM_HOME/.local/bin/pi"
check "settings.json 默认 provider/model" grep -q '"defaultModel": "global.moonshotai.kimi-k3.1"' "$SIM_HOME/.pi/agent/settings.json"
check "mcp-proxy-for-aws-cli 安装在 \$HOME 内（依赖哈希锁定）" test -x "$SIM_HOME/.local/share/pi-bedrock/uv/venv/bin/mcp-proxy-for-aws-cli"
check "护栏与运行时文件为只读" bash -c "[ ! -w '$SIM_HOME/.pi/agent/extensions/aws-ops-guard/index.ts' ] && [ ! -w '$SIM_HOME/.local/share/pi-bedrock/lib/config.sh' ]"
check "mcp.json 中配置了 aws-mcp" grep -q '"aws-mcp"' "$SIM_HOME/.pi/agent/mcp.json"
check "aws-ops-guard 扩展已安装" test -f "$SIM_HOME/.pi/agent/extensions/aws-ops-guard/index.ts"
SKILLS="$(find "$SIM_HOME/.pi/agent/skills" -name SKILL.md | wc -l)"
check "预装 AWS 运维 skills（$SKILLS 个）" test "$SKILLS" -gt 10
check "AGENTS.md 写入运维规则" grep -q '先查后改' "$SIM_HOME/.pi/agent/AGENTS.md"
check "enabledModels 只包含当前区域可用模型（含默认模型）" node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const m = s.enabledModels ?? [];
  process.exit(m.length > 0 && m.length < 150 && m[0] === "amazon-bedrock/global.moonshotai.kimi-k3.1" ? 0 : 1);
' "$SIM_HOME/.pi/agent/settings.json"
CHOSEN="$(sed -n 's/^PI_BEDROCK_REGION=//p' "$SIM_HOME/.local/share/pi-bedrock/env")"
echo "  选定 Bedrock 源区域: ${CHOSEN:-跟随 AWS_REGION}"
echo "  安装占用: $(du -sh "$SIM_HOME/.local/share/pi-bedrock" | cut -f1)，\$HOME 总计 $(du -sh "$SIM_HOME" | cut -f1)"

# ---- 2. 新 shell ----
step "2. 新 shell 中的 pi"
WHICH_PI="$(in_shell 'command -v pi')"
check "PATH 中的 pi 指向包装器（$WHICH_PI）" test "$WHICH_PI" = "$SIM_HOME/.local/bin/pi"
VERSION="$(in_shell 'pi --version')"
check "pi --version = $VERSION（旧版 Node 未被 shebang 选中）" test -n "$VERSION"
MODELS="$(in_shell 'pi --list-models kimi-k3.1' 2>&1 || true)"
check "pi --list-models 包含 Kimi K3.1（amazon-bedrock 已识别容器凭证）" grep -q "global.moonshotai.kimi-k3.1" <<<"$MODELS"

# ---- 3. 对话 ----
step "3. pi -p 通过 Bedrock 调用 Kimi K3.1"
HITS_BEFORE="$(creds_hits)"
OUT="$(in_shell 'timeout 240 pi -p --no-session --no-tools --mode json "Join the two words PI_BEDROCK and E2E_OK with an underscore and reply with only the result."' 2>&1 || true)"
LAST="$(printf '%s' "$OUT" | "$HOST_NODE" "$REPO_ROOT/tests/e2e/last-assistant.mjs")"
echo "    | $LAST"
check "助手回复 PI_BEDROCK_E2E_OK（非 prompt 回显）" grep -q '"text":"PI_BEDROCK_E2E_OK' <<<"$LAST"
check "实际使用 amazon-bedrock / Kimi K3.1 且未报错" grep -q '"provider":"amazon-bedrock","model":"global.moonshotai.kimi-k3.1","stopReason":"stop"' <<<"$LAST"
check "pi 进程从容器凭证端点获取了凭证（$HITS_BEFORE → $(creds_hits)）" test "$(creds_hits)" -gt "$HITS_BEFORE"

# ---- 4. bash 工具中的区域 ----
step "4. agent 的 bash 工具看到的仍是 CloudShell 原区域"
# shellcheck disable=SC2016 # $AWS_REGION 需在 agent 的 bash 工具中展开
JSON="$(in_shell 'timeout 300 pi -p --no-session --mode json "Use the bash tool to run exactly this command: echo SHELL_REGION=\$AWS_REGION . Then reply DONE."' 2>&1 || true)"
printf '%s\n' "$JSON" >"$WORK/tool.jsonl"
check "bash 工具输出 SHELL_REGION=$SIM_REGION" grep -q "SHELL_REGION=$SIM_REGION" "$WORK/tool.jsonl"
if [ -n "$CHOSEN" ] && [ "$CHOSEN" != "$SIM_REGION" ]; then
  check "bash 工具未泄漏 Bedrock 源区域 $CHOSEN" bash -c "! grep -q 'SHELL_REGION=$CHOSEN' '$WORK/tool.jsonl'"
fi

step "4b. bash 凭证模型：普通命令无凭证，简单只读 aws 命令自动带凭证"
# shellcheck disable=SC2016
in_shell 'timeout 300 pi -p --no-session --mode json "Use the bash tool to run exactly this command, then reply DONE: echo CRED_VARS=\$(printenv | cut -d= -f1 | grep -c -e _TOKEN -e _KEY_ID -e _FULL_URI)"' >"$WORK/bash-nocreds.jsonl" 2>&1 || true
check "普通 bash 命令中没有 AWS 凭证变量（CRED_VARS=0）" grep -q 'CRED_VARS=0' "$WORK/bash-nocreds.jsonl"
in_shell 'timeout 300 pi -p --no-session --mode json "Use the bash tool to run exactly this command, then reply DONE: aws sts get-caller-identity --query Account --output text"' >"$WORK/bash-aws.jsonl" 2>&1 || true
check "简单只读 aws 命令自动带凭证执行（返回账号 $ACCOUNT）" grep -q "$ACCOUNT" "$WORK/bash-aws.jsonl"
check "简单只读 aws 命令未触发确认" bash -c "! grep -q 'aws sts get-caller-identity' '$SIM_HOME/.pi/agent/aws-ops-guard.log' 2>/dev/null"

# ---- 5. AWS MCP 只读调用 ----
step "5. AWS MCP Server：连接与只读调用"
MCP_LIST="$(in_shell 'timeout 180 pi mcp list' 2>&1 || true)"
check "pi mcp list: aws-mcp connected" grep -q "aws-mcp: connected" <<<"$MCP_LIST"
READ_PROMPT="使用 aws___run_script 执行一次脚本：调用 sts 的 GetCallerIdentity，以及 ec2 的 DescribeAvailabilityZones（不要传 region_name）。最后只输出一行：ACCOUNT=<账号ID> ZONES=<逗号分隔的 ZoneName>"
GUARD_BEFORE="$(guard_log | wc -l)"
in_shell "timeout 400 pi -p --no-session --mode json '$READ_PROMPT'" >"$WORK/mcp-read.jsonl" 2>&1 || true
check "调用了 mcp__aws_mcp__aws___run_script" grep -q '"toolName":"mcp__aws_mcp__aws___run_script"' "$WORK/mcp-read.jsonl"
check "返回账号 $ACCOUNT" grep -q "ACCOUNT=$ACCOUNT" "$WORK/mcp-read.jsonl"
check "默认运维区域为 CloudShell 区域 $SIM_REGION（而非 Bedrock 区域 ${CHOSEN:-无}）" grep -q "${SIM_REGION}a" "$WORK/mcp-read.jsonl"
check "只读调用未被护栏拦截（审计日志无新增）" test "$(guard_log | wc -l)" -eq "$GUARD_BEFORE"

# ---- 6. 写操作护栏 ----
step "6. 写操作护栏"
write_prompt() { printf '在 CloudWatch 中创建一个名为 %s 的告警：指标 AWS/EC2 CPUUtilization，统计 Average，周期 300 秒，阈值大于 99，1 个评估周期，不需要通知。' "$1"; }
ALARM1="$ALARM_PREFIX-noninteractive"
in_shell "timeout 400 pi -p --no-session --mode json '$(write_prompt "$ALARM1")'" >"$WORK/guard-p.jsonl" 2>&1 || true
check "非交互模式（pi -p）写操作被拒绝并记录审计日志" grep -q '"decision":"blocked-noninteractive"' <<<"$(guard_log)"
if alarm_created "$ALARM1"; then fail "告警 $ALARM1 被创建（已清理）——护栏失效"; else pass "告警 $ALARM1 未被创建"; fi

ALARM2="$ALARM_PREFIX-interactive"
# shellcheck disable=SC2016 # 命令在模拟 CloudShell 的 shell 中展开
RPC_CMD='node_bin="$(sed -n "s/^PI_BEDROCK_NODE_BIN=//p" ~/.local/share/pi-bedrock/env)"; timeout 450 "$node_bin/node" "$1" "$(command -v pi)" "$2" 400'
RPC_OUT="$(cd "$PROJECT" && "${SIM_ENV[@]}" bash -c "source ~/.bashrc >/dev/null 2>&1; $RPC_CMD" _ "$REPO_ROOT/tests/e2e/rpc-deny.mjs" "$(write_prompt "$ALARM2")" </dev/null 2>/dev/null || true)"
printf '%s\n' "$RPC_OUT" >"$WORK/guard-rpc.json"
check "交互模式（RPC）弹出写操作确认框" grep -q '需要确认的操作' "$WORK/guard-rpc.json"
check "用户选择拒绝后记录 denied 审计日志" grep -q '"decision":"denied"' <<<"$(guard_log)"
if alarm_created "$ALARM2"; then fail "告警 $ALARM2 被创建（已清理）——护栏失效"; else pass "告警 $ALARM2 未被创建"; fi
echo "  审计日志:"; guard_log | sed 's/^/    | /' | cut -c1-220

# ---- 7. doctor ----
step "7. pi-bedrock-doctor"
if in_shell 'pi-bedrock-doctor' >"$WORK/doctor.log" 2>&1; then pass "doctor 全部通过"; else fail "doctor 报告问题"; fi
sed 's/^/    | /' "$WORK/doctor.log"

# ---- 8. 幂等 ----
step "8. 重复安装（幂等）"
if (cd "$PROJECT" && "${SIM_ENV[@]}" bash "$REPO_ROOT/install.sh") >"$WORK/install2.log" 2>&1; then pass "二次安装成功"; else fail "二次安装失败"; fi
check "跳过已安装的 pi" grep -q "已安装，跳过" "$WORK/install2.log"
check "复用私有 Node" grep -q "复用私有 Node.js" "$WORK/install2.log"
check "跳过已安装的 MCP proxy 与 skills" grep -q "mcp-proxy-for-aws-cli 1.8.0 已安装，跳过" "$WORK/install2.log"
check ".bashrc 中仅一个托管段落" test "$(grep -c '>>> pi-bedrock >>>' "$SIM_HOME/.bashrc")" -eq 1

# ---- 9. 卸载 ----
step "9. 卸载"
if in_shell "bash ~/.local/share/pi-bedrock/uninstall.sh" >"$WORK/uninstall.log" 2>&1; then pass "uninstall.sh 成功"; else fail "uninstall.sh 失败"; cat "$WORK/uninstall.log"; fi
check "安装目录已删除" test ! -e "$SIM_HOME/.local/share/pi-bedrock"
check "包装器已删除" test ! -e "$SIM_HOME/.local/bin/pi"
check ".bashrc 托管段落已移除" bash -c "! grep -q 'pi-bedrock' '$SIM_HOME/.bashrc'"
check "mcp.json 中的 aws-mcp 已移除" bash -c "! grep -q aws-mcp '$SIM_HOME/.pi/agent/mcp.json'"
check "skills / 扩展 / AGENTS 段落已移除" bash -c "[ ! -e '$SIM_HOME/.pi/agent/skills/aws-agent-toolkit' ] && [ ! -e '$SIM_HOME/.pi/agent/extensions/aws-ops-guard' ] && ! grep -q pi-bedrock '$SIM_HOME/.pi/agent/AGENTS.md'"
check "settings.json 中的默认模型已回滚" bash -c "! grep -q defaultModel '$SIM_HOME/.pi/agent/settings.json'"
check "用户会话目录保留" test -d "$SIM_HOME/.pi/agent"

printf '\n结果: %d 通过, %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
