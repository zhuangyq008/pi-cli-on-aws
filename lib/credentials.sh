# shellcheck shell=bash
# shellcheck disable=SC2034 # PI_AWS_PROFILE / PI_DEFAULT_AWS_REGION 供 install.sh 与 pi-bedrock-login 使用
# 本地环境（macOS / Windows / 非 CloudShell 的 Linux）的 AWS 凭证检测与引导式配置。
# 凭证与 Region 为必需项：没有可用凭证时交互式引导（aws login / IAM Identity Center / AK+SK / 已有 profile），
# 配置后用 sts:GetCallerIdentity 验证。结果写入全局变量 PI_AWS_PROFILE、PI_DEFAULT_AWS_REGION 并 export AWS_PROFILE。

: "${PI_AWS_SETUP_PROFILE:=pi-bedrock}"
[[ "$PI_AWS_SETUP_PROFILE" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "ERROR: 非法的 PI_AWS_SETUP_PROFILE: $PI_AWS_SETUP_PROFILE" >&2; exit 1; }

_PI_IN_FD=0

aws_cli_install_hint() {
  case "$(os_name 2>/dev/null)" in
    darwin) printf '%s\n' "  官方安装包: curl -fsSLo /tmp/AWSCLIV2.pkg https://awscli.amazonaws.com/AWSCLIV2.pkg && sudo installer -pkg /tmp/AWSCLIV2.pkg -target /" ;;
    windows) printf '%s\n' "  PowerShell: winget install -e --id Amazon.AWSCLI    或下载安装 https://awscli.amazonaws.com/AWSCLIV2.msi" ;;
    *) printf '%s\n' "  参考: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
  esac
}

require_aws_cli() {
  if ! command -v aws >/dev/null 2>&1; then
    log_error "需要 AWS CLI v2 来登录 AWS 与调用 Bedrock，请先安装："
    aws_cli_install_hint >&2
    exit 1
  fi
  aws --version 2>&1 | grep -q '^aws-cli/2\.' || die "需要 AWS CLI v2（当前: $(aws --version 2>&1 | head -n1)）"
}

# 当前环境下凭证可用时输出调用者 ARN
aws_identity() {
  AWS_MAX_ATTEMPTS=2 _strip_cr run_timeout 60 aws sts get-caller-identity --query Arn --output text 2>/dev/null
}

# 凭证验证失败时的错误摘要（最后一行，如 ExpiredToken、Connect timeout）
aws_identity_error() {
  AWS_MAX_ATTEMPTS=2 _strip_cr run_timeout 60 aws sts get-caller-identity --query Arn --output text 2>&1 >/dev/null | tail -n 1
}

# 选择交互输入来源：终端 → /dev/tty → 管道（自动化测试）
_open_input() {
  # 自动化（如 Windows E2E 经 SSM 执行，无交互终端）：PI_BEDROCK_WIZARD_INPUT 指定应答文件
  if [ -n "${PI_BEDROCK_WIZARD_INPUT:-}" ]; then
    exec 7<"$PI_BEDROCK_WIZARD_INPUT" || return 1
    _PI_IN_FD=7
  elif [ -t 0 ]; then
    _PI_IN_FD=0
  elif { exec 7</dev/tty; } 2>/dev/null; then
    _PI_IN_FD=7
  elif [ -p /dev/stdin ] || [ -f /dev/stdin ]; then
    _PI_IN_FD=0
  else
    return 1
  fi
}

# 输入结束（EOF，如 Ctrl+D 或应答文件读完）时返回 2，调用方据此中止引导，而不是落入默认选项
_ask() {
  local msg="$1" default="${2:-}" answer=""
  printf '%s%s: ' "$msg" "${default:+ [$default]}" >&2
  IFS= read -r -u "$_PI_IN_FD" answer || [ -n "$answer" ] || { printf '\n' >&2; return 2; }
  printf '%s' "${answer:-$default}"
}

