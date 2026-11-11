#!/usr/bin/env node
// 合并 / 回滚 pi 的 MCP 配置（~/.pi/agent/mcp.json）中由 pi-cli-bedrock 管理的 aws-mcp 条目。
// - apply：写入（或更新）条目；若已存在不属于本工具的同名条目（用户自建），返回 3 且不修改
// - remove：仅删除本工具的条目
// 本工具的条目：command 即启动器（Linux / macOS），或 command 为解释器、args[0] 为启动器（Windows：Git Bash 运行 bash 启动器）
import { isAbsolute } from "node:path";
import { readJsonObject, writeJsonAtomic, parseArgs, fail } from "./json-file.mjs";

const TOOL = "merge-mcp";
const NAME_PATTERN = /^[A-Za-z0-9_-]+$/;
const DEFAULT_DESCRIPTION =
  "AWS 官方托管 MCP Server（Agent Toolkit for AWS）：用 aws___run_script 调用 AWS API（成本与用量、CloudWatch 指标/日志/告警、CloudTrail 等），检索 AWS 文档与 skills。";

// Windows 路径不区分大小写，且可能混用 / 与 \、C:/ 与 /c/ 形式
export function samePath(a, b, platform = process.platform) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (platform !== "win32") return a === b;
  const key = (p) => p.replace(/\\/g, "/").replace(/^\/([a-zA-Z])\//, "$1:/").toLowerCase();
  return key(a) === key(b);
}

export function isOwnEntry(entry, launcher, platform = process.platform) {
  if (!entry || typeof entry !== "object") return false;
  return samePath(entry.command, launcher, platform) || (Array.isArray(entry.args) && samePath(entry.args[0], launcher, platform));
}

export function applyEntry(config, { name, command, launcher = command, description, timeout, platform = process.platform }) {
  const servers = config.mcpServers ?? {};
  const existing = servers[name];
  if (existing && !isOwnEntry(existing, launcher, platform)) return { config, conflict: true };
  const args = launcher === command ? [] : [launcher];
  const entry = { command, args, timeout, exposure: "direct", description };
  return { config: { ...config, mcpServers: { ...servers, [name]: entry } }, conflict: false };
}

export function removeEntry(config, { name, command, platform = process.platform }) {
  const servers = config.mcpServers ?? {};
  if (!isOwnEntry(servers[name], command, platform)) return config;
  const { [name]: _removed, ...rest } = servers;
  return { ...config, mcpServers: rest };
}

function main() {
  const { mode, file, opts } = parseArgs(TOOL, process.argv.slice(2), ["apply", "remove"],
    "merge-mcp.mjs <apply|remove> <mcp.json> --name N --command PATH [--launcher PATH] [--timeout SECONDS]");
  if (!opts.name || !NAME_PATTERN.test(opts.name)) fail(TOOL, "缺少或非法的 --name", 64);
  if (!opts.command || !isAbsolute(opts.command)) fail(TOOL, "--command 必须是绝对路径", 64);
  if (opts.launcher !== undefined && !isAbsolute(opts.launcher)) fail(TOOL, "--launcher 必须是绝对路径", 64);
  const current = readJsonObject(TOOL, file);
  if (current.mcpServers !== undefined && (typeof current.mcpServers !== "object" || Array.isArray(current.mcpServers))) {
    fail(TOOL, `${file} 中的 mcpServers 必须是对象，已放弃修改`);
  }
  if (mode === "apply") {
    const timeout = Number(opts.timeout ?? 300);
    if (!Number.isInteger(timeout) || timeout <= 0) fail(TOOL, "--timeout 必须是正整数", 64);
    const { config, conflict } = applyEntry(current, {
      name: opts.name, command: opts.command, launcher: opts.launcher ?? opts.command, description: opts.description ?? DEFAULT_DESCRIPTION, timeout,
    });
    if (conflict) process.exit(3);
    if (JSON.stringify(config) !== JSON.stringify(current)) writeJsonAtomic(file, config);
    return;
  }
  const next = removeEntry(current, { name: opts.name, command: opts.command });
  if (JSON.stringify(next) !== JSON.stringify(current)) writeJsonAtomic(file, next);
}

// 作为脚本运行时才执行 main（允许测试 import 纯函数）。按文件名判断：Windows 上 argv[1] 可能是 8.3 短路径，与 import.meta.url 不一致
if (/[\\/]merge-mcp\.mjs$/.test(process.argv[1] ?? "")) main();
