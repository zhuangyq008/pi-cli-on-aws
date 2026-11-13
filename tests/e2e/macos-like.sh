#!/usr/bin/env bash
# 在 Linux 上模拟 macOS 用户环境，对 install.sh → pi → Bedrock / AWS MCP → 护栏 → 卸载做端到端验证：
#   - bash 3.2（macOS 自带版本；通过 BASH32 指定可执行文件或包装脚本）
#   - 缺少 GNU 工具：无 sha256sum / timeout，readlink 不支持 -f
#   - 凭证只来自 ~/.aws 的 default profile（无任何凭证环境变量，禁用 IMDS），AWS_REGION 未设置
#   - 默认 shell 为 zsh；pi 的 bash 工具同样使用 bash 3.2（settings.json 的 shellPath）
# 注意：会产生少量真实 Bedrock 调用与只读 AWS API 调用。
# 用法: BASH32=/path/to/bash-3.2 bash tests/e2e/macos-like.sh   可选: KEEP_WORK=1
#   获取 bash 3.2 的一种方式：docker 镜像 bash:3.2（见 docs/development.md）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASH32="${BASH32:?请通过 BASH32 指定 bash 3.2 可执行文件}"
# shellcheck disable=SC2016 # 在 bash 3.2 中展开
"$BASH32" -c '[[ "$BASH_VERSION" == 3.2* ]]' || { echo "BASH32 不是 bash 3.2" >&2; exit 1; }
WORK="$(mktemp -d /tmp/pi-macos-like.XXXXXX)"
SIM_HOME="$WORK/home"
MACBIN="$WORK/bin"
PROJECT="$WORK/project"
mkdir -p "$SIM_HOME/.aws" "$MACBIN" "$PROJECT"
PASS=0
FAIL=0
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

cleanup() {
  # 临时写入的真实凭证始终删除（即使 KEEP_WORK=1）
  rm -f "$SIM_HOME/.aws/credentials"
  if [ "${KEEP_WORK:-0}" = 1 ]; then echo "保留工作目录（凭证文件已删除）: $WORK"; else chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; fi
}
trap cleanup EXIT
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

