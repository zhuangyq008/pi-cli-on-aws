#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/config.sh"
  SETTINGS="$PI_CODING_AGENT_DIR/settings.json"
  NPM_PREFIX="$PI_BEDROCK_HOME/npm-global"
}
teardown() { teardown_sandbox; }

ORIG="$BATS_TEST_TMPDIR/settings.orig.json"
apply() { merge_settings node "$REPO_ROOT/lib" "$SETTINGS" amazon-bedrock global.moonshotai.kimi-k3.1 medium /opt/node/bin/npm "$NPM_PREFIX" "$ORIG"; }
unapply() { unmerge_settings node "$REPO_ROOT/lib" "$SETTINGS" amazon-bedrock global.moonshotai.kimi-k3.1 "$NPM_PREFIX" "$ORIG"; }
jq_get() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const v=s[process.argv[2]]; process.stdout.write(v===undefined?"<unset>":typeof v==="string"?v:JSON.stringify(v));' "$SETTINGS" "$1"; }

# ---------- settings.json ----------
@test "merge_settings: 文件不存在时创建并写入 Bedrock 默认值" {
  run apply
  [ "$status" -eq 0 ]
  [ "$(jq_get defaultProvider)" = amazon-bedrock ]
  [ "$(jq_get defaultModel)" = global.moonshotai.kimi-k3.1 ]
  [ "$(jq_get defaultThinkingLevel)" = medium ]
  [[ "$(jq_get shellCommandPrefix)" == *"pi-bedrock:restore-shell-region"* ]]
  [ "$(jq_get selfUpdateCommand)" = '["/opt/node/bin/npm","install","-g","--prefix","'"$NPM_PREFIX"'","{installSpec}"]' ]
  [ "$(stat -c %a "$SETTINGS")" = 600 ]
}

@test "merge_settings: 保留用户已有配置，并备份原文件" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"theme":"light","defaultModel":"old","enabledModels":["a"]}\n' >"$SETTINGS"
  apply
  [ "$(jq_get theme)" = light ]
  [ "$(jq_get enabledModels)" = '["a"]' ]
  [ "$(jq_get defaultModel)" = global.moonshotai.kimi-k3.1 ]
  grep -q '"old"' "$SETTINGS.pi-bedrock.bak"
}

@test "merge_settings: 幂等——重复执行不重复追加 prefix 片段" {
  apply
  apply
  local prefix
  prefix="$(jq_get shellCommandPrefix)"
  [ "$(grep -o 'pi-bedrock:restore-shell-region' <<<"$prefix" | wc -l)" -eq 1 ]
}

@test "merge_settings: 与用户已有 shellCommandPrefix 共存（我方片段在前）" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"shellCommandPrefix":"shopt -s expand_aliases"}\n' >"$SETTINGS"
  apply
  apply
  local prefix
  prefix="$(jq_get shellCommandPrefix)"
  [[ "$prefix" == *"pi-bedrock:restore-shell-region"*$'\n'"shopt -s expand_aliases" ]]
}

@test "merge_settings: 非法 JSON 时拒绝修改且原文件不变" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{ broken' >"$SETTINGS"
  run apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"不是合法 JSON"* ]]
  [ "$(cat "$SETTINGS")" = '{ broken' ]
}

@test "merge_settings: 顶层为数组时拒绝修改" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '[1,2]' >"$SETTINGS"
  run apply
  [ "$status" -eq 2 ]
}

@test "merge_settings: 拒绝非法 thinking level" {
  run merge_settings node "$REPO_ROOT/lib" "$SETTINGS" amazon-bedrock m ultra /npm "$NPM_PREFIX" "$ORIG"
  [ "$status" -eq 64 ]
}

@test "unmerge_settings: 回滚我方写入的键，保留用户的键与 prefix" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"theme":"light","shellCommandPrefix":"shopt -s expand_aliases"}\n' >"$SETTINGS"
  apply
  unapply
  [ "$(jq_get theme)" = light ]
  [ "$(jq_get shellCommandPrefix)" = "shopt -s expand_aliases" ]
  [ "$(jq_get defaultProvider)" = "<unset>" ]
  ! grep -q selfUpdateCommand "$SETTINGS"
}

