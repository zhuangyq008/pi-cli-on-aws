#!/usr/bin/env bats
# 本地 AWS 凭证引导（lib/credentials.sh）：aws 命令为桩，用户输入经管道提供
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/credentials.sh"
  unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_EXECUTION_ENV AWS_ACCESS_KEY_ID AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE PI_DEFAULT_AWS_REGION PI_AWS_PROFILE
  export STUB_LOG="$SANDBOX/aws.log"
  # 测试用的假密钥在运行时拼接：文件中不出现密钥格式的字面量（避免触发密钥扫描）
  FAKE_AK="AKIA$(printf 'ABCDEFGHIJKLMNOP')" FAKE_AK2="AKIA$(printf 'Z%.0s' {1..16})" FAKE_ASIA="ASIA${FAKE_AK#AKIA}"
  FAKE_SK="$(printf 'abcdefghij')klmnopqrstuvwxyz0123456789ABCD" FAKE_SK2="$(printf 'z%.0s' {1..40})"
  # aws 桩：--profile pi-bedrock 且 credentials 中有合法 AK 时 sts 成功；STUB_OK_PROFILE 指定的 profile 也视为有效
  make_stub aws '
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
  "--version "*|"--version") echo "aws-cli/2.37.11 Python/3.12" ; exit 0 ;;
  "sts get-caller-identity")
    p="${AWS_PROFILE:-}"
    if [ -n "${STUB_OK_PROFILE:-}" ] && [ "$p" = "$STUB_OK_PROFILE" ]; then echo "arn:aws:iam::123456789012:user/$p"; exit 0; fi
    if [ "$p" = pi-bedrock ] && grep -q "aws_access_key_id = AKIA" "$HOME/.aws/credentials" 2>/dev/null; then echo "arn:aws:iam::123456789012:user/pi"; exit 0; fi
    echo "Unable to locate credentials" >&2; exit 255 ;;
  "configure list-profiles") printf "%b" "${STUB_PROFILES:-}" ; exit 0 ;;
  "configure get") echo "${STUB_REGION:-}"; exit 0 ;;
  "configure set") exit 0 ;;
  "configure sso") exit 0 ;;
  "login --profile") exit 0 ;;
esac
exit 0'
  export PATH="$STUB_BIN:$PATH"
}
teardown() { teardown_sandbox; }

@test "现有凭证可用：直接使用，不提示" {
  export STUB_OK_PROFILE=prod AWS_PROFILE=prod STUB_REGION=eu-west-1
  ensure_aws_credentials </dev/null
  [ "$PI_AWS_PROFILE" = prod ]
  [ "$PI_DEFAULT_AWS_REGION" = eu-west-1 ]
}

@test "AK/SK：写入专用 profile（保留其他 profile，权限 0600），设置 Region" {
  mkdir -p "$HOME/.aws"
  printf '[other]\naws_access_key_id = %s\n' "AKIA$(printf 'OTHER0000000')" >"$HOME/.aws/credentials"
  ensure_aws_credentials < <(printf '%s\n' 3 us-west-2 "$FAKE_AK" "$FAKE_SK" "")
  [ "$PI_AWS_PROFILE" = pi-bedrock ]
  [ "$AWS_PROFILE" = pi-bedrock ]
  [ "$PI_DEFAULT_AWS_REGION" = us-west-2 ]
  grep -q '^\[other\]' "$HOME/.aws/credentials"
  grep -q "aws_access_key_id = $FAKE_AK" "$HOME/.aws/credentials"
  grep -q '^\[profile pi-bedrock\]' "$HOME/.aws/config"
  grep -q 'region = us-west-2' "$HOME/.aws/config"
  [ "$(stat -c %a "$HOME/.aws/credentials")" = 600 ]
  ! grep -q "$FAKE_SK" "$STUB_LOG"   # 密钥不经过命令行参数
}

@test "AK/SK：重复配置时替换原 [pi-bedrock] 分区" {
  ensure_aws_credentials < <(printf '%s\n' 3 us-west-2 "$FAKE_AK" "$FAKE_SK" "")
  export PI_FORCE_CREDENTIAL_SETUP=1
  ensure_aws_credentials < <(printf '%s\n' 3 us-east-1 "$FAKE_AK2" "$FAKE_SK2" "")
  [ "$(grep -c '^\[pi-bedrock\]' "$HOME/.aws/credentials")" -eq 1 ]
  grep -q "$FAKE_AK2" "$HOME/.aws/credentials"
  ! grep -q "$FAKE_AK" "$HOME/.aws/credentials"
}

@test "临时凭证缺少 Session Token 时提示并重试" {
  run ensure_aws_credentials < <(printf '%s\n' 3 us-west-2 "$FAKE_ASIA" "$FAKE_SK" "" 3 us-west-2 "$FAKE_AK" "$FAKE_SK" "")
  [ "$status" -eq 0 ]
  [[ "$output" == *"必须提供 Session Token"* ]]
  [[ "$output" == *"凭证验证成功"* ]]
}

