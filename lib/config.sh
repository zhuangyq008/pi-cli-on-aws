# shellcheck shell=bash
# 配置读写：env 文件、settings.json 合并、~/.bashrc 托管段落、Bedrock 区域注入。
# 注意：bin/pi 包装器只 source 本文件（不依赖 common.sh），保持启动开销最小。

# env 文件允许的键（白名单）。env 文件按 KEY=VALUE 逐行解析，绝不 source/eval。
PI_BEDROCK_ENV_KEYS="PI_BEDROCK_REGION PI_BEDROCK_MODEL PI_BEDROCK_NODE_BIN PI_BEDROCK_PI_BIN PI_AWS_MCP_PROXY_BIN PI_BIN_DIR PI_CODING_AGENT_DIR PI_DEFAULT_AWS_REGION PI_AWS_PROFILE"
PI_BEDROCK_PREFIX_TAG="pi-bedrock:restore-shell-region"
PI_BEDROCK_MARKER_BEGIN="# >>> pi-bedrock >>>"
PI_BEDROCK_MARKER_END="# <<< pi-bedrock <<<"

_env_key_allowed() {
  case " $PI_BEDROCK_ENV_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# 值只允许路径/区域/模型 ID 常见字符，拒绝 $ ` ; 空格 等可被解释的字符
_env_value_safe() { [[ "$1" =~ ^[A-Za-z0-9._:/@+-]*$ ]]; }

# load_env_file FILE：把白名单内的键导出到当前 shell。已存在的环境变量优先（运行时覆盖）。
load_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    value="${value#\"}" value="${value%\"}"
    _env_key_allowed "$key" || continue
    _env_value_safe "$value" || continue
    [ -n "${!key+x}" ] && continue
    export "$key=$value"
  done <"$file"
}

# write_env_file FILE KEY=VALUE...：原子写入（先写临时文件再 mv），拒绝非法键值。
write_env_file() {
  local file="$1" kv key value tmp
  shift
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  # shellcheck disable=SC2094 # 写入的是临时文件，并未同时读写同一文件
  {
    printf '# 由 pi-cli-bedrock 安装器生成。可手工编辑；格式为 KEY=VALUE，不支持 shell 语法。\n'
    for kv in "$@"; do
      key="${kv%%=*}" value="${kv#*=}"
      if ! _env_key_allowed "$key" || ! _env_value_safe "$value"; then
        # shellcheck disable=SC2094
        rm -f "$tmp"
        printf 'ERROR: 非法的 env 项: %s\n' "$kv" >&2
        return 1
      fi
      printf '%s=%s\n' "$key" "$value"
    done
  } >"$tmp"
  mv -f "$tmp" "$file"
}

