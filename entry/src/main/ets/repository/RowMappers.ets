/**
 * 实体 ↔ 数据行映射纯函数（任务 C1）。
 *
 * 每个实体一对 toRow / fromRow：
 *   toRow   实体 → RowObject（写库前值域收敛为 string/number/null）
 *   fromRow RowObject → 实体（读库后还原类型）
 *
 * 转换规则（与 DatabaseSchema.ets 的列定义一一对应）：
 *   - JSON TEXT 列：HostProfile.initCommands（string[]）/ envVars（Record<string,string>）、
 *     AppearanceProfile.palette（string[]）在 toRow 做 JSON.stringify，fromRow 解析并逐元素校验；
 *   - 布尔列：AppearanceProfile.ligatures / boldAsBright / cursorBlink、PortForwardRule.enabled
 *     以 INTEGER 0/1 存储，往返在映射函数内转换；
 *   - 可空外键：group_id / appearance_id / jump_host_id 在实体侧为 string | null，直通；
 *   - KnownHostEntry.addedAt 是 ISO 时间串，TEXT 直通不解析。
 *
 * 错误策略：本模块是纯函数，不记日志。列缺失/类型不符/JSON 损坏一律抛 Error，
 * 由 DAO 层统一记日志并包装为 SshError（INTERNAL_ERROR）——脏数据必须暴露，不能静默扩散。
 * 枚举样联合类型（authType / cursorStyle / forwards.type）读库时做白名单收敛，
 * 非法值回退默认值（与 SettingsRepository.getThemeMode 的脏数据策略一致）。
 */

import {
  AppearanceProfile,
  AuthType,
  CursorStyle,
  HostGroup,
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  PortForwardType,
  Snippet
} from '../common/model/models';
import { RowObject } from './RdbGateway';

// ---------- 内部读取辅助 ----------

/** 读非空 TEXT 列；缺失或类型不符视为数据损坏 */
function reqString(row: RowObject, column: string): string {
  const value: string | number | null = row[column];
  if (typeof value === 'string') {
    return value;
  }
  throw new Error(`数据行损坏：列 ${column} 期望非空 TEXT，实际 ${JSON.stringify(value)}`);
}

/** 读非空 INTEGER/REAL 列 */
function reqNumber(row: RowObject, column: string): number {
  const value: string | number | null = row[column];
  if (typeof value === 'number') {
    return value;
  }
  throw new Error(`数据行损坏：列 ${column} 期望非空数值，实际 ${JSON.stringify(value)}`);
}

/** 读可空 TEXT 列（缺失或 NULL → null） */
function optString(row: RowObject, column: string): string | null {
  const value: string | number | null = row[column];
  return typeof value === 'string' ? value : null;
}

/** 读 0/1 布尔列 */
function reqBool(row: RowObject, column: string): boolean {
  return reqNumber(row, column) !== 0;
}

/** 解析 JSON string[] 列，逐元素校验 */
function parseStringArray(json: string, column: string): string[] {
  const parsed: Object | null = JSON.parse(json);
  if (parsed === null || !Array.isArray(parsed)) {
    throw new Error(`数据行损坏：列 ${column} 不是 JSON 数组`);
  }
  const result: string[] = [];
  const items: Object[] = parsed as Object[];
  for (let i = 0; i < items.length; i++) {
    if (typeof items[i] !== 'string') {
      throw new Error(`数据行损坏：列 ${column} 的数组元素不是字符串`);
    }
    result.push(items[i] as string);
  }
  return result;
}

/** 解析 JSON Record<string,string> 列，逐键值校验 */
function parseStringRecord(json: string, column: string): Record<string, string> {
  const parsed: Object | null = JSON.parse(json);
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`数据行损坏：列 ${column} 不是 JSON 对象`);
  }
  const result: Record<string, string> = {};
  const entries: Record<string, Object> = parsed as Record<string, Object>;
  const keys: string[] = Object.keys(entries);
  for (let i = 0; i < keys.length; i++) {
    const value: Object = entries[keys[i]];
    if (typeof value !== 'string') {
      throw new Error(`数据行损坏：列 ${column} 的键 ${keys[i]} 的值不是字符串`);
    }
    result[keys[i]] = value as string;
  }
  return result;
}

