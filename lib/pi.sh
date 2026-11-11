# shellcheck shell=bash
# 使用指定 Node 把 pi 安装到 $PI_BEDROCK_HOME/npm-global（位于 ${HOME}，CloudShell 重启后保留）。
# 先下载 tarball 并校验固定的 sha512（npm dist.integrity），再从本地 tarball 安装；
# 传递依赖由 pi 发布的 npm-shrinkwrap.json 锁定，npm 安装时逐个校验 integrity。
# 结果写入全局变量 PI_BEDROCK_PI_BIN 与 PI_BEDROCK_NPM_PREFIX。

# 已验证版本的 tarball 完整性（与 `npm view <pkg>@<ver> dist.integrity` 一致）
_pi_integrity() {
  case "$PI_PACKAGE@$PI_VERSION" in
    @earendil-works/pi-coding-agent@1.5.2) printf 'sha512-mUWI04rqF1Vd/m1q+Ps1XeWsTXEVvRUnsmRa83I3Dzua0Tx5bYS93imeqtIfrXf7PkkaR6ERz+AuQhIJlom5yA==' ;;
    *) printf '%s' "${PI_PACKAGE_INTEGRITY:-}" ;;
  esac
}

pi_installed_version() {
  local pkg="$1/lib/node_modules/$PI_PACKAGE/package.json"
  [ -f "$pkg" ] || return 1
  "$PI_BEDROCK_NODE_BIN/node" -e 'process.stdout.write(require(process.argv[1]).version)' "$pkg"
}

_npm() { PATH="$PI_BEDROCK_NODE_BIN:$PATH" "$PI_BEDROCK_NODE_BIN/npm" "$@"; }

# 下载并校验 tarball，输出本地 tarball 路径
_fetch_verified_pi() {
  local workdir="$1" cache="$2" expected tarball actual
  expected="$(_pi_integrity)"
  tarball="$(cd "$workdir" && _npm pack "$PI_PACKAGE@$PI_VERSION" --cache "$cache" --silent --loglevel=error)" ||
    { log_error "下载 $PI_PACKAGE@$PI_VERSION 失败"; return 1; }
  tarball="$workdir/$(printf '%s' "$tarball" | tail -n1)"
  actual="$("$PI_BEDROCK_NODE_BIN/node" -e '
    const data = require("fs").readFileSync(process.argv[1]);
    process.stdout.write("sha512-" + require("crypto").createHash("sha512").update(data).digest("base64"));
  ' "$tarball")"
  if [ -z "$expected" ]; then
    log_warn "未内置 $PI_PACKAGE@$PI_VERSION 的完整性哈希，仅依赖 npm registry 校验（实际 ${actual}；可设置 PI_PACKAGE_INTEGRITY 固定）"
  elif [ "$actual" != "$expected" ]; then
    log_error "$PI_PACKAGE@$PI_VERSION 完整性校验失败（期望 ${expected}，实际 ${actual}）"
    return 1
  else
    log_info "tarball 完整性与内置 sha512 一致"
  fi
  printf '%s' "$tarball"
}

install_pi() {
  local prefix="$PI_BEDROCK_HOME/npm-global" cache work current tarball
  # shellcheck disable=SC2034 # 供 install.sh 使用
  PI_BEDROCK_NPM_PREFIX="$prefix"
  PI_BEDROCK_PI_BIN="$prefix/bin/pi"

  current="$(pi_installed_version "$prefix" 2>/dev/null || true)"
  if [ -n "$current" ] && [ "$current" = "$PI_VERSION" ] && [ -e "$PI_BEDROCK_PI_BIN" ] && [ "${PI_BEDROCK_FORCE_PI:-0}" != 1 ]; then
    log_info "pi $current 已安装，跳过"
    return 0
  fi

  log_info "安装 $PI_PACKAGE@${PI_VERSION}（npm prefix: ${prefix}）"
  # 临时 npm 缓存：避免在 1 GB 的 $HOME 中留下数百 MB 缓存
  cache="$(mktemp -d)"
  work="$(mktemp -d)"
  if ! tarball="$(_fetch_verified_pi "$work" "$cache")"; then
    rm -rf "$cache" "$work"
    die "pi 下载或校验失败，已中止"
  fi
  # --ignore-scripts：依赖的 install 脚本不在带凭证的 CloudShell 中执行（pi 不依赖任何 install 脚本）
  if ! _npm install -g --prefix "$prefix" --cache "$cache" \
    --no-fund --no-audit --update-notifier=false --loglevel=error --ignore-scripts "$tarball"; then
    rm -rf "$cache" "$work"
    die "npm 安装 $PI_PACKAGE@$PI_VERSION 失败"
  fi
  rm -rf "$cache" "$work"
  [ -e "$PI_BEDROCK_PI_BIN" ] || die "安装后未找到 $PI_BEDROCK_PI_BIN"
  log_info "pi $(pi_installed_version "$prefix") 安装完成"
}