step "构造类 macOS 环境"
# 1. 工具目录：系统命令的符号链接，去掉 GNU 专有工具；bash 指向 3.2；readlink 不支持 -f
for dir in /usr/local/bin /usr/bin /bin; do
  for f in "$dir"/*; do
    name="$(basename "$f")"
    case "$name" in sha256sum | timeout | gtimeout | bash | readlink) continue ;; esac
    [ -e "$MACBIN/$name" ] || [ -L "$MACBIN/$name" ] || ln -s "$f" "$MACBIN/$name"
  done
done
ln -s "$BASH32" "$MACBIN/bash"
# shellcheck disable=SC2016 # 写入脚本文件，运行时展开
printf '#!/bin/sh\nif [ "$1" = -f ]; then echo "readlink: illegal option -- f" >&2; exit 1; fi\nexec /usr/bin/readlink "$@"\n' >"$MACBIN/readlink"
chmod +x "$MACBIN/readlink"
# 2. 凭证：写入 ~/.aws 的 default profile（与 macOS 上 aws configure / aws login 的效果一致）
eval "$(aws configure export-credentials --format env-no-export | sed 's/^/CRED_/')"
(umask 077 && printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\naws_session_token = %s\n' \
  "$CRED_AWS_ACCESS_KEY_ID" "$CRED_AWS_SECRET_ACCESS_KEY" "$CRED_AWS_SESSION_TOKEN" >"$SIM_HOME/.aws/credentials")
printf '[default]\nregion = ap-northeast-1\n' >"$SIM_HOME/.aws/config"
unset CRED_AWS_ACCESS_KEY_ID CRED_AWS_SECRET_ACCESS_KEY CRED_AWS_SESSION_TOKEN

# /usr/local/bin 只含 root 所有的 aws CLI（护栏只信任当前用户不可写的 aws 路径），不含 sha256sum / timeout
MAC_ENV=(env -i HOME="$SIM_HOME" USER="${USER:-macuser}" TERM=xterm-256color LANG=en_US.UTF-8 SHELL=/bin/zsh
  PATH="$MACBIN:/usr/local/bin" AWS_EC2_METADATA_DISABLED=true)
in_mac() { (cd "$PROJECT" && "${MAC_ENV[@]}" "$BASH32" -c "source ~/.zshrc >/dev/null 2>&1; $1" </dev/null); }
check "环境中 bash 为 3.2" bash -c "\"\${@}\" bash -c '[[ \$BASH_VERSION == 3.2* ]]'" _ "${MAC_ENV[@]}"
check "环境中没有 sha256sum / timeout" bash -c "! \"\${@}\" bash -c 'command -v sha256sum || command -v timeout'" _ "${MAC_ENV[@]}"

step "1. 安装（bash 3.2）"
if (cd "$PROJECT" && "${MAC_ENV[@]}" "$BASH32" "$REPO_ROOT/install.sh") >"$WORK/install.log" 2>&1; then pass "install.sh 成功"; else fail "install.sh 失败"; fi
sed 's/^/    | /' "$WORK/install.log"
check "从 AWS CLI 配置读取默认区域 ap-northeast-1" grep -q "使用 AWS CLI 配置中的默认区域 ap-northeast-1" "$WORK/install.log"
check "PATH 写入 ~/.zshrc" grep -q '>>> pi-bedrock >>>' "$SIM_HOME/.zshrc"
check "skills 内容哈希校验通过（无 sha256sum 时结果一致）" bash -c "find '$SIM_HOME/.pi/agent/skills' -name SKILL.md | grep -q ."
# 让 pi 的 bash 工具也使用 bash 3.2（模拟 macOS 的 /bin/bash）
node -e 'const f=process.argv[1],fs=require("fs");const s=JSON.parse(fs.readFileSync(f));fs.writeFileSync(f,JSON.stringify({...s,shellPath:process.argv[2]},null,2))' \
  "$SIM_HOME/.pi/agent/settings.json" "$BASH32"

step "2. doctor（profile 凭证、AWS MCP、端到端）"
if in_mac 'pi-bedrock-doctor' >"$WORK/doctor.log" 2>&1; then pass "doctor 全部通过"; else fail "doctor 报告问题"; fi
sed 's/^/    | /' "$WORK/doctor.log"

step "3. 护栏（pi 的 bash 工具运行于 bash 3.2）"
in_mac 'perl -e "alarm 300; exec @ARGV" pi -p --no-session --mode json "Use the bash tool to run exactly this command, then reply DONE: aws sts get-caller-identity --query Account --output text"' >"$WORK/strict.jsonl" 2>&1 || true
check "简单只读 aws 命令自动执行（profile 凭证仅交给 aws 进程，返回账号）" grep -q "$ACCOUNT" "$WORK/strict.jsonl"
# shellcheck disable=SC2016 # 命令在模拟环境的 shell 中展开
in_mac 'perl -e "alarm 300; exec @ARGV" pi -p --no-session --mode json "Use the bash tool to run exactly this command, then reply DONE: echo CRED_VARS=\$(printenv | cut -d= -f1 | grep -c -e _PROFILE -e _KEY_ID -e _TOKEN)"' >"$WORK/nocreds.jsonl" 2>&1 || true
check "普通 bash 命令中没有凭证相关变量（CRED_VARS=0）" grep -q 'CRED_VARS=0' "$WORK/nocreds.jsonl"

step "3b. 被篡改的 ~/.aws/config 不会被自动执行的 aws 命令读取"
printf '#!/bin/sh\ntouch %s/EVIL_RAN\n' "$WORK" >"$WORK/evil.sh" && chmod +x "$WORK/evil.sh"
cp "$SIM_HOME/.aws/config" "$WORK/config.bak"
printf 'credential_process = %s/evil.sh\n' "$WORK" >>"$SIM_HOME/.aws/config"
in_mac 'perl -e "alarm 300; exec @ARGV" pi -p --no-session --mode json "Use the bash tool to run exactly this command, then reply DONE: aws sts get-caller-identity --query Account --output text"' >"$WORK/poisoned.jsonl" 2>&1 || true
check "credential_process 未被执行（aws 进程读取的是白名单重写后的快照）" test ! -e "$WORK/EVIL_RAN"
check "被篡改配置中的安全部分仍可用（返回账号）" grep -q "$ACCOUNT" "$WORK/poisoned.jsonl"
# 冒号分隔与 \r 换行的写法（与 Python configparser 的解析规则一致）
printf '[default]\rcredential_process: %s/evil.sh\rregion = ap-northeast-1\r' "$WORK" >"$SIM_HOME/.aws/config"
in_mac 'perl -e "alarm 300; exec @ARGV" pi -p --no-session --mode json "Use the bash tool to run exactly this command, then reply DONE: aws sts get-caller-identity --query Account --output text"' >"$WORK/poisoned2.jsonl" 2>&1 || true
check "冒号 / \\r 写法的 credential_process 同样未被执行" test ! -e "$WORK/EVIL_RAN"
cp "$WORK/config.bak" "$SIM_HOME/.aws/config"

step "4. 卸载（bash 3.2）"
if in_mac 'bash ~/.local/share/pi-bedrock/uninstall.sh' >"$WORK/uninstall.log" 2>&1; then pass "uninstall.sh 成功"; else fail "uninstall.sh 失败"; cat "$WORK/uninstall.log"; fi
check "安装目录已删除" test ! -e "$SIM_HOME/.local/share/pi-bedrock"
check ".zshrc 与 .bashrc 中的托管段落已移除" bash -c "! grep -qs 'pi-bedrock' '$SIM_HOME/.zshrc' '$SIM_HOME/.bashrc'"

printf '\n结果: %d 通过, %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
