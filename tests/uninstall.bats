#!/usr/bin/env bats
# uninstall.sh：针对模拟的已安装目录树运行（无网络），覆盖只读文件、备份恢复与 set -e 陷阱
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/config.sh"
  local h="$PI_BEDROCK_HOME" a="$PI_CODING_AGENT_DIR"
  mkdir -p "$h/lib" "$h/bin" "$a/extensions/aws-ops-guard" "$a/skills/aws-agent-toolkit/x" "$PI_BIN_DIR"
  cp "$REPO_ROOT/lib/"{common,config,region,mcp-runtime,skills}.sh "$REPO_ROOT/lib/"{json-file,merge-settings,merge-mcp}.mjs "$h/lib/"
  cp "$REPO_ROOT/uninstall.sh" "$h/uninstall.sh"
  printf 'pi-cli-bedrock\n' >"$h/.pi-bedrock-managed"
  write_env_file "$h/env" "PI_BEDROCK_NODE_BIN=$(dirname "$(command -v node)")" "PI_BIN_DIR=$PI_BIN_DIR" "PI_CODING_AGENT_DIR=$a"
  printf '#!/bin/sh\n# pi-cli-bedrock-wrapper\n' >"$PI_BIN_DIR/pi"
  printf '#!/bin/sh\n# pi-cli-bedrock\n' >"$PI_BIN_DIR/pi-bedrock-doctor"
  printf 'x' >"$a/extensions/aws-ops-guard/index.ts"
  printf 'pi-cli-bedrock\n' >"$a/extensions/aws-ops-guard/.pi-bedrock-managed"
  printf 'ref\n' >"$a/skills/aws-agent-toolkit/.pi-bedrock-managed"
  printf '{"mcpServers":{"aws-mcp":{"command":"%s/bin/aws-mcp-proxy"},"keep":{"command":"x"}}}\n' "$h" >"$a/mcp.json"
  printf '{"defaultProvider":"amazon-bedrock","defaultModel":"global.moonshotai.kimi-k3.1","theme":"dark"}\n' >"$a/settings.json"
  printf '{"defaultProvider":"anthropic","defaultModel":"claude-x","defaultThinkingLevel":null,"selfUpdateCommand":null}\n' >"$h/settings.orig.json"
  printf '# mine\n' >"$HOME/.bashrc"
  write_rc_block "$HOME/.bashrc" "$PI_BIN_DIR"
  printf '<!-- >>> pi-bedrock >>> -->\nrules\n<!-- <<< pi-bedrock <<< -->\n' >"$a/AGENTS.md"
  # 与安装器一致：运行时文件只读
  chmod 0444 "$a/extensions/aws-ops-guard/"* && chmod 0555 "$a/extensions/aws-ops-guard"
  chmod -R a-w "$h/lib" "$h/bin" && chmod 0555 "$PI_BIN_DIR/pi" "$h/uninstall.sh" && chmod 0400 "$h/env"
}
teardown() { chmod -R u+w "$SANDBOX" 2>/dev/null; teardown_sandbox; }

@test "uninstall.sh（从安装目录运行）: 清理全部内容并恢复用户配置" {
  run env -u PI_BEDROCK_HOME -u PI_BIN_DIR -u PI_CODING_AGENT_DIR bash "$PI_BEDROCK_HOME/uninstall.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$PI_BEDROCK_HOME" ]
  [ ! -e "$PI_BIN_DIR/pi" ] && [ ! -e "$PI_BIN_DIR/pi-bedrock-doctor" ]
  [ ! -e "$PI_CODING_AGENT_DIR/extensions/aws-ops-guard" ]
  [ ! -e "$PI_CODING_AGENT_DIR/skills/aws-agent-toolkit" ]
  [ "$(cat "$HOME/.bashrc")" = "# mine" ]
  [ "$(cat "$PI_CODING_AGENT_DIR/AGENTS.md")" = "" ]
  grep -q '"keep"' "$PI_CODING_AGENT_DIR/mcp.json"
  ! grep -q aws-mcp "$PI_CODING_AGENT_DIR/mcp.json"
  grep -q '"defaultModel": "claude-x"' "$PI_CODING_AGENT_DIR/settings.json"
  grep -q '"theme": "dark"' "$PI_CODING_AGENT_DIR/settings.json"
}

@test "uninstall.sh: 恢复安装前备份的同名护栏扩展" {
  mkdir -p "$PI_CODING_AGENT_DIR/.pi-bedrock-backup/aws-ops-guard.20260101000000"
  printf 'old' >"$PI_CODING_AGENT_DIR/.pi-bedrock-backup/aws-ops-guard.20260101000000/index.ts"
  run bash "$PI_BEDROCK_HOME/uninstall.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$PI_CODING_AGENT_DIR/extensions/aws-ops-guard/index.ts")" = old ]
  [ ! -e "$PI_CODING_AGENT_DIR/.pi-bedrock-backup" ]
}

@test "uninstall.sh: 没有归属标记的目录不删除" {
  chmod u+w "$PI_BEDROCK_HOME"
  rm -f "$PI_BEDROCK_HOME/.pi-bedrock-managed"
  run bash "$REPO_ROOT/uninstall.sh"
  [ "$status" -eq 0 ]
  [ -d "$PI_BEDROCK_HOME" ]
  [[ "$output" == *"跳过删除"* ]]
}
