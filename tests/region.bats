#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/region.sh"
  export PI_BEDROCK_PROBE_REGIONS="us-east-1 us-west-2 eu-north-1 ap-southeast-1"
  export STUB_AWS_LOG="$SANDBOX/aws-calls.log"
  # aws 桩：按 STUB_AWS_RESULTS（"region=status ..."）返回对应的 CLI 错误
  make_stub aws '
region=""; while [ $# -gt 0 ]; do [ "$1" = "--region" ] && region="$2"; shift; done
echo "$region" >>"$STUB_AWS_LOG"
status=error
for kv in $STUB_AWS_RESULTS; do [ "${kv%%=*}" = "$region" ] && status="${kv#*=}"; done
case "$status" in
  ok) echo end_turn; exit 0 ;;
  throttled) echo "aws: [ERROR]: An error occurred (ThrottlingException) when calling the Converse operation (reached max retries: 0): Too many tokens, please wait before trying again." >&2 ;;
  denied) echo "aws: [ERROR]: An error occurred (AccessDeniedException) when calling the Converse operation: not authorized" >&2 ;;
  unavailable) echo "aws: [ERROR]: An error occurred (ValidationException) when calling the Converse operation: The provided model identifier is invalid." >&2 ;;
  nocreds) echo "Unable to locate credentials. You can configure credentials by running \"aws configure\"." >&2 ;;
  *) echo "boom" >&2 ;;
esac
exit 254'
  export PATH="$STUB_BIN:$PATH"
}
teardown() { teardown_sandbox; }

@test "classify_probe_error: 覆盖主要错误类型" {
  [ "$(classify_probe_error 'An error occurred (ThrottlingException) when ...')" = throttled ]
  [ "$(classify_probe_error 'An error occurred (AccessDeniedException) ...')" = denied ]
  [ "$(classify_probe_error 'The provided model identifier is invalid.')" = unavailable ]
  [ "$(classify_probe_error 'An error occurred (ExpiredTokenException)')" = nocreds ]
  [ "$(classify_probe_error 'Could not connect to the endpoint URL')" = network ]
  [ "$(classify_probe_error 'weird')" = error ]
}

@test "bedrock_probe: 成功与限流" {
  STUB_AWS_RESULTS="us-east-1=throttled ap-southeast-1=ok"
  export STUB_AWS_RESULTS
  [ "$(bedrock_probe ap-southeast-1 m)" = ok ]
  [ "$(bedrock_probe us-east-1 m)" = throttled ]
}

@test "order_regions: 当前区域优先，同地理分组其次，去重" {
  run order_regions eu-north-1 us-east-1 eu-north-1 ap-southeast-1 eu-west-1
  [ "$output" = $'eu-north-1\neu-west-1\nus-east-1\nap-southeast-1' ]
}

@test "select_bedrock_region: 当前区域可用时直接返回，不再探测其他区域" {
  export STUB_AWS_RESULTS="us-east-1=ok ap-southeast-1=ok"
  run select_bedrock_region m us-east-1
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = us-east-1 ]
  [ "$(wc -l <"$STUB_AWS_LOG")" -eq 1 ]
}

@test "select_bedrock_region: 当前区域配额为 0 时回退到首个可用区域（按偏好顺序）" {
  export STUB_AWS_RESULTS="us-east-1=throttled us-west-2=throttled eu-north-1=ok ap-southeast-1=ok"
  region="$(select_bedrock_region m us-east-1 2>/dev/null)"
  [ "$region" = eu-north-1 ]
}

@test "select_bedrock_region: 同地理分组优先（ap-northeast-1 控制台 → ap-southeast-1）" {
  export STUB_AWS_RESULTS="ap-northeast-1=throttled eu-north-1=ok ap-southeast-1=ok"
  export PI_BEDROCK_PROBE_REGIONS="us-east-1 eu-north-1 ap-northeast-1 ap-southeast-1"
  region="$(select_bedrock_region m ap-northeast-1 2>/dev/null)"
  [ "$region" = ap-southeast-1 ]
}

@test "select_bedrock_region: 无凭证时返回 3 且不扫描其他区域" {
  export STUB_AWS_RESULTS="us-east-1=nocreds"
  run select_bedrock_region m us-east-1
  [ "$status" -eq 3 ]
  [ "$(wc -l <"$STUB_AWS_LOG")" -eq 1 ]
}

@test "select_bedrock_region: 全部无权限返回 3，全部限流返回 4" {
  export STUB_AWS_RESULTS="us-east-1=denied us-west-2=denied eu-north-1=denied ap-southeast-1=denied"
  run select_bedrock_region m us-east-1
  [ "$status" -eq 3 ]
  export STUB_AWS_RESULTS="us-east-1=throttled us-west-2=throttled eu-north-1=unavailable ap-southeast-1=throttled"
  run select_bedrock_region m us-east-1
  [ "$status" -eq 4 ]
}

@test "select_bedrock_region: 当前区域不在候选列表中也会被优先探测" {
  export STUB_AWS_RESULTS="me-central-1=ok"
  region="$(select_bedrock_region m me-central-1 2>/dev/null)"
  [ "$region" = me-central-1 ]
}
