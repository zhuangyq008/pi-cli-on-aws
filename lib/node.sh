# shellcheck shell=bash
# 确保存在 Node.js >= PI_MIN_NODE。
# CloudShell 只持久化 ${HOME}（1 GB），因此私有 Node 安装在 $PI_BEDROCK_HOME/node 下；
# 结果写入全局变量 PI_BEDROCK_NODE_BIN（包含 node 与 npm 的目录；Windows 上为 node.exe 所在的发行包根目录）。

# PI_BEDROCK_NODE_MODE: auto（系统 Node 满足版本则复用，否则安装私有 Node）| private | system
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

ensure_node() {
  # Windows：系统 Node 通常位于含空格的 Program Files 下，且无法可靠判断是否可被改写，auto 模式下始终使用私有 Node
  local mode="$PI_BEDROCK_NODE_MODE"
  [ "$mode" = auto ] && is_windows && mode=private
  case "$mode" in
    auto | system)
      if _system_node_ok; then
        local sys_bin
        sys_bin="$(dirname "$(resolve_path "$(command -v node)")")"
        # 路径需能安全写入 env 文件；auto 模式下只复用当前用户不可改写的 Node（pi 以它运行并持有凭证，
        # 可写位置如 Homebrew 的 /opt/homebrew、nvm 的 ~/.nvm 可被 agent 替换）
        if [[ "$sys_bin" =~ ^/[A-Za-z0-9._/@+-]+$ ]] && { [ "$PI_BEDROCK_NODE_MODE" = system ] || path_immutable "$sys_bin/node"; }; then
          PI_BEDROCK_NODE_BIN="$sys_bin"
          log_info "复用系统 Node.js $(node -v)（${PI_BEDROCK_NODE_BIN}）"
          return 0
        fi
        [ "$PI_BEDROCK_NODE_MODE" = system ] && die "系统 Node.js 路径包含不支持的字符: $sys_bin"
        log_info "检测到 $sys_bin 下的 Node.js（当前用户可写，如 Homebrew / nvm），改用私有 Node.js"
      fi
      [ "$PI_BEDROCK_NODE_MODE" = system ] && die "系统 Node.js 不满足 >= ${PI_MIN_NODE}（当前: $(node -v 2>/dev/null || echo 无)）"
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
