// JSON 配置文件的安全读写：非法 JSON 拒绝写入；原子写（tmp + rename）；首次修改前备份为 *.pi-bedrock.bak。
import { existsSync, readFileSync, writeFileSync, renameSync, copyFileSync, chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export function fail(tool, message, code = 2) {
  process.stderr.write(`${tool}: ${message}\n`);
  process.exit(code);
}

/** @returns {Record<string, unknown>} 文件不存在或为空时返回 {} */
export function readJsonObject(tool, file) {
  if (!existsSync(file)) return {};
  const raw = readFileSync(file, "utf8");
  if (raw.trim() === "") return {};
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    fail(tool, `${file} 不是合法 JSON，已放弃修改（请先修复该文件）: ${err.message}`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    fail(tool, `${file} 顶层必须是 JSON 对象，已放弃修改`);
  }
  return parsed;
}

export function writeJsonAtomic(file, data) {
  mkdirSync(dirname(file), { recursive: true });
  const backup = `${file}.pi-bedrock.bak`;
  if (existsSync(file) && !existsSync(backup)) {
    copyFileSync(file, backup);
    chmodSync(backup, 0o600);
  }
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, file);
}

/** 解析 "<mode> <file> --key value ..." 形式的参数 */
export function parseArgs(tool, argv, modes, usage) {
  const [mode, file, ...rest] = argv;
  if (!modes.includes(mode) || !file) fail(tool, `用法: ${usage}`, 64);
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i];
    const value = rest[i + 1];
    if (!key?.startsWith("--") || value === undefined) fail(tool, `参数错误: ${key}`, 64);
    opts[key.slice(2)] = value;
  }
  return { mode, file, opts };
}
