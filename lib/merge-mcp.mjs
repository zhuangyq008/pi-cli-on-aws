#!/usr/bin/env node
// 合并 / 回滚 pi 的 MCP 配置（~/.pi/agent/mcp.json）中由 pi-cli-bedrock 管理的 aws-mcp 条目。
// - apply：写入（或更新）条目；若已存在 command 不同的同名条目（用户自建），返回 3 且不修改
// - remove：仅当条目的 command 与本工具启动器一致时删除
import { readJsonObject, writeJsonAtomic, parseArgs, fail } from "./json-file.mjs";

const TOOL = "merge-mcp";
const NAME_PATTERN = /^[A-Za-z0-9_-]+$/;
const DEFAULT_DESCRIPTION =
  "AWS 官方托管 MCP Server（Agent Toolkit for AWS）：用 aws___run_script 调用 AWS API（成本与用量、CloudWatch 指标/日志/告警、CloudTrail 等），检索 AWS 文档与 skills。";

export function applyEntry(config, { name, command, description, timeout }) {
  const servers = config.mcpServers ?? {};
  const existing = servers[name];
  if (existing && existing.command !== command) return { config, conflict: true };
  const entry = { command, args: [], timeout, exposure: "direct", description };
  return { config: { ...config, mcpServers: { ...servers, [name]: entry } }, conflict: false };
}

export function removeEntry(config, { name, command }) {
  const servers = config.mcpServers ?? {};
  if (servers[name]?.command !== command) return config;
  const { [name]: _removed, ...rest } = servers;
  return { ...config, mcpServers: rest };
}

function main() {
  const { mode, file, opts } = parseArgs(TOOL, process.argv.slice(2), ["apply", "remove"],
    "merge-mcp.mjs <apply|remove> <mcp.json> --name N --command PATH [--timeout SECONDS]");
  if (!opts.name || !NAME_PATTERN.test(opts.name)) fail(TOOL, "缺少或非法的 --name", 64);
  if (!opts.command?.startsWith("/")) fail(TOOL, "--command 必须是绝对路径", 64);
  const current = readJsonObject(TOOL, file);
  if (current.mcpServers !== undefined && (typeof current.mcpServers !== "object" || Array.isArray(current.mcpServers))) {
    fail(TOOL, `${file} 中的 mcpServers 必须是对象，已放弃修改`);
  }
  if (mode === "apply") {
    const timeout = Number(opts.timeout ?? 300);
    if (!Number.isInteger(timeout) || timeout <= 0) fail(TOOL, "--timeout 必须是正整数", 64);
    const { config, conflict } = applyEntry(current, {
      name: opts.name, command: opts.command, description: opts.description ?? DEFAULT_DESCRIPTION, timeout,
    });
    if (conflict) process.exit(3);
    if (JSON.stringify(config) !== JSON.stringify(current)) writeJsonAtomic(file, config);
    return;
  }
  const next = removeEntry(current, { name: opts.name, command: opts.command });
  if (JSON.stringify(next) !== JSON.stringify(current)) writeJsonAtomic(file, next);
}

main();