_ask_secret() {
  local msg="$1" answer=""
  printf '%s: ' "$msg" >&2
  IFS= read -r -s -u "$_PI_IN_FD" answer || [ -n "$answer" ] || { printf '\n' >&2; return 2; }
  printf '\n' >&2
  printf '%s' "$answer"
}

_ask_region() {
  local default="${AWS_REGION:-${AWS_DEFAULT_REGION:-${PI_DEFAULT_AWS_REGION:-us-east-1}}}" r
  while :; do
    r="$(_ask "AWS Region（必填，例如 us-east-1、ap-northeast-1）" "$default")" || return 2
    is_valid_region "$r" && { printf '%s' "$r"; return 0; }
    log_warn "非法的 Region: $r"
  done
}

# upsert_ini_section FILE SECTION KEY=VALUE...：替换（或追加）INI 分区，保留其他内容；文件权限 0600
upsert_ini_section() {
  local file="$1" section="$2" tmp kv
  shift 2
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  tmp="$(mktemp "$file.XXXXXX")"
  # 只按"去掉首尾空白后整行等于 [SECTION]"匹配分区头，不会误删其他分区
  awk -v s="[$section]" '
    /^[[:space:]]*\[/ { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); skip = (line == s) }
    !skip { print }
  ' "$file" >"$tmp"
  [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | od -An -c | tr -d ' ')" != '\n' ] && printf '\n' >>"$tmp"
  {
    printf '[%s]\n' "$section"
    for kv in "$@"; do printf '%s = %s\n' "${kv%%=*}" "${kv#*=}"; done
  } >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

_setup_access_keys() {
  local profile="$1" region="$2" ak sk token
  ak="$(_ask "Access Key ID")" || return 2
  sk="$(_ask_secret "Secret Access Key（输入不显示）")" || return 2
  token="$(_ask_secret "Session Token（临时凭证必填，长期 IAM 用户密钥直接回车）")" || return 2
  [[ "$ak" =~ ^(AKIA|ASIA)[A-Z0-9]{12,}$ ]] || { log_warn "Access Key ID 格式不正确"; return 1; }
  [[ "$sk" =~ ^[A-Za-z0-9/+=]{20,}$ ]] || { log_warn "Secret Access Key 格式不正确"; return 1; }
  [ -z "$token" ] || [[ "$token" =~ ^[A-Za-z0-9/+=]{20,}$ ]] || { log_warn "Session Token 格式不正确"; return 1; }
  [[ "$ak" == ASIA* ]] && [ -z "$token" ] && { log_warn "ASIA 开头的临时凭证必须提供 Session Token"; return 1; }
  local -a entries=("aws_access_key_id=$ak" "aws_secret_access_key=$sk")
  [ -n "$token" ] && entries+=("aws_session_token=$token")
  local aws_home
  aws_home="$(aws_user_home)"
  upsert_ini_section "${AWS_SHARED_CREDENTIALS_FILE:-$aws_home/.aws/credentials}" "$profile" "${entries[@]}"
  upsert_ini_section "${AWS_CONFIG_FILE:-$aws_home/.aws/config}" "profile $profile" "region=$region" "output=json"
  log_info "凭证已写入 ~/.aws/credentials 的 [$profile]（仅当前用户可读）"
}

_choose_existing_profile() {
  local profiles i=0 choice name
  profiles="$(_strip_cr aws configure list-profiles 2>/dev/null || true)"
  [ -n "$profiles" ] || { log_warn "AWS CLI 中没有已配置的 profile"; return 1; }
  while IFS= read -r name; do i=$((i + 1)); printf '  %d) %s\n' "$i" "$name" >&2; done <<<"$profiles"
  choice="$(_ask "选择 profile 编号")" || return 2
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  name="$(printf '%s\n' "$profiles" | sed -n "${choice}p")"
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

_aws_login() {
  local -a extra=()
  # 无图形界面的 Linux（如 SSH 到 EC2）使用 --remote：在另一台设备的浏览器中完成登录
  if [ "$(os_name)" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then extra=(--remote); fi
  aws login --profile "$1" --region "$2" ${extra[@]+"${extra[@]}"} <&"$_PI_IN_FD" >&2
}

# 引导一次配置；成功时输出 "PROFILE REGION"（在子 shell 中运行，不能直接设置全局变量）
_credential_wizard_once() {
  local choice region profile="$PI_AWS_SETUP_PROFILE"
  printf '\n%s\n' "未检测到可用的 AWS 凭证，请选择配置方式：" >&2
  printf '%s\n' "  1) aws login：浏览器登录 AWS 控制台身份（推荐，需要 AWS CLI 2.32+）" \
    "  2) IAM Identity Center（SSO）：aws configure sso" \
    "  3) Access Key / Secret Key（可选 Session Token）" \
    "  4) 使用已有 profile" >&2
  choice="$(_ask "请输入 1-4" 1)" || return 2
  region="$(_ask_region)" || return 2
  case "$choice" in
    1) _aws_login "$profile" "$region" || return 1 ;;
    2)
      log_info "按提示填写 SSO Start URL、SSO Region，并在浏览器中授权、选择账号与角色"
      aws configure sso --profile "$profile" <&"$_PI_IN_FD" >&2 || return 1
      aws configure set region "$region" --profile "$profile"
      ;;
    3) _setup_access_keys "$profile" "$region" || return $? ;;
    4) profile="$(_choose_existing_profile)" || return $? ;;
    *) log_warn "无效选择: $choice"; return 1 ;;
  esac
  printf '%s %s' "$profile" "$region"
}

