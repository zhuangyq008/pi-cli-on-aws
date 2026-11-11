// 以 RPC 模式驱动 pi，模拟"交互用户在写操作确认框中选择拒绝"。
// 用法: node rpc-deny.mjs <pi 包装器> <prompt> [timeoutSeconds]
// 输出（stdout，JSON）: { selects: [{title, options}], toolCalls: [...], blocked: [...], finished, error? }
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const [wrapper, prompt, timeoutArg] = process.argv.slice(2);
if (!wrapper || !prompt) {
  process.stderr.write("用法: node rpc-deny.mjs <pi> <prompt> [timeoutSeconds]\n");
  process.exit(64);
}
const DENY = "拒绝";
const summary = { selects: [], toolCalls: [], blocked: [], finished: false };

const child = spawn(wrapper, ["--mode", "rpc", "--no-session"], { stdio: ["pipe", "pipe", "inherit"] });
const send = (obj) => child.stdin.write(`${JSON.stringify(obj)}\n`);
const finish = (error) => {
  if (error) summary.error = error;
  process.stdout.write(`${JSON.stringify(summary)}\n`);
  child.kill("SIGTERM");
  process.exit(error ? 1 : 0);
};
const timer = setTimeout(() => finish("timeout"), Number(timeoutArg ?? 300) * 1000);

createInterface({ input: child.stdout }).on("line", (line) => {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return;
  }
  if (event.type === "extension_ui_request" && event.method === "select") {
    summary.selects.push({ title: event.title, options: event.options });
    send({ type: "extension_ui_response", id: event.id, value: DENY });
  } else if (event.type === "extension_ui_request" && event.method === "confirm") {
    send({ type: "extension_ui_response", id: event.id, confirmed: false });
  } else if (event.type === "tool_execution_start") {
    summary.toolCalls.push(event.toolName);
  } else if (event.type === "tool_execution_end" && event.isError) {
    summary.blocked.push(JSON.stringify(event.result ?? "").slice(0, 300));
  } else if (event.type === "agent_end") {
    summary.finished = true;
    clearTimeout(timer);
    finish();
  }
});
child.on("exit", (code) => {
  if (!summary.finished) finish(`pi exited with code ${code}`);
});

send({ id: "e2e-1", type: "prompt", message: prompt });