@test "unmerge_settings: 用户已改用其他默认模型时保留其选择" {
  apply
  node -e 'const f=process.argv[1];const fs=require("fs");const s=JSON.parse(fs.readFileSync(f));fs.writeFileSync(f,JSON.stringify({...s,defaultModel:"other"}))' "$SETTINGS"
  unapply
  [ "$(jq_get defaultModel)" = other ]
}

@test "unmerge_settings: 恢复安装前的默认模型与 selfUpdateCommand 原值" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"defaultProvider":"anthropic","defaultModel":"claude-x","selfUpdateCommand":["brew","upgrade","pi"]}\n' >"$SETTINGS"
  apply
  apply   # 第二次安装不能覆盖首次保存的原值
  [ "$(jq_get defaultModel)" = global.moonshotai.kimi-k3.1 ]
  unapply
  [ "$(jq_get defaultProvider)" = anthropic ]
  [ "$(jq_get defaultModel)" = claude-x ]
  [ "$(jq_get selfUpdateCommand)" = '["brew","upgrade","pi"]' ]
  [ "$(jq_get defaultThinkingLevel)" = "<unset>" ]
}

# ---------- env 文件 ----------
@test "write_env_file + load_env_file: 往返读写" {
  write_env_file "$PI_BEDROCK_HOME/env" PI_BEDROCK_REGION=ap-southeast-1 PI_BEDROCK_PI_BIN=/a/b/pi
  unset PI_BEDROCK_REGION PI_BEDROCK_PI_BIN
  load_env_file "$PI_BEDROCK_HOME/env"
  [ "$PI_BEDROCK_REGION" = ap-southeast-1 ]
  [ "$PI_BEDROCK_PI_BIN" = /a/b/pi ]
}

@test "write_env_file: 拒绝白名单外的键与危险字符" {
  run write_env_file "$PI_BEDROCK_HOME/env" EVIL=1
  [ "$status" -ne 0 ]
  run write_env_file "$PI_BEDROCK_HOME/env" 'PI_BEDROCK_REGION=$(id)'
  [ "$status" -ne 0 ]
}

@test "load_env_file: 不执行内容、忽略白名单外的键与危险值" {
  mkdir -p "$PI_BEDROCK_HOME"
  cat >"$PI_BEDROCK_HOME/env" <<'ENV'
# comment
PATH=/evil
PI_BEDROCK_REGION=$(touch /tmp/pwned-by-env)
PI_BEDROCK_MODEL="global.moonshotai.kimi-k3.1"
LD_PRELOAD=/evil.so
ENV
  local old_path="$PATH"
  unset PI_BEDROCK_REGION PI_BEDROCK_MODEL
  load_env_file "$PI_BEDROCK_HOME/env"
  [ "$PATH" = "$old_path" ]
  [ -z "${PI_BEDROCK_REGION:-}" ]
  [ -z "${LD_PRELOAD:-}" ]
  [ "$PI_BEDROCK_MODEL" = global.moonshotai.kimi-k3.1 ]
  [ ! -e /tmp/pwned-by-env ]
}

@test "load_env_file: 运行时环境变量优先于文件" {
  write_env_file "$PI_BEDROCK_HOME/env" PI_BEDROCK_REGION=ap-southeast-1
  export PI_BEDROCK_REGION=eu-north-1
  load_env_file "$PI_BEDROCK_HOME/env"
  [ "$PI_BEDROCK_REGION" = eu-north-1 ]
}

# ---------- 区域注入 ----------
@test "apply_bedrock_region: 覆盖 pi 进程区域并保存原区域" {
  export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 PI_BEDROCK_REGION=ap-southeast-1
  apply_bedrock_region
  [ "$AWS_REGION" = ap-southeast-1 ]
  [ "$AWS_DEFAULT_REGION" = ap-southeast-1 ]
  [ "$PI_SHELL_AWS_REGION" = us-east-1 ]
}

@test "apply_bedrock_region: 区域相同或未设置时不做任何事" {
  export AWS_REGION=us-east-1
  unset PI_BEDROCK_REGION PI_SHELL_AWS_REGION
  apply_bedrock_region
  [ "$AWS_REGION" = us-east-1 ]
  export PI_BEDROCK_REGION=us-east-1
  apply_bedrock_region
  [ -z "${PI_SHELL_AWS_REGION:-}" ]
}

