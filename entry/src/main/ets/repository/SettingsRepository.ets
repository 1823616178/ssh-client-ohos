/**
 * 应用设置封装（DESIGN §5.1 / §6.6，任务 C3）。
 *
 * 轻量偏好（主题模式、默认字号、后台策略、上次会话等）存 @ohos.data.preferences，
 * store 名 'app_settings'。键集合对齐 §6.6「不同步（设备本地）」清单
 * （后台保活策略、触感开关、功能键条布局、息屏断开策略）+ 常用项。
 *
 * 类型约束说明：理想形态是 get<K>(key: K) 配合映射类型把「键 → 值类型」绑定到编译期，
 * 但 ArkTS 不支持 keyof 映射类型（除 Record 外的 mapped type 均不可用），
 * 因此退化为「键定义表 SETTING_DEFS + 每个键一对显式 getter/setter」：
 * 定义表驱动首启默认值写入与完整性校验，显式 getter/setter 保证调用方在编译期
 * 就不可能写错类型。新增设置必须先在 SETTING_DEFS 登记并补一对访问器，单元测试会校验完整性。
 *
 * 使用方式：EntryAbility.onCreate 中（Logger.init 之后）调用
 *   SettingsRepository.init(this.context);
 *   SettingsRepository.ensureDefaults();
 * 之后各处直接 getXxx() / setXxx()。init 失败时读写静默回退默认值并记日志。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/utils/Logger';

/** preferences store 名称 */
const STORE_NAME: string = 'app_settings';

/** 主题模式 */
export type ThemeMode = 'system' | 'dark' | 'light';

/** 设置值类型标签（preferences 支持的三种标量） */
export type SettingValueType = 'string' | 'number' | 'boolean';

/** 单个设置键的定义：键名、类型、默认值、说明 */
export interface SettingDef {
  readonly key: string;
  readonly type: SettingValueType;
  readonly defaultValue: string | number | boolean;
  readonly comment: string;
}

/** 键名常量：SETTING_DEFS 与访问器共用，避免散落的字符串字面量 */
const KEY_THEME_MODE: string = 'themeMode';
const KEY_DEFAULT_FONT_SIZE: string = 'defaultFontSize';
const KEY_KEEP_ALIVE_IN_BACKGROUND: string = 'keepAliveInBackground';
const KEY_SCREEN_OFF_DISCONNECT_MINUTES: string = 'screenOffDisconnectMinutes';
const KEY_HAPTIC_ENABLED: string = 'hapticEnabled';
const KEY_KEY_BAR_LAYOUT: string = 'keyBarLayout';
const KEY_LAST_SESSION_ID: string = 'lastSessionId';
const KEY_SYNC_POLL_INTERVAL_MINUTES: string = 'syncPollIntervalMinutes';
const KEY_HOST_GROUP_COLLAPSED: string = 'hostGroupCollapsed';
const KEY_HOST_LAST_USED: string = 'hostLastUsed';
const KEY_KEYBOARD_SHORTCUTS: string = 'keyboardShortcuts';
const KEY_SYNC_DEVICE_ID: string = 'syncDeviceId';
const KEY_SYNC_USER_EMAIL: string = 'syncUserEmail';
const KEY_SYNC_USER_ID: string = 'syncUserId';
const KEY_SYNC_VAULT_ID: string = 'syncVaultId';
const KEY_SYNC_LAST_REVISION: string = 'syncLastRevision';
const KEY_SYNC_PASSWORDS: string = 'syncPasswords';
const KEY_SYNC_PRIVATE_KEYS: string = 'syncPrivateKeys';
const KEY_SYNC_PASSTHROUGH: string = 'syncPassthrough';

/**
 * 键定义表：所有设置键的唯一声明处。
 * 新增设置必须先在此追加一条（并补一对显式 getter/setter），
 * SettingsRepository 单元测试会校验本表完整性（每键有类型与匹配的默认值、键名唯一）。
 */
