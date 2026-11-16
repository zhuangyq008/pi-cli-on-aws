#!/usr/bin/env bats
# 复用本机已有的 Node.js / uv / Python，以及安装器的后台任务
load helpers

setup() {
  ORIG_PATH="$PATH"
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/node.sh"
  source "$REPO_ROOT/lib/mcp.sh"
  source "$REPO_ROOT/lib/jobs.sh"
  PI_GUARD_RUNTIME_ROOTS=""
  # 只含桩命令与基础工具的 PATH（不受本机真实 node / uv / python 影响）
  BASE="$SANDBOX/base"
  mkdir -p "$BASE"
  local t
  for t in bash sh cat dirname basename readlink awk sed tr grep mkdir rm ln chmod mktemp find wc head tail sort env sleep kill cp mv uname sha256sum; do
    ln -sf "$(type -P "$t")" "$BASE/$t"
  done
  export PATH="$STUB_BIN:$BASE"
}
teardown() { PATH="$ORIG_PATH"; teardown_sandbox; }

# fake_node DIR VERSION [EXEC_PATH]：node 桩；-p process.execPath 输出 EXEC_PATH（默认自身）
fake_node() {
  local dir="$1" ver="$2" exe="${3:-$1/node}"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\ncase "$1" in -v) echo v%s ;; -p) echo %s ;; esac\n' "$ver" "$exe" >"$dir/node"
  chmod +x "$dir/node"
}
fake_npm() { printf '#!/usr/bin/env bash\n' >"$1/npm"; chmod +x "$1/npm"; }

@test "ensure_node：复用用户可写的 Node（如 nvm），安装目录加入护栏保护，删除旧的私有 Node" {
  local nvm="$HOME/.nvm/versions/node/v24.1.0/bin"
  fake_node "$nvm" 24.1.0
  fake_npm "$nvm"
  mkdir -p "$PI_BEDROCK_HOME/node/old"
  PATH="$nvm:$PATH"
  ensure_node 2>"$SANDBOX/log"
  [ "$PI_BEDROCK_NODE_BIN" = "$nvm" ]
  [ "$PI_GUARD_RUNTIME_ROOTS" = "$HOME/.nvm/versions/node/v24.1.0:$nvm" ]
  [ ! -e "$PI_BEDROCK_HOME/node" ]
  grep -q '已加入 aws-ops-guard 保护目录' "$SANDBOX/log"
}

@test "ensure_node：不可写的系统 Node 直接复用，不加入保护目录" {
  local sys="$SANDBOX/usr/bin"
  fake_node "$sys" 22.19.0
  fake_npm "$sys"
  path_immutable() { return 0; }
  PATH="$sys:$PATH"
  ensure_node 2>"$SANDBOX/log"
  [ "$PI_BEDROCK_NODE_BIN" = "$sys" ]
  [ -z "$PI_GUARD_RUNTIME_ROOTS" ]
  grep -q '复用系统 Node.js v22.19.0' "$SANDBOX/log"
}

@test "ensure_node：版本管理器的 shim 解析为真实的 Node 目录" {
  local real="$HOME/.volta/tools/image/node/24.2.0/bin" shim="$HOME/.volta/bin"
  fake_node "$real" 24.2.0
  fake_npm "$real"
  fake_node "$shim" 24.2.0 "$real/node"
  PATH="$shim:$PATH"
  ensure_node 2>/dev/null
  [ "$PI_BEDROCK_NODE_BIN" = "$real" ]
}

@test "ensure_node：版本过低、缺少 npm 或 --node private 时安装私有 Node" {
  install_private_node() { PI_BEDROCK_NODE_BIN=private; }
  local d="$SANDBOX/n1"
  fake_node "$d" 22.17.0
  fake_npm "$d"
  PATH="$d:$PATH" ensure_node 2>/dev/null
  [ "$PI_BEDROCK_NODE_BIN" = private ]

  d="$SANDBOX/n2"
  fake_node "$d" 24.0.0
  PI_BEDROCK_NODE_BIN=""
  PATH="$d:$PATH" ensure_node 2>"$SANDBOX/log"
  [ "$PI_BEDROCK_NODE_BIN" = private ]
  grep -q '没有 npm' "$SANDBOX/log"

  fake_npm "$d"
  PI_BEDROCK_NODE_BIN=""
  PATH="$d:$PATH" PI_BEDROCK_NODE_MODE=private ensure_node 2>/dev/null
  [ "$PI_BEDROCK_NODE_BIN" = private ]
  [ -z "$PI_GUARD_RUNTIME_ROOTS" ]
}