# 需要时询问 Region（已有凭证但未配置任何区域的情况）
ensure_aws_region() {
  [ -n "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}${PI_DEFAULT_AWS_REGION:-}" ] && return 0
  local r
  r="$(_strip_cr aws configure get region 2>/dev/null || true)"
  if is_valid_region "$r"; then
    PI_DEFAULT_AWS_REGION="$r"
    log_info "未设置 AWS_REGION，使用 AWS CLI 配置中的默认区域 $r"
    return 0
  fi
  if _open_input; then
    PI_DEFAULT_AWS_REGION="$(_ask_region)" || die "输入已结束，未配置 AWS Region"
  else
    die "未配置 AWS Region：请 export AWS_REGION=<region> 或运行 aws configure set region <region> 后重试"
  fi
}

# PI_FORCE_CREDENTIAL_SETUP=1 时即使现有凭证可用也进入引导（pi-bedrock-login --reconfigure）
ensure_aws_credentials() {
  is_cloudshell && return 0
  require_aws_cli
  local arn profile attempt
  if [ "${PI_FORCE_CREDENTIAL_SETUP:-0}" != 1 ] && arn="$(aws_identity)" && [ -n "$arn" ]; then
    log_info "使用现有 AWS 凭证：$arn${AWS_PROFILE:+（profile ${AWS_PROFILE}）}"
    [ -n "${AWS_PROFILE:-}" ] && PI_AWS_PROFILE="$AWS_PROFILE"
    ensure_aws_region
    return 0
  fi
  _open_input || die "未检测到可用的 AWS 凭证，且当前不是交互式终端。请先运行 aws login / aws configure sso / aws configure，或在终端中重新运行 install.sh"
  local result region rc
  for attempt in 1 2 3; do
    rc=0
    result="$(_credential_wizard_once)" || rc=$?
    [ "$rc" -eq 2 ] && die "输入已结束，未完成 AWS 凭证配置"
    if [ "$rc" -eq 0 ]; then
      profile="${result% *}" region="${result##* }"
      if arn="$(AWS_PROFILE="$profile" aws_identity)" && [ -n "$arn" ]; then
        export AWS_PROFILE="$profile"
        PI_AWS_PROFILE="$profile"
        PI_DEFAULT_AWS_REGION="$region"
        log_info "凭证验证成功：${arn}（profile ${profile}，Region ${region}）"
        return 0
      fi
      log_warn "profile ${profile} 的凭证验证失败：$(AWS_PROFILE="$profile" aws_identity_error)"
    fi
    log_warn "凭证配置或验证失败（第 ${attempt}/3 次），请重试"
  done
  die "未能完成 AWS 凭证配置"
}