export const SETTING_DEFS: SettingDef[] = [
  { key: KEY_THEME_MODE, type: 'string', defaultValue: 'system', comment: '主题模式：system / dark / light' },
  { key: KEY_DEFAULT_FONT_SIZE, type: 'number', defaultValue: 14, comment: '默认终端字号（§4.4 常用值，可选 8–32）' },
  { key: KEY_KEEP_ALIVE_IN_BACKGROUND, type: 'boolean', defaultValue: true, comment: '后台保持连接（§7.5 默认开）' },
  { key: KEY_SCREEN_OFF_DISCONNECT_MINUTES, type: 'number', defaultValue: 0, comment: '息屏 N 分钟后断开，0 = 关（§7.5 默认关）' },
  { key: KEY_HAPTIC_ENABLED, type: 'boolean', defaultValue: true, comment: '触感反馈开关（§4.4）' },
  { key: KEY_KEY_BAR_LAYOUT, type: 'string', defaultValue: '', comment: '功能键条布局（JSON 串，空串 = 内置默认布局）' },
  { key: KEY_LAST_SESSION_ID, type: 'string', defaultValue: '', comment: '上次会话 id（§5.1），空串 = 无' },
  { key: KEY_SYNC_POLL_INTERVAL_MINUTES, type: 'number', defaultValue: 15, comment: '同步轮询间隔（分钟，§6.4 默认 15）' },
  { key: KEY_HOST_GROUP_COLLAPSED, type: 'string', defaultValue: '{}', comment: '主机分组折叠状态（JSON 串 groupId→boolean，U1；空对象 = 全部展开）' },
  { key: KEY_HOST_LAST_USED, type: 'string', defaultValue: '{}', comment: '主机最后使用时间（JSON 串 hostId→epochMs，本机；首页列表近者优先）' },
  { key: KEY_KEYBOARD_SHORTCUTS, type: 'string', defaultValue: '', comment: '终端快捷键表（JSON 数组，空串 = 内置默认：Ctrl+Shift+T 新标签等）' },
  { key: KEY_SYNC_DEVICE_ID, type: 'string', defaultValue: '', comment: '同步设备 id（登录复用，避免挤占 10 台配额）' },
  { key: KEY_SYNC_USER_EMAIL, type: 'string', defaultValue: '', comment: '已登录邮箱（展示用）' },
  { key: KEY_SYNC_USER_ID, type: 'string', defaultValue: '', comment: '已登录用户 id' },
  { key: KEY_SYNC_VAULT_ID, type: 'string', defaultValue: '', comment: '云端 vault id' },
  { key: KEY_SYNC_LAST_REVISION, type: 'string', defaultValue: '', comment: '上次成功同步的 revision' },
  { key: KEY_SYNC_PASSWORDS, type: 'boolean', defaultValue: false, comment: '是否同步密码（S7，默认关）' },
  { key: KEY_SYNC_PRIVATE_KEYS, type: 'boolean', defaultValue: false, comment: '是否同步私钥（S7，默认关）' },
  { key: KEY_SYNC_PASSTHROUGH, type: 'string', defaultValue: '{}', comment: '桌面端专有字段透传缓存（JSON；隧道名/分组色等本地库无列可存的字段，上行时原样带回）' }
];

export class SettingsRepository {
  /** 已获取的 preferences store；null 表示未初始化或初始化失败（读写回退默认值） */
  private static store: preferences.Preferences | null = null;

