/**
 * 主机凭据存储（DESIGN §5.1 / D6，任务 C2）。
 *
 * 密码、私钥密码短语、私钥内容存 @ohos.security.asset（@kit.AssetStoreKit），
 * 等价桌面端 safeStorage：明文只进出 ASSET 系统服务（加密存储于系统区），
 * 不落应用沙箱；不显式设置 IS_PERSISTENT（默认 false），卸载应用即被系统清除——
 * 验收标准「hdc 导出沙箱无明文 / 卸载后不可恢复」依赖该系统属性，实现侧保证
 * 不绕开 ASSET 自行落盘，两条均列为真机待验项。
 * 账号 token / Vault key 缓存属 M5 同步任务，不在本文件范围，别名方案已预留命名空间。
 *
 * 别名方案（唯一声明处，纯函数可测）：
 *   host_secret:<hostId>:<kind>   主机凭据，kind ∈ password / passphrase / private_key
 *   sync_token:<name>             （预留）M5 云端同步账号 token
 *   vault_key:<name>              （预留）M5 Vault key 缓存
 * hostId 为 HostProfile.id（UUID，只含十六进制与连字符，不含冒号），按冒号切分无歧义。
 *
 * 使用方式（全部为异步 Promise API，无需 context/init）：
 *   await CredentialStore.setSecret(host.id, 'password', secret);
 *   const pwd: string | null = await CredentialStore.getSecret(host.id, 'password');
 *   await CredentialStore.removeSecret(host.id, 'password');
 *   await CredentialStore.removeAllSecrets(host.id);  // 删除主机时级联清理三种凭据
 *
 * 错误策略（与 C1 DAO 惯例一致，调用方只依赖「null = 不存在」「抛 SshError = 失败」）：
 *   - 别名不存在（24000002 NOT_FOUND）：getSecret 返回 null，removeSecret 幂等成功；
 *   - 别名冲突（24000003 DUPLICATED）：setSecret 内部 add 转 update，调用方无感；
 *   - 其余故障（服务不可用 / 参数错误 / 加密失败等）：Logger.error 记录后抛
 *     SshError(SshErrorCode.INTERNAL_ERROR)。分类逻辑见 classifyAssetError（纯函数，可测）。
 *
 * 纪律：任何日志不得包含凭据明文，只记录操作名与别名（别名不含秘密本体）；
 * Logger 另有 sanitize 脱敏兜底。
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { SshError, SshErrorCode } from '../common/SshError';
import { Logger } from '../common/utils/Logger';

const LOG_TAG: string = 'CredentialStore';

/** 主机凭据别名前缀 */
const ALIAS_PREFIX_HOST_SECRET: string = 'host_secret:';
/** 预留命名空间（M5 使用，本文件不产出）：sync_token:<name> / vault_key:<name> */

/**
 * 凭据种类：password 登录密码 / passphrase 私钥密码短语 / private_key 私钥内容（PEM 文本）。
 * 字符串字面量联合类型（与 models 中 authType 等枚举字段同风格）。
 */
export type CredentialKind = 'password' | 'passphrase' | 'private_key';

/** 全部凭据种类：removeAllSecrets 级联删除与测试完整性校验的唯一来源 */
export const ALL_CREDENTIAL_KINDS: CredentialKind[] = ['password', 'passphrase', 'private_key'];

/**
 * asset.ErrorCode.NOT_FOUND（24000002）：别名不存在。
 * 数值与 @ohos.security.asset.d.ts 对拍（单测断言防漂移）；本地常量而非引用
 * asset.ErrorCode 运行时枚举，保证纯逻辑判定不依赖系统服务加载。
 */
export const ASSET_ERROR_NOT_FOUND: number = 24000002;
/** asset.ErrorCode.DUPLICATED（24000003）：add 时别名已存在 */
export const ASSET_ERROR_DUPLICATED: number = 24000003;

