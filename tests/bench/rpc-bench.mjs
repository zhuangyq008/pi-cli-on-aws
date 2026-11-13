// 以 RPC 模式驱动 pi 执行一个运维任务，采集 token 用量、轮数、工具调用与耗时。
// 护栏确认框：仅当所有原因都是"需要 AWS 凭证：<op>（只读）"时自动批准（模拟用户点"执行一次"），其余一律拒绝。
// 用法: node rpc-bench.mjs <pi 包装器> <prompt> [timeoutSeconds]
// 输出（stdout，单行 JSON）: { durationMs, firstTokenMs, turns, usage, toolCalls, approvals, denials, finalText, error? }
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const [wrapper, prompt, timeoutArg] = process.argv.slice(2);
if (!wrapper || !prompt) {
  process.stderr.write("用法: node rpc-bench.mjs <pi> <prompt> [timeoutSeconds]\n");
  process.exit(64);
}
const APPROVE = "执行一次";
const DENY = "拒绝";
// 只接受 "<service> <operation>（只读）" 形状，service / operation 只含小写字母、数字、连字符
const READ_ONLY_REASON = /^• 需要 AWS 凭证：[a-z0-9-]+ [a-z0-9-]+（只读）$/;

/** 确认框标题中以 "• " 开头的行就是护栏给出的原因 */
function isReadOnlyCredentialPrompt(title) {
  const reasons = String(title ?? "").split("\n").filter((line) => line.startsWith("• "));
  return reasons.length > 0 && reasons.every((line) => READ_ONLY_REASON.test(line));
}

const ZERO_USAGE = Object.freeze({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: 0 });
const addUsage = (acc, u = {}) => ({
  input: acc.input + (u.input ?? 0),
  output: acc.output + (u.output ?? 0),
  cacheRead: acc.cacheRead + (u.cacheRead ?? 0),
  cacheWrite: acc.cacheWrite + (u.cacheWrite ?? 0),
  totalTokens: acc.totalTokens + (u.totalTokens ?? (u.input ?? 0) + (u.output ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0)),
  cost: acc.cost + (typeof u.cost === "object" ? (u.cost?.total ?? 0) : (u.cost ?? 0)),
});
const textOf = (message) => (message?.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");

const start = Date.now();
let state = {
  firstTokenMs: undefined,
  turns: 0,
  maxContextInput: 0,
  usage: ZERO_USAGE,
  toolCalls: [],
  toolErrors: 0,
  toolResultChars: 0,
  approvals: [],
  denials: [],
  finalText: "",
  stopReasons: [],
  finished: false,
};

const child = spawn(wrapper, ["--mode", "rpc", "--no-session"], { stdio: ["pipe", "pipe", "inherit"] });
const send = (obj) => child.stdin.write(`${JSON.stringify(obj)}\n`);
const finish = (error) => {
  const out = { ...state, durationMs: Date.now() - start, ...(error ? { error } : {}) };
  process.stdout.write(`${JSON.stringify(out)}\n`);
  child.kill("SIGTERM");
  process.exit(error ? 1 : 0);
};
const timer = setTimeout(() => finish("timeout"), Number(timeoutArg ?? 600) * 1000);

function onEvent(event) {
  if (event.type === "extension_ui_request" && event.method === "select") {
    const ok = isReadOnlyCredentialPrompt(event.title);
    const entry = String(event.title ?? "").split("\n").filter((l) => l.startsWith("• ")).join(" | ").slice(0, 300);
    state = ok ? { ...state, approvals: [...state.approvals, entry] } : { ...state, denials: [...state.denials, entry] };
    send({ type: "extension_ui_response", id: event.id, value: ok ? APPROVE : DENY });
  } else if (event.type === "extension_ui_request" && event.method === "confirm") {
    state = { ...state, denials: [...state.denials, `confirm: ${String(event.title ?? "").slice(0, 200)}`] };
    send({ type: "extension_ui_response", id: event.id, confirmed: false });
  } else if (event.type === "message_update" && state.firstTokenMs === undefined) {
    state = { ...state, firstTokenMs: Date.now() - start };
  } else if (event.type === "message_end" && event.message?.role === "assistant") {
    const u = event.message.usage ?? {};
    const ctxIn = (u.input ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0);
    state = {
      ...state,
      turns: state.turns + 1,
      usage: addUsage(state.usage, u),
      maxContextInput: Math.max(state.maxContextInput, ctxIn),
      stopReasons: [...state.stopReasons, event.message.stopReason],
      finalText: textOf(event.message) || state.finalText,
    };
  } else if (event.type === "tool_execution_start") {
    state = { ...state, toolCalls: [...state.toolCalls, event.toolName] };
  } else if (event.type === "tool_execution_end") {
    const chars = JSON.stringify(event.result ?? "").length;
    state = { ...state, toolErrors: state.toolErrors + (event.isError ? 1 : 0), toolResultChars: state.toolResultChars + chars };
  } else if (event.type === "agent_end") {
    state = { ...state, finished: true };
    clearTimeout(timer);
    finish();
  }
}

createInterface({ input: child.stdout }).on("line", (line) => {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return;
  }
  onEvent(event);
});
child.on("exit", (code) => {
  if (!state.finished) finish(`pi exited with code ${code}`);
});

send({ id: "bench-1", type: "prompt", message: prompt });
