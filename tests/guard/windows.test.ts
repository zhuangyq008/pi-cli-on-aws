// aws-ops-guard 的 Windows 路径与命令处理（platform: "win32"，在任意平台上运行）
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  assessBashCommand,
  buildStrictCommand,
  decideBash,
  isCredentialPath,
  isProtectedPath,
  localScriptFindings,
  searchesCredentialTree,
} from "../../extensions/aws-ops-guard/classify.ts";
import { protectedTextPattern } from "../../extensions/aws-ops-guard/paths.ts";

const HOME = "C:\\Users\\Me";
const CWD = "C:\\work\\proj";
const WIN = { platform: "win32", agentDir: "C:/Users/Me/.pi/agent" } as const;

test("Windows：凭证路径的各种写法（反斜杠、正斜杠、Git Bash /c/、~\\、大小写、相对路径）都识别", () => {
  for (const p of [
    "C:\\Users\\Me\\.aws\\credentials",
    "c:/users/me/.AWS/Credentials",
    "/c/Users/Me/.aws/config",
    "~\\.aws\\credentials",
    "~/.aws/sso/cache/x.json",
    "..\\..\\Users\\Me\\.aws\\credentials",
    "\\\\?\\C:\\Users\\Me\\.aws\\credentials",
    "C:/Users/Me/.pi/agent/auth.json",
  ]) {
    assert.equal(isCredentialPath(p, HOME, CWD, WIN), true, p);
  }
  for (const p of ["C:\\Users\\Me\\project\\aws.txt", "D:\\Users\\Me\\.aws\\credentials", "C:\\Users\\Me\\.awsx\\c"]) {
    assert.equal(isCredentialPath(p, HOME, CWD, WIN), false, p);
  }
});

test("Windows：受保护位置（pi 配置、安装目录、.local\\bin、~/.bashrc、项目级 .pi）", () => {
  for (const p of [
    "C:\\Users\\Me\\.pi\\agent\\settings.json",
    "c:/users/me/.local/share/pi-bedrock/env",
    "/c/Users/Me/.local/bin/pi.cmd",
    "C:\\Users\\Me\\.BashRC",
    "C:\\work\\proj\\.pi\\extensions\\x.ts",
    ".pi\\settings.json",
  ]) {
    assert.equal(isProtectedPath(p, HOME, CWD, WIN), true, p);
  }
  assert.equal(isProtectedPath("C:\\work\\proj\\src\\index.ts", HOME, CWD, WIN), false);
});

test("Windows：realpath 解析（8.3 短路径 / 目录联接）后的路径也参与判断", () => {
  const realpath = (abs: string): string | undefined => (abs.toLowerCase() === "c:\\link\\creds" ? "C:\\Users\\Me\\.aws\\credentials" : undefined);
  assert.equal(isCredentialPath("C:\\link\\creds", HOME, CWD, { ...WIN, realpath }), true);
});

test("Windows：grep 在包含 ~/.aws 的目录树中搜索需要确认", () => {
  assert.equal(searchesCredentialTree("C:\\Users", HOME, CWD, WIN), true);
  assert.equal(searchesCredentialTree("/c/", HOME, CWD, WIN), true);
  assert.equal(searchesCredentialTree("C:\\work", HOME, CWD, WIN), false);
  assert.equal(searchesCredentialTree("", HOME, "C:\\Users\\Me", WIN), true);
});

test("bash：Windows 路径写法（引号内反斜杠、%USERPROFILE%、大写）访问凭证 / 受保护位置都需要确认", () => {
  for (const cmd of [
    "cat 'C:\\Users\\Me\\.aws\\credentials'",
    'type "%USERPROFILE%\\.aws\\credentials"',
    "powershell.exe -c \"gc $env:USERPROFILE\\.aws\\credentials\"",
    "cat ~/.AWS/CREDENTIALS",
    "echo x >> 'C:\\Users\\Me\\.pi\\agent\\settings.json'",
  ]) {
    assert.ok(assessBashCommand(cmd, { platform: "win32", home: "/c/Users/Me", cwd: "/c/work" }).guardFindings.length > 0, cmd);
  }
});