/** asset 调用结果分类：决定上层语义是「归一正常」还是「抛真故障」 */
export enum AssetErrorCategory {
  /** 别名不存在：查询归一为 null，删除归一为幂等成功 */
  NOT_FOUND = 0,
  /** 别名已存在：add 冲突，由 setSecret 转 update */
  DUPLICATED = 1,
  /** 其余一切（服务不可用 / 参数错误 / 加密失败 / 非 BusinessError 等）：记日志抛 SshError */
  FATAL = 2
}

/** 把 asset 抛出的 BusinessError.code 分类为「不存在 / 冲突 / 真故障」（纯判定，可测） */
export function classifyAssetError(code: number): AssetErrorCategory {
  if (code === ASSET_ERROR_NOT_FOUND) {
    return AssetErrorCategory.NOT_FOUND;
  }
  if (code === ASSET_ERROR_DUPLICATED) {
    return AssetErrorCategory.DUPLICATED;
  }
  return AssetErrorCategory.FATAL;
}

/** kind 合法性判定 */
export function isCredentialKind(value: string): boolean {
  for (let i = 0; i < ALL_CREDENTIAL_KINDS.length; i++) {
    if (ALL_CREDENTIAL_KINDS[i] === value) {
      return true;
    }
  }
  return false;
}

/** 主机 id + 凭据种类 → asset 别名（编码唯一入口） */
export function secretAlias(hostId: string, kind: CredentialKind): string {
  return `${ALIAS_PREFIX_HOST_SECRET}${hostId}:${kind}`;
}

/** 别名解析结果 */
export interface SecretAliasParts {
  readonly hostId: string;
  readonly kind: CredentialKind;
}

/**
 * 别名 → (hostId, kind) 解码；非本方案别名（含预留命名空间）或格式非法返回 null。
 * hostId 不含冒号（UUID），故按最后一个冒号切分 kind 段即可无歧义往返。
 */
export function parseSecretAlias(alias: string): SecretAliasParts | null {
  if (!alias.startsWith(ALIAS_PREFIX_HOST_SECRET)) {
    return null;
  }
  const rest: string = alias.substring(ALIAS_PREFIX_HOST_SECRET.length);
  const sep: number = rest.lastIndexOf(':');
  if (sep <= 0 || sep === rest.length - 1) {
    return null;
  }
  const hostId: string = rest.substring(0, sep);
  const kind: string = rest.substring(sep + 1);
  if (!isCredentialKind(kind)) {
    return null;
  }
  return { hostId: hostId, kind: kind as CredentialKind };
}

/** 字符串 → UTF-8 字节（asset 的 ALIAS/SECRET 均为 Uint8Array） */
function encodeUtf8(text: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(text);
}

/** UTF-8 字节 → 字符串 */
function decodeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

/** 从捕获的异常提取 BusinessError.code；非 BusinessError（无数值 code）归 -1 → FATAL */
function businessErrorCode(err: Object): number {
  const businessError: BusinessError = err as BusinessError;
  return typeof businessError.code === 'number' ? businessError.code : -1;
}

/**
 * 主机凭据的存取与删除。静态类、无内部状态，直接转发 ASSET 系统服务。
 * 真实读写依赖设备上的 ASSET 服务，单元测试不覆盖（真机/预览器验证）。
 */
