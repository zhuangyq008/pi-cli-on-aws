# shellcheck shell=bash
# 安装器的后台任务：互不依赖的步骤（Bedrock 区域探测、AWS MCP 代理安装）与 Node.js / pi 安装并行，缩短总耗时。
# 每个任务的 stdout / stderr 写入独立文件，结束后再回放日志，避免与前台输出交错。
# 兼容 bash 3.2（macOS 自带）：不使用关联数组，PID 保存在 _BG_PID_<NAME> 变量中。

_BG_DIR=""
_BG_NAMES=""

_bg_valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]; }

# bg_start NAME CMD...：在子 shell 中后台运行 CMD（继承 set -e；die 只结束该子 shell）
bg_start() {
  local name="$1"
  shift
  _bg_valid_name "$name" || { log_error "非法的后台任务名: $name"; return 1; }
  [ -n "$_BG_DIR" ] || _BG_DIR="$(mktemp -d)"
  ("$@") >"$_BG_DIR/$name.out" 2>"$_BG_DIR/$name.log" </dev/null &
  printf -v "_BG_PID_$name" '%s' "$!"
  _BG_NAMES="$_BG_NAMES $name"
}

_bg_pid() { local v="_BG_PID_$1"; printf '%s' "${!v:-}"; }

# bg_running NAME：任务仍在运行
bg_running() {
  local pid
  pid="$(_bg_pid "$1")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# bg_wait NAME [MESSAGE]：等待任务结束并回放其日志；返回任务的退出码。仍在运行时先输出 MESSAGE
bg_wait() {
  local name="$1" pid rc=0
  pid="$(_bg_pid "$name")"
  [ -n "$pid" ] || { log_error "未启动的后台任务: $name"; return 1; }
  if [ -n "${2:-}" ] && bg_running "$name"; then log_info "$2"; fi
  wait "$pid" || rc=$?
  printf -v "_BG_PID_$name" '%s' ""
  cat "$_BG_DIR/$name.log" >&2
  return "$rc"
}

# bg_output NAME：任务的 stdout（bg_wait 之后调用）
bg_output() { cat "$_BG_DIR/$1.out" 2>/dev/null || true; }

# bg_cleanup：结束仍在运行的任务（安装失败或被中断时由 EXIT trap 调用）并删除临时目录
bg_cleanup() {
  local name pid
  for name in $_BG_NAMES; do
    pid="$(_bg_pid "$name")"
    [ -n "$pid" ] || continue
    if command -v pkill >/dev/null 2>&1; then pkill -TERM -P "$pid" 2>/dev/null || true; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true   # 回收任务，避免 bash 打印 "Terminated"
  done
  [ -n "$_BG_DIR" ] && rm -rf "$_BG_DIR"
  return 0
}
