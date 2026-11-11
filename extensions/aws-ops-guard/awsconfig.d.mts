// awsconfig.mjs 的类型声明（供 TypeScript 模块导入）
export declare const SAFE_CONFIG_KEYS: ReadonlySet<string>;
export declare const SAFE_CREDENTIAL_KEYS: ReadonlySet<string>;
export declare function awsConfigIssues(text: string): string[];
export declare function sanitizeAwsConfig(text: string, kind: "config" | "credentials"): string;
