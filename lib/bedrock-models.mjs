#!/usr/bin/env node
// 筛选当前 Bedrock 源区域中真正可用的模型，供 pi 的 enabledModels 使用（/model 默认只显示这些模型）。
// 判定（只读查询，不调用模型，因此不会触发第三方模型的 Marketplace 自动订阅）：
//   1. 模型 ID 是该区域 ACTIVE 的系统推理配置文件，或支持 ON_DEMAND 的 ACTIVE 基础模型
//      （否则调用会报 "The provided model identifier is invalid"）
//   2. GetFoundationModelAvailability：已授权、已开通、协议可用、区域可用
// 用法: bedrock-models.mjs --region R --catalog amazon-bedrock.json [--default MODEL_ID] [--concurrency 8]
// 输出（stdout，JSON）: { enabled: ["amazon-bedrock/<id>", ...], total, notInRegion, notAuthorized, availabilityUnknown }
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { promisify } from "node:util";

const run = promisify(execFile);
const PROVIDER = "amazon-bedrock";

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 2) opts[argv[i].replace(/^--/, "")] = argv[i + 1];
  if (!/^[a-z]{2}(-gov)?-[a-z]+-[0-9]$/.test(opts.region ?? "")) throw new Error("缺少或非法的 --region");
  if (!opts.catalog) throw new Error("缺少 --catalog");
  return { region: opts.region, catalog: opts.catalog, defaultModel: opts.default, concurrency: Number(opts.concurrency ?? 8) };
}

async function aws(args) {
  const { stdout } = await run("aws", [...args, "--output", "json"], { maxBuffer: 64 * 1024 * 1024, timeout: 120_000 });
  return JSON.parse(stdout);
}

export function catalogChatModels(catalog) {
  const entries = Object.values(catalog).flatMap((group) => Object.values(group ?? {}));
  return [...new Set(entries.filter((m) => m?.type === "chat" && typeof m.id === "string").map((m) => m.id))];
}

const fmIdFromArn = (arn) => arn.split("foundation-model/")[1];

// 纯函数：根据区域内的推理配置文件与基础模型，得到每个目录模型对应的基础模型 ID（不在区域内则为 undefined）
export function resolveRegionModels(ids, profiles, foundationModels) {
  const profileMap = new Map(profiles.filter((p) => p.status === "ACTIVE").map((p) => [p.inferenceProfileId, p]));
  const fmMap = new Map(foundationModels.map((m) => [m.modelId, m]));
  return new Map(ids.map((id) => {
    const profile = profileMap.get(id);
    if (profile) return [id, [...new Set((profile.models ?? []).map((m) => fmIdFromArn(m.modelArn)).filter(Boolean))]];
    const fm = fmMap.get(id);
    const onDemand = fm && (fm.inferenceTypesSupported ?? []).includes("ON_DEMAND") && (fm.modelLifecycle?.status ?? "ACTIVE") === "ACTIVE";
    return [id, onDemand ? [id] : undefined];
  }));
}

export function isUsable(availability) {
  return availability?.authorizationStatus === "AUTHORIZED" && availability?.entitlementAvailability === "AVAILABLE" &&
    availability?.regionAvailability === "AVAILABLE" && availability?.agreementAvailability?.status === "AVAILABLE";
}

async function mapLimit(items, limit, fn) {
  const results = new Map();
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const item = items[next++];
      results.set(item, await fn(item));
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, worker));
  return results;
}

async function main() {
  const { region, catalog, defaultModel, concurrency } = parseArgs(process.argv.slice(2));
  const ids = catalogChatModels(JSON.parse(readFileSync(catalog, "utf8")));
  const [profiles, fms] = await Promise.all([
    aws(["bedrock", "list-inference-profiles", "--region", region, "--type-equals", "SYSTEM_DEFINED"]),
    aws(["bedrock", "list-foundation-models", "--region", region]),
  ]);
  const regionModels = resolveRegionModels(ids, profiles.inferenceProfileSummaries ?? [], fms.modelSummaries ?? []);
  const inRegion = ids.filter((id) => regionModels.get(id));
  const fmIds = [...new Set(inRegion.flatMap((id) => regionModels.get(id)))];
  const availability = await mapLimit(fmIds, concurrency, async (fm) => {
    try {
      return await aws(["bedrock", "get-foundation-model-availability", "--region", region, "--model-id", fm]);
    } catch {
      return undefined;
    }
  });
  const unknown = fmIds.filter((fm) => availability.get(fm) === undefined);
  // 无权查询可用性（全部失败）时，退化为只按区域过滤
  const usable = (id) => unknown.length === fmIds.length || regionModels.get(id).every((fm) => isUsable(availability.get(fm)));
  const enabled = inRegion.filter((id) => usable(id) || id === defaultModel);
  const ordered = [...enabled.filter((id) => id === defaultModel), ...enabled.filter((id) => id !== defaultModel).sort()];
  process.stdout.write(`${JSON.stringify({
    enabled: ordered.map((id) => `${PROVIDER}/${id}`),
    total: ids.length,
    notInRegion: ids.length - inRegion.length,
    notAuthorized: inRegion.length - enabled.length,
    availabilityUnknown: unknown.length,
  })}\n`);
}

// 按文件名判断是否作为脚本运行（Windows 上 argv[1] 为 C:\...，与 import.meta.url 的 file:///C:/... 形式不同）
if (/[\\/]bedrock-models\.mjs$/.test(process.argv[1] ?? "")) {
  main().catch((err) => {
    process.stderr.write(`bedrock-models: ${err.message}\n`);
    process.exit(1);
  });
}
