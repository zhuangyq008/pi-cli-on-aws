// 汇总 bench 结果为 Markdown 报告。
// 用法: node report.mjs <results 目录> <tasks.tsv>
// BENCH_REPORT_ANSWERS=0：不输出工具调用序列与最终回答（用于公开文档，回答中含账号的成本 / 资源数据）
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [dir, tasksFile] = process.argv.slice(2);
const tasks = readFileSync(tasksFile, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t")[0]);
const ARMS = ["mcp", "cli"];
const LABEL = { mcp: process.env.BENCH_LABEL_MCP ?? "MCP+Skills", cli: "纯 CLI" };

const runs = readdirSync(dir)
  .filter((f) => f.endsWith(".json"))
  .map((f) => {
    const [task, arm, rep] = f.replace(/\.json$/, "").split(".");
    try {
      return { task, arm, rep, ...JSON.parse(readFileSync(join(dir, f), "utf8")) };
    } catch {
      return { task, arm, rep, error: "结果无法解析" };
    }
  });

const avg = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN);
const fmt = (n, d = 0) => (Number.isFinite(n) ? n.toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: d }) : "-");
const pct = (a, b) => (Number.isFinite(a) && Number.isFinite(b) && b !== 0 ? `${a >= b ? "+" : ""}${(((a - b) / b) * 100).toFixed(0)}%` : "-");

function summarize(rs) {
  const ok = rs.filter((r) => !r.error && r.usage);
  const pick = (f) => avg(ok.map(f));
  return {
    n: rs.length,
    failed: rs.length - ok.length,
    seconds: pick((r) => r.durationMs / 1000),
    turns: pick((r) => r.turns),
    tools: pick((r) => r.toolCalls.length),
    toolErrors: pick((r) => r.toolErrors),
    approvals: pick((r) => r.approvals.length),
    denials: pick((r) => r.denials.length),
    input: pick((r) => r.usage.input),
    output: pick((r) => r.usage.output),
    cacheRead: pick((r) => r.usage.cacheRead),
    cacheWrite: pick((r) => r.usage.cacheWrite),
    total: pick((r) => r.usage.totalTokens),
    maxCtx: pick((r) => r.maxContextInput),
    toolResultKB: pick((r) => r.toolResultChars / 1024),
    cost: pick((r) => r.usage.cost),
  };
}

const ROWS = [
  ["耗时（秒）", "seconds", 1],
  ["模型调用轮数", "turns", 1],
  ["工具调用次数", "tools", 1],
  ["工具报错次数", "toolErrors", 1],
  ["护栏自动批准 / 拒绝", null],
  ["input tokens", "input", 0],
  ["output tokens（含 thinking）", "output", 0],
  ["cacheRead tokens", "cacheRead", 0],
  ["cacheWrite tokens", "cacheWrite", 0],
  ["**总 tokens**", "total", 0],
  ["单轮最大上下文", "maxCtx", 0],
  ["工具返回量（KB）", "toolResultKB", 1],
  ["估算费用（USD）", "cost", 4],
];

function table(title, m, c) {
  const lines = [`### ${title}`, "", `| 指标 | ${LABEL.mcp} | ${LABEL.cli} | MCP 相对 CLI |`, "|---|---:|---:|---:|"];
  for (const [name, key, d] of ROWS) {
    if (!key) {
      lines.push(`| ${name} | ${fmt(m.approvals, 1)} / ${fmt(m.denials, 1)} | ${fmt(c.approvals, 1)} / ${fmt(c.denials, 1)} | |`);
      continue;
    }
    lines.push(`| ${name} | ${fmt(m[key], d)} | ${fmt(c[key], d)} | ${pct(m[key], c[key])} |`);
  }
  if (m.failed || c.failed) lines.push("", `失败运行：MCP ${m.failed}/${m.n}，CLI ${c.failed}/${c.n}`);
  return lines.join("\n");
}

const out = ["# pi AWS 运维 benchmark：MCP+Skills vs 纯 CLI", ""];
const totals = { mcp: [], cli: [] };
for (const task of tasks) {
  const per = Object.fromEntries(ARMS.map((a) => [a, runs.filter((r) => r.task === task && r.arm === a)]));
  if (!per.mcp.length && !per.cli.length) continue;
  ARMS.forEach((a) => totals[a].push(...per[a]));
  out.push(table(`任务 ${task}`, summarize(per.mcp), summarize(per.cli)), "");
  if (process.env.BENCH_REPORT_ANSWERS === "0") continue; // 公开文档：不输出模型回答（含账号数据）
  out.push("<details><summary>工具调用序列与最终回答</summary>", "");
  for (const r of [...per.mcp, ...per.cli]) {
    out.push(`**${LABEL[r.arm]} #${r.rep}**${r.error ? `（错误：${r.error}）` : ""}`, "");
    out.push(`- 工具：${(r.toolCalls ?? []).join(" → ") || "无"}`);
    if (r.approvals?.length) out.push(`- 自动批准：${r.approvals.join("；")}`);
    if (r.denials?.length) out.push(`- 拒绝：${r.denials.join("；")}`);
    out.push("", "```text", String(r.finalText ?? "").slice(0, 1500), "```", "");
  }
  out.push("</details>", "");
}
out.push(table("全部任务平均（每个任务）", summarize(totals.mcp), summarize(totals.cli)), "");
process.stdout.write(`${out.join("\n")}\n`);
