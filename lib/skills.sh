# shellcheck shell=bash
# 安装内置的 Agent Toolkit for AWS 运维 skills，并把运维规则写入 pi 的全局 AGENTS.md 托管段落。
# skills 内置在本仓库的 vendor/agent-toolkit-for-aws（由 scripts/sync-aws-skills.sh 从固定 commit 同步，Apache-2.0），
# 安装时不联网。安装位置：$PI_CODING_AGENT_DIR/skills/aws-agent-toolkit（含 .pi-bedrock-managed 标记，卸载时整体删除）

# shellcheck disable=SC2034 # 供 install.sh 与 scripts/sync-aws-skills.sh 使用
PI_SKILLS_VENDOR_REL="vendor/agent-toolkit-for-aws"

# core：日常运维（成本、可观测、排障、IAM、告警 / CloudTrail / 网络监控）。每个 skill 的描述都会进入每轮请求的
# system prompt，因此默认只装 core；full 另含安全评估、Well-Architected 评审与韧性（Resilience Hub / ARC / FIS）。
# 其余 skill 可由模型通过 AWS MCP 的 aws___retrieve_skill 在线获取。
PI_SKILLS_CORE="core-skills/aws-billing-and-cost-management core-skills/aws-observability core-skills/aws-investigation core-skills/aws-iam specialized-skills/operations-skills"
PI_SKILLS_FULL="$PI_SKILLS_CORE core-skills/aws-security core-skills/aws-well-architected-review specialized-skills/resilience-skills"
: "${PI_BEDROCK_SKILLS:=core}"   # core | full | none（install.sh --skills）

AGENTS_MARKER_BEGIN="<!-- >>> pi-bedrock >>> -->"
AGENTS_MARKER_END="<!-- <<< pi-bedrock <<< -->"
SKILLS_MARKER=".pi-bedrock-managed"

skills_dir() { printf '%s/skills/aws-agent-toolkit' "$PI_CODING_AGENT_DIR"; }

is_valid_skills_profile() { case "${1:-}" in core | full | none) return 0 ;; *) return 1 ;; esac; }

# 要安装的 skill 目录（相对 vendor/.../skills）：PI_AWS_SKILLS 显式指定时优先，否则按 PI_BEDROCK_SKILLS
skills_selection() {
  if [ -n "${PI_AWS_SKILLS:-}" ]; then printf '%s' "$PI_AWS_SKILLS"; return 0; fi
  case "$PI_BEDROCK_SKILLS" in
    full) printf '%s' "$PI_SKILLS_FULL" ;;
    none) ;;
    *) printf '%s' "$PI_SKILLS_CORE" ;;
  esac
}

# vendor_field VENDOR_DIR KEY：读取 SOURCE 中的 KEY=VALUE（不 source）
vendor_field() {
  [ -f "$1/SOURCE" ] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1/SOURCE"
}

# 内容清单哈希：对 skills/ 与 rules/ 下每个文件（按路径排序）的 sha256 再做一次 sha256。
# 输出格式与 GNU `sha256sum` 一致（"<hash>  ./path"），保证各平台计算结果相同
skills_manifest() {
  (cd "$1" && find ./skills ./rules -type f -print0 | LC_ALL=C sort -z |
    while IFS= read -r -d '' f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done) | sha256_of -
}

# install_aws_skills VENDOR_DIR：把选中的 skill 目录复制到 skills_dir（整体替换，幂等）
install_aws_skills() {
  local vendor="$1" dest stage s list ref count
  dest="$(skills_dir)"
  list="$(skills_selection)"
  if [ -e "$dest" ] && [ ! -f "$dest/$SKILLS_MARKER" ]; then
    log_warn "$dest 已存在且不由本工具管理，跳过 skills 安装"
    return 0
  fi
  if [ -z "$list" ]; then remove_aws_skills; return 0; fi
  if [ ! -d "$vendor/skills" ]; then
    log_warn "缺少内置 skills（${vendor}/skills），已跳过（模型仍可通过 aws___retrieve_skill 在线获取 skills）"
    return 0
  fi
  ref="$(vendor_field "$vendor" REF)"
  # 内置副本与 SOURCE 记录的内容清单哈希一致才安装（防止被改动的检出把任意内容写入 skills / AGENTS.md）
  local expected actual
  expected="$(vendor_field "$vendor" MANIFEST)"
  actual="$(skills_manifest "$vendor")"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    log_warn "内置 skills 内容与 ${vendor}/SOURCE 记录的哈希不一致（期望 ${expected:-无}，实际 ${actual}），已跳过 skills 安装；请重新获取本仓库"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  stage="$(mktemp -d "$(dirname "$dest")/.aws-agent-toolkit.XXXXXX")"
  for s in $list; do
    if ! [[ "$s" =~ ^(core|specialized)-skills/[a-z0-9-]+$ ]]; then
      log_warn "忽略非法的 skill 路径: $s"
    elif [ -d "$vendor/skills/$s" ]; then
      cp -R "$vendor/skills/$s" "$stage/"
    else
      log_warn "内置 skills 中没有 ${s}（可运行 scripts/sync-aws-skills.sh 同步）"
    fi
  done
  find "$stage" -type l -delete
  printf '%s %s\n' "${ref:-unknown}" "$list" >"$stage/$SKILLS_MARKER"
  rm -rf "$dest"
  mv "$stage" "$dest"
  count="$(find "$dest" -name SKILL.md | wc -l | tr -d ' ')"
  log_info "已安装 $count 个 AWS skills 到 ${dest}（${PI_AWS_SKILLS:+自定义列表}${PI_AWS_SKILLS:-$PI_BEDROCK_SKILLS}，$(vendor_field "$vendor" REPO)@${ref:0:7}）"
}

remove_aws_skills() {
  local dest
  dest="$(skills_dir)"
  [ -f "$dest/$SKILLS_MARKER" ] && rm -rf "$dest"
  return 0
}

# install_agent_rules TEMPLATE VENDOR_DIR：把运维规则 + 官方 aws-agent-rules 写入 AGENTS.md 托管段落（不影响段落外的用户内容）
install_agent_rules() {
  local template="$1" vendor="${2:-}" official
  official="$vendor/rules/aws-agent-rules.md"
  {
    printf '<!-- 由 pi-cli-bedrock 管理，uninstall.sh 会移除本段；自定义内容请写在本段之外 -->\n'
    cat "$template"
    # 官方规则同样受内容清单保护：仅在 skills 校验通过（已安装）时写入
    if [ -n "$vendor" ] && [ -f "$official" ] && [ -f "$(skills_dir)/$SKILLS_MARKER" ]; then
      printf '\n<!-- 以下来自 %s@%s rules/aws-agent-rules.md（Apache-2.0） -->\n' "$(vendor_field "$vendor" REPO)" "$(vendor_field "$vendor" REF | cut -c1-7)"
      cat "$official"
    fi
  } | write_marked_block "$PI_CODING_AGENT_DIR/AGENTS.md" "$AGENTS_MARKER_BEGIN" "$AGENTS_MARKER_END"
  # 旧版本把官方规则下载到 $PI_BEDROCK_HOME/rules，现已改为直接读取内置副本
  rm -rf "$PI_BEDROCK_HOME/rules"
}

remove_agent_rules() {
  remove_marked_block "$PI_CODING_AGENT_DIR/AGENTS.md" "$AGENTS_MARKER_BEGIN" "$AGENTS_MARKER_END"
}
