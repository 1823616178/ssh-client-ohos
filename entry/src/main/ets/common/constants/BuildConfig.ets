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
 */

export class BuildConfig {
  /** 同步服务器根地址（不含 /api/v1），客户端在此基础上拼接具体端点 */
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
}
