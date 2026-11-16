# shellcheck shell=bash
# 确保存在 Node.js >= PI_MIN_NODE。
# CloudShell 只持久化 ${HOME}（1 GB），因此私有 Node 安装在 $PI_BEDROCK_HOME/node 下；
# 结果写入全局变量 PI_BEDROCK_NODE_BIN（包含 node 与 npm 的目录；Windows 上为 node.exe 所在的发行包根目录）。

# PI_BEDROCK_NODE_MODE: auto（PATH 中的 Node 满足版本则复用，否则安装私有 Node；Windows 始终私有）| private | system
: "${PI_BEDROCK_NODE_MODE:=auto}"

_system_node_ok() {
  local node
  node="$(command -v node 2>/dev/null)" || return 1
  version_ge "$("$node" -v 2>/dev/null)" "$PI_MIN_NODE"
}

# 私有 Node 的 bin 目录。Windows 上 MSYS 的 ln -s 默认会复制整个目录，因此不使用 current 符号链接
private_node_bin() {
  if is_windows; then
    printf '%s/node/node-v%s-win-%s' "$PI_BEDROCK_HOME" "$PI_NODE_VERSION" "$(node_arch)"
  else
    printf '%s/node/current/bin' "$PI_BEDROCK_HOME"
  fi
}

_private_node_ok() {
  local node
  node="$(private_node_bin)/node"
  [ -x "$node" ] && [ "$("$node" -v 2>/dev/null | tr -d '\r')" = "v$PI_NODE_VERSION" ]
}

