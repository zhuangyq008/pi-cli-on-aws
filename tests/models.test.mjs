// lib/bedrock-models.mjs 纯函数测试：node --test tests/models.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { catalogChatModels, resolveRegionModels, isUsable } from "../lib/bedrock-models.mjs";

const catalog = {
  "bedrock-converse-stream": {
    "chat:global.moonshotai.kimi-k3.1": { id: "global.moonshotai.kimi-k3.1", type: "chat" },
    "chat:us.anthropic.claude-sonnet-4-6": { id: "us.anthropic.claude-sonnet-4-6", type: "chat" },
    "chat:amazon.nova-pro-v1:0": { id: "amazon.nova-pro-v1:0", type: "chat" },
    "chat:legacy.model-v1": { id: "legacy.model-v1", type: "chat" },
    "embed:amazon.titan-embed": { id: "amazon.titan-embed", type: "embedding" },
  },
};
const profiles = [
  { inferenceProfileId: "global.moonshotai.kimi-k3.1", status: "ACTIVE", models: [
    { modelArn: "arn:aws:bedrock:::foundation-model/moonshotai.kimi-k3.1" },
    { modelArn: "arn:aws:bedrock:ap-southeast-1::foundation-model/moonshotai.kimi-k3.1" },
  ] },
  { inferenceProfileId: "apac.amazon.nova-lite-v1:0", status: "ACTIVE", models: [] },
];
const fms = [
  { modelId: "amazon.nova-pro-v1:0", inferenceTypesSupported: ["ON_DEMAND"], modelLifecycle: { status: "ACTIVE" } },
  { modelId: "legacy.model-v1", inferenceTypesSupported: ["ON_DEMAND"], modelLifecycle: { status: "LEGACY" } },
];

test("catalogChatModels：只取 chat 模型", () => {
  assert.deepEqual(catalogChatModels(catalog).sort(), ["amazon.nova-pro-v1:0", "global.moonshotai.kimi-k3.1", "legacy.model-v1", "us.anthropic.claude-sonnet-4-6"]);
});

test("resolveRegionModels：推理配置文件映射到基础模型；区域内不存在 / 非 ACTIVE 的模型排除", () => {
  const r = resolveRegionModels(catalogChatModels(catalog), profiles, fms);
  assert.deepEqual(r.get("global.moonshotai.kimi-k3.1"), ["moonshotai.kimi-k3.1"]);
  assert.deepEqual(r.get("amazon.nova-pro-v1:0"), ["amazon.nova-pro-v1:0"]);
  assert.equal(r.get("us.anthropic.claude-sonnet-4-6"), undefined, "us.* 在 ap-southeast-1 不存在 → 会报 invalid model identifier");
  assert.equal(r.get("legacy.model-v1"), undefined);
});

test("isUsable：授权、开通、协议、区域均可用才算可用", () => {
  const ok = { authorizationStatus: "AUTHORIZED", entitlementAvailability: "AVAILABLE", regionAvailability: "AVAILABLE", agreementAvailability: { status: "AVAILABLE" } };
  assert.equal(isUsable(ok), true);
  assert.equal(isUsable({ ...ok, authorizationStatus: "NOT_AUTHORIZED" }), false);
  assert.equal(isUsable({ ...ok, agreementAvailability: { status: "NOT_AVAILABLE" } }), false);
  assert.equal(isUsable(undefined), false);
});
