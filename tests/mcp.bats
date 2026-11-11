#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/mcp-runtime.sh"
  MCP_JSON="$PI_CODING_AGENT_DIR/mcp.json"
  LAUNCHER="$PI_BEDROCK_HOME/bin/aws-mcp-proxy"
}
teardown() { teardown_sandbox; }

merge() { node "$REPO_ROOT/lib/merge-mcp.mjs" "$@"; }
get() { node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],c); process.stdout.write(v===undefined?"<unset>":typeof v==="string"?v:JSON.stringify(v))' "$MCP_JSON" "$1"; }

# ---------- endpoint 区域映射 ----------
@test "aws_mcp_endpoint_region: 支持的区域直接使用，其余映射到最近的 endpoint" {
  [ "$(aws_mcp_endpoint_region us-east-1)" = us-east-1 ]
  [ "$(aws_mcp_endpoint_region ap-southeast-1)" = ap-southeast-1 ]
  [ "$(aws_mcp_endpoint_region us-east-2)" = us-east-1 ]
  [ "$(aws_mcp_endpoint_region us-west-1)" = us-west-2 ]
  [ "$(aws_mcp_endpoint_region sa-east-1)" = us-east-1 ]
  [ "$(aws_mcp_endpoint_region eu-west-3)" = eu-west-1 ]
  [ "$(aws_mcp_endpoint_region eu-north-1)" = eu-central-1 ]
  [ "$(aws_mcp_endpoint_region me-central-1)" = eu-central-1 ]
  [ "$(aws_mcp_endpoint_region ap-northeast-2)" = ap-northeast-1 ]
  [ "$(aws_mcp_endpoint_region ap-southeast-4)" = ap-southeast-2 ]
  [ "$(aws_mcp_endpoint_region ap-south-1)" = ap-southeast-1 ]
  [ "$(aws_mcp_endpoint_region "")" = us-east-1 ]
}

# ---------- mcp.json 合并 ----------
@test "merge-mcp apply: 新建 aws-mcp 条目（direct 暴露、绝对路径命令）并保留其他服务器" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"mcpServers":{"github":{"url":"https://example.com/mcp"}},"other":1}\n' >"$MCP_JSON"
  run merge apply "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$(get mcpServers.aws-mcp.command)" = "$LAUNCHER" ]
  [ "$(get mcpServers.aws-mcp.exposure)" = direct ]
  [ "$(get mcpServers.aws-mcp.timeout)" = 300 ]
  [ "$(get mcpServers.github.url)" = https://example.com/mcp ]
  [ "$(get other)" = 1 ]
  [ -f "$MCP_JSON.pi-bedrock.bak" ]
}

@test "merge-mcp apply: 幂等；遇到用户自建的同名条目返回 3 且不修改" {
  merge apply "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  merge apply "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  printf '{"mcpServers":{"aws-mcp":{"command":"uvx","args":["x"]}}}\n' >"$MCP_JSON"
  run merge apply "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  [ "$status" -eq 3 ]
  [ "$(get mcpServers.aws-mcp.command)" = uvx ]
}

@test "merge-mcp remove: 只删除本工具的条目" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"mcpServers":{"aws-mcp":{"command":"uvx"},"keep":{"command":"x"}}}\n' >"$MCP_JSON"
  merge remove "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  [ "$(get mcpServers.aws-mcp.command)" = uvx ]
  merge apply "$MCP_JSON" --name other --command "$LAUNCHER"
  merge remove "$MCP_JSON" --name other --command "$LAUNCHER"
  [ "$(get mcpServers.other)" = "<unset>" ]
  [ "$(get mcpServers.keep.command)" = x ]
}