export class CredentialStore {
  /**
   * 写入凭据；别名已存在时 add 冲突自动转 update（幂等覆盖语义）。
   * 访问控制在 add 时设定（update 只覆盖 SECRET）：
   *   - Accessibility = DEVICE_FIRST_UNLOCKED：开机后首次解锁前不可读
   *     （防冷启动旁路提取），解锁一次后即使再次锁屏仍可读，
   *     不影响 §7.5 后台保活期间的静默重连；未设锁屏密码的设备自动等价
   *     DEVICE_POWERED_ON，不产生额外门槛。DEVICE_UNLOCKED 会在锁屏后拒绝读取，
   *     破坏后台保活，故不取。
   *   - SYNC_TYPE = NEVER：凭据不随换机克隆 / 云同步迁出本机。
   *   - IS_PERSISTENT = false：卸载应用即被系统清除（验收标准依赖项，且免申请
   *     ohos.permission.STORE_PERSISTENT_DATA）。
   * 生物识别门禁（预留接口位，未实现）：如需「读取凭据前强制用户认证」，add 时追加
   *   asset.Tag.AUTH_TYPE = asset.AuthType.ANY（可选 AUTH_VALIDITY_PERIOD），
   *   读取改走 asset.preQuery → userAuth 用户认证 → asset.query → asset.postQuery 流程。
   */
  static async setSecret(hostId: string, kind: CredentialKind, value: string): Promise<void> {
    const alias: string = secretAlias(hostId, kind);
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, encodeUtf8(alias));
    attributes.set(asset.Tag.SECRET, encodeUtf8(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.IS_PERSISTENT, false);
    // THROW_ERROR：冲突时抛 DUPLICATED，由下方转 update（OVERWRITE 会静默覆盖，无法在日志区分新建与覆盖）
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
    try {
      await asset.add(attributes);
      return;
    } catch (err) {
      if (classifyAssetError(businessErrorCode(err)) !== AssetErrorCategory.DUPLICATED) {
        throw CredentialStore.fatal('add', alias, err);
      }
    }
    // 别名已存在：仅覆盖 SECRET，访问控制属性沿用首次 add 的设定
    const query: asset.AssetMap = CredentialStore.aliasQuery(alias);
    const toUpdate: asset.AssetMap = new Map();
    toUpdate.set(asset.Tag.SECRET, encodeUtf8(value));
    try {
      await asset.update(query, toUpdate);
    } catch (err) {
      throw CredentialStore.fatal('update', alias, err);
    }
  }

  /** 读取凭据；不存在返回 null（NOT_FOUND 归一），真故障抛 SshError(INTERNAL_ERROR) */
  static async getSecret(hostId: string, kind: CredentialKind): Promise<string | null> {
    const alias: string = secretAlias(hostId, kind);
    const query: asset.AssetMap = CredentialStore.aliasQuery(alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let results: asset.AssetMap[];
    try {
      results = await asset.query(query);
    } catch (err) {
      if (classifyAssetError(businessErrorCode(err)) === AssetErrorCategory.NOT_FOUND) {
        return null;
      }
      throw CredentialStore.fatal('query', alias, err);
    }
    if (results.length === 0) {
      return null;
    }
    const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
    if (secret === undefined || !(secret instanceof Uint8Array)) {
      // ReturnType.ALL 的命中结果缺 SECRET 属于数据损坏，按真故障处理而非误判为「不存在」
      throw CredentialStore.fatal('query', alias, new Error('查询结果缺少 SECRET 字段'));
    }
    return decodeUtf8(secret);
  }

  /** 删除单个凭据；不存在视为幂等成功，真故障抛 SshError(INTERNAL_ERROR) */
  static async removeSecret(hostId: string, kind: CredentialKind): Promise<void> {
    const alias: string = secretAlias(hostId, kind);
    try {
      await asset.remove(CredentialStore.aliasQuery(alias));
    } catch (err) {
      if (classifyAssetError(businessErrorCode(err)) === AssetErrorCategory.NOT_FOUND) {
        return;
      }
      throw CredentialStore.fatal('remove', alias, err);
    }
  }

  /** 删除主机时级联清理三种凭据（密码 / 密码短语 / 私钥） */
  static async removeAllSecrets(hostId: string): Promise<void> {
    for (const kind of ALL_CREDENTIAL_KINDS) {
      await CredentialStore.removeSecret(hostId, kind);
    }
  }

  /** 仅含别名的查询条件（remove / update 共用） */
  private static aliasQuery(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, encodeUtf8(alias));
    return query;
  }

  /** 真故障统一出口：记日志（只含操作名与别名，绝不含明文）后包装为 SshError(INTERNAL_ERROR) */
  private static fatal(op: string, alias: string, err: Object): SshError {
    Logger.error(`CredentialStore ${op} 失败（alias=${alias}）: ${JSON.stringify(err)}`, LOG_TAG);
    return new SshError(SshErrorCode.INTERNAL_ERROR, `凭据存储操作失败：${op}`);
  }
}
