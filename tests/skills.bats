#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/skills.sh"
  # 与 vendor/agent-toolkit-for-aws 相同结构的 fixture
  VENDOR="$SANDBOX/vendor"
  mkdir -p "$VENDOR/skills/core-skills/aws-observability/references" "$VENDOR/skills/core-skills/aws-iam" \
    "$VENDOR/skills/specialized-skills/operations-skills/alarms" "$VENDOR/skills/core-skills/aws-cdk" "$VENDOR/rules"
  printf -- '---\nname: aws-observability\ndescription: obs\n---\n' >"$VENDOR/skills/core-skills/aws-observability/SKILL.md"
  printf 'ref\n' >"$VENDOR/skills/core-skills/aws-observability/references/a.md"
  ln -s /etc/passwd "$VENDOR/skills/core-skills/aws-observability/references/evil"
  printf -- '---\nname: aws-iam\ndescription: iam\n---\n' >"$VENDOR/skills/core-skills/aws-iam/SKILL.md"
  printf -- '---\nname: alarms\ndescription: a\n---\n' >"$VENDOR/skills/specialized-skills/operations-skills/alarms/SKILL.md"
  printf -- '---\nname: aws-cdk\ndescription: c\n---\n' >"$VENDOR/skills/core-skills/aws-cdk/SKILL.md"
  printf '# AWS Guidance\n- Prefer the AWS MCP Server\n' >"$VENDOR/rules/aws-agent-rules.md"
  write_source
  export PI_AWS_SKILLS="core-skills/aws-observability core-skills/aws-iam specialized-skills/operations-skills core-skills/missing ../../etc"
  # 安装不应联网
  make_stub curl 'echo "unexpected curl" >&2; exit 99'
  export PATH="$STUB_BIN:$PATH"
  TEMPLATE="$SANDBOX/ops-rules.md"
  printf '# 运维规则\n- 先查后改\n' >"$TEMPLATE"
}
teardown() { teardown_sandbox; }

# 与 scripts/sync-aws-skills.sh 相同：SOURCE 记录内容清单哈希（符号链接 evil 不计入：find -type f 不包含它）
write_source() {
  printf 'REPO=aws/agent-toolkit-for-aws\nREF=abcdef0123456789abcdef0123456789abcdef01\nMANIFEST=%s\n' "$(skills_manifest "$VENDOR")" >"$VENDOR/SOURCE"
}

@test "install_aws_skills: 只安装选中的 skills，去掉符号链接，写入标记，不联网" {
  run install_aws_skills "$VENDOR"
  [ "$status" -eq 0 ]
  local dest
  dest="$(skills_dir)"
  [ -f "$dest/aws-observability/SKILL.md" ]
  [ -f "$dest/aws-observability/references/a.md" ]
  [ ! -e "$dest/aws-observability/references/evil" ]
  [ -f "$dest/aws-iam/SKILL.md" ]
  [ -f "$dest/operations-skills/alarms/SKILL.md" ]
  [ ! -e "$dest/aws-cdk" ]
  [ "$(cat "$dest/.pi-bedrock-managed")" = "abcdef0123456789abcdef0123456789abcdef01 $PI_AWS_SKILLS" ]
  [[ "$output" == *"忽略非法的 skill 路径: ../../etc"* ]]
  [[ "$output" == *"内置 skills 中没有 core-skills/missing"* ]]
  [[ "$output" == *"已安装 3 个 AWS skills"* ]]
  [[ "$output" != *"unexpected curl"* ]]
  # 不残留临时目录
  [ "$(find "$(dirname "$dest")" -maxdepth 1 -name '.aws-agent-toolkit.*' | wc -l)" -eq 0 ]
}

@test "skills_selection: core 为默认，full 为超集，none 为空；PI_AWS_SKILLS 优先" {
  unset PI_AWS_SKILLS
  [ "$(skills_selection)" = "$PI_SKILLS_CORE" ]
  PI_BEDROCK_SKILLS=full
  [ "$(skills_selection)" = "$PI_SKILLS_FULL" ]
  local s
  for s in $PI_SKILLS_CORE; do [[ " $PI_SKILLS_FULL " == *" $s "* ]]; done
  PI_BEDROCK_SKILLS=none
  [ -z "$(skills_selection)" ]
  PI_AWS_SKILLS="core-skills/aws-iam"
  [ "$(skills_selection)" = core-skills/aws-iam ]
  is_valid_skills_profile core && is_valid_skills_profile full && is_valid_skills_profile none
  ! is_valid_skills_profile all
}