# 复用 PATH 中的 Node.js。版本管理器的 shim（volta / asdf / mise）用 process.execPath 解析出真实路径；
# 否则使用 PATH 中的路径（如 Homebrew 的 /opt/homebrew/bin，升级后不变）。成功时设置 PI_BEDROCK_NODE_BIN
_use_system_node() {
  local cmd real dir home_real
  cmd="$(command -v node)" || return 1
  real="$("$cmd" -p process.execPath 2>/dev/null | tr -d '\r')"
  [ -n "$real" ] && [ -x "$real" ] || return 1
  real="$(resolve_path "$real")"
  # 在 pi 启动的 shell 中重新安装时，PATH 最前面是本工具的私有 Node：交给私有 Node 的逻辑处理（不能复用后再删除）
  home_real="$(resolve_path "$PI_BEDROCK_HOME" 2>/dev/null || true)"
  case "$real" in "${home_real:-$PI_BEDROCK_HOME}"/* | "$PI_BEDROCK_HOME"/*) return 1 ;; esac
  if [ "$(resolve_path "$cmd")" = "$real" ]; then dir="$(dirname "$cmd")"; else dir="$(dirname "$real")"; fi
  if ! [[ "$dir" =~ ^/[A-Za-z0-9._/@+-]+$ ]]; then
    log_info "系统 Node.js 路径包含不支持的字符（${dir}），改用私有 Node.js"
    return 1
  fi
  if [ ! -x "$dir/npm" ]; then
    log_info "$dir 下没有 npm，改用私有 Node.js"
    return 1
  fi
  PI_BEDROCK_NODE_BIN="$dir"
  # PATH 中的目录（可能只是指向系统 Node 的符号链接所在处）与真实路径都不可写，才视为系统 Node
  if path_immutable "$real" && path_immutable "$dir/node"; then
    log_info "复用系统 Node.js $("$real" -v)（${dir}）"
  else
    # pi 以这个 Node 运行并持有 AWS 凭证：其安装目录加入护栏保护（agent 写入需人工确认）
    add_runtime_root "$(dirname "$(dirname "$real")")"
    add_runtime_root "$dir"
    add_runtime_alias "$real"
    log_info "复用 Node.js $("$real" -v)（${dir}，当前用户可写，已加入 aws-ops-guard 保护目录；需要隔离时使用 --node private）"
  fi
  # 之前安装过的私有 Node 不再使用，释放空间（CloudShell $HOME 仅 1 GB）
  rm -rf "${PI_BEDROCK_HOME:?}/node"
}

ensure_node() {
  # Windows：系统 Node 通常位于含空格的 Program Files 下，且无法可靠判断是否可被改写，auto 模式下始终使用私有 Node
  local mode="$PI_BEDROCK_NODE_MODE"
  [ "$mode" = auto ] && is_windows && mode=private
  case "$mode" in
    auto | system)
      if _system_node_ok && _use_system_node; then return 0; fi
      [ "$PI_BEDROCK_NODE_MODE" = system ] && die "系统 Node.js 不可用（需要 >= ${PI_MIN_NODE} 且同目录有 npm；当前: $(node -v 2>/dev/null || echo 无)）"
      ;;
    private) ;;
    *) die "非法的 PI_BEDROCK_NODE_MODE: ${PI_BEDROCK_NODE_MODE}（可选 auto|private|system）" ;;
  esac

  if _private_node_ok && [ "${PI_BEDROCK_FORCE_NODE:-0}" != 1 ]; then
    PI_BEDROCK_NODE_BIN="$(private_node_bin)"
    log_info "复用私有 Node.js $("$PI_BEDROCK_NODE_BIN/node" -v)"
    return 0
  fi
  log_info "安装私有 Node.js v${PI_NODE_VERSION}（系统 Node.js: $(node -v 2>/dev/null || echo 无)，pi 需要 >= ${PI_MIN_NODE}）"
  install_private_node
}

# 私有 Node 版本与 SHA256（固定在代码中；升级时同时更新两处，哈希取自 nodejs.org 的 SHASUMS256.txt）
: "${PI_NODE_VERSION:=24.22.2}"
_node_sha256() {
  case "$PI_NODE_VERSION:$1" in
    24.22.2:linux-x64.tar.xz) printf '48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75' ;;
    24.22.2:linux-x64.tar.gz) printf '361718c444e49af2ca5a110c83ba6a8901143f23ab285ebbef0341f391f482a9' ;;
    24.22.2:linux-arm64.tar.xz) printf 'eb187837a2230d4047161ac0be008584e16b46f726e9c9490ee35dc6b17d9ba8' ;;
    24.22.2:linux-arm64.tar.gz) printf '95c264150aceb7f3437a29fd6984924f5f8d1511ea3cbd6c508b83f6c555dae2' ;;
    24.22.2:darwin-x64.tar.xz) printf '6965578fd823e72c1b5387f5ab84cb25368f886e02eb8779e6f0fce6b91c27b7' ;;
    24.22.2:darwin-x64.tar.gz) printf 'd5e336d588c45be0c37dbd52cc29895593009ca4997a77a1fd02815131ed0e52' ;;
    24.22.2:darwin-arm64.tar.xz) printf '1f5ac075be50bed4780ea3be19a007fda95ea4d527d28d76d0b91de47d915115' ;;
    24.22.2:darwin-arm64.tar.gz) printf 'aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a' ;;
    24.22.2:win-x64.zip) printf 'ca1bff5d8ead13c9f2ea404a176db46bd430704d5b5113734049fa365e7799e2' ;;
    24.22.2:win-arm64.zip) printf 'f47968c213105077f64c6510f007632c0ca2574802a0b5067c327c49abe1c468' ;;
    *) if [ -n "${PI_NODE_SHA256:-}" ]; then printf '%s' "$PI_NODE_SHA256"; else return 1; fi ;;
  esac
}

# 从 nodejs.org 下载固定版本，校验内置 SHA256 后解压到 $PI_BEDROCK_HOME/node
install_private_node() {
  local os arch dir tmp ext file name sha
  os="$(os_name)" || die "不支持的操作系统: $(uname -s)"
  arch="$(node_arch)" || die "不支持的 CPU 架构: $(uname -m)"
  [[ "$PI_NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "非法的 PI_NODE_VERSION: $PI_NODE_VERSION"
  dir="$PI_BEDROCK_HOME/node"
  if [ "$os" = windows ]; then
    os=win ext=zip
  else
    ext=tar.gz
    command -v xz >/dev/null 2>&1 && ext=tar.xz
  fi
  sha="$(_node_sha256 "$os-$arch.$ext")" ||
    die "未内置 Node.js $PI_NODE_VERSION ($os-$arch.$ext) 的 SHA256，请设置 PI_NODE_SHA256 或使用默认版本"
  name="node-v$PI_NODE_VERSION-$os-$arch"
  file="$name.$ext"

  tmp="$(mktemp -d)"
  log_info "下载 $file"
  download "$PI_NODE_DIST_BASE/v$PI_NODE_VERSION/$file" "$tmp/$file" ||
    { rm -rf "$tmp"; die "下载 Node.js 失败: $PI_NODE_DIST_BASE/v$PI_NODE_VERSION/$file"; }
  verify_sha256 "$tmp/$file" "$sha" || { rm -rf "$tmp"; die "Node.js 发行包 SHA256 校验失败，已中止"; }

  mkdir -p "$dir"
  rm -rf "${dir:?}/$name"
  if [ "$ext" = zip ]; then
    extract_zip "$tmp/$file" "$dir" || { rm -rf "$tmp"; die "解压 $file 失败"; }
  else
    tar -xf "$tmp/$file" -C "$dir" --no-same-owner
  fi
  rm -rf "$tmp"
  # 精简体积（CloudShell $HOME 仅 1 GB）：头文件与文档对运行 pi 无用
  rm -rf "${dir:?}/$name/include" "${dir:?}/$name/share" "${dir:?}/$name"/{CHANGELOG.md,README.md}
  [ "$ext" = zip ] || ln -sfn "$name" "$dir/current"
  _prune_old_nodes "$dir" "$name"
  PI_BEDROCK_NODE_BIN="$(private_node_bin)"
  log_info "Node.js $("$PI_BEDROCK_NODE_BIN/node" -v) 已安装到 $dir/$name"
}

_prune_old_nodes() {
  local dir="$1" keep="$2" d
  for d in "$dir"/node-v*; do
    [ -d "$d" ] && [ "$(basename "$d")" != "$keep" ] && rm -rf "$d"
  done
  return 0
}
