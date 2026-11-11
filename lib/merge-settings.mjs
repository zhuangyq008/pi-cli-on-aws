#!/usr/bin/env node
// 合并 / 回滚 pi 的 settings.json（~/.pi/agent/settings.json）。
// - apply：写入 Bedrock 默认 provider/model/thinking、shellCommandPrefix、selfUpdateCommand，保留其余用户配置
// - remove：仅移除本工具写入且未被用户改动的值
// 原则：不修改输入对象（返回新对象）；JSON 非法时拒绝写入；原子写（tmp + rename）；首次修改前备份。
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { readJsonObject, writeJsonAtomic, parseArgs as parseCliArgs, fail as failWith } from "./json-file.mjs";

const TOOL = "merge-settings";
// 安装时会覆盖的键：首次安装前的原值保存到 --orig 文件，卸载时恢复
const OWNED_KEYS = ["defaultProvider", "defaultModel", "defaultThinkingLevel", "selfUpdateCommand", "enabledModels", "shellPath"];
const MODEL_PATTERN = /^amazon-bedrock\/[A-Za-z0-9.:_\/-]+$/;
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

// npmCli：Windows 上 npm 是 .cmd 脚本（Node 不允许不经 shell 直接执行），改为 node.exe + npm-cli.js
export function selfUpdateCommand(npm, npmPrefix, npmCli) {
  if (!npm || !npmPrefix) return undefined;
  return [npm, ...(npmCli ? [npmCli] : []), "install", "-g", "--prefix", npmPrefix, "{installSpec}"];
}

export function applySettings(current, { provider, model, thinking, selfUpdate, snippet, tag, enabledModels, shellPath }) {
  const others = splitPrefix(current.shellCommandPrefix, tag);
  return {
    ...current,
    defaultProvider: provider,
    defaultModel: model,
    defaultThinkingLevel: thinking,
    shellCommandPrefix: [snippet, ...others].join("\n"),
    ...(selfUpdate ? { selfUpdateCommand: selfUpdate } : {}),
    ...(enabledModels ? { enabledModels } : {}),
    ...(shellPath ? { shellPath } : {}),
  };
}

export function captureOriginals(current) {
  return Object.fromEntries(OWNED_KEYS.map((key) => [key, current[key] ?? null]));
}

// originals：首次安装前的原值（null 表示原来不存在）；仍是本工具写入的值时恢复，用户之后改过的保留
export function removeSettings(current, { provider, model, npmPrefix, shellPath: ownShellPath, tag, originals = {} }) {
  const { defaultProvider, defaultModel, defaultThinkingLevel, shellCommandPrefix, selfUpdateCommand, enabledModels, shellPath, ...rest } = current;
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
    ...restore("enabledModels", enabledModels, ownsDefaults),
    ...restore("shellPath", shellPath, Boolean(ownShellPath) && shellPath === ownShellPath),
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
    const selfUpdate = selfUpdateCommand(opts.npm, opts["npm-prefix"], opts["npm-cli"]);
    const shellPath = opts["shell-path"];
    if (shellPath !== undefined && !/^[A-Za-z]:[\\/].*bash\.exe$/i.test(shellPath)) fail("--shell-path 必须是 Windows 上 bash.exe 的绝对路径", 64);
    if (opts.orig && !existsSync(opts.orig)) {
      writeFileSync(opts.orig, `${JSON.stringify(captureOriginals(current), null, 2)}\n`, { mode: 0o600 });
    }
    let enabledModels;
    if (opts["enabled-models"]) {
      try {
        enabledModels = JSON.parse(opts["enabled-models"]);
      } catch {
        fail("--enabled-models 必须是 JSON 数组", 64);
      }
      if (!Array.isArray(enabledModels) || enabledModels.length === 0 || !enabledModels.every((m) => typeof m === "string" && MODEL_PATTERN.test(m))) {
        fail("--enabled-models 必须是非空的 amazon-bedrock/<model-id> 字符串数组", 64);
      }
    }
    next = applySettings(current, { provider: opts.provider, model: opts.model, thinking, selfUpdate, snippet, tag, enabledModels, shellPath });
  } else {
    if (!existsSync(file)) return;
    next = dropUndefined(removeSettings(current, {
      provider: opts.provider, model: opts.model, npmPrefix: opts["npm-prefix"], shellPath: opts["shell-path"], tag, originals: readOriginals(opts.orig),
    }));
  }

  if (JSON.stringify(next) === JSON.stringify(current)) return;
  writeJsonAtomic(file, next);
}

// 作为脚本运行时才执行 main（允许测试 import 纯函数）。按文件名判断：Windows 上 argv[1] 可能是 8.3 短路径，与 import.meta.url 不一致
if (/[\\/]merge-settings\.mjs$/.test(process.argv[1] ?? "")) main();