@test "merge-mcp: 拒绝非法输入（相对路径命令、非法名称、非法 JSON、mcpServers 非对象）" {
  run merge apply "$MCP_JSON" --name aws-mcp --command relative/path
  [ "$status" -eq 64 ]
  run merge apply "$MCP_JSON" --name 'bad name' --command "$LAUNCHER"
  [ "$status" -eq 64 ]
  mkdir -p "$PI_CODING_AGENT_DIR"; printf '{broken' >"$MCP_JSON"
  run merge apply "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  [ "$status" -eq 2 ]
  printf '{"mcpServers":[]}' >"$MCP_JSON"
  run merge apply "$MCP_JSON" --name aws-mcp --command "$LAUNCHER"
  [ "$status" -eq 2 ]
}

# ---------- 启动器 ----------
install_launcher() {
  mkdir -p "$PI_BEDROCK_HOME/lib" "$PI_BEDROCK_HOME/bin" "$SANDBOX/proxy"
  cp "$REPO_ROOT/lib/config.sh" "$REPO_ROOT/lib/mcp-runtime.sh" "$PI_BEDROCK_HOME/lib/"
  local content
  content="$(cat "$REPO_ROOT/bin/aws-mcp-proxy")"
  printf '%s\n' "${content//__PI_BEDROCK_HOME__/$PI_BEDROCK_HOME}" >"$LAUNCHER"
  chmod +x "$LAUNCHER"
  printf '#!/usr/bin/env bash\necho "args=$*"\necho "AWS_REGION=$AWS_REGION"\n' >"$SANDBOX/proxy/mcp-proxy-for-aws-cli"
  chmod +x "$SANDBOX/proxy/mcp-proxy-for-aws-cli"
  write_env_file "$PI_BEDROCK_HOME/env" "PI_AWS_MCP_PROXY_BIN=$SANDBOX/proxy/mcp-proxy-for-aws-cli"
}

@test "aws-mcp-proxy: 运维区域来自 PI_OPS_AWS_REGION，签名区域为最近的 endpoint" {
  install_launcher
  run env -u PI_BEDROCK_HOME AWS_REGION=sa-east-1 PI_OPS_AWS_REGION=ap-northeast-2 "$LAUNCHER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=https://aws-mcp.ap-northeast-1.api.aws/mcp --region ap-northeast-1 --metadata AWS_REGION=ap-northeast-2"* ]]
  [[ "$output" == *"AWS_REGION=ap-northeast-2"* ]]
}

@test "aws-mcp-proxy: 未设置 PI_OPS_AWS_REGION 时使用 PI_SHELL_AWS_REGION（Bedrock 区域被覆盖的情况）" {
  install_launcher
  run env -u PI_BEDROCK_HOME -u PI_OPS_AWS_REGION AWS_REGION=sa-east-1 PI_SHELL_AWS_REGION=us-east-1 "$LAUNCHER"
  [[ "$output" == *"--metadata AWS_REGION=us-east-1"* ]]
}

@test "aws-mcp-proxy: 拒绝非法区域，支持覆盖 endpoint 区域" {
  install_launcher
  run env -u PI_BEDROCK_HOME PI_OPS_AWS_REGION='us-east-1;id' "$LAUNCHER"
  [ "$status" -eq 64 ]
  run env -u PI_BEDROCK_HOME PI_OPS_AWS_REGION=us-east-1 PI_AWS_MCP_ENDPOINT_REGION=eu-west-2 "$LAUNCHER"
  [[ "$output" == *"https://aws-mcp.eu-west-2.api.aws/mcp --region eu-west-2 --metadata AWS_REGION=us-east-1"* ]]
}

# ---------- 运维区域捕获 ----------
@test "apply_bedrock_region: 改写 AWS_REGION 前记录运维区域；用户设置的 PI_OPS_AWS_REGION 优先" {
  unset PI_OPS_AWS_REGION
  export AWS_REGION=us-east-1 PI_BEDROCK_REGION=sa-east-1
  apply_bedrock_region
  [ "$PI_OPS_AWS_REGION" = us-east-1 ]
  [ "$AWS_REGION" = sa-east-1 ]
  export AWS_REGION=us-east-1 PI_OPS_AWS_REGION=eu-west-1
  apply_bedrock_region
  [ "$PI_OPS_AWS_REGION" = eu-west-1 ]
}
