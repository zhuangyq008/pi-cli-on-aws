#!/usr/bin/env bash
# pi-cli-bedrock 安装器：在 AWS CloudShell / macOS / Linux / Windows（Git Bash，由 install.ps1 调用）上安装
# pi coding agent（默认 Amazon Bedrock + Kimi K3.1），并集成 AWS MCP Server、运维 skills 与 AWS 写操作护栏，
# 用于云上运维（成本 / 可观测 / 告警）。幂等；所有文件位于 ${HOME}（CloudShell 重启后保留）。
# 本地环境没有 AWS 凭证时引导配置（aws login / IAM Identity Center / Access Key / 已有 profile）。用法见 --help。
set -euo pipefail
umask 077   # 新建的配置、日志、凭证相关文件仅当前用户可读

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 记录用户覆盖的版本 / 完整性 / 下载地址（加载默认值之前），安装时醒目提示
SECURITY_OVERRIDES=()
for _v in PI_VERSION PI_PACKAGE PI_PACKAGE_INTEGRITY PI_NODE_VERSION PI_NODE_SHA256 PI_NODE_DIST_BASE PI_UV_VERSION PI_UV_DOWNLOAD_BASE \
  PI_AWS_TOOLKIT_REPO PI_AWS_TOOLKIT_REF PI_AWS_TOOLKIT_TARBALL_URL PI_AWS_SKILLS PI_AWS_SKILLS_SHA256; do
  [ -n "${!_v:-}" ] && SECURITY_OVERRIDES+=("$_v=${!_v}")
done
unset _v
for _lib in common config node pi region mcp mcp-runtime skills models credentials; do
  [ -f "$SCRIPT_DIR/lib/$_lib.sh" ] || { echo "ERROR: 缺少 $SCRIPT_DIR/lib/$_lib.sh，请使用完整的 pi-cli-bedrock 目录运行" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/lib/$_lib.sh"
done
unset _lib
# shellcheck disable=SC2034 # 供 lib/mcp.sh 使用（依赖锁文件位置）
PI_BEDROCK_LIB_SRC="$SCRIPT_DIR/lib"
INSTALL_MARKER=".pi-bedrock-managed"
GUARD_FILES="index.ts classify.ts policy.ts shell.ts strict.ts awscli.ts script.ts ops.ts paths.ts redact.ts awsconfig.mjs awsconfig.d.mts snapshot.mjs"

MIN_FREE_MB_BASE=350   # Node + pi
MIN_FREE_MB_MCP=600    # + uv、托管 Python、mcp-proxy-for-aws-cli
OPT_REGION=""
OPT_PROBE=1
OPT_BASHRC=1
OPT_MCP=1
OPT_SKILLS=1
OPT_FILTER_MODELS=1

usage() {
  cat <<EOF
用法: bash install.sh [选项]

选项:
  --region REGION     固定 Bedrock 源区域（默认: 自动探测，优先 CloudShell 当前区域）
  --no-probe          不探测区域，pi 直接使用 AWS_REGION
  --model ID          默认模型（默认: ${PI_BEDROCK_MODEL}）
  --thinking LEVEL    默认思考等级 off|minimal|low|medium|high|xhigh|max（默认: ${PI_BEDROCK_THINKING}）
  --pi-version VER    pi 版本（默认: ${PI_VERSION}，可设为 latest）
  --node MODE         auto|private|system（默认: ${PI_BEDROCK_NODE_MODE}）
  --no-mcp            不安装 AWS MCP Server（节省约 220 MB）
  --no-skills         不预装 AWS 运维 skills 与规则文件
  --all-models        /model 显示 pi 内置的全部 Bedrock 模型（默认只启用当前区域可用的模型）
  --no-bashrc         不修改 ~/.bashrc
  -h, --help          显示帮助

示例:
  bash install.sh
  bash install.sh --region ap-southeast-1 --thinking high
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --region) OPT_REGION="${2:?--region 需要参数}"; shift 2 ;;
      --no-probe) OPT_PROBE=0; shift ;;
      --model) PI_BEDROCK_MODEL="${2:?--model 需要参数}"; shift 2 ;;
      --thinking) PI_BEDROCK_THINKING="${2:?--thinking 需要参数}"; shift 2 ;;
      --pi-version) PI_VERSION="${2:?--pi-version 需要参数}"; shift 2 ;;
      --node) PI_BEDROCK_NODE_MODE="${2:?--node 需要参数}"; shift 2 ;;
      --no-bashrc) OPT_BASHRC=0; shift ;;
      --no-mcp) OPT_MCP=0; shift ;;
      --no-skills) OPT_SKILLS=0; shift ;;
      --all-models) OPT_FILTER_MODELS=0; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "未知参数: $1" ;;
    esac
  done
}

