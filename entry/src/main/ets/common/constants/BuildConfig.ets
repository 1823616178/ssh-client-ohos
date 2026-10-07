import BuildProfile from 'BuildProfile';

/**
 * 构建期配置（DESIGN §6.5.1）。
 *
 * 字段由 entry/build-profile.json5 的 buildOptionSet[].arkOptions.buildProfileFields 在构建时生成
 * （构建产物见 entry/build/default/generated/profile/default/BuildProfile.ets），
 * 通过 hvigor 产出的 BuildProfile 类读取。这里只放非敏感项——HAP 是可解包的 zip，
 * 这些值在产物中就是明文常量，服务端密钥绝不能出现在这里。
 *
 * 关于默认值回退：ArkTS 是静态类型语言，字段「整个缺失」会在编译期直接报错（fail-fast，
 * 此时应检查 build-profile.json5 的配置是否生效）；这里的回退针对「值为空/非法」的情况
 * （例如误配了空字符串或 0），保证应用始终拿到可用值。
 *
 * ---------------------------------------------------------------------------
 * P6 HTTPS 就绪（docs/P6-HTTPS-READINESS.md，风险 R-8）
 * ---------------------------------------------------------------------------
 * `SYNC_API_URL` 可在运维完成「域名 + Let's Encrypt」后直接改为 `https://domain`，
 * 客户端无需改代码路径（仍拼 `/api/v1`）。在此之前：
 *   - 开发/联调地址为明文 `http://<ip>:<port>`；
 *   - `resources/base/profile/network_config.json` 的 cleartext 域名白名单必须保留
 *     （base-config 已 disallow cleartext，仅放行当前同步 IP）；
 *   - 账号同步等 UI 用 `shouldShowCleartextWarning()` 决定是否展示明文告警：
 *     URL 一旦以 `https://` 开头则跳过告警。
 * 运维切换清单见 P6 文档；删除 network_config.json 的 network 节点动作留给运维与上架阶段。
 */

/** true：URL 使用 https 方案（大小写不敏感） */
export function isHttpsApiUrl(url: string): boolean {
  return url.toLowerCase().startsWith('https://');
}

/**
 * 纯函数：当前同步 API 是否仍走明文 HTTP（或非法空串）。
 * UI 在 true 时展示明文风险提示；`SYNC_API_URL` 以 https:// 开头则 false（跳过告警）。
 */
export function shouldShowCleartextWarning(syncApiUrl: string): boolean {
  return !isHttpsApiUrl(syncApiUrl);
}

/** 根地址 → `/api/v1` 基础路径（去掉重复尾斜杠） */
function joinApiV1(root: string): string {
  const trimmed: string = root.endsWith('/') ? root.slice(0, root.length - 1) : root;
  return `${trimmed}/api/v1`;
}

/**
 * 解析同步 API 基础路径；有可用的 https 候选时优先 https（P6 切换后的调用形态）。
 *
 * @param configuredUrl 构建注入的根地址（BuildConfig.SYNC_API_URL）
 * @param preferredHttpsUrl 可选 https 候选（例如运维给出的域名）；非 https 或空则忽略
 */
export function syncApiBaseUrl(configuredUrl: string, preferredHttpsUrl?: string): string {
  if (preferredHttpsUrl !== undefined && preferredHttpsUrl.length > 0
    && isHttpsApiUrl(preferredHttpsUrl)) {
    return joinApiV1(preferredHttpsUrl);
  }
  return joinApiV1(configuredUrl);
}

export class BuildConfig {
  /**
   * 同步服务器根地址（不含 /api/v1），客户端在此基础上拼接具体端点。
   * P6：运维挂好域名与证书后，把 build-profile.json5 的 SYNC_API_URL 改为 `https://<domain>` 即可。
   */
  static readonly SYNC_API_URL: string =
    BuildProfile.SYNC_API_URL.length > 0 ? BuildProfile.SYNC_API_URL : 'http://123.161.179.32:46926';
  /** 同步 API 基础路径 */
  static readonly SYNC_API_BASE: string = BuildConfig.SYNC_API_URL + '/api/v1';
  /** 日志级别：debug 构建为 debug，release 构建为 info */
  static readonly LOG_LEVEL: string =
    BuildProfile.LOG_LEVEL.length > 0 ? BuildProfile.LOG_LEVEL : 'debug';
  /** 是否写日志文件（应用 files 目录，轮转策略见下两个字段） */
  static readonly LOG_TO_FILE: boolean = BuildProfile.LOG_TO_FILE;
  /** 单个日志文件最大字节数，默认 5 MiB */
  static readonly LOG_MAX_BYTES: number =
    BuildProfile.LOG_MAX_BYTES > 0 ? BuildProfile.LOG_MAX_BYTES : 5242880;
  /** 日志文件保留个数 */
  static readonly LOG_MAX_FILES: number =
    BuildProfile.LOG_MAX_FILES > 0 ? BuildProfile.LOG_MAX_FILES : 3;

  /**
   * 当前构建同步 API 是否已切 HTTPS（读 BuildConfig.SYNC_API_URL）。
   * P6 完成前恒为 false；切换 buildProfileFields 后自动变 true，无需改 UI 判断逻辑。
   */
  static isSyncApiHttps(): boolean {
    return isHttpsApiUrl(BuildConfig.SYNC_API_URL);
  }

  /** 当前构建是否应展示明文 HTTP 告警（https 时跳过） */
  static shouldShowCleartextWarning(): boolean {
    return shouldShowCleartextWarning(BuildConfig.SYNC_API_URL);
  }

  /**
   * 同步 API 基础路径；若传入可用的 https 候选则优先之，否则用构建期 SYNC_API_URL。
   * 等价于既有 `SYNC_API_BASE`，并为 P6 的 https 优先解析留出纯函数出口。
   */
  static syncApiBaseUrl(preferredHttpsUrl?: string): string {
    return syncApiBaseUrl(BuildConfig.SYNC_API_URL, preferredHttpsUrl);
  }
}