@test "apply_bedrock_region: 忽略非法区域值" {
  export AWS_REGION=us-east-1 PI_BEDROCK_REGION='x;id'
  run apply_bedrock_region
  [[ "$output" == *"忽略非法"* ]]
  apply_bedrock_region 2>/dev/null
  [ "$AWS_REGION" = us-east-1 ]
}

@test "shell_prefix_snippet: 在 bash 中还原原区域；未设置时为 no-op" {
  local snippet
  snippet="$(shell_prefix_snippet)"
  run env AWS_REGION=ap-southeast-1 PI_SHELL_AWS_REGION=us-east-1 bash -c "$snippet"$'\n''echo "$AWS_REGION/$AWS_DEFAULT_REGION"'
  [ "$output" = "us-east-1/us-east-1" ]
  run env -u PI_SHELL_AWS_REGION AWS_REGION=ap-southeast-1 bash -c "$snippet"$'\n''echo "$AWS_REGION"'
  [ "$output" = "ap-southeast-1" ]
  run env -u PI_SHELL_AWS_REGION AWS_REGION=ap-southeast-1 sh -c "$snippet"$'\n''echo "$AWS_REGION"'
  [ "$output" = "ap-southeast-1" ]
}

# ---------- ~/.bashrc ----------
@test "write_rc_block: 幂等，且 source 后 PATH 包含 bin 目录" {
  printf 'alias ll="ls -l"' >"$HOME/.bashrc"   # 末尾无换行
  write_rc_block "$HOME/.bashrc" "$PI_BIN_DIR"
  write_rc_block "$HOME/.bashrc" "$PI_BIN_DIR"
  [ "$(grep -cF '# >>> pi-bedrock >>>' "$HOME/.bashrc")" -eq 1 ]
  grep -qx 'alias ll="ls -l"' "$HOME/.bashrc"
  run bash -c "PATH=/usr/bin:/bin; source '$HOME/.bashrc'; echo \"\$PATH\""
  [[ "$output" == "$PI_BIN_DIR:"* ]]
  run bash -c "PATH=$PI_BIN_DIR:/usr/bin; source '$HOME/.bashrc'; echo \"\$PATH\""
  [ "$output" = "$PI_BIN_DIR:/usr/bin" ]
}

@test "remove_rc_block: 只移除托管段落" {
  printf 'line1\n' >"$HOME/.bashrc"
  write_rc_block "$HOME/.bashrc" "$PI_BIN_DIR"
  printf 'line2\n' >>"$HOME/.bashrc"
  remove_rc_block "$HOME/.bashrc"
  [ "$(cat "$HOME/.bashrc")" = $'line1\nline2' ]
}

@test "merge_settings: 写入 enabledModels（仅当前区域可用模型），卸载时恢复原值" {
  mkdir -p "$PI_CODING_AGENT_DIR"
  printf '{"enabledModels":["anthropic/claude-x"]}\n' >"$SETTINGS"
  merge_settings node "$REPO_ROOT/lib" "$SETTINGS" amazon-bedrock global.moonshotai.kimi-k3.1 medium /npm "$NPM_PREFIX" "$ORIG" '["amazon-bedrock/global.moonshotai.kimi-k3.1","amazon-bedrock/apac.amazon.nova-pro-v1:0"]'
  [ "$(jq_get enabledModels)" = '["amazon-bedrock/global.moonshotai.kimi-k3.1","amazon-bedrock/apac.amazon.nova-pro-v1:0"]' ]
  unapply
  [ "$(jq_get enabledModels)" = '["anthropic/claude-x"]' ]
}

@test "merge_settings: 拒绝非法的 enabledModels" {
  run merge_settings node "$REPO_ROOT/lib" "$SETTINGS" amazon-bedrock m medium /npm "$NPM_PREFIX" "$ORIG" '["evil; rm -rf ~"]'
  [ "$status" -eq 64 ]
  run merge_settings node "$REPO_ROOT/lib" "$SETTINGS" amazon-bedrock m medium /npm "$NPM_PREFIX" "$ORIG" '[]'
  [ "$status" -eq 64 ]
}