validate_inputs() {
  [ -z "$OPT_REGION" ] || is_valid_region "$OPT_REGION" || die "非法区域: $OPT_REGION"
  is_valid_model_id "$PI_BEDROCK_MODEL" || die "非法模型 ID: $PI_BEDROCK_MODEL"
  is_valid_thinking "$PI_BEDROCK_THINKING" || die "非法思考等级: $PI_BEDROCK_THINKING"
  is_valid_pi_version "$PI_VERSION" || die "非法 pi 版本: $PI_VERSION"
  local p
  for p in "$PI_BEDROCK_HOME" "$PI_BIN_DIR" "$PI_CODING_AGENT_DIR"; do
    is_valid_install_path "$p" || die "路径包含不支持的字符（仅允许字母数字 ._/@+-）: ${p}。可设置 PI_BEDROCK_HOME / PI_BIN_DIR / PI_CODING_AGENT_DIR 指定其他目录"
  done
}

preflight() {
  require_cmd curl tar awk mktemp
  os_name >/dev/null || die "不支持的操作系统: $(uname -s)（支持 Linux、macOS 与 Windows（Git Bash），x86_64 / arm64）"
  if is_windows; then
    require_cmd cygpath
    git_bash_path >/dev/null || die "未找到 Git for Windows 的 bin/bash.exe，请使用 install.ps1 安装"
  fi
  node_arch >/dev/null || die "不支持的 CPU 架构: $(uname -m)（支持 x86_64 / arm64）"
  have_sha256 || die "缺少 SHA256 工具（需要 sha256sum、shasum 或 openssl 之一）"
  local avail need=0
  avail="$(df -Pm "$HOME" | awk 'NR==2 {print $4}')"
  [ -d "$PI_BEDROCK_HOME/npm-global" ] || need=$MIN_FREE_MB_BASE
  [ "$OPT_MCP" = 1 ] && [ ! -d "$PI_BEDROCK_HOME/uv" ] && need=$((need + MIN_FREE_MB_MCP - MIN_FREE_MB_BASE))
  if [ "${avail:-0}" -lt "$need" ]; then
    die "\$HOME 剩余空间 ${avail} MB，不足 ${need} MB（CloudShell 上限 1 GB）。请清理后重试，或使用 --no-mcp"
  fi
  local o
  # bash 3.2（macOS 自带）在 set -u 下展开空数组会报错，使用 ${arr[@]+...} 形式
  for o in ${SECURITY_OVERRIDES[@]+"${SECURITY_OVERRIDES[@]}"}; do
    log_warn "检测到覆盖固定版本 / 完整性校验的设置：${o}（请确认来源可信）"
  done
  if is_cloudshell; then
    log_info "检测到 AWS CloudShell（区域 ${AWS_REGION:-未知}，\$HOME 剩余 ${avail} MB）"
  else
    log_info "未检测到 CloudShell，按本地 $(os_name)/$(node_arch) 环境安装（\$HOME 剩余 ${avail} MB）"
  fi
}

# 非 CloudShell（如 macOS）通常不设置 AWS_REGION：从 AWS CLI 配置读取默认区域并记录到 env 文件
detect_default_region() {
  : "${PI_DEFAULT_AWS_REGION:=}"
  [ -n "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}${PI_DEFAULT_AWS_REGION}" ] && return 0
  command -v aws >/dev/null 2>&1 || return 0
  local r
  r="$(AWS_PROFILE="${AWS_PROFILE:-default}" _strip_cr aws configure get region 2>/dev/null || true)"
  if is_valid_region "$r"; then
    PI_DEFAULT_AWS_REGION="$r"
    log_info "未设置 AWS_REGION，使用 AWS CLI 配置中的默认区域 $r"
  else
    log_warn "未设置 AWS_REGION，且 AWS CLI 配置中没有默认区域，将使用 us-east-1（可 export AWS_REGION=... 后重新安装）"
  fi
}