# _path_entry DIR：PATH 中的条目。Windows（Git Bash）上 PATH 以 ":" 分隔，C:/... 必须转换为 /c/... 形式
_path_entry() {
  case "$1" in
    [A-Za-z]:/*) if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; return 0; fi ;;
  esac
  printf '%s' "$1"
}

_is_region() { [[ "${1:-}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]]; }

# 记录"运维区域"（CloudShell 当前区域）到 PI_OPS_AWS_REGION，供 AWS MCP Server 作为默认操作区域。
# 必须在 apply_bedrock_region 改写 AWS_REGION 之前调用；用户显式设置的 PI_OPS_AWS_REGION 优先。
capture_ops_region() {
  if [ -n "${PI_OPS_AWS_REGION:-}" ]; then
    _is_region "$PI_OPS_AWS_REGION" && return 0
    printf 'pi-bedrock: 忽略非法的 PI_OPS_AWS_REGION=%s\n' "$PI_OPS_AWS_REGION" >&2
    unset PI_OPS_AWS_REGION
  fi
  local current="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  _is_region "$current" && export PI_OPS_AWS_REGION="$current"
  return 0
}

# 未设置 AWS_REGION 时（如 macOS 本地），使用安装时从 `aws configure get region` 记录的默认区域
apply_default_region() {
  if [ -z "${AWS_REGION:-}" ] && [ -z "${AWS_DEFAULT_REGION:-}" ] && _is_region "${PI_DEFAULT_AWS_REGION:-}"; then
    export AWS_REGION="$PI_DEFAULT_AWS_REGION" AWS_DEFAULT_REGION="$PI_DEFAULT_AWS_REGION"
  fi
  return 0
}

# AWS CLI / SDK 使用的用户目录：Windows 上 Python / Node 版 SDK 读取 %USERPROFILE%\.aws（忽略 HOME），其他平台为 $HOME
aws_user_home() {
  if [ -n "${USERPROFILE:-}" ] && case "$(uname -s)" in MINGW* | MSYS*) true ;; *) false ;; esac; then
    cygpath -u "$USERPROFILE"
  else
    printf '%s' "$HOME"
  fi
}

# pi 只在检测到 AWS 凭证相关环境变量时才启用 amazon-bedrock。macOS 等本地环境常用 ~/.aws 中的
# default profile 而不设置任何变量，此时显式设置 AWS_PROFILE=default（CloudShell 有容器凭证变量，不受影响）
apply_aws_profile_hint() {
  local v
  for v in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_BEARER_TOKEN_BEDROCK AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_WEB_IDENTITY_TOKEN_FILE; do
    [ -n "${!v:-}" ] && return 0
  done
  # 安装 / pi-bedrock-login 时配置的 profile 优先，其次是 ~/.aws 中的 default profile
  local aws_home
  aws_home="$(aws_user_home)"
  if [ -n "${PI_AWS_PROFILE:-}" ]; then
    export AWS_PROFILE="$PI_AWS_PROFILE"
  elif grep -qs '^\[\(profile \)\{0,1\}default\]' "${AWS_CONFIG_FILE:-$aws_home/.aws/config}" "${AWS_SHARED_CREDENTIALS_FILE:-$aws_home/.aws/credentials}"; then
    export AWS_PROFILE=default
  fi
  return 0
}

# update_env_file FILE KEY=VALUE...：保留现有键，更新 / 新增指定键（原子写入，权限 0400）
update_env_file() {
  local file="$1" key line
  shift
  local -a entries=()
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]] || continue
      key="${BASH_REMATCH[1]}"
      case " ${*%%=*} " in *" $key "*) continue ;; esac
      _env_key_allowed "$key" && entries+=("$line")
    done <"$file"
  fi
  entries+=("$@")
  write_env_file "$file" "${entries[@]}"
  chmod 0400 "$file"
}

# 若设置了 PI_BEDROCK_REGION，则仅对 pi 进程把 AWS_REGION 指向 Bedrock 区域，
# 并把原区域保存在 PI_SHELL_AWS_REGION，供 shellCommandPrefix 在 agent 的 bash 工具中还原。
apply_bedrock_region() {
  local target="${PI_BEDROCK_REGION:-}" current
  capture_ops_region
  [ -n "$target" ] || return 0
  if ! _is_region "$target"; then
    printf 'pi-bedrock: 忽略非法的 PI_BEDROCK_REGION=%s\n' "$target" >&2
    return 0
  fi
  current="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  [ "$current" = "$target" ] && return 0
  [ -n "$current" ] && export PI_SHELL_AWS_REGION="$current"
  export AWS_REGION="$target" AWS_DEFAULT_REGION="$target"
}

# 注入 pi 的 shellCommandPrefix（以换行与原命令拼接）
shell_prefix_snippet() {
  # 单引号内的 $ 需原样写入 settings.json，由 agent 的 shell 在运行时展开
  # shellcheck disable=SC2016
  # unset MSYS2_ARG_CONV_EXCL：Windows 包装器为 pi 关闭了参数路径转换，agent 的 bash 命令中需恢复（其他平台无影响）
  printf 'unset MSYS2_ARG_CONV_EXCL MSYS_NO_PATHCONV; if [ -n "${PI_SHELL_AWS_REGION:-}" ]; then export AWS_REGION="$PI_SHELL_AWS_REGION" AWS_DEFAULT_REGION="$PI_SHELL_AWS_REGION"; fi # %s' "$PI_BEDROCK_PREFIX_TAG"
}

# merge_settings NODE SCRIPT_DIR SETTINGS_FILE PROVIDER MODEL THINKING NPM_BIN NPM_PREFIX ORIG_FILE [ENABLED_MODELS_JSON] [--opt VALUE...]
merge_settings() {
  local -a extra=()
  [ -n "${10:-}" ] && extra=(--enabled-models "${10}")
  [ $# -gt 10 ] && extra+=("${@:11}")
  PI_BEDROCK_PREFIX_SNIPPET="$(shell_prefix_snippet)" \
    PI_BEDROCK_PREFIX_TAG="$PI_BEDROCK_PREFIX_TAG" \
    "$1" "$2/merge-settings.mjs" apply "$3" \
    --provider "$4" --model "$5" --thinking "$6" --npm "$7" --npm-prefix "$8" --orig "$9" ${extra[@]+"${extra[@]}"}
}

# unmerge_settings NODE SCRIPT_DIR SETTINGS_FILE PROVIDER MODEL NPM_PREFIX ORIG_FILE [--opt VALUE...]
unmerge_settings() {
  [ -f "$3" ] || return 0
  PI_BEDROCK_PREFIX_TAG="$PI_BEDROCK_PREFIX_TAG" \
    "$1" "$2/merge-settings.mjs" remove "$3" \
    --provider "$4" --model "$5" --npm-prefix "$6" --orig "$7" "${@:8}"
}

# ---- 托管段落（~/.bashrc、AGENTS.md 等）-----------------------------------
# remove_marked_block FILE BEGIN END：删除 BEGIN..END 之间（含标记行）的内容，保留文件 inode 与权限
remove_marked_block() {
  local file="$1" begin="$2" end="$3" tmp
  [ -f "$file" ] || return 0
  grep -qF "$begin" "$file" || return 0
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# write_marked_block FILE BEGIN END：用 stdin 内容替换（或追加）托管段落，幂等
write_marked_block() {
  local file="$1" begin="$2" end="$3"
  mkdir -p "$(dirname "$file")"
  remove_marked_block "$file" "$begin" "$end"
  touch "$file"
  # 若文件末尾没有换行，补一个，避免与上一行粘连
  [ -s "$file" ] && [ "$(tail -c1 "$file" | od -An -c | tr -d ' ')" != '\n' ] && printf '\n' >>"$file"
  {
    printf '%s\n' "$begin"
    cat
    printf '%s\n' "$end"
  } >>"$file"
}

remove_rc_block() { remove_marked_block "$1" "$PI_BEDROCK_MARKER_BEGIN" "$PI_BEDROCK_MARKER_END"; }

# write_rc_block RC BIN_DIR：确保 BIN_DIR 在 PATH 最前面（幂等）
write_rc_block() {
  local rc="$1" bin_dir="$2" quoted
  quoted="$(printf '%q' "$bin_dir")"
  {
    printf '# 由 pi-cli-bedrock 管理，运行 uninstall.sh 会自动移除本段\n'
    # shellcheck disable=SC2016 # $PATH 需原样写入 ~/.bashrc，在登录时展开
    printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH=%s:"$PATH" ;; esac\n' "$bin_dir" "$quoted"
  } | write_marked_block "$rc" "$PI_BEDROCK_MARKER_BEGIN" "$PI_BEDROCK_MARKER_END"
}
