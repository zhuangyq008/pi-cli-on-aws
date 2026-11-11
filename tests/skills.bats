#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  source "$REPO_ROOT/lib/skills.sh"
  # 构造与 GitHub codeload 相同结构的 fixture 压缩包
  local root="$SANDBOX/fixture/agent-toolkit-for-aws-abc"
  mkdir -p "$root/skills/core-skills/aws-observability/references" "$root/skills/core-skills/aws-iam" \
    "$root/skills/specialized-skills/operations-skills/alarms" "$root/skills/core-skills/aws-cdk" "$root/rules"
  printf -- '---\nname: aws-observability\ndescription: obs\n---\n' >"$root/skills/core-skills/aws-observability/SKILL.md"
  printf 'ref\n' >"$root/skills/core-skills/aws-observability/references/a.md"
  ln -s /etc/passwd "$root/skills/core-skills/aws-observability/references/evil"
  printf -- '---\nname: aws-iam\ndescription: iam\n---\n' >"$root/skills/core-skills/aws-iam/SKILL.md"
  printf -- '---\nname: alarms\ndescription: a\n---\n' >"$root/skills/specialized-skills/operations-skills/alarms/SKILL.md"
  printf -- '---\nname: aws-cdk\ndescription: c\n---\n' >"$root/skills/core-skills/aws-cdk/SKILL.md"
  printf '# AWS Guidance\n- Prefer the AWS MCP Server\n' >"$root/rules/aws-agent-rules.md"
  tar -czf "$SANDBOX/toolkit.tgz" -C "$SANDBOX/fixture" agent-toolkit-for-aws-abc
  export FIXTURE="$SANDBOX/toolkit.tgz" CURL_LOG="$SANDBOX/curl.log"
  # curl 桩：把 fixture 写到 -o 指定的位置
  make_stub curl 'out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done; echo call >>"$CURL_LOG"; cp "$FIXTURE" "$out"'
  export PATH="$STUB_BIN:$PATH"
  export PI_AWS_SKILLS="core-skills/aws-observability core-skills/aws-iam specialized-skills/operations-skills core-skills/missing ../../etc"
  export PI_AWS_SKILLS_SHA256=skip
  TEMPLATE="$SANDBOX/ops-rules.md"
  printf '# 运维规则\n- 先查后改\n' >"$TEMPLATE"
}
teardown() { teardown_sandbox; }

@test "install_aws_skills: 只安装白名单 skills，去掉符号链接，写入标记" {
  run install_aws_skills
  [ "$status" -eq 0 ]
  local dest
  dest="$(skills_dir)"
  [ -f "$dest/aws-observability/SKILL.md" ]
  [ -f "$dest/aws-observability/references/a.md" ]
  [ ! -e "$dest/aws-observability/references/evil" ]
  [ -f "$dest/aws-iam/SKILL.md" ]
  [ -f "$dest/operations-skills/alarms/SKILL.md" ]
  [ ! -e "$dest/aws-cdk" ]
  [ -f "$dest/.pi-bedrock-managed" ]
  [ -f "$PI_BEDROCK_HOME/rules/aws-agent-rules.md" ]
  [[ "$output" == *"忽略非法的 skill 路径: ../../etc"* ]]
  [[ "$output" == *"上游未找到 skill: core-skills/missing"* ]]
  [[ "$output" == *"已安装 3 个 AWS skills"* ]]
}

@test "install_aws_skills: 内容哈希不匹配时跳过安装并提示实际哈希；匹配时安装" {
  export PI_AWS_SKILLS_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  run install_aws_skills
  [ "$status" -eq 0 ]
  [[ "$output" == *"内容校验失败"* ]]
  [ ! -e "$(skills_dir)" ]
  local actual
  actual="$(grep -o '实际 [0-9a-f]*' <<<"$output" | head -n1 | cut -d' ' -f2)"
  export PI_AWS_SKILLS_SHA256="$actual"
  run install_aws_skills
  [[ "$output" == *"已安装 3 个 AWS skills"* ]]
}

@test "install_aws_skills: 规则文件为符号链接时忽略" {
  local root="$SANDBOX/fixture/agent-toolkit-for-aws-abc"
  rm "$root/rules/aws-agent-rules.md"
  ln -s /etc/hostname "$root/rules/aws-agent-rules.md"
  tar -czf "$SANDBOX/toolkit.tgz" -C "$SANDBOX/fixture" agent-toolkit-for-aws-abc
  run install_aws_skills
  [[ "$output" == *"已忽略"* ]]
  [ ! -e "$PI_BEDROCK_HOME/rules/aws-agent-rules.md" ]
}

@test "install_aws_skills: 已是最新时跳过下载" {
  install_aws_skills 2>/dev/null
  run install_aws_skills
  [[ "$output" == *"跳过"* ]]
  [ "$(wc -l <"$CURL_LOG")" -eq 1 ]
}

@test "install_aws_skills: 不覆盖非本工具管理的同名目录" {
  mkdir -p "$(skills_dir)"
  printf 'mine' >"$(skills_dir)/note"
  run install_aws_skills
  [[ "$output" == *"不由本工具管理"* ]]
  [ "$(cat "$(skills_dir)/note")" = mine ]
}

@test "install_aws_skills: 下载失败时不中断安装，仅告警" {
  make_stub curl 'exit 22'
  run install_aws_skills
  [ "$status" -eq 0 ]
  [[ "$output" == *"安装失败，已跳过"* ]]
  [ ! -e "$(skills_dir)" ]
}

@test "install_aws_skills: 拒绝非 https 下载地址" {
  export PI_AWS_TOOLKIT_TARBALL_URL=http://example.com/x.tgz
  run install_aws_skills
  [ "$status" -ne 0 ]
}

@test "remove_aws_skills: 只删除带标记的目录" {
  install_aws_skills 2>/dev/null
  remove_aws_skills
  [ ! -e "$(skills_dir)" ]
  mkdir -p "$(skills_dir)"
  remove_aws_skills
  [ -d "$(skills_dir)" ]
}

@test "install_agent_rules: 写入托管段落（含官方规则），保留用户内容，幂等，可移除" {
  rm -f "$PI_BEDROCK_HOME/rules/aws-agent-rules.md"
  install_aws_skills 2>/dev/null
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '# 我的规则\n- 用户自定义\n' >"$PI_CODING_AGENT_DIR/AGENTS.md"
  install_agent_rules "$TEMPLATE"
  install_agent_rules "$TEMPLATE"
  local f="$PI_CODING_AGENT_DIR/AGENTS.md"
  [ "$(grep -cF '<!-- >>> pi-bedrock >>> -->' "$f")" -eq 1 ]
  grep -q '用户自定义' "$f"
  grep -q '先查后改' "$f"
  grep -q 'Prefer the AWS MCP Server' "$f"
  remove_agent_rules
  [ "$(cat "$f")" = $'# 我的规则\n- 用户自定义' ]
}
