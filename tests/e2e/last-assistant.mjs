// 从 pi --mode json 事件流（stdin）中取最后一条助手消息，输出 JSON：{ provider, model, stopReason, text }
// 不能直接 grep 事件流：其中会回显用户 prompt，失败的助手消息也带 provider 字段。
import { readFileSync } from "node:fs";

let last;
for (const line of readFileSync(0, "utf8").split("\n")) {
  try {
    const event = JSON.parse(line);
    if (event.type === "message_end" && event.message?.role === "assistant") last = event.message;
  } catch {
    // 非 JSON 行（例如 stderr 混入）忽略
  }
}
const text = (last?.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");
process.stdout.write(`${JSON.stringify({ provider: last?.provider, model: last?.model, stopReason: last?.stopReason, text })}\n`);
