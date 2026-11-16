#!/usr/bin/env node
// 筛选当前 Bedrock 源区域中真正可用的模型，供 pi 的 enabledModels 使用（/model 默认只显示这些模型）。
// 判定（只读查询，不调用模型，因此不会触发第三方模型的 Marketplace 自动订阅）：
//   1. 模型 ID 是该区域 ACTIVE 的系统推理配置文件，或支持 ON_DEMAND 的 ACTIVE 基础模型
//      （否则调用会报 "The provided model identifier is invalid"）
//   2. GetFoundationModelAvailability：已授权、已开通、协议可用、区域可用
// 调用方式：优先在进程内用 pi 自带的 AWS SDK 模块（凭证链与 pi 调用 Bedrock 时一致）签名后直接请求 Bedrock API，
// 几十次 GetFoundationModelAvailability 约 1~2 秒；SDK 不可用、配置了代理 / 自定义 CA / 自定义 endpoint 或请求失败时，
// 回退为逐次调用 aws CLI（每次需启动一个 Python 进程，2 vCPU 上约 20 秒）。
// 用法: bedrock-models.mjs --region R --catalog amazon-bedrock.json [--default MODEL_ID] [--concurrency N]
// 输出（stdout，JSON）: { enabled: ["amazon-bedrock/<id>", ...], total, notInRegion, notAuthorized, availabilityUnknown, via }
import { execFile } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { promisify } from "node:util";

const run = promisify(execFile);
const PROVIDER = "amazon-bedrock";

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 2) opts[argv[i].replace(/^--/, "")] = argv[i + 1];
  if (!/^[a-z]{2}(-gov)?-[a-z]+-[0-9]$/.test(opts.region ?? "")) throw new Error("缺少或非法的 --region");
  if (!opts.catalog) throw new Error("缺少 --catalog");
  return { region: opts.region, catalog: opts.catalog, defaultModel: opts.default, concurrency: opts.concurrency ? Number(opts.concurrency) : undefined };
}

// 单次请求超时（网络不通时尽快回退 CLI）；429 / 5xx 按指数退避重试（与 aws CLI 的 standard 重试模式相当）
const REQUEST_TIMEOUT_MS = 8_000;
const MAX_ATTEMPTS = 4;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const retryable = (status) => status === 429 || status >= 500;

async function aws(args) {
  const { stdout } = await run("aws", [...args, "--output", "json"], { maxBuffer: 64 * 1024 * 1024, timeout: 120_000 });
  return JSON.parse(stdout);
}

// @smithy/signature-v4 需要的哈希实现（与 @aws-crypto/sha256-js 接口一致）
export class Sha256 {
  constructor(secret) { this.hash = secret ? createHmac("sha256", secret) : createHash("sha256"); }
  update(data) { this.hash.update(typeof data === "string" ? Buffer.from(data, "utf8") : data); }
  async digest() { return new Uint8Array(this.hash.digest()); }
}

// aws CLI 支持而 Node fetch 不支持（或行为不同）的配置：此时直接使用 CLI，保证与用户的 aws 命令结果一致
export function needsCli(env, region = "") {
  if (region.startsWith("cn-")) return true;   // 中国区 endpoint 为 .amazonaws.com.cn
  return ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "AWS_CA_BUNDLE", "AWS_ENDPOINT_URL", "AWS_ENDPOINT_URL_BEDROCK", "AWS_USE_FIPS_ENDPOINT"]
    .some((k) => Boolean(env[k]));
}

// catalog 所在的顶层 npm 包目录（pi 的全局安装目录）：只从这里加载 SDK，
// 不沿 node_modules 继续向上解析到 ~/node_modules、/node_modules 等可被他人放置模块的位置
export function packageRoot(catalogPath) {
  const m = /^(.*?\/node_modules\/(?:@[^/]+\/)?[^/]+)\//.exec(catalogPath.replace(/\\/g, "/"));
  return m ? m[1] : undefined;
}

// 从 pi 的依赖中加载凭证链与 SigV4 签名器（catalog 位于 pi-ai 包内）
export function loadSdk(catalogPath) {
  const root = packageRoot(catalogPath);
  if (!root) return undefined;
  const inside = (p) => p.replace(/\\/g, "/").startsWith(`${root}/`);
  const bases = [catalogPath];
  try { bases.push(createRequire(catalogPath).resolve("@aws-sdk/client-bedrock-runtime")); } catch { /* 用 catalog 位置解析 */ }
  for (const base of bases.filter(inside)) {
    try {
      const req = createRequire(base);
      const paths = ["@aws-sdk/credential-provider-node", "@smithy/signature-v4"].map((m) => req.resolve(m));
      if (!paths.every(inside)) continue;
      const { defaultProvider } = req(paths[0]);
      const { SignatureV4 } = req(paths[1]);
      if (typeof defaultProvider === "function" && typeof SignatureV4 === "function") return { defaultProvider, SignatureV4 };
    } catch { /* 尝试下一个位置 */ }
  }
  return undefined;
}

