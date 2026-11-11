#!/usr/bin/env bash
# pi-cli-bedrock 卸载：移除包装器、私有 Node/pi、uv/MCP 代理、运维 skills、护栏扩展、~/.bashrc 与 AGENTS.md 托管段落，
# 并回滚 settings.json / mcp.json 中本工具写入的内容。保留 ~/.pi/agent 下的会话、auth.json 等用户数据。
set -euo pipefail

main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/config.sh
  . "$script_dir/lib/config.sh"
  # 从已安装目录运行时，以脚本所在目录为准（支持自定义 PI_BEDROCK_HOME）
  if [ -z "${PI_BEDROCK_HOME:-}" ] && [ -f "$script_dir/.pi-bedrock-managed" ]; then PI_BEDROCK_HOME="$script_dir"; fi
  : "${PI_BEDROCK_HOME:=$HOME/.local/share/pi-bedrock}"
  load_env_file "$PI_BEDROCK_HOME/env"
  # shellcheck source=lib/common.sh
  . "$script_dir/lib/common.sh"
  # shellcheck source=lib/skills.sh
  . "$script_dir/lib/skills.sh"
  # Windows：与安装时写入配置的 C:/... 形式保持一致
  if is_windows; then PI_BEDROCK_HOME="$(cygpath -m "$PI_BEDROCK_HOME")"; fi

  case "${1:-}" in
    -h | --help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    "") ;;
    *) die "未知参数: $1" ;;
  esac

  revert_settings "$script_dir"
  remove_ops_integrations
  remove_wrappers
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do remove_rc_block "$rc"; done
  log_info "已移除 shell 启动文件中的 pi-bedrock 段落"
  remove_home
  log_info "卸载完成。会话与凭证仍保留在 ${PI_CODING_AGENT_DIR}（如不需要可手动删除）"
}

revert_settings() {
  local script_dir="$1" node=""
  if [ -x "${PI_BEDROCK_NODE_BIN:-}/node" ]; then
    node="$PI_BEDROCK_NODE_BIN/node"
  elif command -v node >/dev/null 2>&1; then
    node="$(command -v node)"
  fi
  if [ -z "$node" ]; then
    log_warn "未找到 node，跳过 settings.json 回滚"
    return 0
  fi
  local -a extra=()
  if is_windows && git_bash_path >/dev/null; then extra=(--shell-path "$(git_bash_path)"); fi
  unmerge_settings "$node" "$script_dir/lib" "$PI_CODING_AGENT_DIR/settings.json" \
    "$PI_BEDROCK_PROVIDER" "$PI_BEDROCK_MODEL" "$PI_BEDROCK_HOME/npm-global" "$PI_BEDROCK_HOME/settings.orig.json" ${extra[@]+"${extra[@]}"} ||
    log_warn "settings.json 回滚失败，请手动检查"
  if [ -f "$PI_CODING_AGENT_DIR/mcp.json" ]; then
    "$node" "$script_dir/lib/merge-mcp.mjs" remove "$PI_CODING_AGENT_DIR/mcp.json" \
      --name aws-mcp --command "$PI_BEDROCK_HOME/bin/aws-mcp-proxy" || log_warn "mcp.json 回滚失败，请手动检查"
  fi
  log_info "已回滚 settings.json / mcp.json 中本工具写入的内容"
}

remove_ops_integrations() {
  local guard="$PI_CODING_AGENT_DIR/extensions/aws-ops-guard" backup
  if [ -f "$guard/.pi-bedrock-managed" ]; then
    chmod -R u+w "$guard"
    rm -rf "$guard"
    backup="$(find "$PI_CODING_AGENT_DIR/.pi-bedrock-backup" -maxdepth 1 -name 'aws-ops-guard.*' -type d 2>/dev/null | sort | tail -n1 || true)"
    if [ -n "$backup" ]; then
      mv -f "$backup" "$guard"
      log_info "已恢复安装前的 aws-ops-guard 扩展"
    fi
    rmdir "$PI_CODING_AGENT_DIR/.pi-bedrock-backup" 2>/dev/null || true
    log_info "已移除 aws-ops-guard 扩展"
  fi
  remove_aws_skills
  remove_agent_rules
  log_info "已移除 AWS skills 与 AGENTS.md 托管段落"
}

remove_wrappers() {
  local f
  for f in pi.cmd pi-bedrock-doctor.cmd pi-bedrock-login.cmd; do
    if [ -f "$PI_BIN_DIR/$f" ] && grep -q 'pi-cli-bedrock' "$PI_BIN_DIR/$f"; then rm -f "$PI_BIN_DIR/$f"; fi
  done
  for f in pi pi-bedrock-doctor pi-bedrock-login; do
    if [ -f "$PI_BIN_DIR/$f" ] && grep -q 'pi-cli-bedrock' "$PI_BIN_DIR/$f"; then
      chmod u+w "$PI_BIN_DIR/$f"
      rm -f "$PI_BIN_DIR/$f"
      if [ -e "$PI_BIN_DIR/$f.pre-pi-bedrock" ]; then
        mv -f "$PI_BIN_DIR/$f.pre-pi-bedrock" "$PI_BIN_DIR/$f"
        log_info "已恢复安装前的 $PI_BIN_DIR/$f"
      fi
    fi
  done
}

remove_home() {
  local home_dir cmp base1 base2
  home_dir="$(resolve_path "$PI_BEDROCK_HOME" 2>/dev/null || true)"
  cmp="$home_dir" base1="$HOME" base2="$(_path_entry "$_PI_BASE_HOME")"
  # Windows：readlink -f 保留输入的 C:/... 形式而 $HOME 为 /c/...，统一转换后比较；路径不区分大小写
  if is_windows; then
    cmp="$(cygpath -u "$cmp" | tr '[:upper:]' '[:lower:]')"
    base1="$(printf '%s' "$base1" | tr '[:upper:]' '[:lower:]')"
    base2="$(printf '%s' "$base2" | tr '[:upper:]' '[:lower:]')"
  fi
  # 防御：只删除位于 $HOME 下、且带有本工具归属标记的目录
  case "$cmp" in
    "$base1"/?* | "$base2"/?*) ;;
    *) log_warn "PI_BEDROCK_HOME=$PI_BEDROCK_HOME 不在 \$HOME 下，跳过删除"; return 0 ;;
  esac
  if [ -f "$home_dir/.pi-bedrock-managed" ]; then
    chmod -R u+w "$home_dir"
    rm -rf "$home_dir"
    log_info "已删除 $home_dir"
  else
    log_warn "$home_dir 不像是 pi-bedrock 安装目录，跳过删除"
  fi
}

# 整个脚本先被解析进 main 再执行，因此脚本自身位于待删除目录中也安全
main "$@"
exit $?