@test "ensure_node：--node system 且不可用时报错" {
  local d="$SANDBOX/n"
  fake_node "$d" 20.0.0
  PATH="$d:$PATH" PI_BEDROCK_NODE_MODE=system run ensure_node
  [ "$status" -ne 0 ]
  [[ "$output" == *"系统 Node.js 不可用"* ]]
}

@test "add_runtime_root：去重，拒绝根目录与非法路径" {
  add_runtime_root /opt/homebrew/bin
  add_runtime_root /opt/homebrew/bin
  add_runtime_root /
  add_runtime_root 'relative/path'
  add_runtime_root '/bad path'
  add_runtime_root /opt/homebrew/Cellar/node/24.1.0
  [ "$PI_GUARD_RUNTIME_ROOTS" = /opt/homebrew/bin:/opt/homebrew/Cellar/node/24.1.0 ]
}

@test "ensure_uv：复用 PATH 中满足最低版本的 uv，并删除私有 uv；版本过低时下载固定版本" {
  make_stub uv 'echo "uv 0.9.2 (abc 2025-01-01)"'
  mkdir -p "$PI_BEDROCK_HOME/uv/bin"
  ensure_uv 2>/dev/null
  [ "$PI_UV_BIN" = "$STUB_BIN/uv" ]
  [ ! -e "$PI_BEDROCK_HOME/uv/bin" ]

  make_stub uv 'echo "uv 0.4.9"'
  make_stub curl 'exit 22'
  run ensure_uv
  [ "$status" -ne 0 ]
  [[ "$output" == *"下载 uv 失败"* ]]
}

# fake_python NAME VERSION [IN_VENV]：python 桩，按 find_system_python / _select_mcp_python 的调用方式应答
fake_python() {
  local name="$1" ver="$2" venv="${3:-0}" minor
  minor="${ver#3.}"
  minor="${minor%%.*}"
  make_stub "$name" "
case \"\$*\" in
  *sys.executable*) if [ $venv = 0 ] && [ $minor -ge 11 ] && [ $minor -le 14 ]; then echo '$STUB_BIN/$name'; else echo ''; fi ;;
  *realpath*) echo '$HOME/.pyenv/versions/$ver' ;;
  *base_prefix*) echo '$HOME/.pyenv/versions/$ver' ;;
  -V) echo 'Python $ver' ;;
esac"
}

@test "find_system_python：按 3.13 → 3.12 → 3.11 → 3.14 → python3 的顺序选择，跳过版本不符与 venv" {
  fake_python python3 3.9.6
  run find_system_python
  [ "$status" -ne 0 ]
  fake_python python3.12 3.12.4 1
  run find_system_python
  [ "$status" -ne 0 ]
  fake_python python3.11 3.11.9
  [ "$(find_system_python)" = "$STUB_BIN/python3.11" ]
  fake_python python3.13 3.13.1
  [ "$(find_system_python)" = "$STUB_BIN/python3.13" ]
}

@test "_select_mcp_python：可写的系统 Python 加入保护目录；managed / 未找到时使用托管 Python" {
  fake_python python3.12 3.12.4
  _select_mcp_python 2>/dev/null
  [ "$_PI_MCP_PY" = "$STUB_BIN/python3.12" ]
  [ "$_PI_UV_PY_PREF" = only-system ]
  [ "$_PI_MCP_PY_ID" = "system:$STUB_BIN/python3.12" ]
  [ "$PI_GUARD_RUNTIME_ROOTS" = "$HOME/.pyenv/versions/3.12.4:$STUB_BIN" ]

  PI_GUARD_RUNTIME_ROOTS=""
  PI_MCP_PYTHON_MODE=managed _select_mcp_python 2>/dev/null
  [ "$_PI_UV_PY_PREF" = only-managed ]
  [ "$_PI_MCP_PY" = "$PI_MCP_PYTHON" ]
  [ -z "$PI_GUARD_RUNTIME_ROOTS" ]

  rm "$STUB_BIN/python3.12"
  _select_mcp_python 2>/dev/null
  [ "$_PI_MCP_PY_ID" = "managed:$PI_MCP_PYTHON" ]
  PI_MCP_PYTHON_MODE=system run _select_mcp_python
  [ "$status" -ne 0 ]
  [[ "$output" == *"未在 PATH 中找到 Python 3.11–3.14"* ]]
}

