#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/config.sh"
  mkdir -p "$PI_BEDROCK_HOME/lib" "$PI_BIN_DIR" "$SANDBOX/nodebin"
  cp "$REPO_ROOT/lib/config.sh" "$PI_BEDROCK_HOME/lib/"
  local content
  content="$(cat "$REPO_ROOT/bin/pi")"
  printf '%s\n' "${content//__PI_BEDROCK_HOME__/$PI_BEDROCK_HOME}" >"$PI_BIN_DIR/pi"
  chmod +x "$PI_BIN_DIR/pi"
  # 假 node：打印收到的参数与关键环境变量
  cat >"$SANDBOX/nodebin/node" <<'NODE'
#!/usr/bin/env bash
echo "argv=$*"
echo "AWS_REGION=${AWS_REGION:-}"
echo "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-}"
echo "PI_SHELL_AWS_REGION=${PI_SHELL_AWS_REGION:-}"
echo "PATH0=${PATH%%:*}"
NODE
  chmod +x "$SANDBOX/nodebin/node"
  unset PI_BEDROCK_HOME_OVERRIDE
}
teardown() { teardown_sandbox; }

write_env() { write_env_file "$PI_BEDROCK_HOME/env" "PI_BEDROCK_NODE_BIN=$SANDBOX/nodebin" "PI_BEDROCK_PI_BIN=/opt/pi/cli.js" "$@"; }
run_wrapper() { run env -u PI_BEDROCK_HOME "$@" "$PI_BIN_DIR/pi" --model x -p "hello world"; }

@test "wrapper: 用绝对路径 node 启动 pi 并透传参数，node 目录位于 PATH 最前" {
  write_env
  run_wrapper AWS_REGION=us-east-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"argv=/opt/pi/cli.js --model x -p hello world"* ]]
  [[ "$output" == *"PATH0=$SANDBOX/nodebin"* ]]
  [[ "$output" == *"AWS_REGION=us-east-1"* ]]
  [[ "$output" == *"PI_SHELL_AWS_REGION="$'\n'* ]]
}

@test "wrapper: 固定 Bedrock 区域时改写 AWS_REGION 并保存 CloudShell 原区域" {
  write_env PI_BEDROCK_REGION=ap-southeast-1
  run_wrapper AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
  [[ "$output" == *"AWS_REGION=ap-southeast-1"* ]]
  [[ "$output" == *"AWS_DEFAULT_REGION=ap-southeast-1"* ]]
  [[ "$output" == *"PI_SHELL_AWS_REGION=us-east-1"* ]]
}

@test "wrapper: 运行时 PI_BEDROCK_REGION 覆盖 env 文件" {
  write_env PI_BEDROCK_REGION=ap-southeast-1
  run_wrapper AWS_REGION=us-east-1 PI_BEDROCK_REGION=eu-north-1
  [[ "$output" == *"AWS_REGION=eu-north-1"* ]]
}

@test "wrapper: 安装目录缺失时给出明确提示" {
  rm -rf "$PI_BEDROCK_HOME"
  run_wrapper
  [ "$status" -eq 1 ]
  [[ "$output" == *"请重新运行 install.sh"* ]]
}

@test "wrapper: env 文件缺少必需键时失败" {
  write_env_file "$PI_BEDROCK_HOME/env" PI_BEDROCK_REGION=ap-southeast-1
  run_wrapper
  [ "$status" -ne 0 ]
  [[ "$output" == *"PI_BEDROCK_NODE_BIN"* ]]
}
