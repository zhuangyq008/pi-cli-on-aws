# shellcheck shell=bash
# bats 公共夹具：每个测试使用独立的沙箱 HOME，避免污染真实环境。
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup_sandbox() {
  SANDBOX="$(mktemp -d "${BATS_TMPDIR:-/tmp}/pi-bedrock-test.XXXXXX")"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export PI_BEDROCK_HOME="$HOME/.local/share/pi-bedrock"
  export PI_BIN_DIR="$HOME/.local/bin"
  export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
  unset PI_BEDROCK_REGION PI_BEDROCK_MODEL PI_SHELL_AWS_REGION
  STUB_BIN="$SANDBOX/stubs"
  mkdir -p "$STUB_BIN"
}

teardown_sandbox() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# make_stub NAME BODY：在 STUB_BIN 下创建可执行桩脚本
make_stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}
