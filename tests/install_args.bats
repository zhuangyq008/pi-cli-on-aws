#!/usr/bin/env bats
# install.sh 参数校验：非法输入必须在任何下载/写盘之前被拒绝
load helpers

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "install.sh --help 正常退出" {
  run bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--region REGION"* ]]
}

@test "install.sh 拒绝未知参数" {
  run bash "$REPO_ROOT/install.sh" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"未知参数"* ]]
}

@test "install.sh 拒绝非法区域 / 模型 / 思考等级 / 版本，且不写任何文件" {
  run bash "$REPO_ROOT/install.sh" --region 'us-east-1;id'
  [ "$status" -ne 0 ]; [[ "$output" == *"非法区域"* ]]
  run bash "$REPO_ROOT/install.sh" --model 'a b'
  [ "$status" -ne 0 ]; [[ "$output" == *"非法模型"* ]]
  run bash "$REPO_ROOT/install.sh" --thinking ultra
  [ "$status" -ne 0 ]; [[ "$output" == *"非法思考等级"* ]]
  run bash "$REPO_ROOT/install.sh" --pi-version '1.0.0;rm'
  [ "$status" -ne 0 ]; [[ "$output" == *"非法 pi 版本"* ]]
  [ -z "$(ls -A "$HOME")" ]
}

@test "install.sh 拒绝包含特殊字符的安装路径" {
  run env PI_BEDROCK_HOME="$HOME/bad dir" bash "$REPO_ROOT/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"不支持的字符"* ]]
}

@test "install.sh 缺少 lib 目录时给出明确提示" {
  cp "$REPO_ROOT/install.sh" "$SANDBOX/install.sh"
  run bash "$SANDBOX/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"完整的 pi-cli-bedrock 目录"* ]]
}