@test "bg_start / bg_wait：返回任务退出码，回放日志，stdout 可读取" {
  ok_job() { log_info "job log"; printf 'us-west-2'; }
  bad_job() { die "boom"; }
  bg_start ok ok_job
  bg_start bad bad_job
  bg_wait ok 2>"$SANDBOX/log"
  grep -q 'job log' "$SANDBOX/log"
  [ "$(bg_output ok)" = us-west-2 ]
  run bg_wait bad
  [ "$status" -eq 1 ]
  [[ "$output" == *"boom"* ]]
  bg_cleanup
}

@test "bg_cleanup：结束仍在运行的任务并删除临时目录" {
  bg_start slow sleep 30
  local pid dir="$_BG_DIR"
  pid="$(_bg_pid slow)"
  bg_running slow
  bg_cleanup
  sleep 0.2
  ! kill -0 "$pid" 2>/dev/null
  [ ! -d "$dir" ]
}

@test "bg_start：拒绝非法任务名" {
  run bg_start 'a;b' true
  [ "$status" -ne 0 ]
}

@test "ensure_node：PATH 最前面是本工具的私有 Node（在 pi 的 shell 中重装）时不当作系统 Node 复用、不删除" {
  local priv="$PI_BEDROCK_HOME/node/node-v24.22.2-linux-x64/bin"
  fake_node "$priv" 24.22.2
  fake_npm "$priv"
  ln -s node-v24.22.2-linux-x64 "$PI_BEDROCK_HOME/node/current"
  install_private_node() { PI_BEDROCK_NODE_BIN=reinstalled; }
  PATH="$PI_BEDROCK_HOME/node/current/bin:$PATH" ensure_node 2>/dev/null
  [ -x "$priv/node" ]
  [ -z "$PI_GUARD_RUNTIME_ROOTS" ]
  [ "$PI_BEDROCK_NODE_BIN" != "$priv" ]
}

@test "add_runtime_root：拒绝过于宽泛的目录（\$HOME、/usr/local、/opt/homebrew 等），保留更具体的目录" {
  local d
  for d in "$HOME" "$HOME/.local" /usr /usr/local /opt/homebrew /opt /; do add_runtime_root "$d"; done
  [ -z "$PI_GUARD_RUNTIME_ROOTS" ]
  add_runtime_root "$HOME/bin"
  add_runtime_root /usr/local/bin/
  [ "$PI_GUARD_RUNTIME_ROOTS" = "$HOME/bin:/usr/local/bin" ]
}

@test "add_runtime_alias：Homebrew Cellar 路径同时保护 opt/<formula> 别名" {
  add_runtime_alias /opt/homebrew/Cellar/node/24.1.0/bin/node
  add_runtime_alias /opt/homebrew/Cellar/python@3.12/3.12.4/Frameworks/Python.framework/Versions/3.12
  add_runtime_alias /usr/bin/node
  [ "$PI_GUARD_RUNTIME_ROOTS" = /opt/homebrew/opt/node:/opt/homebrew/opt/python@3.12 ]
}

@test "ensure_node：真实 Node 不可写、但 PATH 目录中的符号链接可写时，加入保护目录" {
  local sys="$SANDBOX/usr/bin" link="$HOME/bin"
  fake_node "$sys" 22.19.0
  fake_npm "$sys"
  mkdir -p "$link"
  ln -s "$sys/node" "$link/node"
  ln -s "$sys/npm" "$link/npm"
  path_immutable() { case "$1" in "$SANDBOX/usr/"*) return 0 ;; *) return 1 ;; esac; }
  PATH="$link:$PATH"
  ensure_node 2>/dev/null
  [ "$PI_BEDROCK_NODE_BIN" = "$link" ]
  [[ ":$PI_GUARD_RUNTIME_ROOTS:" == *":$link:"* ]]
}

@test "ensure_uv：可写目录中的 uv 加入保护目录" {
  make_stub uv 'echo "uv 0.9.2"'
  ensure_uv 2>/dev/null
  [ "$PI_GUARD_RUNTIME_ROOTS" = "$STUB_BIN" ]
}
