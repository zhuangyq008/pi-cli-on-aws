// 受保护位置：护栏自身、pi 配置与扩展（含项目级 .pi）、包装器与安装目录、AWS CLI 配置、shell 启动文件。
// agent 修改这些位置可以持久地关闭护栏、替换 pi 或劫持后续 AWS 调用，因此写入一律需要人工确认；
// 其中凭证文件的读取同样需要确认。
import { posix } from "node:path";

export interface PathOptions {
  readonly agentDir?: string;
  readonly realpath?: (abs: string) => string | undefined;
}

// $HOME 下的 shell 启动文件：.bashrc*、.bash_*、.zsh*、.profile、.bashrc.d/ 等
function isRcFile(abs: string, home: string): boolean {
  if (!abs.startsWith(`${home}/`)) return false;
  const first = abs.slice(home.length + 1).split("/")[0];
  return /^\.(bash|zsh|profile|zprofile|zlogin|zlogout|login|logout|inputrc)/.test(first);
}

function resolvePaths(path: string, home: string, cwd: string, options: PathOptions): string[] {
  const expanded = path === "~" ? home : path.startsWith("~/") ? `${home}${path.slice(1)}` : path;
  const abs = posix.resolve(cwd, expanded);
  const real = options.realpath?.(abs);
  return [abs, real].filter((p): p is string => Boolean(p));
}

export function isProtectedPath(path: string, home: string, cwd: string, options: PathOptions = {}): boolean {
  if (path === "") return false;
  const roots = [options.agentDir, `${home}/.pi`, `${home}/.local/share/pi-bedrock`, `${home}/.local/bin`, `${home}/.aws`]
    .filter((root): root is string => Boolean(root))
    .map((root) => posix.resolve(root));
  return resolvePaths(path, home, cwd, options).some((p) =>
    roots.some((root) => p === root || p.startsWith(`${root}/`)) || isRcFile(p, home) || p.split("/").includes(".pi"),
  );
}

// read / grep / find / ls 工具：读取这些位置会把凭证带入模型上下文
export function isCredentialPath(path: string, home: string, cwd: string, options: PathOptions = {}): boolean {
  if (path === "") return false;
  const agentDir = options.agentDir ?? `${home}/.pi/agent`;
  return resolvePaths(path, home, cwd, options).some((p) =>
    p === `${home}/.aws` || p.startsWith(`${home}/.aws/`) ||
    p === `${agentDir}/auth.json` || p === `${agentDir}/mcp-auth.json` ||
    /^\/proc\/.+\/environ$/.test(p),
  );
}

// bash 命令文本（已去掉引号与反斜杠）中提到受保护位置或护栏设置
export const PROTECTED_TEXT =
  /(^|[\s=:;|&(<>~/])\.(pi|aws|local)(\/|\s|$|[;&|)])|pi-bedrock|\.(bash|zsh)\w*|\.(profile|zprofile|zlogin|inputrc)\b|PI_AWS_OPS_GUARD|PI_CODING_AGENT_DIR|PI_BEDROCK_/;

// 访问 AWS 凭证：容器凭证端点 / IMDS、凭证环境变量、进程环境、凭证缓存文件
export const CREDENTIAL_TEXT =
  /AWS_CONTAINER_|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_ACCESS_KEY_ID|169\.254\.170\.|169\.254\.169\.254|:1338\b|export-credentials|--aws-sigv4|\/proc\/\S*\/environ|\bcd\s+\/proc\b|\.aws\/(credentials|login|sso|cli)\b/;
