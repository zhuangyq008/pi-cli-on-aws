// 受保护位置：护栏自身、pi 配置与扩展（含项目级 .pi）、包装器与安装目录、AWS CLI 配置、shell 启动文件。
// agent 修改这些位置可以持久地关闭护栏、替换 pi 或劫持后续 AWS 调用，因此写入一律需要人工确认；
// 其中凭证文件的读取同样需要确认。
// Windows：路径不区分大小写，可能混用 \ 与 /、C:\ 与 Git Bash 的 /c/ 形式，统一转换为小写的 c:/... 后比较。
import { posix, win32 } from "node:path";

export interface PathOptions {
  readonly agentDir?: string;
  readonly realpath?: (abs: string) => string | undefined;
  /** 默认 process.platform（测试中可指定 win32） */
  readonly platform?: string;
  /** 额外的受保护目录（Windows：当前用户可写的 Git for Windows 安装目录） */
  readonly extraRoots?: readonly string[];
}

const isWindows = (options: PathOptions): boolean => (options.platform ?? process.platform) === "win32";

// Windows 路径的比较键：c:/users/me/.aws
export function windowsKey(path: string): string {
  const key = path.replace(/\\/g, "/").replace(/^\/\/\?\//, "").toLowerCase();
  return key.length > 3 ? key.replace(/\/+$/, "") : key;
}

function expandHome(path: string, home: string, windows: boolean): string {
  if (path === "~") return home;
  if (path.startsWith("~/") || (windows && path.startsWith("~\\"))) return `${home}/${path.slice(2)}`;
  return path;
}

// 路径（及解析符号链接后的真实路径）的比较键。Windows 上 /c/Users/... 既可能是 Git Bash 的 C:\Users\...，
// 也可能是 Node 眼中当前盘符下的 \c\Users\...，两种解释都检查
function pathKeys(path: string, home: string, cwd: string, options: PathOptions): string[] {
  const windows = isWindows(options);
  const expanded = expandHome(path, home, windows);
  if (!windows) {
    const abs = posix.resolve(cwd, expanded);
    return [abs, options.realpath?.(abs)].filter((p): p is string => Boolean(p));
  }
  const msys = /^[\\/]([a-zA-Z])([\\/]|$)/.exec(expanded);
  const forms = msys ? [expanded, `${msys[1]}:/${expanded.slice(3)}`] : [expanded];
  return forms.flatMap((form) => {
    const abs = win32.resolve(cwd, form);
    return [abs, options.realpath?.(abs)].filter((p): p is string => Boolean(p)).map(windowsKey);
  });
}

function rootKey(root: string, options: PathOptions): string {
  return isWindows(options) ? windowsKey(win32.resolve(root)) : posix.resolve(root);
}

const under = (p: string, root: string): boolean => p === root || p.startsWith(root.endsWith("/") ? root : `${root}/`);

// Windows：PATH 是否位于 DIR 之下（不区分大小写，忽略 \ 与 / 的差异）
export function isUnderWindowsDir(path: string, dir: string): boolean {
  return under(windowsKey(win32.resolve(path)), windowsKey(win32.resolve(dir)));
}

// $HOME 下的 shell 启动文件：.bashrc*、.bash_*、.zsh*、.profile、.bashrc.d/ 等
function isRcFile(p: string, homeKey: string): boolean {
  if (!p.startsWith(`${homeKey}/`)) return false;
  const first = p.slice(homeKey.length + 1).split("/")[0];
  return /^\.(bash|zsh|profile|zprofile|zlogin|zlogout|login|logout|inputrc)/i.test(first);
}

export function isProtectedPath(path: string, home: string, cwd: string, options: PathOptions = {}): boolean {
  if (path === "") return false;
  const roots = [options.agentDir, `${home}/.pi`, `${home}/.local/share/pi-bedrock`, `${home}/.local/bin`, `${home}/.aws`, ...(options.extraRoots ?? [])]
    .filter((root): root is string => Boolean(root))
    .map((root) => rootKey(root, options));
  const homeKey = rootKey(home, options);
  return pathKeys(path, home, cwd, options).some((p) =>
    roots.some((root) => under(p, root)) || isRcFile(p, homeKey) || p.split("/").includes(".pi"),
  );
}

// read / grep / find / ls 工具：读取这些位置会把凭证带入模型上下文
export function isCredentialPath(path: string, home: string, cwd: string, options: PathOptions = {}): boolean {
  if (path === "") return false;
  const awsDir = rootKey(`${home}/.aws`, options);
  const agentDir = rootKey(options.agentDir ?? `${home}/.pi/agent`, options);
  const secrets = [`${agentDir}/auth.json`, `${agentDir}/mcp-auth.json`];
  return pathKeys(path, home, cwd, options).some((p) =>
    under(p, awsDir) || secrets.includes(p) || /^\/proc\/.+\/environ$/.test(p),
  );
}

// grep 在包含 ~/.aws 的范围内递归搜索也会读到凭证文件
export function searchesCredentialTree(path: string, home: string, cwd: string, options: PathOptions = {}): boolean {
  const awsDir = `${rootKey(`${home}/.aws`, options)}/`;
  return pathKeys(path || ".", home, cwd, { ...options, realpath: undefined }).some((p) =>
    awsDir.startsWith(p.endsWith("/") ? p : `${p}/`),
  );
}

// bash 命令文本（已去掉引号；反斜杠去掉或转换为 /）中提到受保护位置或护栏设置
export const PROTECTED_TEXT =
  /(^|[\s=:;|&(<>~/%])\.(pi|aws|local)(\/|\s|$|[;&|)])|pi-bedrock|\.(bash|zsh)\w*|\.(profile|zprofile|zlogin|inputrc)\b|PI_AWS_OPS_GUARD|PI_CODING_AGENT_DIR|PI_BEDROCK_/;

// 访问 AWS 凭证：容器凭证端点 / IMDS、凭证环境变量、进程环境、凭证缓存文件
export const CREDENTIAL_TEXT =
  /AWS_CONTAINER_|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_ACCESS_KEY_ID|169\.254\.170\.|169\.254\.169\.254|:1338\b|export-credentials|--aws-sigv4|\/proc\/\S*\/environ|\bcd\s+\/proc\b|\.aws\/(credentials|login|sso|cli)\b/;

// Windows 文件名不区分大小写（~/.AWS/Credentials 同样有效），文本检查也不区分大小写
const PROTECTED_TEXT_CI = new RegExp(PROTECTED_TEXT.source, "i");
const CREDENTIAL_TEXT_CI = new RegExp(CREDENTIAL_TEXT.source, "i");

export function protectedTextPattern(platform: string = process.platform): RegExp {
  return platform === "win32" ? PROTECTED_TEXT_CI : PROTECTED_TEXT;
}

export function credentialTextPattern(platform: string = process.platform): RegExp {
  return platform === "win32" ? CREDENTIAL_TEXT_CI : CREDENTIAL_TEXT;
}
