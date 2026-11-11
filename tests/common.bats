#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  # shellcheck source=../lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
}
teardown() { teardown_sandbox; }

@test "version_ge: 相等版本返回真" {
  run version_ge 22.19.0 22.19.0
  [ "$status" -eq 0 ]
}

@test "version_ge: 22.17.0 低于 22.19.0" {
  run version_ge v22.17.0 22.19.0
  [ "$status" -eq 1 ]
}

@test "version_ge: 主版本更高即满足（24.1.0 >= 22.19.0）" {
  run version_ge v24.1.0 22.19.0
  [ "$status" -eq 0 ]
}

@test "version_ge: 按数值而非字典序比较（22.100.0 > 22.19.0）" {
  run version_ge 22.100.0 22.19.0
  [ "$status" -eq 0 ]
}

@test "version_ge: 非法版本号返回 2" {
  run version_ge "abc" 22.19.0
  [ "$status" -eq 2 ]
}

@test "node_arch: 映射 x86_64 / aarch64，拒绝未知架构" {
  [ "$(node_arch x86_64)" = x64 ]
  [ "$(node_arch aarch64)" = arm64 ]
  run node_arch mips
  [ "$status" -ne 0 ]
}

@test "is_valid_region: 接受标准区域，拒绝注入" {
  is_valid_region us-east-1
  is_valid_region ap-southeast-1
  is_valid_region us-gov-west-1
  ! is_valid_region "us-east-1; rm -rf ~"
  ! is_valid_region ""
  ! is_valid_region "US-EAST-1"
}

@test "is_valid_model_id: 接受 profile ID 与 ARN，拒绝空格/引号" {
  is_valid_model_id global.moonshotai.kimi-k3.1
  is_valid_model_id "arn:aws:bedrock:ap-southeast-1:123456789012:inference-profile/global.moonshotai.kimi-k3.1"
  ! is_valid_model_id 'kimi" ; echo pwned'
  ! is_valid_model_id ""
}

@test "is_valid_thinking / is_valid_pi_version" {
  is_valid_thinking medium
  ! is_valid_thinking ultra
  is_valid_pi_version 1.5.2
  is_valid_pi_version latest
  ! is_valid_pi_version "1.5.2 && curl evil"
}

@test "is_cloudshell: 依据 AWS_EXECUTION_ENV 判断" {
  AWS_EXECUTION_ENV=CloudShell is_cloudshell
  ! AWS_EXECUTION_ENV=EC2 is_cloudshell
}