# 输出需要固定的 Bedrock 区域（空串表示跟随 AWS_REGION）
resolve_bedrock_region() {
  local current="${AWS_REGION:-${AWS_DEFAULT_REGION:-${PI_DEFAULT_AWS_REGION:-}}}" chosen rc=0
  if [ -n "$OPT_REGION" ]; then
    printf '%s' "$OPT_REGION"
    return 0
  fi
  if [ "$OPT_PROBE" = 0 ]; then
    log_info "跳过区域探测，pi 将使用 AWS_REGION=${current:-未设置}"
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    log_warn "未找到 aws CLI，跳过区域探测"
    return 0
  fi
  log_info "探测 Bedrock 源区域（模型 ${PI_BEDROCK_MODEL}，每次探测为一次 maxTokens=16 的极小调用）"
  chosen="$(select_bedrock_region "$PI_BEDROCK_MODEL" "${current:-us-east-1}")" || rc=$?
  case "$rc" in
    0)
      if [ "$chosen" = "$current" ]; then
        log_info "当前区域 $current 可直接调用 $PI_BEDROCK_MODEL"
      else
        log_warn "当前区域 ${current:-未设置} 无法调用 ${PI_BEDROCK_MODEL}（多为 TPM 配额为 0），已将 pi 的 Bedrock 源区域固定为 $chosen"
        log_warn "global.* 推理配置文件本身会跨全球商业区域路由，源区域只决定配额与 CloudWatch 指标归属"
        printf '%s' "$chosen"
      fi
      ;;
    3) log_warn "凭证或 IAM 权限不足，无法调用 Bedrock。安装将继续，请修复权限后运行 pi-bedrock-doctor" ;;
    *) log_warn "所有候选区域均无法调用 ${PI_BEDROCK_MODEL}（配额为 0 或模型未开放）。安装将继续，请在 Service Quotas 申请提额后运行 pi-bedrock-doctor" ;;
  esac
}

# 生成可执行脚本：替换 __PI_BEDROCK_HOME__ 占位符后原子写入
_install_script() {
  local src="$1" dest="$2" content
  content="$(cat "$src")"
  printf '%s\n' "${content//__PI_BEDROCK_HOME__/$PI_BEDROCK_HOME}" >"$dest.tmp"
  chmod 755 "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
}

# 归属标记：最先写入，使中途失败的安装也能被 uninstall.sh 识别并清理
mark_install_home() {
  mkdir -p "$PI_BEDROCK_HOME"
  printf 'pi-cli-bedrock\n' >"$PI_BEDROCK_HOME/$INSTALL_MARKER"
}

# 运行时文件设为只读（防止 agent 或误操作改写护栏 / 包装器；重新安装时先恢复可写）
_writable() { [ -e "$1" ] && chmod -R u+w "$1" 2>/dev/null; return 0; }
_readonly() { chmod -R a-w "$@" 2>/dev/null; return 0; }

