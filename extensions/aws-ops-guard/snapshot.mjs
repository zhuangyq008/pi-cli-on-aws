#!/usr/bin/env node
// 在命令执行时为 aws 进程生成 ~/.aws 快照目录（输出目录路径）：
//   - config / credentials 经白名单重写（见 awsconfig.mjs），文件只读
//   - 只复制 sso/cache、login/cache 中的普通 *.json 文件（不跟随符号链接）
// 由 policy.ts 生成的命令调用；命令结束时由 EXIT trap 删除快照。
import { chmodSync, copyFileSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { sanitizeAwsConfig } from "./awsconfig.mjs";

const MAX_BYTES = 1_000_000;
const home = homedir();

function readConfig(path) {
  try {
    const stat = statSync(path);
    return stat.isFile() && stat.size <= MAX_BYTES ? readFileSync(path, "utf8") : undefined;
  } catch {
    return undefined;
  }
}

function copyTokenCache(src, dest) {
  let names = [];
  try {
    // 缓存目录及其上级（~/.aws/sso）本身不能是符号链接
    if (!lstatSync(src).isDirectory() || !lstatSync(join(src, "..")).isDirectory()) return;
    names = readdirSync(src);
  } catch {
    return;
  }
  mkdirSync(dest, { recursive: true, mode: 0o700 });
  for (const name of names) {
    const path = join(src, name);
    const stat = lstatSync(path);
    if (!stat.isFile() || !name.endsWith(".json") || stat.size > MAX_BYTES) continue;
    copyFileSync(path, join(dest, name));
    chmodSync(join(dest, name), 0o400);
  }
}

const dir = mkdtempSync(join(tmpdir(), "pi-aws-home-"));
const awsDir = join(dir, ".aws");
mkdirSync(awsDir, { mode: 0o700 });
const sources = [
  ["config", process.env.AWS_CONFIG_FILE || join(home, ".aws", "config")],
  ["credentials", process.env.AWS_SHARED_CREDENTIALS_FILE || join(home, ".aws", "credentials")],
];
for (const [kind, path] of sources) {
  const text = readConfig(path);
  if (text !== undefined) writeFileSync(join(awsDir, kind), sanitizeAwsConfig(text, kind), { mode: 0o400 });
}
copyTokenCache(join(home, ".aws", "sso", "cache"), join(awsDir, "sso", "cache"));
copyTokenCache(join(home, ".aws", "login", "cache"), join(awsDir, "login", "cache"));
// Windows：输出 C:/... 形式，供 Git Bash 中的命令使用
process.stdout.write(process.platform === "win32" ? dir.replace(/\\/g, "/") : dir);