  /** 获取 store 并持有；重复调用幂等。失败只记日志，不抛给调用方 */
  static init(context: common.Context): void {
    try {
      SettingsRepository.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (err) {
      SettingsRepository.store = null;
      Logger.error(`SettingsRepository init 失败: ${JSON.stringify(err)}`, 'Settings');
    }
  }

  /**
   * 首次启动写入默认值：仅对「键不存在」的项 putSync，已存在的用户值一律不覆盖。
   * 在 EntryAbility.onCreate（Logger.init 之后）调用。
   */
  static ensureDefaults(): void {
    const store: preferences.Preferences | null = SettingsRepository.store;
    if (store === null) {
      Logger.warn('ensureDefaults 跳过：store 未初始化', 'Settings');
      return;
    }
    try {
      let written: number = 0;
      for (let i = 0; i < SETTING_DEFS.length; i++) {
        const def: SettingDef = SETTING_DEFS[i];
        if (!store.hasSync(def.key)) {
          store.putSync(def.key, def.defaultValue);
          written++;
        }
      }
      if (written > 0) {
        store.flush();
        Logger.info(`应用设置写入 ${written} 项默认值（首次启动）`, 'Settings');
      }
    } catch (err) {
      Logger.error(`ensureDefaults 失败: ${JSON.stringify(err)}`, 'Settings');
    }
  }

  // ---- 以下为每个键一对的显式 getter/setter（编译期类型约束，见文件头说明） ----

  static getThemeMode(): ThemeMode {
    const raw: string = SettingsRepository.readString(KEY_THEME_MODE);
    if (raw === 'dark' || raw === 'light' || raw === 'system') {
      return raw;
    }
    // 存量数据出现非法值时回退 system，不把脏数据扩散到调用方
    return 'system';
  }

  static setThemeMode(mode: ThemeMode): void {
    SettingsRepository.writeValue(KEY_THEME_MODE, mode);
  }

  static getDefaultFontSize(): number {
    return SettingsRepository.readNumber(KEY_DEFAULT_FONT_SIZE);
  }

  static setDefaultFontSize(value: number): void {
    SettingsRepository.writeValue(KEY_DEFAULT_FONT_SIZE, value);
  }

  static isKeepAliveInBackground(): boolean {
    return SettingsRepository.readBoolean(KEY_KEEP_ALIVE_IN_BACKGROUND);
  }

  static setKeepAliveInBackground(value: boolean): void {
    SettingsRepository.writeValue(KEY_KEEP_ALIVE_IN_BACKGROUND, value);
  }

  static getScreenOffDisconnectMinutes(): number {
    return SettingsRepository.readNumber(KEY_SCREEN_OFF_DISCONNECT_MINUTES);
  }

  static setScreenOffDisconnectMinutes(value: number): void {
    SettingsRepository.writeValue(KEY_SCREEN_OFF_DISCONNECT_MINUTES, value);
  }

  static isHapticEnabled(): boolean {
    return SettingsRepository.readBoolean(KEY_HAPTIC_ENABLED);
  }

  static setHapticEnabled(value: boolean): void {
    SettingsRepository.writeValue(KEY_HAPTIC_ENABLED, value);
  }

  /** 功能键条布局（JSON 串）；空串表示使用内置默认布局 */
  static getKeyBarLayout(): string {
    return SettingsRepository.readString(KEY_KEY_BAR_LAYOUT);
  }

  static setKeyBarLayout(layoutJson: string): void {
    SettingsRepository.writeValue(KEY_KEY_BAR_LAYOUT, layoutJson);
  }

  static getLastSessionId(): string {
    return SettingsRepository.readString(KEY_LAST_SESSION_ID);
  }

  static setLastSessionId(sessionId: string): void {
    SettingsRepository.writeValue(KEY_LAST_SESSION_ID, sessionId);
  }

  static getSyncPollIntervalMinutes(): number {
    return SettingsRepository.readNumber(KEY_SYNC_POLL_INTERVAL_MINUTES);
  }

  static setSyncPollIntervalMinutes(value: number): void {
    SettingsRepository.writeValue(KEY_SYNC_POLL_INTERVAL_MINUTES, value);
  }

  /** 主机分组折叠状态（JSON 串：groupId→true 表示折叠，U1）；'{}' = 全部展开 */
  static getHostGroupCollapsed(): string {
    return SettingsRepository.readString(KEY_HOST_GROUP_COLLAPSED);
  }

  static setHostGroupCollapsed(collapsedJson: string): void {
    SettingsRepository.writeValue(KEY_HOST_GROUP_COLLAPSED, collapsedJson);
  }

  /** 主机最后使用时间（JSON 串 hostId→epochMs）；'{}' = 从未记录 */
  static getHostLastUsed(): string {
    return SettingsRepository.readString(KEY_HOST_LAST_USED);
  }

  static setHostLastUsed(json: string): void {
    SettingsRepository.writeValue(KEY_HOST_LAST_USED, json);
  }

  /** 终端快捷键表（JSON 数组）；空串表示使用内置默认表 */
  static getKeyboardShortcuts(): string {
    return SettingsRepository.readString(KEY_KEYBOARD_SHORTCUTS);
  }

  static setKeyboardShortcuts(shortcutsJson: string): void {
    SettingsRepository.writeValue(KEY_KEYBOARD_SHORTCUTS, shortcutsJson);
  }

  static getSyncDeviceId(): string {
    return SettingsRepository.readString(KEY_SYNC_DEVICE_ID);
  }

  static setSyncDeviceId(value: string): void {
    SettingsRepository.writeValue(KEY_SYNC_DEVICE_ID, value);
  }

  static getSyncUserEmail(): string {
    return SettingsRepository.readString(KEY_SYNC_USER_EMAIL);
  }

  static setSyncUserEmail(value: string): void {
    SettingsRepository.writeValue(KEY_SYNC_USER_EMAIL, value);
  }

  static getSyncUserId(): string {
    return SettingsRepository.readString(KEY_SYNC_USER_ID);
  }

  static setSyncUserId(value: string): void {
    SettingsRepository.writeValue(KEY_SYNC_USER_ID, value);
  }

  static getSyncVaultId(): string {
    return SettingsRepository.readString(KEY_SYNC_VAULT_ID);
  }

  static setSyncVaultId(value: string): void {
    SettingsRepository.writeValue(KEY_SYNC_VAULT_ID, value);
  }

  static getSyncLastRevision(): string {
    return SettingsRepository.readString(KEY_SYNC_LAST_REVISION);
  }

  static setSyncLastRevision(value: string): void {
    SettingsRepository.writeValue(KEY_SYNC_LAST_REVISION, value);
  }

  static isSyncPasswords(): boolean {
    return SettingsRepository.readBoolean(KEY_SYNC_PASSWORDS);
  }

  static setSyncPasswords(value: boolean): void {
    SettingsRepository.writeValue(KEY_SYNC_PASSWORDS, value);
  }

  static isSyncPrivateKeys(): boolean {
    return SettingsRepository.readBoolean(KEY_SYNC_PRIVATE_KEYS);
  }

  static setSyncPrivateKeys(value: boolean): void {
    SettingsRepository.writeValue(KEY_SYNC_PRIVATE_KEYS, value);
  }

  /** 桌面端专有字段透传缓存（JSON 串）；'{}' 表示空 */
  static getSyncPassthrough(): string {
    return SettingsRepository.readString(KEY_SYNC_PASSTHROUGH);
  }

  static setSyncPassthrough(value: string): void {
    SettingsRepository.writeValue(KEY_SYNC_PASSTHROUGH, value);
  }

  /** accessToken / refreshToken 落 CredentialStore（asset），由 SettingsAuthStore 自行清除，不在此处 */
  static clearSyncSession(): void {
    SettingsRepository.setSyncUserEmail('');
    SettingsRepository.setSyncUserId('');
    SettingsRepository.setSyncVaultId('');
    SettingsRepository.setSyncLastRevision('');
  }

  // ---- 内部读写辅助 ----

  /** 按键名查定义；键名均为本文件常量，正常不会 miss */
  private static defOf(key: string): SettingDef {
    for (let i = 0; i < SETTING_DEFS.length; i++) {
      if (SETTING_DEFS[i].key === key) {
        return SETTING_DEFS[i];
      }
    }
    throw new Error(`SettingsRepository: 未登记的设置键 ${key}`);
  }

  private static readString(key: string): string {
    const def: SettingDef = SettingsRepository.defOf(key);
    const fallback: string = def.defaultValue as string;
    const store: preferences.Preferences | null = SettingsRepository.store;
    if (store === null) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = store.getSync(key, def.defaultValue);
      // 类型与登记不符（如旧版本写坏的数据）时回退默认值
      return typeof value === 'string' ? value : fallback;
    } catch (err) {
      Logger.warn(`读取设置 ${key} 失败，返回默认值: ${JSON.stringify(err)}`, 'Settings');
      return fallback;
    }
  }

