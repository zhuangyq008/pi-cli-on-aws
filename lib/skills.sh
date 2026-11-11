# shellcheck shell=bash
# 安装 Agent Toolkit for AWS 的运维相关 skills（固定 commit），并把运维规则写入 pi 的全局 AGENTS.md 托管段落。
# skills 目录：$PI_CODING_AGENT_DIR/skills/aws-agent-toolkit（含 .pi-bedrock-managed 标记，卸载时整体删除）

: "${PI_AWS_TOOLKIT_REPO:=aws/agent-toolkit-for-aws}"
: "${PI_AWS_TOOLKIT_REF:=00840a095dcc53242dcb19402e7140fa896d2d46}"
: "${PI_AWS_TOOLKIT_TARBALL_URL:=https://codeload.github.com/$PI_AWS_TOOLKIT_REPO/tar.gz/$PI_AWS_TOOLKIT_REF}"
: "${PI_AWS_SKILLS:=core-skills/aws-billing-and-cost-management core-skills/aws-observability core-skills/aws-investigation core-skills/aws-security core-skills/aws-iam core-skills/aws-well-architected-review specialized-skills/operations-skills specialized-skills/resilience-skills}"

# 固定 ref + 默认 skill 列表对应的内容清单哈希（见 _skills_manifest）。修改 ref 或列表时需同时更新，
# 或在安装时设置 PI_AWS_SKILLS_SHA256=<新哈希>（校验失败的提示中会给出实际值）；设为 skip 可跳过校验（不推荐）。
: "${PI_AWS_SKILLS_SHA256:=5407d462366c884b5a1392a9daa3185bca51b5e2b00c39eebd6aa6d1dbd6ef4d}"
MAX_RULES_BYTES=65536

AGENTS_MARKER_BEGIN="<!-- >>> pi-bedrock >>> -->"
AGENTS_MARKER_END="<!-- <<< pi-bedrock <<< -->"
SKILLS_MARKER=".pi-bedrock-managed"

skills_dir() { printf '%s/skills/aws-agent-toolkit' "$PI_CODING_AGENT_DIR"; }

_skills_stamp() { printf '%s %s' "$PI_AWS_TOOLKIT_REF" "$PI_AWS_SKILLS"; }

# 内容清单哈希：对 skills 中每个文件（按路径排序）的 sha256 与规则文件的 sha256 再做一次 sha256
_skills_manifest() {
  local stage="$1" rules="$2"
  {
    # 输出格式与 GNU `sha256sum` 一致（"<hash>  ./path"），保证各平台计算结果相同
    (cd "$stage" && find . -type f ! -name "$SKILLS_MARKER" -print0 | LC_ALL=C sort -z |
      while IFS= read -r -d '' f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done)
    if [ -f "$rules" ]; then printf 'rules  %s\n' "$(sha256_of "$rules")"; fi
  } | sha256_of -
}

# 解压（不可信数据）到独立目录，只复制白名单内的 skill 目录，并去掉符号链接；规则文件写到 RULES_OUT
_stage_skills() {
  local archive="$1" stage="$2" rules_out="$3" src root s
  src="$(dirname "$archive")/src"
  mkdir -p "$src" "$stage"
  tar -xzf "$archive" -C "$src" --no-same-owner --no-same-permissions || return 1
  root="$(find "$src" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -d "$root/skills" ] || { log_error "压缩包中没有 skills 目录"; return 1; }
  for s in $PI_AWS_SKILLS; do
    if ! [[ "$s" =~ ^(core|specialized)-skills/[a-z0-9-]+$ ]]; then
      log_warn "忽略非法的 skill 路径: $s"
    elif [ -d "$root/skills/$s" ]; then
      cp -R "$root/skills/$s" "$stage/"
    else
      log_warn "上游未找到 skill: ${s}（ref ${PI_AWS_TOOLKIT_REF}）"
    fi
  done
  find "$stage" -type l -delete
  local rules="$root/rules/aws-agent-rules.md"
  if [ -f "$rules" ] && [ ! -L "$rules" ] && [ "$(($(wc -c <"$rules")))" -le "$MAX_RULES_BYTES" ]; then
    cp "$rules" "$rules_out"
  else
    log_warn "上游 rules/aws-agent-rules.md 缺失、是符号链接或过大，已忽略"
  fi
}