/** 脏数据收敛：非法 authType 回退 password */
function toAuthType(text: string): AuthType {
  if (text === 'key' || text === 'agent') {
    return text;
  }
  return 'password';
}

/** 脏数据收敛：非法 cursorStyle 回退 block */
function toCursorStyle(text: string): CursorStyle {
  if (text === 'bar' || text === 'underline') {
    return text;
  }
  return 'block';
}

/** 脏数据收敛：非法转发类型回退 local */
function toPortForwardType(text: string): PortForwardType {
  if (text === 'remote' || text === 'dynamic') {
    return text;
  }
  return 'local';
}

// ---------- HostProfile ↔ hosts ----------

// 注意：ArkTS 禁止以 Record 类型（RowObject）为上下文类型的非空对象字面量
// （arkts-no-untyped-obj-literals），因此 toRow 一律「空字面量 + 逐列赋值」。

export function hostToRow(host: HostProfile): RowObject {
  const row: RowObject = {};
  row['id'] = host.id;
  row['name'] = host.name;
  row['host'] = host.host;
  row['port'] = host.port;
  row['username'] = host.username;
  row['auth_type'] = host.authType;
  row['host_fingerprint'] = host.hostFingerprint;
  row['keepalive'] = host.keepalive;
  row['group_id'] = host.groupId;
  row['appearance_id'] = host.appearanceId;
  row['jump_host_id'] = host.jumpHostId;
  row['init_commands'] = JSON.stringify(host.initCommands);
  row['env_vars'] = JSON.stringify(host.envVars);
  row['term_type'] = host.termType;
  row['tmux_auto_attach'] = host.tmuxAutoAttach ? 1 : 0;
  row['tmux_session_name'] = host.tmuxSessionName;
  return row;
}

export function rowToHost(row: RowObject): HostProfile {
  return {
    id: reqString(row, 'id'),
    name: reqString(row, 'name'),
    host: reqString(row, 'host'),
    port: reqNumber(row, 'port'),
    username: reqString(row, 'username'),
    authType: toAuthType(reqString(row, 'auth_type')),
    hostFingerprint: reqString(row, 'host_fingerprint'),
    keepalive: reqNumber(row, 'keepalive'),
    groupId: optString(row, 'group_id'),
    appearanceId: optString(row, 'appearance_id'),
    jumpHostId: optString(row, 'jump_host_id'),
    initCommands: parseStringArray(reqString(row, 'init_commands'), 'init_commands'),
    envVars: parseStringRecord(reqString(row, 'env_vars'), 'env_vars'),
    termType: reqString(row, 'term_type'),
    tmuxAutoAttach: reqNumber(row, 'tmux_auto_attach') !== 0,
    tmuxSessionName: reqString(row, 'tmux_session_name')
  };
}

// ---------- HostGroup ↔ host_groups ----------

export function hostGroupToRow(group: HostGroup): RowObject {
  const row: RowObject = {};
  row['id'] = group.id;
  row['name'] = group.name;
  row['order_index'] = group.order;
  return row;
}

export function rowToHostGroup(row: RowObject): HostGroup {
  return {
    id: reqString(row, 'id'),
    name: reqString(row, 'name'),
    order: reqNumber(row, 'order_index')
  };
}

// ---------- AppearanceProfile ↔ appearance ----------

export function appearanceToRow(appearance: AppearanceProfile): RowObject {
  const row: RowObject = {};
  row['id'] = appearance.id;
  row['name'] = appearance.name;
  row['font_family'] = appearance.fontFamily;
  row['font_size'] = appearance.fontSize;
  row['line_height'] = appearance.lineHeight;
  row['letter_spacing'] = appearance.letterSpacing;
  row['font_weight'] = appearance.fontWeight;
  row['ligatures'] = appearance.ligatures ? 1 : 0;
  row['bold_as_bright'] = appearance.boldAsBright ? 1 : 0;
  row['cursor_style'] = appearance.cursorStyle;
  row['cursor_blink'] = appearance.cursorBlink ? 1 : 0;
  row['background_opacity'] = appearance.backgroundOpacity;
  row['padding'] = appearance.padding;
  row['palette'] = JSON.stringify(appearance.palette);
  row['foreground'] = appearance.foreground;
  row['background'] = appearance.background;
  row['cursor_color'] = appearance.cursorColor;
  row['selection_color'] = appearance.selectionColor;
  // A5 背景图（schema v3）
  row['background_image_path'] = appearance.backgroundImagePath;
  row['background_image_opacity'] = appearance.backgroundImageOpacity;
  row['background_blur'] = appearance.backgroundBlur;
  return row;
}

