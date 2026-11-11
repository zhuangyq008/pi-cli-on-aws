// merge-mcp / merge-settings 纯函数：Windows 条目（解释器 + 启动器）、shellPath 与 self-update 命令
import { test } from "node:test";
import assert from "node:assert/strict";
import { applyEntry, isOwnEntry, removeEntry, samePath } from "../lib/merge-mcp.mjs";
import { applySettings, removeSettings, selfUpdateCommand } from "../lib/merge-settings.mjs";

const LAUNCHER = "C:/Users/Me/.local/share/pi-bedrock/bin/aws-mcp-proxy";
const BASH = "C:\\Program Files\\Git\\bin\\bash.exe";

test("samePath：Windows 不区分大小写、/ 与 \\、/c/ 与 C:/；其他平台精确比较", () => {
  assert.ok(samePath("C:/Users/Me/x", "c:\\users\\me\\X", "win32"));
  assert.ok(samePath("/c/Users/Me/x", "C:/Users/Me/x", "win32"));
  assert.ok(!samePath("/c/Users/Me/x", "C:/Users/Me/x", "linux"));
  assert.ok(!samePath(undefined, "C:/x", "win32"));
});

test("merge-mcp：Windows 条目为 command=Git Bash、args=[启动器]，可识别、更新与删除", () => {
  const { config, conflict } = applyEntry({}, { name: "aws-mcp", command: BASH, launcher: LAUNCHER, description: "d", timeout: 300, platform: "win32" });
  assert.equal(conflict, false);
  assert.deepEqual(config.mcpServers["aws-mcp"].args, [LAUNCHER]);
  assert.equal(config.mcpServers["aws-mcp"].command, BASH);
  assert.ok(isOwnEntry(config.mcpServers["aws-mcp"], "/c/Users/Me/.local/share/pi-bedrock/bin/aws-mcp-proxy", "win32"));
  const again = applyEntry(config, { name: "aws-mcp", command: BASH, launcher: LAUNCHER, description: "d", timeout: 300, platform: "win32" });
  assert.equal(again.conflict, false);
  assert.deepEqual(removeEntry(config, { name: "aws-mcp", command: LAUNCHER, platform: "win32" }).mcpServers, {});
});

test("merge-mcp：用户自建的同名条目（即使也用 bash.exe）不被覆盖或删除", () => {
  const user = { mcpServers: { "aws-mcp": { command: BASH, args: ["C:/tools/my-proxy.sh"] } } };
  assert.equal(applyEntry(user, { name: "aws-mcp", command: BASH, launcher: LAUNCHER, timeout: 300, platform: "win32" }).conflict, true);
  assert.deepEqual(removeEntry(user, { name: "aws-mcp", command: LAUNCHER, platform: "win32" }), user);
});

test("merge-mcp：Linux / macOS 条目保持 command=启动器、args=[]", () => {
  const { config } = applyEntry({}, { name: "aws-mcp", command: "/home/me/bin/aws-mcp-proxy", timeout: 300, platform: "linux" });
  assert.deepEqual(config.mcpServers["aws-mcp"].args, []);
});

test("merge-settings：Windows 的 shellPath 与 node.exe + npm-cli.js 形式的 self-update", () => {
  const update = selfUpdateCommand("C:/n/node.exe", "C:/p/npm-global", "C:/n/node_modules/npm/bin/npm-cli.js");
  assert.deepEqual(update, ["C:/n/node.exe", "C:/n/node_modules/npm/bin/npm-cli.js", "install", "-g", "--prefix", "C:/p/npm-global", "{installSpec}"]);
  assert.deepEqual(selfUpdateCommand("/n/npm", "/p"), ["/n/npm", "install", "-g", "--prefix", "/p", "{installSpec}"]);
  const opts = { provider: "amazon-bedrock", model: "m", thinking: "medium", snippet: "x # tag", tag: "tag", selfUpdate: update, shellPath: BASH };
  const applied = applySettings({ theme: "dark" }, opts);
  assert.equal(applied.shellPath, BASH);
  const removed = removeSettings(applied, { provider: "amazon-bedrock", model: "m", npmPrefix: "C:/p/npm-global", shellPath: BASH, tag: "tag", originals: { shellPath: null } });
  assert.equal(removed.shellPath, undefined);
  assert.equal(removed.theme, "dark");
});

test("merge-settings：卸载时不改动用户之后自行修改的 shellPath", () => {
  const current = { defaultProvider: "amazon-bedrock", defaultModel: "m", shellPath: "D:\\msys64\\usr\\bin\\bash.exe" };
  const removed = removeSettings(current, { provider: "amazon-bedrock", model: "m", shellPath: BASH, tag: "tag", originals: {} });
  assert.equal(removed.shellPath, "D:\\msys64\\usr\\bin\\bash.exe");
});