@test "install_aws_skills: 内置内容与 SOURCE 的哈希不一致（被改动）时跳过安装，规则文件也不写入官方段落" {
  printf 'injected\n' >>"$VENDOR/skills/core-skills/aws-iam/SKILL.md"
  run install_aws_skills "$VENDOR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"哈希不一致"* ]]
  [ ! -e "$(skills_dir)" ]
  install_agent_rules "$TEMPLATE" "$VENDOR"
  ! grep -q 'Prefer the AWS MCP Server' "$PI_CODING_AGENT_DIR/AGENTS.md"
}

@test "install_aws_skills: 重复安装时整体替换（切换到更小的集合会删除多余 skill）" {
  install_aws_skills "$VENDOR" 2>/dev/null
  PI_AWS_SKILLS="core-skills/aws-iam"
  install_aws_skills "$VENDOR" 2>/dev/null
  [ -f "$(skills_dir)/aws-iam/SKILL.md" ]
  [ ! -e "$(skills_dir)/aws-observability" ]
}

@test "install_aws_skills: 选择为空（none）时移除已安装的 skills" {
  install_aws_skills "$VENDOR" 2>/dev/null
  PI_AWS_SKILLS="" PI_BEDROCK_SKILLS=none install_aws_skills "$VENDOR"
  [ ! -e "$(skills_dir)" ]
}

@test "install_aws_skills: 不覆盖非本工具管理的同名目录" {
  mkdir -p "$(skills_dir)"
  printf 'mine' >"$(skills_dir)/note"
  run install_aws_skills "$VENDOR"
  [[ "$output" == *"不由本工具管理"* ]]
  [ "$(cat "$(skills_dir)/note")" = mine ]
}

@test "install_aws_skills: 缺少内置 skills 时不中断安装，仅告警" {
  run install_aws_skills "$SANDBOX/nowhere"
  [ "$status" -eq 0 ]
  [[ "$output" == *"缺少内置 skills"* ]]
  [ ! -e "$(skills_dir)" ]
}

@test "remove_aws_skills: 只删除带标记的目录" {
  install_aws_skills "$VENDOR" 2>/dev/null
  remove_aws_skills
  [ ! -e "$(skills_dir)" ]
  mkdir -p "$(skills_dir)"
  remove_aws_skills
  [ -d "$(skills_dir)" ]
}

@test "install_agent_rules: 写入托管段落（含官方规则与来源），保留用户内容，幂等，可移除，清理旧版规则目录" {
  mkdir -p "$PI_CODING_AGENT_DIR" "$PI_BEDROCK_HOME/rules"
  printf 'old' >"$PI_BEDROCK_HOME/rules/aws-agent-rules.md"
  printf '# 我的规则\n- 用户自定义\n' >"$PI_CODING_AGENT_DIR/AGENTS.md"
  install_aws_skills "$VENDOR" 2>/dev/null
  install_agent_rules "$TEMPLATE" "$VENDOR"
  install_agent_rules "$TEMPLATE" "$VENDOR"
  local f="$PI_CODING_AGENT_DIR/AGENTS.md"
  [ "$(grep -cF '<!-- >>> pi-bedrock >>> -->' "$f")" -eq 1 ]
  grep -q '用户自定义' "$f"
  grep -q '先查后改' "$f"
  grep -q 'Prefer the AWS MCP Server' "$f"
  grep -q 'aws/agent-toolkit-for-aws@abcdef0' "$f"
  [ ! -e "$PI_BEDROCK_HOME/rules" ]
  remove_agent_rules
  [ "$(cat "$f")" = $'# 我的规则\n- 用户自定义' ]
}

@test "vendor：内置 skills 与 SOURCE 中的内容清单哈希一致，包含 full 集合与许可证，无符号链接" {
  local vendor="$REPO_ROOT/$PI_SKILLS_VENDOR_REL" s
  [ "$(skills_manifest "$vendor")" = "$(vendor_field "$vendor" MANIFEST)" ]
  [[ "$(vendor_field "$vendor" REF)" =~ ^[0-9a-f]{40}$ ]]
  for s in $PI_SKILLS_FULL; do [ -f "$vendor/skills/$s/SKILL.md" ] || [ -n "$(find "$vendor/skills/$s" -name SKILL.md)" ]; done
  [ -f "$vendor/LICENSE" ] && [ -f "$vendor/NOTICE" ] && [ -f "$vendor/rules/aws-agent-rules.md" ]
  [ -z "$(find "$vendor" -type l)" ]
  [ "$(find "$vendor/skills" -path '*core-skills/*' -name SKILL.md -o -path '*specialized-skills/*' -name SKILL.md | wc -l | tr -d ' ')" -eq 19 ]
}

@test "vendor：默认 core 集合安装 9 个 skills" {
  unset PI_AWS_SKILLS
  run install_aws_skills "$REPO_ROOT/$PI_SKILLS_VENDOR_REL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"已安装 9 个 AWS skills"* ]]
}
