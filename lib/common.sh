# shellcheck shell=bash
# 公共常量与工具函数。由 install.sh / uninstall.sh / bin/* source，不直接执行。

# ---- 默认值（均可通过同名环境变量覆盖）-------------------------------------
: "${PI_PACKAGE:=@earendil-works/pi-coding-agent}"
: "${PI_VERSION:=1.5.2}"                      # 已验证版本；设为 latest 可跟随上游
: "${PI_MIN_NODE:=22.19.0}"                   # pi 的 engines.node 下限
: "${PI_NODE_DIST_BASE:=https://nodejs.org/dist}"
: "${PI_BEDROCK_PROVIDER:=amazon-bedrock}"
: "${PI_BEDROCK_MODEL:=global.moonshotai.kimi-k3.1}"
: "${PI_BEDROCK_THINKING:=medium}"
: "${PI_BEDROCK_HOME:=$HOME/.local/share/pi-bedrock}"
: "${PI_BIN_DIR:=$HOME/.local/bin}"
: "${PI_CODING_AGENT_DIR:=$HOME/.pi/agent}"

# ---- 日志 ----------------------------------------------------------------
if [ -t 2 ]; then
  _C_RED=$'\033[31m' _C_YEL=$'\033[33m' _C_GRN=$'\033[32m' _C_DIM=$'\033[2m' _C_OFF=$'\033[0m'
else
  _C_RED='' _C_YEL='' _C_GRN='' _C_DIM='' _C_OFF=''
fi

log_info() { printf '%s==>%s %s\n' "$_C_GRN" "$_C_OFF" "$*" >&2; }
log_warn() { printf '%sWARN:%s %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
log_error() { printf '%sERROR:%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; }
log_debug() { [ "${PI_BEDROCK_DEBUG:-0}" = 1 ] && printf '%s[debug] %s%s\n' "$_C_DIM" "$*" "$_C_OFF" >&2; return 0; }
die() { log_error "$*"; exit 1; }

# ---- 版本比较 --------------------------------------------------------------
# version_ge A B：A >= B 时返回 0。接受 "v22.19.0" / "22.19.0" / "22.19"。
version_ge() {
  local a="${1#v}" b="${2#v}"
  [[ "$a" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 2
  [[ "$b" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 2
  local IFS=.
  # shellcheck disable=SC2206
  local -a va=($a) vb=($b)
  local i x y
  for i in 0 1 2; do
    x="${va[$i]:-0}" y="${vb[$i]:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

# ---- 平台识别 --------------------------------------------------------------
# 输出 Node 官方发行包使用的架构名
node_arch() {
  case "${1:-$(uname -m)}" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

is_cloudshell() { [ "${AWS_EXECUTION_ENV:-}" = "CloudShell" ]; }

# ---- 输入校验 --------------------------------------------------------------
is_valid_region() { [[ "${1:-}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]]; }

# Bedrock 模型 / 推理配置文件 ID，例如 global.moonshotai.kimi-k3.1 或 inference-profile ARN
is_valid_model_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{2,255}$ ]]; }

is_valid_thinking() {
  case "${1:-}" in off | minimal | low | medium | high | xhigh | max) return 0 ;; *) return 1 ;; esac
}

# npm 版本说明符：语义化版本或 dist-tag
is_valid_pi_version() { [[ "${1:-}" =~ ^([0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?|latest|next)$ ]]; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
  done
}
