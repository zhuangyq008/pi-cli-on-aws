#!/usr/bin/env node
// 合并 / 回滚 pi 的 settings.json（~/.pi/agent/settings.json）。
// - apply：写入 Bedrock 默认 provider/model/thinking、shellCommandPrefix、selfUpdateCommand，保留其余用户配置
// - remove：仅移除本工具写入且未被用户改动的值
// 原则：不修改输入对象（返回新对象）；JSON 非法时拒绝写入；原子写（tmp + rename）；首次修改前备份。
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { readJsonObject, writeJsonAtomic, parseArgs as parseCliArgs, fail as failWith } from "./json-file.mjs";

const TOOL = "merge-settings";
// 安装时会覆盖的键：首次安装前的原值保存到 --orig 文件，卸载时恢复
const OWNED_KEYS = ["defaultProvider", "defaultModel", "defaultThinkingLevel", "selfUpdateCommand"];
const THINKING_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);

function fail(message, code = 2) {
  failWith(TOOL, message, code);
}

function parseArgs(argv) {
  return parseCliArgs(TOOL, argv, ["apply", "remove"],
    "merge-settings.mjs <apply|remove> <settings.json> --provider P --model M [--thinking T] [--npm BIN --npm-prefix DIR]");
}

function readSettings(file) {
  return readJsonObject(TOOL, file);
}

function splitPrefix(prefix, tag) {
  return typeof prefix === "string" && prefix.length > 0
    ? prefix.split("\n").filter((line) => !line.includes(tag))
    : [];
}

export function selfUpdateCommand(npm, npmPrefix) {
  return npm && npmPrefix ? [npm, "install", "-g", "--prefix", npmPrefix, "{installSpec}"] : undefined;
}

export function applySettings(current, { provider, model, thinking, selfUpdate, snippet, tag }) {
  const others = splitPrefix(current.shellCommandPrefix, tag);
  return {
    ...current,
    defaultProvider: provider,
    defaultModel: model,
    defaultThinkingLevel: thinking,
    shellCommandPrefix: [snippet, ...others].join("\n"),
    ...(selfUpdate ? { selfUpdateCommand: selfUpdate } : {}),
  };
}

export function captureOriginals(current) {
  return Object.fromEntries(OWNED_KEYS.map((key) => [key, current[key] ?? null]));
}

// originals：首次安装前的原值（null 表示原来不存在）；仍是本工具写入的值时恢复，用户之后改过的保留
export function removeSettings(current, { provider, model, npmPrefix, tag, originals = {} }) {
  const { defaultProvider, defaultModel, defaultThinkingLevel, shellCommandPrefix, selfUpdateCommand, ...rest } = current;
  const ownsDefaults = defaultProvider === provider && defaultModel === model;
  const others = splitPrefix(shellCommandPrefix, tag);
  const ownsUpdate = Boolean(npmPrefix) && Array.isArray(selfUpdateCommand) && selfUpdateCommand.includes(npmPrefix);
  const restore = (key, value, owned) => {
    const next = owned ? originals[key] ?? null : value;
    return next === null || next === undefined ? {} : { [key]: next };
  };
  return {
    ...rest,
    ...restore("defaultProvider", defaultProvider, ownsDefaults),
    ...restore("defaultModel", defaultModel, ownsDefaults),
    ...restore("defaultThinkingLevel", defaultThinkingLevel, ownsDefaults),
    ...(others.length > 0 ? { shellCommandPrefix: others.join("\n") } : {}),
    ...restore("selfUpdateCommand", selfUpdateCommand, ownsUpdate),
  };
}

function readOriginals(file) {
  if (!file || !existsSync(file)) return {};
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function dropUndefined(obj) {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));
}

function main() {
  const { mode, file, opts } = parseArgs(process.argv.slice(2));
  const tag = process.env.PI_BEDROCK_PREFIX_TAG;
  if (!tag) fail("缺少 PI_BEDROCK_PREFIX_TAG", 64);
  if (!opts.provider || !opts.model) fail("缺少 --provider / --model", 64);
  const current = readSettings(file);

  let next;
  if (mode === "apply") {
    const thinking = opts.thinking ?? "medium";
    if (!THINKING_LEVELS.has(thinking)) fail(`非法 thinking level: ${thinking}`, 64);
    const snippet = process.env.PI_BEDROCK_PREFIX_SNIPPET;
    if (!snippet?.includes(tag)) fail("缺少 PI_BEDROCK_PREFIX_SNIPPET", 64);
    const selfUpdate = selfUpdateCommand(opts.npm, opts["npm-prefix"]);
    if (opts.orig && !existsSync(opts.orig)) {
      writeFileSync(opts.orig, `${JSON.stringify(captureOriginals(current), null, 2)}\n`, { mode: 0o600 });
    }
    next = applySettings(current, { provider: opts.provider, model: opts.model, thinking, selfUpdate, snippet, tag });
  } else {
    if (!existsSync(file)) return;
    next = dropUndefined(removeSettings(current, {
      provider: opts.provider, model: opts.model, npmPrefix: opts["npm-prefix"], tag, originals: readOriginals(opts.orig),
    }));
  }

  if (JSON.stringify(next) === JSON.stringify(current)) return;
  writeJsonAtomic(file, next);
}

main();