test("bash：aws.exe / 带路径的 aws.exe 被识别为 AWS 调用", () => {
  for (const cmd of ["aws.exe s3 ls", "'/c/Program Files/Amazon/AWSCLIV2/aws.exe' ec2 terminate-instances --instance-ids i-1"]) {
    assert.ok(assessBashCommand(cmd, { platform: "win32" }).awsLabels.length > 0, cmd);
  }
});

test("本地脚本：引号拼接的 .aws 路径（Path.home() / \".aws\"）被识别", () => {
  const py = 'from pathlib import Path\nprint((Path.home() / ".aws" / "credentials").read_text())';
  assert.ok(localScriptFindings(py, "python").some((f) => f.includes("受保护")));
  const pyWin = 'open("C:\\\\Users\\\\Me\\\\.aws\\\\credentials").read()';
  assert.ok(localScriptFindings(pyWin, "python").some((f) => f.includes("凭证") || f.includes("受保护")));
});

test("Windows 文本检查不区分大小写；其他平台保持区分", () => {
  assert.equal(protectedTextPattern("win32").test("cat ~/.AWS/config"), true);
  assert.equal(protectedTextPattern("linux").test("cat ~/.AWS/config"), false);
});

test("严格只读命令（Windows）：aws 进程的 USERPROFILE 也指向快照，其余与 Linux 相同", () => {
  const assessment = assessBashCommand("aws sts get-caller-identity --query Account --output text", {});
  assert.ok(assessment.strict);
  const snapshot = { node: "C:/Users/Me/.local/share/pi-bedrock/node/node.exe", script: "C:/Users/Me/.pi/agent/extensions/aws-ops-guard/snapshot.mjs" };
  const awsPath = "C:/Program Files/Amazon/AWSCLIV2/aws.exe";
  const win = buildStrictCommand(assessment.strict, awsPath, snapshot, true);
  assert.match(win, /"USERPROFILE=\$__pi_awshome"/);
  assert.match(win, /'C:\/Program Files\/Amazon\/AWSCLIV2\/aws\.exe' 'sts' 'get-caller-identity'/);
  assert.doesNotMatch(buildStrictCommand(assessment.strict, "/usr/bin/aws", snapshot), /USERPROFILE/);
  const decision = decideBash(assessment, { awsPath, snapshot, windows: true });
  assert.equal(decision.action, "run-with-credentials");
  assert.ok(decision.action === "run-with-credentials" && decision.command.includes("USERPROFILE="));
});

test("安全审查 H1：8.3 短文件名、路径段末尾的 .、NTFS 备用数据流都需要确认", () => {
  for (const cmd of [
    "cat ~/AWS~1/credentials",
    "cat ~/.aws./credentials",
    "cat ~/.aws:x/credentials",
    "echo x >> ~/PI~1/agent/settings.json",
    "echo x >> ~/BASHRC~1",
    "cat 'C:\\Users\\Me\\.aws. \\credentials'",
  ]) {
    assert.ok(assessBashCommand(cmd, { platform: "win32" }).guardFindings.length > 0, cmd);
  }
  // 不影响 git 的 HEAD~1 等常见写法
  for (const cmd of ["git diff HEAD~1", "git log -3 --oneline", "ls -la", "cat ./README.md"]) {
    assert.deepEqual(assessBashCommand(cmd, { platform: "win32" }).guardFindings, [], cmd);
  }
});

test("安全审查 H2：从 bash 调用 powershell / cmd / setx / reg 等需要确认", () => {
  for (const cmd of [
    "powershell -c \"gc ($env:USERPROFILE+'\\.a'+'ws\\credentials')\"",
    "cmd /c \"type %USERPROFILE%\\.a^ws\\credentials\"",
    "pwsh -enc ZQBjAGgAbwA=",
    "powershell.exe -EncodedCommand ZQBjAGgAbwA=",
    "setx ProgramW6432 C:\\evil",
    "reg add HKCU\\Environment /v ProgramFiles /d C:\\evil",
    "'C:\\Windows\\System32\\cmd.exe' /c dir",
    "ls | xargs cmd /c echo",
    "wsl cat /mnt/c/Users/Me/.aws/credentials",
  ]) {
    assert.ok(assessBashCommand(cmd, { platform: "win32" }).guardFindings.length > 0, cmd);
  }
  // Linux / macOS 上不受影响；Git Bash 内的 bash -c 仍做递归分析
  assert.deepEqual(assessBashCommand("cmd /c dir", { platform: "linux" }).guardFindings, []);
  assert.deepEqual(assessBashCommand("bash -c 'ls -la'", { platform: "win32" }).guardFindings, []);
});

