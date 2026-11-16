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

import { Sha256, needsCli, sdkApi, sdkClient, filterModels, loadSdk } from "../lib/bedrock-models.mjs";

test("Sha256：与 node:crypto 结果一致（含 HMAC）", async () => {
  const h = new Sha256();
  h.update("abc");
  assert.equal(Buffer.from(await h.digest()).toString("hex"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  const m = new Sha256("key");
  m.update(new TextEncoder().encode("The quick brown fox jumps over the lazy dog"));
  assert.equal(Buffer.from(await m.digest()).toString("hex"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
});

test("needsCli：代理、自定义 CA / endpoint、FIPS 时使用 aws CLI", () => {
  assert.equal(needsCli({}), false);
  for (const k of ["HTTPS_PROXY", "https_proxy", "AWS_CA_BUNDLE", "AWS_ENDPOINT_URL", "AWS_USE_FIPS_ENDPOINT"]) assert.equal(needsCli({ [k]: "x" }), true, k);
});

test("loadSdk：找不到 pi 的依赖时返回 undefined", () => {
  assert.equal(loadSdk("/nonexistent/pi-ai/dist/providers/data/amazon-bedrock.json"), undefined);
});

// 伪造的 SDK 与 fetch：记录请求，按路径返回 Bedrock API 响应
function fakeBedrock(routes) {
  const calls = [];
  const sdk = {
    defaultProvider: () => async () => ({ accessKeyId: "AKID", secretAccessKey: "secret" }),
    SignatureV4: class { async sign(req) { return { ...req, headers: { ...req.headers, authorization: "AWS4-HMAC-SHA256 fake" } }; } },
  };
  const fetchImpl = async (url, init) => {
    const u = new URL(url);
    calls.push({ path: u.pathname, query: Object.fromEntries(u.searchParams), headers: init.headers });
    const handler = routes[u.pathname] ?? routes["*"];
    const [status, body] = handler ? handler(u) : [404, "{}"];
    return { ok: status < 400, status, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) };
  };
  return { calls, call: sdkClient("us-east-1", sdk, fetchImpl) };
}

const available = { authorizationStatus: "AUTHORIZED", entitlementAvailability: "AVAILABLE", regionAvailability: "AVAILABLE", agreementAvailability: { status: "AVAILABLE" } };

test("sdkApi + filterModels：分页列出推理配置文件，模型 ID 做 URL 编码，不发送 host 头", async () => {
  const { calls, call } = fakeBedrock({
    "/inference-profiles": (u) => (u.searchParams.get("nextToken")
      ? [200, { inferenceProfileSummaries: [profiles[0]] }]
      : [200, { inferenceProfileSummaries: [], nextToken: "t1" }]),
    "/foundation-models": () => [200, { modelSummaries: fms }],
    "*": (u) => [u.pathname.includes("nova-pro") ? 403 : 200, u.pathname.includes("nova-pro") ? "denied" : available],
  });
  const ids = catalogChatModels(catalog);
  const r = await filterModels(sdkApi(call), { ids, defaultModel: "global.moonshotai.kimi-k3.1" });
  assert.equal(r.via, "sdk");
  assert.equal(r.allFailedByNetwork, false);
  assert.ok(r.enabled.includes("amazon-bedrock/global.moonshotai.kimi-k3.1"));
  assert.ok(!r.enabled.includes("amazon-bedrock/amazon.nova-pro-v1:0"), "403 视为不可用");
  assert.equal(calls.filter((c) => c.path === "/inference-profiles").length, 2);
  assert.deepEqual(calls[0].query, { maxResults: "1000", type: "SYSTEM_DEFINED" });
  assert.ok(calls.some((c) => c.path === "/foundation-model-availability/amazon.nova-pro-v1%3A0"));
  assert.ok(calls.every((c) => !Object.keys(c.headers).some((k) => k.toLowerCase() === "host")));
});

test("filterModels：可用性查询全部因网络失败时标记 allFailedByNetwork（由调用方回退 CLI）", async () => {
  const api = {
    via: "sdk",
    concurrency: 4,
    listProfiles: async () => profiles,
    listFoundationModels: async () => fms,
    availability: async () => { throw new Error("fetch failed"); },
  };
  const r = await filterModels(api, { ids: catalogChatModels(catalog), defaultModel: "global.moonshotai.kimi-k3.1" });
  assert.equal(r.allFailedByNetwork, true);
  assert.equal(r.availabilityUnknown > 0, true);
});

test("sdkClient：429 / 5xx 重试后成功；4xx 不重试", async () => {
  let n = 0;
  const sdk = {
    defaultProvider: () => async () => ({ accessKeyId: "a", secretAccessKey: "b" }),
    SignatureV4: class { async sign(req) { return req; } },
  };
  const fetchImpl = async (url) => {
    n += 1;
    if (url.includes("/flaky")) return n < 3 ? { ok: false, status: 429, text: async () => "slow down" } : { ok: true, status: 200, text: async () => "{\"ok\":1}" };
    return { ok: false, status: 400, text: async () => "bad" };
  };
  const call = sdkClient("us-east-1", sdk, fetchImpl, async () => {});
  assert.deepEqual(await call("/flaky"), { ok: 1 });
  assert.equal(n, 3);
  n = 0;
  await assert.rejects(call("/bad"), (e) => e.status === 400);
  assert.equal(n, 1);
});

test("needsCli：中国区走 CLI", () => {
  assert.equal(needsCli({}, "cn-north-1"), true);
  assert.equal(needsCli({}, "us-east-1"), false);
});

import { packageRoot } from "../lib/bedrock-models.mjs";

test("packageRoot / loadSdk：只从 pi 的顶层包目录加载 SDK", () => {
  assert.equal(packageRoot("/h/npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/providers/data/amazon-bedrock.json"),
    "/h/npm-global/lib/node_modules/@earendil-works/pi-coding-agent");
  assert.equal(packageRoot("C:\\Users\\me\\npm-global\\node_modules\\pi\\dist\\a.json"), "C:/Users/me/npm-global/node_modules/pi");
  assert.equal(packageRoot("/tmp/amazon-bedrock.json"), undefined);
  assert.equal(loadSdk("/tmp/amazon-bedrock.json"), undefined);
});