install_aws_skills() {
  local dest tmp count
  dest="$(skills_dir)"
  if [ -f "$dest/$SKILLS_MARKER" ] && [ "$(cat "$dest/$SKILLS_MARKER")" = "$(_skills_stamp)" ] &&
    [ -f "$PI_BEDROCK_HOME/rules/aws-agent-rules.md" ]; then
    log_info "AWS skills 已是最新（ref ${PI_AWS_TOOLKIT_REF:0:7}），跳过"
    return 0
  fi
  if [ -e "$dest" ] && [ ! -f "$dest/$SKILLS_MARKER" ]; then
    log_warn "$dest 已存在且不由本工具管理，跳过 skills 安装"
    return 0
  fi
  [[ "$PI_AWS_TOOLKIT_TARBALL_URL" =~ ^https:// ]] || die "PI_AWS_TOOLKIT_TARBALL_URL 必须使用 https"

  tmp="$(mktemp -d)"
  log_info "下载 Agent Toolkit for AWS skills（$PI_AWS_TOOLKIT_REPO@${PI_AWS_TOOLKIT_REF:0:7}）"
  if ! curl -fsSL --retry 3 --proto '=https' "$PI_AWS_TOOLKIT_TARBALL_URL" -o "$tmp/toolkit.tgz" ||
    ! _stage_skills "$tmp/toolkit.tgz" "$tmp/stage" "$tmp/rules.md"; then
    rm -rf "$tmp"
    log_warn "AWS skills 安装失败，已跳过（模型仍可通过 aws___retrieve_skill 在线获取 skills）"
    return 0
  fi
  local manifest
  manifest="$(_skills_manifest "$tmp/stage" "$tmp/rules.md")"
  if [ "$PI_AWS_SKILLS_SHA256" != skip ] && [ "$manifest" != "$PI_AWS_SKILLS_SHA256" ]; then
    rm -rf "$tmp"
    log_warn "AWS skills 内容校验失败（期望 ${PI_AWS_SKILLS_SHA256}，实际 ${manifest}），已跳过安装"
    log_warn "若你有意修改了 PI_AWS_TOOLKIT_REF / PI_AWS_SKILLS，请审阅内容后设置 PI_AWS_SKILLS_SHA256=$manifest 重新安装"
    return 0
  fi
  mkdir -p "$PI_BEDROCK_HOME/rules"
  if [ -f "$tmp/rules.md" ]; then cp -f "$tmp/rules.md" "$PI_BEDROCK_HOME/rules/aws-agent-rules.md"; fi
  _skills_stamp >"$tmp/stage/$SKILLS_MARKER"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp/stage" "$dest"
  rm -rf "$tmp"
  count="$(find "$dest" -name SKILL.md | wc -l | tr -d ' ')"
  log_info "已安装 $count 个 AWS skills 到 $dest"
}

remove_aws_skills() {
  local dest
  dest="$(skills_dir)"
  [ -f "$dest/$SKILLS_MARKER" ] && rm -rf "$dest"
  return 0
}

# install_agent_rules TEMPLATE：把运维规则 + 官方 aws-agent-rules 写入 AGENTS.md 托管段落（不影响段落外的用户内容）
install_agent_rules() {
  local template="$1" official="$PI_BEDROCK_HOME/rules/aws-agent-rules.md"
  {
    printf '<!-- 由 pi-cli-bedrock 管理，uninstall.sh 会移除本段；自定义内容请写在本段之外 -->\n'
    cat "$template"
    if [ -f "$official" ]; then
      printf '\n<!-- 以下来自 %s@%s rules/aws-agent-rules.md（Apache-2.0） -->\n' "$PI_AWS_TOOLKIT_REPO" "${PI_AWS_TOOLKIT_REF:0:7}"
      cat "$official"
    fi
  } | write_marked_block "$PI_CODING_AGENT_DIR/AGENTS.md" "$AGENTS_MARKER_BEGIN" "$AGENTS_MARKER_END"
}

remove_agent_rules() {
  remove_marked_block "$PI_CODING_AGENT_DIR/AGENTS.md" "$AGENTS_MARKER_BEGIN" "$AGENTS_MARKER_END"
}
