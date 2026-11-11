# shellcheck shell=bash
# Bedrock 区域探测：用一次极小的 Converse 调用（maxTokens=16）验证 "模型 + 区域 + 配额 + IAM" 是否可用。
# 背景：global.* 跨区域推理的 TPM 配额按源区域分别计算，部分账号在多数区域默认为 0，
# 此时 CloudShell 所在区域会持续 ThrottlingException。探测可自动选出有配额的源区域。

# 候选源区域（按地理分组；实际顺序由 order_regions 依当前区域重排）
: "${PI_BEDROCK_PROBE_REGIONS:=us-east-1 us-east-2 us-west-2 ca-central-1 sa-east-1 eu-north-1 eu-west-1 eu-central-1 eu-west-2 ap-southeast-1 ap-northeast-1 ap-southeast-2 ap-south-1}"
: "${PI_BEDROCK_PROBE_PARALLEL:=4}"   # CloudShell 资源有限，限制并发 aws 进程数
: "${PI_BEDROCK_PROBE_TIMEOUT:=45}"

# classify_probe_error STDERR_TEXT：把 AWS CLI 错误归类为稳定的状态字
classify_probe_error() {
  case "$1" in
    *ThrottlingException* | *ServiceQuotaExceededException* | *"Too many tokens"*) printf 'throttled' ;;
    *AccessDeniedException*) printf 'denied' ;;
    *"model identifier is invalid"* | *ResourceNotFoundException* | *"not supported in this region"*) printf 'unavailable' ;;
    *UnrecognizedClientException* | *ExpiredToken* | *"Unable to locate credentials"* | *InvalidSignatureException*) printf 'nocreds' ;;
    *"Could not connect"* | *"Connect timeout"* | *"Read timeout"*) printf 'network' ;;
    *) printf 'error' ;;
  esac
}

# bedrock_probe REGION MODEL：stdout 输出 ok|throttled|denied|unavailable|nocreds|network|error
bedrock_probe() {
  local region="$1" model="$2" err rc=0
  err="$(
    AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard run_timeout "$PI_BEDROCK_PROBE_TIMEOUT" \
      aws bedrock-runtime converse --region "$region" --model-id "$model" \
      --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
      --inference-config '{"maxTokens":16}' \
      --query stopReason --output text 2>&1 >/dev/null
  )" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok'
  elif [ "$rc" -eq 124 ]; then
    printf 'network'
  else
    log_debug "probe $region rc=$rc: $err"
    classify_probe_error "$err"
  fi
}

_region_geo() {
  case "$1" in
    us-* | ca-* | sa-* | mx-*) printf 'amer' ;;
    eu-* | me-* | il-* | af-*) printf 'emea' ;;
    ap-*) printf 'apac' ;;
    *) printf 'other' ;;
  esac
}

# order_regions CURRENT CANDIDATES...：当前区域优先，其次同地理分组，再其余；去重
order_regions() {
  local current="$1" geo r
  shift
  geo="$(_region_geo "$current")"
  {
    [ -n "$current" ] && printf '%s\n' "$current"
    for r in "$@"; do [ "$(_region_geo "$r")" = "$geo" ] && printf '%s\n' "$r"; done
    for r in "$@"; do [ "$(_region_geo "$r")" != "$geo" ] && printf '%s\n' "$r"; done
  } | awk 'NF && !seen[$0]++'
}

# select_bedrock_region MODEL CURRENT_REGION
#   stdout：选中的区域（成功时）
#   返回码：0 选中；3 凭证/权限问题（换区域无意义）；4 所有候选区域均不可用
select_bedrock_region() {
  local model="$1" current="$2" ordered first first_status
  # shellcheck disable=SC2086
  ordered="$(order_regions "$current" $PI_BEDROCK_PROBE_REGIONS)"
  first="$(printf '%s\n' "$ordered" | head -n1)"

  first_status="$(bedrock_probe "$first" "$model")"
  log_info "探测 $first: $first_status"
  case "$first_status" in
    ok) printf '%s' "$first"; return 0 ;;
    nocreds) return 3 ;;
  esac

  local tmp rc=0
  tmp="$(mktemp -d)"
  _probe_others "$model" "$tmp" "$(printf '%s\n' "$ordered" | tail -n +2)"
  _pick_first_ok "$tmp" "$first_status" "$(printf '%s\n' "$ordered" | tail -n +2)" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# 并行探测其余候选区域，结果写入 DIR/<region>
_probe_others() {
  local model="$1" dir="$2" regions="$3"
  [ -n "$regions" ] || return 0
  export -f bedrock_probe classify_probe_error log_debug run_timeout
  export PI_BEDROCK_PROBE_TIMEOUT PI_BEDROCK_DEBUG
  # shellcheck disable=SC2016 # 位置参数在子 bash 中展开
  printf '%s\n' "$regions" | xargs -P "$PI_BEDROCK_PROBE_PARALLEL" -I{} \
    bash -c 'bedrock_probe "$1" "$2" >"$3/$1"' _ {} "$model" "$dir"
}

# 按偏好顺序返回第一个 ok 的区域；全部失败时依据失败类型返回 3 或 4
_pick_first_ok() {
  local dir="$1" first_status="$2" regions="$3" r status summary="" denied=0
  [ "$first_status" = denied ] && denied=1
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    status="$(cat "$dir/$r" 2>/dev/null || printf 'error')"
    summary="$summary $r=$status"
    if [ "$status" = ok ]; then
      log_info "其余候选:$summary"
      printf '%s' "$r"
      return 0
    fi
    [ "$status" = denied ] && denied=1
  done <<<"$regions"
  log_info "其余候选:$summary"
  [ "$denied" = 1 ] && return 3
  return 4
}
