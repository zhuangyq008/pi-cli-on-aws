# shellcheck shell=bash
# 按 Bedrock 源区域筛选可用模型，写入 pi 的 enabledModels（/model 默认只显示这些模型，Tab 可切换查看全部）。
# 结果写入全局变量 PI_ENABLED_MODELS_JSON（JSON 数组；空串表示不修改 enabledModels）。

pi_bedrock_catalog() {
  find "$PI_BEDROCK_NPM_PREFIX/lib/node_modules/$PI_PACKAGE" -path '*pi-ai/dist/providers/data/amazon-bedrock.json' -print 2>/dev/null | head -n1
}

# configure_model_list REGION LIB_DIR
configure_model_list() {
  local region="$1" lib="$2" catalog out
  # shellcheck disable=SC2034 # 供 install.sh 使用
  PI_ENABLED_MODELS_JSON=""
  catalog="$(pi_bedrock_catalog)"
  if [ -z "$catalog" ] || ! command -v aws >/dev/null 2>&1; then
    log_warn "未找到 pi 的 Bedrock 模型目录或 aws CLI，跳过模型列表筛选"
    return 0
  fi
  log_info "筛选 $region 中可用的 Bedrock 模型（只读查询，不调用模型）"
  if ! out="$("$PI_BEDROCK_NODE_BIN/node" "$lib/bedrock-models.mjs" --region "$region" --catalog "$catalog" --default "$PI_BEDROCK_MODEL")"; then
    log_warn "模型列表筛选失败（可能缺少 bedrock:ListInferenceProfiles / ListFoundationModels 权限），/model 将显示全部模型"
    return 0
  fi
  # shellcheck disable=SC2034,SC2016 # 供 install.sh 使用；JS 模板字符串
  PI_ENABLED_MODELS_JSON="$(printf '%s' "$out" | "$PI_BEDROCK_NODE_BIN/node" -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.stdout.write(JSON.stringify(r.enabled));
    process.stderr.write(`${r.enabled.length}/${r.total} 个模型可用（区域内不存在 ${r.notInRegion} 个，未授权或未开通 ${r.notAuthorized} 个）\n`);
  ' 2>"$PI_BEDROCK_HOME/.models-summary")"
  log_info "$(cat "$PI_BEDROCK_HOME/.models-summary")"
  rm -f "$PI_BEDROCK_HOME/.models-summary"
}
