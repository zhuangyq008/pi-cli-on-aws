// 模拟 CloudShell 的容器凭证端点（AWS_CONTAINER_CREDENTIALS_FULL_URI + AWS_CONTAINER_AUTHORIZATION_TOKEN）。
// 仅监听 127.0.0.1，仅用于本地端到端测试。
// 输入环境变量：SIM_CREDS_FILE（`aws configure export-credentials --format process` 输出的 0600 文件）、SIM_TOKEN、SIM_LOG
import { createServer } from "node:http";
import { appendFileSync, readFileSync } from "node:fs";

const port = Number(process.argv[2] ?? 1338);
const token = process.env.SIM_TOKEN;
const logFile = process.env.SIM_LOG;
const source = JSON.parse(process.env.SIM_CREDS_FILE ? readFileSync(process.env.SIM_CREDS_FILE, "utf8") : "{}");
if (!token || !source.AccessKeyId) {
  process.stderr.write("creds-server: 缺少 SIM_TOKEN 或 SIM_CREDS_FILE\n");
  process.exit(2);
}

// 真实的 CloudShell/ECS 端点返回 "2026-01-01T00:00:00Z" 格式；`aws configure export-credentials`
// 输出的是 "+00:00" 偏移格式，JS SDK 的容器凭证解析器只接受 Z 结尾，因此这里统一规范化。
const expiration = new Date(source.Expiration ?? Date.now() + 3600_000).toISOString().replace(/\.\d{3}Z$/, "Z");

const body = JSON.stringify({
  Type: "AWS-HMAC",
  AccessKeyId: source.AccessKeyId,
  SecretAccessKey: source.SecretAccessKey,
  Token: source.SessionToken,
  Expiration: expiration,
  Code: "Success",
});

const server = createServer((req, res) => {
  const authorized = req.headers.authorization === token;
  const pathOk = req.url === "/latest/meta-data/container/security-credentials";
  if (logFile) appendFileSync(logFile, `${new Date().toISOString()} ${req.method} ${req.url} auth=${authorized}\n`);
  if (!pathOk) {
    res.writeHead(404).end();
  } else if (!authorized) {
    res.writeHead(401).end();
  } else {
    res.writeHead(200, { "content-type": "application/json" }).end(body);
  }
});

server.listen(port, "127.0.0.1", () => process.stdout.write(`ready ${port}\n`));
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => server.close(() => process.exit(0)));
