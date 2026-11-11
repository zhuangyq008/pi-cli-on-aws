# shellcheck shell=bash
# 安装 AWS MCP Server 的本地 SigV4 代理（mcp-proxy-for-aws-cli）。
# 全部位于 $PI_BEDROCK_HOME/uv（CloudShell 重启后保留）：uv 二进制、托管 Python、proxy 虚拟环境。
# 结果写入全局变量 PI_AWS_MCP_PROXY_BIN。

: "${PI_UV_VERSION:=0.13.7}"
: "${PI_MCP_PROXY_PKG:=mcp-proxy-for-aws-cli}"
: "${PI_MCP_PROXY_VERSION:=1.8.0}"
: "${PI_MCP_PYTHON:=3.12}"
: "${PI_UV_DOWNLOAD_BASE:=https://github.com/astral-sh/uv/releases/download}"

# uv 发行包 SHA256（固定在代码中，不信任与下载同源的校验文件）
_uv_sha256() {
  case "$PI_UV_VERSION:$1" in
    0.13.7:x86_64-unknown-linux-gnu) printf 'c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83' ;;
    0.13.7:aarch64-unknown-linux-gnu) printf '71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc' ;;
    0.13.7:x86_64-apple-darwin) printf '20c47e4c1f630b8abaff8c291fa9b9aa300fef92c4fbff95adf198b55287cda7' ;;
    0.13.7:aarch64-apple-darwin) printf '81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731' ;;
    0.13.7:x86_64-pc-windows-msvc) printf '0cdc5b38fe5a8168ed6a25814f5ba43c21d313dd3187314fccb37b7cec46e021' ;;
    0.13.7:aarch64-pc-windows-msvc) printf '505d9e65e7692bac3ddf98c66754aa26c5050c409c184af30a881a0a72cc85e3' ;;
    *) return 1 ;;
  esac
}

# uv 发行包的 target triple：Linux x86_64 / arm64、macOS Intel / Apple Silicon、Windows x64 / ARM64
_uv_target() {
  local cpu os
  case "$(node_arch)" in
    x64) cpu=x86_64 ;;
    arm64) cpu=aarch64 ;;
    *) return 1 ;;
  esac
  case "$(os_name)" in
    linux) os=unknown-linux-gnu ;;
    darwin) os=apple-darwin ;;
    windows) os=pc-windows-msvc ;;
    *) return 1 ;;
  esac
  printf '%s-%s' "$cpu" "$os"
}

# venv 中可执行文件所在目录：Windows 为 Scripts/（*.exe），其他平台为 bin/
_venv_bin() { if is_windows; then printf '%s/Scripts' "$1"; else printf '%s/bin' "$1"; fi; }

# venv 中的 Python 解释器（uv 不会自动补 .exe 后缀）
_venv_python() { if is_windows; then printf '%s/Scripts/python.exe' "$1"; else printf '%s/bin/python' "$1"; fi; }

uv_dir() { printf '%s/uv' "$PI_BEDROCK_HOME"; }

# 以隔离环境变量运行 uv：Python、缓存都不落到用户的 ~/.local / ~/.cache
_uv() {
  local dir
  dir="$(uv_dir)"
  UV_PYTHON_INSTALL_DIR="$(native_path "$dir/python")" UV_PYTHON_BIN_DIR="$(native_path "$dir/python-bin")" UV_PYTHON_PREFERENCE=only-managed \
    UV_NO_MODIFY_PATH=1 UV_CACHE_DIR="$(native_path "${_PI_UV_CACHE:?}")" "$dir/bin/uv" "$@"
}

ensure_uv() {
  local dir target sha tmp file
  dir="$(uv_dir)"
  if [ -x "$dir/bin/uv" ] && [ "$("$dir/bin/uv" --version 2>/dev/null | tr -d '\r' | awk '{print $2}')" = "$PI_UV_VERSION" ]; then
    log_info "复用 uv $PI_UV_VERSION"
    return 0
  fi
  target="$(_uv_target)" || die "不支持的 CPU 架构: $(uname -m)"
  sha="$(_uv_sha256 "$target")" || die "未内置 uv $PI_UV_VERSION ($target) 的 SHA256，请同时更新 lib/mcp.sh"
  file="uv-$target.tar.gz"
  is_windows && file="uv-$target.zip"
  tmp="$(mktemp -d)"
  log_info "下载 uv $PI_UV_VERSION"
  download "$PI_UV_DOWNLOAD_BASE/$PI_UV_VERSION/$file" "$tmp/$file" ||
    { rm -rf "$tmp"; die "下载 uv 失败"; }
  verify_sha256 "$tmp/$file" "$sha" || { rm -rf "$tmp"; die "uv 发行包 SHA256 校验失败，已中止"; }
  mkdir -p "$dir/bin"
  if is_windows; then
    # Windows 发行包的 zip 根目录直接包含 uv.exe / uvx.exe / uvw.exe
    extract_zip "$tmp/$file" "$tmp/x" && [ -f "$tmp/x/uv.exe" ] || { rm -rf "$tmp"; die "解压 uv 失败"; }
    cp -f "$tmp/x/uv.exe" "$dir/bin/uv.exe"
  else
    tar -xzf "$tmp/$file" -C "$dir/bin" --strip-components=1 "uv-$target/uv"
    chmod 755 "$dir/bin/uv"
  fi
  rm -rf "$tmp"
}