// 返回 call(path, query) → JSON；HTTP 错误抛出带 status 的 Error
export function sdkClient(region, sdk, fetchImpl = fetch, delay = sleep) {
  const signer = new sdk.SignatureV4({ service: "bedrock", region, credentials: sdk.defaultProvider(), sha256: Sha256 });
  const hostname = `bedrock.${region}.amazonaws.com`;
  const once = async (path, query) => {
    const signed = await signer.sign({ method: "GET", protocol: "https:", hostname, path, query, headers: { host: hostname } });
    const headers = Object.fromEntries(Object.entries(signed.headers).filter(([k]) => k.toLowerCase() !== "host"));
    const qs = new URLSearchParams(query).toString();
    const res = await fetchImpl(`https://${hostname}${path}${qs ? `?${qs}` : ""}`, { headers, redirect: "error", signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    const body = await res.text();
    if (!res.ok) throw Object.assign(new Error(`HTTP ${res.status} ${path}: ${body.slice(0, 200)}`), { status: res.status });
    return JSON.parse(body);
  };
  return async (path, query = {}) => {
    for (let attempt = 1; ; attempt += 1) {
      try {
        return await once(path, query);
      } catch (err) {
        if (attempt >= MAX_ATTEMPTS || !retryable(err?.status)) throw err;
        await delay(200 * 2 ** attempt * (0.5 + Math.random()));
      }
    }
  };
}

// 两种调用方式的统一接口：listProfiles / listFoundationModels / availability(modelId)
export function sdkApi(call) {
  return {
    via: "sdk",
    concurrency: 8,
    async listProfiles() {
      const all = [];
      let nextToken;
      do {
        const page = await call("/inference-profiles", { maxResults: "1000", type: "SYSTEM_DEFINED", ...(nextToken ? { nextToken } : {}) });
        all.push(...(page.inferenceProfileSummaries ?? []));
        nextToken = page.nextToken;
      } while (nextToken);
      return all;
    },
    async listFoundationModels() { return (await call("/foundation-models")).modelSummaries ?? []; },
    availability: (fm) => call(`/foundation-model-availability/${encodeURIComponent(fm)}`),
  };
}

function cliApi(region) {
  return {
    via: "cli",
    concurrency: 8,
    async listProfiles() {
      return (await aws(["bedrock", "list-inference-profiles", "--region", region, "--type-equals", "SYSTEM_DEFINED"])).inferenceProfileSummaries ?? [];
    },
    async listFoundationModels() { return (await aws(["bedrock", "list-foundation-models", "--region", region])).modelSummaries ?? []; },
    availability: (fm) => aws(["bedrock", "get-foundation-model-availability", "--region", region, "--model-id", fm]),
  };
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

// 用 API 计算结果；listProfiles / listFoundationModels 失败时抛出（由调用方决定是否回退）
export async function filterModels(api, { ids, defaultModel, concurrency }) {
  const [profiles, fms] = await Promise.all([api.listProfiles(), api.listFoundationModels()]);
  const regionModels = resolveRegionModels(ids, profiles, fms);
  const inRegion = ids.filter((id) => regionModels.get(id));
  const fmIds = [...new Set(inRegion.flatMap((id) => regionModels.get(id)))];
  let networkErrors = 0;
  let throttled = 0;
  const availability = await mapLimit(fmIds, concurrency ?? api.concurrency, async (fm) => {
    try {
      return await api.availability(fm);
    } catch (err) {
      // 没有 HTTP 状态码：网络 / 超时 / 凭证解析失败（而非 403 等 API 拒绝）
      if (err?.status === undefined) networkErrors += 1;
      else if (retryable(err.status)) throttled += 1;
      return undefined;
    }
  });
  const unknown = fmIds.filter((fm) => availability.get(fm) === undefined);
  // 无权查询可用性（全部失败）时，退化为只按区域过滤
  const usable = (id) => unknown.length === fmIds.length || regionModels.get(id).every((fm) => isUsable(availability.get(fm)));
  const enabled = inRegion.filter((id) => usable(id) || id === defaultModel);
  const ordered = [...enabled.filter((id) => id === defaultModel), ...enabled.filter((id) => id !== defaultModel).sort()];
  return {
    enabled: ordered.map((id) => `${PROVIDER}/${id}`),
    total: ids.length,
    notInRegion: ids.length - inRegion.length,
    notAuthorized: inRegion.length - enabled.length,
    availabilityUnknown: unknown.length,
    via: api.via,
    allFailedByNetwork: fmIds.length > 0 && networkErrors === fmIds.length,
    // 重试后仍被限流 / 5xx 的模型：结果不完整，由调用方改用 CLI 再算一次
    throttled,
  };
}

async function main() {
  const { region, catalog, defaultModel, concurrency } = parseArgs(process.argv.slice(2));
  const ids = catalogChatModels(JSON.parse(readFileSync(catalog, "utf8")));
  const sdk = needsCli(process.env, region) ? undefined : loadSdk(catalog);
  let result;
  if (sdk) {
    try {
      result = await filterModels(sdkApi(sdkClient(region, sdk)), { ids, defaultModel, concurrency });
      // 可用性查询全部因网络原因失败时用 CLI 再试一次（403 等 API 拒绝换用 CLI 结果相同，不重试）
      if (result.allFailedByNetwork || result.throttled > 0) {
        process.stderr.write(`bedrock-models: SDK 可用性查询${result.throttled > 0 ? `有 ${result.throttled} 个被限流` : "全部失败"}，改用 aws CLI\n`);
        result = undefined;
      }
    } catch (err) {
      process.stderr.write(`bedrock-models: SDK 调用失败，改用 aws CLI（${err.message}）\n`);
      result = undefined;
    }
  }
  result ??= await filterModels(cliApi(region), { ids, defaultModel, concurrency });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

// 按文件名判断是否作为脚本运行（Windows 上 argv[1] 为 C:\...，与 import.meta.url 的 file:///C:/... 形式不同）
if (/[\\/]bedrock-models\.mjs$/.test(process.argv[1] ?? "")) {
  main().catch((err) => {
    process.stderr.write(`bedrock-models: ${err.message}\n`);
    process.exit(1);
  });
}
