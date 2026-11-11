# shellcheck shell=bash
# 公共常量与工具函数。由 install.sh / uninstall.sh / bin/* source，不直接执行。

# ---- 平台识别 --------------------------------------------------------------
# 输出 Node / uv 发行包使用的系统名：linux | darwin | windows（Git for Windows 的 Git Bash / MSYS2）
os_name() {
  case "${1:-$(uname -s)}" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    MINGW* | MSYS*) printf 'windows' ;;
    *) return 1 ;;
  esac
}

is_windows() { [ "$(os_name 2>/dev/null)" = windows ]; }

# native_path PATH：Windows 上转换为原生程序可用的 C:/... 形式（node.exe、uv.exe、aws.exe 不认识 /c/...、/tmp/...）
native_path() {
  if is_windows; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# 安装路径的基准目录：Windows 上用 C:/Users/<name> 形式；用户名含空格或非 ASCII 字符时改用 8.3 短路径
_pi_base_home() {
  local h="$HOME"
  if is_windows; then
    h="$(cygpath -m "$HOME")"
    [[ "$h" =~ ^[A-Za-z]:/[A-Za-z0-9._/@+-]+$ ]] || h="$(cygpath -m -s "$HOME" 2>/dev/null || printf '%s' "$h")"
  fi
  printf '%s' "$h"
}

# git_bash_path：Git for Windows 的 bin\bash.exe（Windows 路径形式）。优先使用 install.ps1 传入的 PI_GIT_BASH；
# 否则为当前 Git Bash 的安装根目录下的 bin/bash.exe（会设置 MSYSTEM 与 PATH，供 pi.cmd、settings.shellPath、MCP 使用）
git_bash_path() {
  local p="${PI_GIT_BASH:-}" root
  if [ -z "$p" ]; then
    root="$(cygpath -m / 2>/dev/null)" || return 1
    p="${root%/}/bin/bash.exe"
  fi
  [ -f "$p" ] || return 1
  cygpath -w "$p"
}

# ---- 默认值（均可通过同名环境变量覆盖）-------------------------------------
_PI_BASE_HOME="$(_pi_base_home)"
: "${PI_PACKAGE:=@earendil-works/pi-coding-agent}"
: "${PI_VERSION:=1.5.2}"                      # 已验证版本；设为 latest 可跟随上游
: "${PI_MIN_NODE:=22.19.0}"                   # pi 的 engines.node 下限
: "${PI_NODE_DIST_BASE:=https://nodejs.org/dist}"
: "${PI_BEDROCK_PROVIDER:=amazon-bedrock}"
: "${PI_BEDROCK_MODEL:=global.moonshotai.kimi-k3.1}"
: "${PI_BEDROCK_THINKING:=medium}"
: "${PI_BEDROCK_HOME:=$_PI_BASE_HOME/.local/share/pi-bedrock}"
: "${PI_BIN_DIR:=$_PI_BASE_HOME/.local/bin}"
: "${PI_CODING_AGENT_DIR:=$_PI_BASE_HOME/.pi/agent}"

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

# ---- 架构识别 --------------------------------------------------------------
# 输出 Node 官方发行包使用的架构名
# Windows on ARM 上 x64 版 Git Bash 运行在仿真层中，uname -m 会报告 x86_64；install.ps1 通过 PI_HOST_ARCH 传入真实架构
node_arch() {
  case "${1:-${PI_HOST_ARCH:-$(uname -m)}}" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

is_cloudshell() { [ "${AWS_EXECUTION_ENV:-}" = "CloudShell" ]; }

# 需要写入 PATH 的 shell 启动文件：始终包含 ~/.bashrc；macOS 或 zsh 用户加 ~/.zshrc；
# macOS 上若已存在 ~/.bash_profile 也写入（登录 shell 不会自动读取 ~/.bashrc）
rc_files() {
  printf '%s\n' "$HOME/.bashrc"
  if [ "$(os_name)" = darwin ] || [[ "${SHELL:-}" == */zsh ]]; then printf '%s\n' "$HOME/.zshrc"; fi
  if [ "$(os_name)" = darwin ] && [ -f "$HOME/.bash_profile" ]; then printf '%s\n' "$HOME/.bash_profile"; fi
}

# ---- 可移植工具（Linux GNU / macOS BSD / busybox）--------------------------
# sha256_of FILE（或 - 表示 stdin）：输出十六进制摘要
sha256_of() {
  local f="${1:--}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    if [ "$f" = - ]; then openssl dgst -sha256 -r; else openssl dgst -sha256 -r "$f"; fi | awk '{print $1}'
  else
    return 1
  fi
}

have_sha256() { printf '' | sha256_of - >/dev/null 2>&1; }

# verify_sha256 FILE EXPECTED
verify_sha256() {
  local digest
  digest="$(sha256_of "$1")" || return 1
  [ -n "$2" ] && [ -n "$digest" ] && [ "$digest" = "$2" ]
}

# run_timeout SECONDS CMD...：超时返回 124（无 timeout 命令时用 gtimeout 或 perl alarm）
run_timeout() {
  local secs="$1" rc=0
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # exec { $ARGV[0] } @ARGV：即使只有一个参数也不经过 shell 解释
    perl -e 'alarm shift @ARGV; exec { $ARGV[0] } @ARGV or exit 127' "$secs" "$@" || rc=$?
    [ "$rc" -eq 142 ] && return 124
    return "$rc"
  fi
}

# extract_zip ZIP DEST：Windows 自带的 bsdtar（System32\tar.exe，Windows 10 1803+ / Server 2019+）解压 zip；
# 其次 unzip；最后用 PowerShell Expand-Archive（较慢）
extract_zip() {
  local zip="$1" dest="$2" systar=""
  mkdir -p "$dest"   # bsdtar 的 -C 要求目标目录已存在
  [ -n "${SYSTEMROOT:-}" ] && systar="$(cygpath -u "$SYSTEMROOT" 2>/dev/null)/System32/tar.exe"
  if [ -n "$systar" ] && [ -x "$systar" ]; then
    "$systar" -xf "$(native_path "$zip")" -C "$(native_path "$dest")"
  elif command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip" -d "$dest"
  else
    powershell.exe -NoProfile -NonInteractive -Command \
      "Expand-Archive -LiteralPath '$(native_path "$zip")' -DestinationPath '$(native_path "$dest")' -Force"
  fi
}

# download URL OUT：HTTPS 下载（内容完整性由调用方的 SHA256 / 清单哈希校验）。
# Windows 上 Git 自带的 curl 使用 schannel，吊销检查需访问 80 端口的 CRL / OCSP，在企业网络中常失败
# （CRYPT_E_REVOCATION_OFFLINE）：--ssl-revoke-best-effort 只在吊销服务器不可达时放过，证书已吊销时仍拒绝；
# schannel 偶发 "server closed abruptly (missing close_notify)"（错误 56，--retry 默认不重试），加 --retry-all-errors
download() {
  local -a extra=()
  is_windows && extra=(--ssl-revoke-best-effort --retry-all-errors)
  curl -fsSL --retry 3 --proto '=https' ${extra[@]+"${extra[@]}"} "$1" -o "$2"
}

# _strip_cr CMD...：运行命令并去掉输出中的 \r，保留退出码。Windows 上的原生程序（aws.exe）向管道输出 CRLF，
# $(...) 只去掉末尾的 \n，残留的 \r 会让区域、profile 名等校验失败
_strip_cr() {
  local out rc=0
  out="$("$@")" || rc=$?
  printf '%s' "${out//$'\r'/}"
  return "$rc"
}

# path_immutable PATH：PATH 及其所有上级目录对当前用户都不可写（例如 Homebrew 的 /opt/homebrew、nvm 的 ~/.nvm 都可写）
path_immutable() {
  local p="$1"
  # Windows（NTFS ACL）上 -w 不能可靠反映可写性，一律视为可改写
  is_windows && return 1
  while :; do
    [ -w "$p" ] && return 1
    [ "$p" = / ] && return 0
    p="$(dirname "$p")"
  done
}

# resolve_path PATH：解析符号链接后的绝对路径（macOS 旧版 readlink 不支持 -f）
resolve_path() {
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$1"
  elif command -v perl >/dev/null 2>&1; then
    perl -MCwd -e 'print Cwd::abs_path(shift)' "$1"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]), end="")' "$1"
  fi
}

# ---- 输入校验 --------------------------------------------------------------
# 安装路径：绝对路径（Windows 上为 C:/... 形式），只含字母数字与 ._/@+-
is_valid_install_path() { [[ "${1:-}" =~ ^([A-Za-z]:)?/[A-Za-z0-9._/@+-]+$ ]]; }

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