export function rowToAppearance(row: RowObject): AppearanceProfile {
  return {
    id: reqString(row, 'id'),
    name: reqString(row, 'name'),
    fontFamily: reqString(row, 'font_family'),
    fontSize: reqNumber(row, 'font_size'),
    lineHeight: reqNumber(row, 'line_height'),
    letterSpacing: reqNumber(row, 'letter_spacing'),
    fontWeight: reqNumber(row, 'font_weight'),
    ligatures: reqBool(row, 'ligatures'),
    boldAsBright: reqBool(row, 'bold_as_bright'),
    cursorStyle: toCursorStyle(reqString(row, 'cursor_style')),
    cursorBlink: reqBool(row, 'cursor_blink'),
    backgroundOpacity: reqNumber(row, 'background_opacity'),
    padding: reqNumber(row, 'padding'),
    palette: parseStringArray(reqString(row, 'palette'), 'palette'),
    foreground: reqString(row, 'foreground'),
    background: reqString(row, 'background'),
    cursorColor: reqString(row, 'cursor_color'),
    selectionColor: reqString(row, 'selection_color'),
    // A5：迁移后列必在；历史/缺列时回退默认，不把脏数据扩散到 UI
    backgroundImagePath: typeof row['background_image_path'] === 'string'
      ? row['background_image_path'] as string : '',
    backgroundImageOpacity: typeof row['background_image_opacity'] === 'number'
      ? row['background_image_opacity'] as number : 1,
    backgroundBlur: typeof row['background_blur'] === 'number'
      ? row['background_blur'] as number : 0
  };
}

// ---------- Snippet ↔ snippets ----------

export function snippetToRow(snippet: Snippet): RowObject {
  const row: RowObject = {};
  row['id'] = snippet.id;
  row['name'] = snippet.name;
  row['content'] = snippet.content;
  row['group_id'] = snippet.groupId;
  return row;
}

export function rowToSnippet(row: RowObject): Snippet {
  return {
    id: reqString(row, 'id'),
    name: reqString(row, 'name'),
    content: reqString(row, 'content'),
    groupId: optString(row, 'group_id')
  };
}

// ---------- KnownHostEntry ↔ known_hosts ----------

export function knownHostToRow(entry: KnownHostEntry): RowObject {
  const row: RowObject = {};
  row['id'] = entry.id;
  row['host'] = entry.host;
  row['port'] = entry.port;
  row['key_type'] = entry.keyType;
  row['fingerprint'] = entry.fingerprint;
  row['added_at'] = entry.addedAt;
  return row;
}

export function rowToKnownHost(row: RowObject): KnownHostEntry {
  return {
    id: reqString(row, 'id'),
    host: reqString(row, 'host'),
    port: reqNumber(row, 'port'),
    keyType: reqString(row, 'key_type'),
    fingerprint: reqString(row, 'fingerprint'),
    addedAt: reqString(row, 'added_at')
  };
}

// ---------- PortForwardRule ↔ forwards ----------

export function forwardToRow(rule: PortForwardRule): RowObject {
  const row: RowObject = {};
  row['id'] = rule.id;
  row['host_id'] = rule.hostId;
  row['type'] = rule.type;
  row['bind_address'] = rule.bindAddress;
  row['local_port'] = rule.localPort;
  row['remote_host'] = rule.remoteHost;
  row['remote_port'] = rule.remotePort;
  row['enabled'] = rule.enabled ? 1 : 0;
  return row;
}

export function rowToForward(row: RowObject): PortForwardRule {
  return {
    id: reqString(row, 'id'),
    hostId: reqString(row, 'host_id'),
    type: toPortForwardType(reqString(row, 'type')),
    bindAddress: reqString(row, 'bind_address'),
    localPort: reqNumber(row, 'local_port'),
    remoteHost: reqString(row, 'remote_host'),
    remotePort: reqNumber(row, 'remote_port'),
    enabled: reqBool(row, 'enabled')
  };
}
