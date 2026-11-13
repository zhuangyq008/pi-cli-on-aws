#!/usr/bin/env bash
# shellcheck disable=SC2016 # 内联 node 脚本中的 ${} 是 JS 模板字符串
# AWS 运维任务 benchmark：同一模型、同一组只读任务，对比两种 pi 配置的 token 消耗与耗时
#   mcp：默认安装（AWS MCP Server + 运维 skills + AGENTS.md 运维规则 + 护栏）
#   cli：--no-mcp --no-skills（只用 bash 工具中的 aws CLI + 护栏）
# 两组都通过 RPC 驱动，护栏确认框中"只读 + 需要凭证"的命令自动批准，其余拒绝（见 rpc-bench.mjs）。
# 注意：会产生真实 Bedrock 调用与只读 AWS API 调用（含 Cost Explorer，每次请求 0.01 USD）。
# 用法: bash tests/bench/bench.sh [setup|creds|run|report|clean|all]
#   环境变量: BENCH_WORK（默认 /tmp/pi-bench） BENCH_REGION（默认 us-east-1） BENCH_ARMS（默认 "mcp cli"）
#             BENCH_TASKS（默认 tasks.tsv 中全部） BENCH_REPEAT（默认 1） BENCH_TIMEOUT（默认 600 秒）
set -euo pipefail
umask 077

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/../.." && pwd)"
WORK="${BENCH_WORK:-/tmp/pi-bench}"
REGION="${BENCH_REGION:-us-east-1}"
ARMS="${BENCH_ARMS:-mcp cli}"
REPEAT="${BENCH_REPEAT:-1}"
TIMEOUT="${BENCH_TIMEOUT:-600}"
HOST_NODE="$(command -v node)" || { echo "需要 node" >&2; exit 1; }
AWS_DIR="$(dirname "$(command -v aws)")"
SENTINEL=".pi-bench-workdir"

for arm in $ARMS; do
  case "$arm" in mcp | cli) ;; *) echo "未知分组 $arm（只支持 mcp / cli）" >&2; exit 64 ;; esac
done

# 工作目录必须归当前用户所有、不是符号链接，并带有 bench 标记文件（防止共享主机上被预先创建 / clean 误删其他目录）
ensure_work() {
  if [ -e "$WORK" ] || [ -L "$WORK" ]; then
    [ -d "$WORK" ] && [ ! -L "$WORK" ] && [ -O "$WORK" ] && [ -f "$WORK/$SENTINEL" ] \
      || { echo "拒绝使用 $WORK：不是当前用户创建的 bench 工作目录" >&2; exit 1; }
  else
    mkdir -m 700 "$WORK" && : >"$WORK/$SENTINEL"
  fi
  chmod 700 "$WORK"
}

arm_home() { printf '%s/%s/home' "$WORK" "$1"; }
arm_env() {
  printf '%s\0' env -i HOME="$(arm_home "$1")" USER="${USER:-bench}" TERM=xterm-256color LANG=C.UTF-8 SHELL=/bin/bash \
    PATH="$AWS_DIR:/usr/bin:/bin" AWS_EC2_METADATA_DISABLED=true AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
}
in_arm() { local arm="$1"; shift; local -a e; mapfile -d '' e < <(arm_env "$arm"); (cd "$WORK/$arm/project" && "${e[@]}" "$@" </dev/null); }

# 凭证：宿主身份的临时凭证写入各组 ~/.aws/credentials（0600），clean 时删除
write_creds() {
  local home="$1" tmp
  mkdir -p "$home/.aws"
  rm -f "$home/.aws/credentials"
  tmp="$(mktemp "$home/.aws/.credentials.XXXXXX")"
  (aws configure export-credentials --format process | "$HOST_NODE" -e '
    const c = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const lines = ["[default]", `aws_access_key_id = ${c.AccessKeyId}`, `aws_secret_access_key = ${c.SecretAccessKey}`];
    if (c.SessionToken) lines.push(`aws_session_token = ${c.SessionToken}`);
    if (!c.Expiration) process.stderr.write("警告：导出的是长期凭证（无 Expiration），bench 结束后会删除，但建议改用临时凭证\n");
    process.stdout.write(lines.join("\n") + "\n");' >"$tmp") || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$home/.aws/credentials"
  printf '[default]\nregion = %s\n' "$REGION" >"$home/.aws/config"
}

setup() {
  local arm flags
  for arm in $ARMS; do
    case "$arm" in mcp) flags=() ;; cli) flags=(--no-mcp --no-skills) ;; *) echo "未知分组 $arm" >&2; exit 64 ;; esac
    mkdir -p "$(arm_home "$arm")" "$WORK/$arm/project"
    write_creds "$(arm_home "$arm")"
    echo "== 安装 $arm 组（${flags[*]:-默认}）"
    in_arm "$arm" bash "$REPO_ROOT/install.sh" --no-bashrc "${flags[@]}" >"$WORK/$arm/install.log" 2>&1 \
      || { tail -30 "$WORK/$arm/install.log"; exit 1; }
    tail -3 "$WORK/$arm/install.log"
  done
}

refresh_creds() { local arm; for arm in $ARMS; do write_creds "$(arm_home "$arm")"; done; }
wipe_creds() { local arm; for arm in mcp cli; do rm -f "$(arm_home "$arm")/.aws/credentials"; done; }

run() {
  local arm id prompt i out
  refresh_creds
  mkdir -p "$WORK/results"
  while IFS=$'\t' read -r id prompt; do
    [ -z "$id" ] && continue
    if [ -n "${BENCH_TASKS:-}" ] && [[ " $BENCH_TASKS " != *" $id "* ]]; then continue; fi
    for i in $(seq 1 "$REPEAT"); do
      for arm in $ARMS; do
        out="$WORK/results/$id.$arm.$i.json"
        echo "== [$id #$i] $arm"
        in_arm "$arm" "$(sed -n 's/^PI_BEDROCK_NODE_BIN=//p' "$(arm_home "$arm")/.local/share/pi-bedrock/env")/node" \
          "$BENCH_DIR/rpc-bench.mjs" "$(arm_home "$arm")/.local/bin/pi" "$prompt" "$TIMEOUT" >"$out" 2>"$out.stderr" || true
        "$HOST_NODE" -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
          console.log(`   ${(r.durationMs/1000).toFixed(1)}s turns=${r.turns} tools=${r.toolCalls.length} tokens=${r.usage.totalTokens} ${r.error??""}`)' "$out" \
          || { echo "   结果无效，见 $out.stderr"; tail -5 "$out.stderr"; }
      done
    done
  done <"$BENCH_DIR/tasks.tsv"
}

report() { "$HOST_NODE" "$BENCH_DIR/report.mjs" "$WORK/results" "$BENCH_DIR/tasks.tsv" | tee "$WORK/report.md"; }

clean() {
  [ -e "$WORK" ] || return 0
  ensure_work
  wipe_creds
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}

case "${1:-all}" in setup | creds | run | all) ensure_work ;; esac
# setup / run / all 结束（含异常退出）时删除临时凭证；creds 子命令用于手工调试，保留凭证，用完请 clean
case "${1:-all}" in setup | run | all) trap wipe_creds EXIT ;; esac
case "${1:-all}" in
  setup) setup ;;
  run) run ;;
  creds) refresh_creds ;;
  report) report ;;
  clean) clean ;;
  all) setup; run; report ;;
  *) echo "用法: $0 [setup|creds|run|report|clean|all]" >&2; exit 64 ;;
esac