  private static readNumber(key: string): number {
    const def: SettingDef = SettingsRepository.defOf(key);
    const fallback: number = def.defaultValue as number;
    const store: preferences.Preferences | null = SettingsRepository.store;
    if (store === null) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = store.getSync(key, def.defaultValue);
      return typeof value === 'number' ? value : fallback;
    } catch (err) {
      Logger.warn(`读取设置 ${key} 失败，返回默认值: ${JSON.stringify(err)}`, 'Settings');
      return fallback;
    }
  }

  private static readBoolean(key: string): boolean {
    const def: SettingDef = SettingsRepository.defOf(key);
    const fallback: boolean = def.defaultValue as boolean;
    const store: preferences.Preferences | null = SettingsRepository.store;
    if (store === null) {
      return fallback;
    }
    try {
      const value: preferences.ValueType = store.getSync(key, def.defaultValue);
      return typeof value === 'boolean' ? value : fallback;
    } catch (err) {
      Logger.warn(`读取设置 ${key} 失败，返回默认值: ${JSON.stringify(err)}`, 'Settings');
      return fallback;
    }
  }

  private static writeValue(key: string, value: preferences.ValueType): void {
    const store: preferences.Preferences | null = SettingsRepository.store;
    if (store === null) {
      Logger.warn(`写入设置 ${key} 失败：store 未初始化`, 'Settings');
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (err) {
      Logger.error(`写入设置 ${key} 失败: ${JSON.stringify(err)}`, 'Settings');
    }
  }
}