@test "选择已有 profile" {
  export STUB_PROFILES='default\nprod\n' STUB_OK_PROFILE=prod
  ensure_aws_credentials <<<$'4\nap-northeast-1\n2\n'
  [ "$PI_AWS_PROFILE" = prod ]
  [ "$PI_DEFAULT_AWS_REGION" = ap-northeast-1 ]
}

@test "aws login / SSO：以专用 profile 与所选 Region 调用 AWS CLI" {
  export STUB_OK_PROFILE=pi-bedrock
  ensure_aws_credentials <<<$'1\nus-east-1\n'
  grep -q '^login --profile pi-bedrock --region us-east-1' "$STUB_LOG"
  : >"$STUB_LOG"
  export PI_FORCE_CREDENTIAL_SETUP=1
  ensure_aws_credentials <<<$'2\neu-central-1\n'
  grep -q '^configure sso --profile pi-bedrock' "$STUB_LOG"
  grep -q '^configure set region eu-central-1 --profile pi-bedrock' "$STUB_LOG"
}

@test "三次失败后退出" {
  run ensure_aws_credentials <<<$'9\nus-east-1\n9\nus-east-1\n9\nus-east-1\n'
  [ "$status" -ne 0 ]
  [[ "$output" == *"未能完成 AWS 凭证配置"* ]]
}

@test "非交互且无凭证：给出明确指引" {
  run ensure_aws_credentials </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"不是交互式终端"* ]]
}

@test "未安装 AWS CLI：给出安装指引" {
  rm "$STUB_BIN/aws"
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/credentials.sh'; [ -x /usr/local/bin/aws ] && PATH=\"\${PATH//\/usr\/local\/bin/}\"; require_aws_cli"
  [ "$status" -ne 0 ]
  [[ "$output" == *"需要 AWS CLI v2"* ]]
}

@test "CloudShell：跳过凭证引导" {
  export AWS_EXECUTION_ENV=CloudShell
  ensure_aws_credentials </dev/null
  [ ! -s "$STUB_LOG" ]
}

@test "已有凭证但未配置 Region：询问 Region" {
  export STUB_OK_PROFILE=prod AWS_PROFILE=prod STUB_REGION=
  ensure_aws_credentials <<<$'ap-southeast-1\n'
  [ "$PI_DEFAULT_AWS_REGION" = ap-southeast-1 ]
}

@test "update_env_file：保留其他键，更新指定键" {
  write_env_file "$SANDBOX/env" PI_BEDROCK_MODEL=m PI_AWS_PROFILE=old
  update_env_file "$SANDBOX/env" PI_AWS_PROFILE=new PI_DEFAULT_AWS_REGION=us-west-2
  grep -qx 'PI_BEDROCK_MODEL=m' "$SANDBOX/env"
  grep -qx 'PI_AWS_PROFILE=new' "$SANDBOX/env"
  ! grep -q 'PI_AWS_PROFILE=old' "$SANDBOX/env"
  grep -qx 'PI_DEFAULT_AWS_REGION=us-west-2' "$SANDBOX/env"
}

@test "输入结束（EOF）时立即中止，不落入默认的 aws login" {
  run ensure_aws_credentials < <(printf '%s\n' 3 us-west-2 "$FAKE_AK")
  [ "$status" -ne 0 ]
  [[ "$output" == *"输入已结束"* ]]
  ! grep -q '^login' "$STUB_LOG"
}

@test "PI_BEDROCK_WIZARD_INPUT：从应答文件读取（无终端的自动化环境）" {
  printf '%s\n' 3 us-west-2 "$FAKE_AK" "$FAKE_SK" "" >"$SANDBOX/answers"
  PI_BEDROCK_WIZARD_INPUT="$SANDBOX/answers" ensure_aws_credentials </dev/null
  [ "$PI_AWS_PROFILE" = pi-bedrock ]
}

@test "验证失败时显示 AWS CLI 的错误原因" {
  run ensure_aws_credentials <<<$'4\nus-west-2\n1\n'
  [[ "$output" == *"凭证验证失败：Unable to locate credentials"* ]] || [[ "$output" == *"没有已配置的 profile"* ]]
  export STUB_PROFILES='broken\n'
  run ensure_aws_credentials <<<$'4\nus-west-2\n1\n'
  [[ "$output" == *"profile broken 的凭证验证失败：Unable to locate credentials"* ]]
}

@test "upsert_ini_section：只替换完全匹配的分区（不误删注释中或名称相近的分区）" {
  local f="$SANDBOX/ini"
  printf '[pi-bedrock-old]\nk = 1\n[x] # [pi-bedrock]\nk = 2\n  [pi-bedrock]  \nk = 3\n' >"$f"
  upsert_ini_section "$f" pi-bedrock "k=9"
  grep -q '^\[pi-bedrock-old\]' "$f"
  grep -q '^\[x\] # \[pi-bedrock\]' "$f"
  [ "$(grep -c '^k = ' "$f")" -eq 3 ]
  ! grep -q 'k = 3' "$f"
  grep -q 'k = 9' "$f"
}

@test "PI_AWS_SETUP_PROFILE：拒绝可注入 INI 的名称" {
  run env PI_AWS_SETUP_PROFILE=$'x]\n[default' bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/credentials.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法的 PI_AWS_SETUP_PROFILE"* ]]
}