# 依赖锁文件（含全部传递依赖的 SHA256）；其哈希作为已安装版本的标记
_proxy_lock_file() { printf '%s/mcp-proxy-requirements.txt' "${PI_BEDROCK_LIB_SRC:?}"; }

# 在独立 venv 中以 --require-hashes 安装 mcp-proxy-for-aws-cli：任何包哈希不匹配都会中止
install_mcp_proxy() {
  local dir lock stamp venv
  dir="$(uv_dir)"
  venv="$dir/venv"
  lock="$(_proxy_lock_file)"
  [ -f "$lock" ] || die "缺少依赖锁文件 $lock"
  PI_AWS_MCP_PROXY_BIN="$(_venv_bin "$venv")/$PI_MCP_PROXY_PKG"
  is_windows && PI_AWS_MCP_PROXY_BIN="$PI_AWS_MCP_PROXY_BIN.exe"
  stamp="$(sha256_of "$lock")"
  if [ -x "$PI_AWS_MCP_PROXY_BIN" ] && [ "$(cat "$venv/.pi-bedrock-lock" 2>/dev/null)" = "$stamp" ]; then
    log_info "$PI_MCP_PROXY_PKG $PI_MCP_PROXY_VERSION 已安装，跳过"
    return 0
  fi
  log_info "安装 $PI_MCP_PROXY_PKG==${PI_MCP_PROXY_VERSION}（Python ${PI_MCP_PYTHON}，依赖哈希锁定，位于 ${dir}）"
  _PI_UV_CACHE="$(mktemp -d)"
  # 直接在最终位置重建（venv 内脚本的 shebang 是绝对路径，不能搬移）；失败时重新运行安装器即可
  rm -rf "$venv" "$dir/tools" "$dir/tool-bin"
  if ! { _uv venv --quiet --python "$PI_MCP_PYTHON" "$(native_path "$venv")" &&
    _uv pip install --quiet --python "$(native_path "$(_venv_python "$venv")")" --require-hashes --no-deps -r "$(native_path "$lock")"; } >"$_PI_UV_CACHE/install.log" 2>&1; then
    tail -n 20 "$_PI_UV_CACHE/install.log" >&2
    rm -rf "$_PI_UV_CACHE" "$venv"
    die "安装 $PI_MCP_PROXY_PKG 失败（见上方输出；可使用 --no-mcp 跳过 MCP）"
  fi
  rm -rf "$_PI_UV_CACHE"
  unset _PI_UV_CACHE
  printf '%s\n' "$stamp" >"$venv/.pi-bedrock-lock"
  [ -x "$PI_AWS_MCP_PROXY_BIN" ] || die "安装后未找到 $PI_AWS_MCP_PROXY_BIN"
  "$PI_AWS_MCP_PROXY_BIN" --help >/dev/null 2>&1 || die "$PI_MCP_PROXY_PKG 无法启动"
}

remove_mcp_config() {
  [ -f "$3" ] || return 0
  "$1" "$2/merge-mcp.mjs" remove "$(native_path "$3")" --name aws-mcp --command "$4" || log_warn "从 $3 移除 aws-mcp 失败，请手动检查"
}

# configure_mcp NODE LIB_DIR MCP_JSON LAUNCHER：启动器是 bash 脚本；
# Windows 上 pi（Node）无法直接执行它，改为 command = Git Bash、args = [启动器]
configure_mcp() {
  local rc=0 bash_exe
  local -a cmd=(--command "$4")
  if is_windows; then
    bash_exe="$(git_bash_path)" || die "未找到 Git Bash（bash.exe），无法配置 AWS MCP Server"
    cmd=(--command "$bash_exe" --launcher "$4")
  fi
  "$1" "$2/merge-mcp.mjs" apply "$(native_path "$3")" --name aws-mcp "${cmd[@]}" || rc=$?
  case "$rc" in
    0) log_info "已在 $3 中配置 AWS MCP Server（aws-mcp）" ;;
    3) log_warn "$3 中已存在非本工具创建的 aws-mcp 条目，保持不变（如需替换请先删除该条目再重新安装）" ;;
    *) die "写入 $3 失败" ;;
  esac
}