test("安全审查 H3：Git for Windows 在用户目录时，修改其中的 bash.exe / env.exe 需要确认", () => {
  const options = { platform: "win32", windowsGitRoot: "C:\\Users\\Me\\AppData\\Local\\Programs\\Git" } as const;
  for (const cmd of [
    "cp evil.exe /usr/bin/env.exe",
    "mv /bin/bash.exe /tmp/x",
    "echo 'exec evil' >> /etc/profile",
    "cp evil.exe 'C:\\Users\\Me\\AppData\\Local\\Programs\\Git\\usr\\bin\\env.exe'",
    "cd ~/AppData/Local/Programs/Git && mv bin/bash.exe x",
  ]) {
    assert.ok(assessBashCommand(cmd, options).guardFindings.length > 0, cmd);
  }
  // 只读使用不提示；Git 安装在 Program Files（未设置 windowsGitRoot）时不提示
  assert.deepEqual(assessBashCommand("/usr/bin/env python3 --version", options).guardFindings, []);
  assert.deepEqual(assessBashCommand("cp evil.exe /usr/bin/env.exe", { platform: "win32" }).guardFindings, []);
  const roots = { platform: "win32", extraRoots: [options.windowsGitRoot] } as const;
  assert.equal(isProtectedPath("C:/Users/Me/AppData/Local/Programs/Git/usr/bin/env.exe", HOME, CWD, roots), true);
  assert.equal(isProtectedPath("C:/Users/Me/AppData/Local/Programs/Other/x.exe", HOME, CWD, roots), false);
});

test("安全复验 N1 / N2：相对路径的 8.3 短名、动态命令名、-exec / eval 之后的解释器", () => {
  for (const cmd of [
    "cat AWS~1/credentials",
    "cat AWS~1/*",
    "cat *WS~1/cred*",
    "pushd AWS~1",
    "for f in AWS~1/*; do cat $f; done",
    "cd \"$(cygpath $USERPROFILE)\" && cat AWS~1/credentials",
    "c=cmd; $c /c x",
    "x=powershell; \"$x\" -enc AA",
    "find . -exec powershell -enc AA \;",
    "eval cmd /c x",
    "eval \"$x\"",
    "`echo cmd` /c dir",
  ]) {
    assert.ok(assessBashCommand(cmd, { platform: "win32" }).guardFindings.length > 0, cmd);
  }
  for (const cmd of ["git diff HEAD~1", "git rebase -i origin/main~3", "git log stash@{0}~1", "git log main~1..HEAD", "echo done"]) {
    assert.deepEqual(assessBashCommand(cmd, { platform: "win32" }).guardFindings, [], cmd);
  }
});

test("安全复验 NEW-1 / NEW-2：git 不再整段豁免 8.3 检查；~ 后的数字来自展开时同样识别", () => {
  for (const cmd of [
    "git diff --no-index /dev/null ~/AWS~1/credentials",
    "git hash-object -w AWS~1/credentials",
    "git config --file AWS~1/config -l",
    "git grep --no-index -r . AWS~1",
    "git -C AWS~1 status",
    "n=1; cat AWS~$n/credentials",
    "cat AWS~${n}/credentials",
    "cat AWS~$((1))/credentials",
  ]) {
    assert.ok(assessBashCommand(cmd, { platform: "win32" }).guardFindings.length > 0, cmd);
  }
  // ~ 位于词首（HOME 展开）不受影响
  assert.deepEqual(assessBashCommand("ls ~/project", { platform: "win32" }).guardFindings, []);
});