# AWS 写操作护栏扩展 → ~/.pi/agent/extensions/aws-ops-guard（pi 自动加载）
install_guard_extension() {
  local dest="$PI_CODING_AGENT_DIR/extensions/aws-ops-guard"
  local backup="$PI_CODING_AGENT_DIR/.pi-bedrock-backup"
  if [ -d "$dest" ] && [ ! -f "$dest/$INSTALL_MARKER" ]; then
    # 备份到 extensions/ 之外，避免被 pi 当作扩展加载
    mkdir -p "$backup"
    mv -f "$dest" "$backup/aws-ops-guard.$(date +%Y%m%d%H%M%S)"
    log_warn "已将原有 $dest 备份到 $backup/"
  fi
  _writable "$dest"
  rm -rf "$dest"
  mkdir -p "$dest"
  local f
  for f in $GUARD_FILES; do cp "$SCRIPT_DIR/extensions/aws-ops-guard/$f" "$dest/"; done
  printf 'pi-cli-bedrock\n' >"$dest/$INSTALL_MARKER"
  chmod 0444 "$dest"/*.ts "$dest"/*.mjs "$dest"/*.mts "$dest/$INSTALL_MARKER"
  chmod 0555 "$dest"
}

# Windows：PowerShell / cmd 无法直接执行 bash 脚本，为每个命令生成 .cmd shim（经 Git Bash 运行同名 bash 脚本）
install_windows_shims() {
  is_windows || return 0
  local bash_exe f
  bash_exe="$(git_bash_path)" || die "未找到 Git Bash（bash.exe）"
  for f in pi pi-bedrock-doctor pi-bedrock-login; do
    _writable "$PI_BIN_DIR/$f.cmd"
    printf '@echo off\r\nrem pi-cli-bedrock: %s\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
      "$f" "$bash_exe" "$(native_path "$PI_BIN_DIR/$f")" >"$PI_BIN_DIR/$f.cmd.tmp"
    mv -f "$PI_BIN_DIR/$f.cmd.tmp" "$PI_BIN_DIR/$f.cmd"
  done
}

# 复制运行时文件：lib → $PI_BEDROCK_HOME/lib，包装器与 doctor → $PI_BIN_DIR
install_runtime_files() {
  _writable "$PI_BEDROCK_HOME/lib"
  _writable "$PI_BEDROCK_HOME/bin"
  _writable "$PI_BEDROCK_HOME/uninstall.sh"
  mkdir -p "$PI_BEDROCK_HOME/lib" "$PI_BEDROCK_HOME/bin" "$PI_BIN_DIR"
  cp -f "$SCRIPT_DIR/lib/"{common,config,region,mcp-runtime,skills,credentials}.sh "$SCRIPT_DIR/lib/"{json-file,merge-settings,merge-mcp}.mjs "$PI_BEDROCK_HOME/lib/"
  cp -f "$SCRIPT_DIR/uninstall.sh" "$PI_BEDROCK_HOME/uninstall.sh"
  if is_windows; then _writable "$PI_BEDROCK_HOME/uninstall.ps1"; cp -f "$SCRIPT_DIR/uninstall.ps1" "$PI_BEDROCK_HOME/uninstall.ps1"; fi
  _install_script "$SCRIPT_DIR/bin/aws-mcp-proxy" "$PI_BEDROCK_HOME/bin/aws-mcp-proxy"
  install_guard_extension
  local f
  for f in pi pi-bedrock-doctor pi-bedrock-login; do
    _writable "$PI_BIN_DIR/$f"
    if [ -e "$PI_BIN_DIR/$f" ] && ! grep -q 'pi-cli-bedrock' "$PI_BIN_DIR/$f" 2>/dev/null; then
      mv -f "$PI_BIN_DIR/$f" "$PI_BIN_DIR/$f.pre-pi-bedrock"
      log_warn "已将原有 $PI_BIN_DIR/$f 备份为 $f.pre-pi-bedrock"
    fi
    _install_script "$SCRIPT_DIR/bin/$f" "$PI_BIN_DIR/$f"
  done
  install_windows_shims
  chmod 0555 "$PI_BEDROCK_HOME/uninstall.sh" "$PI_BIN_DIR/pi" "$PI_BIN_DIR/pi-bedrock-doctor" "$PI_BIN_DIR/pi-bedrock-login" "$PI_BEDROCK_HOME/bin/aws-mcp-proxy"
  _readonly "$PI_BEDROCK_HOME/lib" "$PI_BEDROCK_HOME/bin"
}

write_configuration() {
  local region="$1"
  local -a entries=(
    "PI_BEDROCK_MODEL=$PI_BEDROCK_MODEL"
    "PI_BEDROCK_NODE_BIN=$PI_BEDROCK_NODE_BIN"
    "PI_BEDROCK_PI_BIN=$PI_BEDROCK_PI_BIN"
    "PI_BIN_DIR=$PI_BIN_DIR"
    "PI_CODING_AGENT_DIR=$PI_CODING_AGENT_DIR"
  )
  [ -n "$region" ] && entries+=("PI_BEDROCK_REGION=$region")
  [ "$OPT_MCP" = 1 ] && entries+=("PI_AWS_MCP_PROXY_BIN=$PI_AWS_MCP_PROXY_BIN")
  [ -n "${PI_DEFAULT_AWS_REGION:-}" ] && entries+=("PI_DEFAULT_AWS_REGION=$PI_DEFAULT_AWS_REGION")
  [ -n "${PI_AWS_PROFILE:-}" ] && entries+=("PI_AWS_PROFILE=$PI_AWS_PROFILE")
  write_env_file "$PI_BEDROCK_HOME/env" "${entries[@]}"
  chmod 0400 "$PI_BEDROCK_HOME/env"
  local npm="$PI_BEDROCK_NODE_BIN/npm"
  local -a win_opts=()
  if is_windows; then
    # Windows：pi 的 bash 工具固定使用本次安装所用的 Git Bash；self-update 用 node.exe + npm-cli.js（npm.cmd 不能直接执行）
    npm="$PI_BEDROCK_NODE_BIN/node.exe"
    win_opts=(--shell-path "$(git_bash_path)" --npm-cli "$PI_BEDROCK_NODE_BIN/node_modules/npm/bin/npm-cli.js")
  fi
  merge_settings "$PI_BEDROCK_NODE_BIN/node" "$PI_BEDROCK_HOME/lib" "$PI_CODING_AGENT_DIR/settings.json" \
    "$PI_BEDROCK_PROVIDER" "$PI_BEDROCK_MODEL" "$PI_BEDROCK_THINKING" \
    "$npm" "$PI_BEDROCK_NPM_PREFIX" "$PI_BEDROCK_HOME/settings.orig.json" "${PI_ENABLED_MODELS_JSON:-}" ${win_opts[@]+"${win_opts[@]}"}
  log_info "已更新 $PI_CODING_AGENT_DIR/settings.json（默认 $PI_BEDROCK_PROVIDER/${PI_BEDROCK_MODEL}，thinking=${PI_BEDROCK_THINKING}）"
  local launcher="$PI_BEDROCK_HOME/bin/aws-mcp-proxy"
  if [ "$OPT_MCP" = 1 ]; then
    configure_mcp "$PI_BEDROCK_NODE_BIN/node" "$PI_BEDROCK_HOME/lib" "$PI_CODING_AGENT_DIR/mcp.json" "$launcher"
  else
    # 之前安装过 MCP、这次使用 --no-mcp：移除配置与代理，避免 pi 中出现连接失败的服务器
    remove_mcp_config "$PI_BEDROCK_NODE_BIN/node" "$PI_BEDROCK_HOME/lib" "$PI_CODING_AGENT_DIR/mcp.json" "$launcher"
    rm -rf "$(uv_dir)"
  fi
  if [ "$OPT_SKILLS" = 1 ]; then
    install_aws_skills
    install_agent_rules "$SCRIPT_DIR/templates/ops-rules.md"
    log_info "已写入运维规则到 $PI_CODING_AGENT_DIR/AGENTS.md（托管段落）"
  else
    remove_aws_skills
    remove_agent_rules
  fi
  if [ "$OPT_BASHRC" = 1 ]; then
    local rc
    while IFS= read -r rc; do
      write_rc_block "$rc" "$(_path_entry "$PI_BIN_DIR")"
      log_info "已在 ~${rc#"$HOME"} 中确保 $PI_BIN_DIR 在 PATH 中"
    done < <(rc_files)
  fi
}

smoke_test() {
  local v
  v="$("$PI_BIN_DIR/pi" --version 2>&1)" || die "pi 启动失败: $v"
  log_info "pi --version: $v"
}

print_summary() {
  local region="$1" shell_rc ops_region activate
  shell_rc="$(rc_files | tail -n1)"
  shell_rc="~${shell_rc#"$HOME"}"
  activate="source $shell_rc        # 当前终端立即生效（新开的终端标签页自动生效）"
  is_windows && activate="重新打开 PowerShell / 终端窗口   # 使 PATH 生效（Git Bash 中也可 source ~/.bashrc）"
  ops_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${PI_DEFAULT_AWS_REGION:-us-east-1}}}"
  cat >&2 <<EOF

$(printf '%s' "${_C_GRN}")安装完成$(printf '%s' "${_C_OFF}")
  pi            $PI_BIN_DIR/pi  (pi $PI_VERSION)
  默认模型      $PI_BEDROCK_PROVIDER / $PI_BEDROCK_MODEL
  Bedrock 区域  ${region:-跟随当前 AWS 区域（${ops_region}）}
  AWS MCP       $([ "$OPT_MCP" = 1 ] && echo "aws-mcp（默认运维区域 = 当前 AWS 区域 ${ops_region}）" || echo "未安装")
  运维 skills   $(if [ "$OPT_SKILLS" = 1 ]; then skills_dir; else echo "未安装"; fi)
  写操作护栏    aws-ops-guard（写操作逐次人工确认；/aws-guard 查看或切换模式）
  配置          $PI_BEDROCK_HOME/env, $PI_CODING_AGENT_DIR/{settings,mcp}.json

下一步:
  $activate
  pi-bedrock-doctor         # 端到端自检
  pi-bedrock-login          # 凭证过期时重新登录（--reconfigure 重新选择方式）
  pi                        # 开始使用
  卸载: $(if is_windows; then printf 'powershell -ExecutionPolicy Bypass -File %s/uninstall.ps1' "$PI_BEDROCK_HOME"; else printf 'bash %s/uninstall.sh' "$PI_BEDROCK_HOME"; fi)
EOF
}

main() {
  parse_args "$@"
  validate_inputs
  preflight
  mark_install_home
  ensure_aws_credentials
  detect_default_region
  ensure_node
  install_pi
  if [ "$OPT_MCP" = 1 ]; then
    ensure_uv
    install_mcp_proxy
  fi
  local region
  region="$(resolve_bedrock_region)"
  PI_ENABLED_MODELS_JSON=""
  if [ "$OPT_FILTER_MODELS" = 1 ]; then
    configure_model_list "${region:-${AWS_REGION:-${AWS_DEFAULT_REGION:-${PI_DEFAULT_AWS_REGION:-us-east-1}}}}" "$SCRIPT_DIR/lib"
  fi
  install_runtime_files
  write_configuration "$region"
  smoke_test
  print_summary "$region"
}

main "$@"
