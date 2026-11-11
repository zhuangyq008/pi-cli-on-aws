// 审计日志脱敏：访问密钥 ID、密钥 / 令牌 / 密码类参数的值
const REDACTIONS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\b(AKIA|ASIA)[0-9A-Z]{16}\b/g, "$1****************"],
  [/((?:secret|token|password|passwd|pwd|credential|api[_-]?key)[A-Za-z_-]*["']?\s*[:=]\s*["']?)[^\s"',}]+/gi, "$1***"],
  [/(--(?:[a-z-]*password|[a-z-]*secret[a-z-]*|[a-z-]*token|api-key)[=\s]+)\S+/gi, "$1***"],
];

export function redact(text: string): string {
  return REDACTIONS.reduce((acc, [pattern, replacement]) => acc.replace(pattern, replacement), text);
}
