/**
 * 同步文档序列化（任务 S5）——严格产出桌面端 ssh-tool 的 SyncDocumentV1。
 *
 * 对端 schema（`E:\code\ssh-tool\src\shared\sync-schemas.ts`）是 `z.strictObject`：
 * 顶层与每个实体多出一个键，对端会整份拒绝解析，而不是忽略。因此本文件只准产出
 * 下列字段，且不得为「本机专有数据」在文档里另开位置。
 *
 * 只同步交集：servers（主机 8 字段）/ tunnels（端口转发）/ groups（分组）。
 * 本机专有（外观、片段、known_hosts、jumpHostId、initCommands、envVars、termType、
 * 分组 order 等）留在本地库，由 SyncRuntime 在下行写回时保护，不随同步清空。
 *
 * 数组按 id 字典序；超限在写出前拦截。同一配置重复序列化字节一致。
 */

import { JSON } from '@kit.ArkTS';
import { AuthType } from '../../common/model/models';
import {
  DOCUMENT_MAX_BYTES,
  HOST_COUNT_MAX,
  PRIVATE_KEY_MAX_BYTES,
  SCHEMA_VERSION
} from '../../common/sync/SyncProtocol';

/** 分组默认色：对端 groupSchema.color 是必填的 /^#[0-9a-fA-F]{6}$/ */
export const DEFAULT_GROUP_COLOR: string = '#4F8CFF';

export interface Identified {
  id: string;
}

/** 对端 portableServerSchema，字段与顺序不得增减 */
export interface PortableServerProfile extends Identified {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  authType: AuthType;
  hostFingerprint: string;
  keepalive: number;
}

/**
 * 对端 serverSecretsSchema。privateKey 一旦出现，encoding/format/fingerprint 必须同时给全，
 * 且对端会用 ssh2 解析私钥、核对 privateKeyFingerprint，对不上直接抛错。
 * 本 App 暂不产出 privateKey（指纹需要与 ssh2 getPublicSSH() 一致的公钥导出，另行实现），
 * 但必须能原样透传远端写入的这几个字段。
 */
export interface SyncedServerSecrets {
  password?: string;
  passphrase?: string;
  privateKey?: string;
  privateKeyEncoding?: string;
  privateKeyFormat?: string;
  privateKeyFingerprint?: string;
}

export interface SyncServerRecord extends Identified {
  /** 便于按 id 对齐合并；序列化时不写出（见 serverToWire） */
  id: string;
  profile: PortableServerProfile;
  secrets?: SyncedServerSecrets;
}

/** 对端 tunnelSchema */
export interface SyncTunnel extends Identified {
  id: string;
  name: string;
  serverId: string;
  groupId: string | null;
  type: string;
  listenHost: string;
  listenPort: number;
  destHost: string;
  destPort: number;
  destServerId: string;
  autoReconnect: boolean;
  enabled: boolean;
}

/** 对端 groupSchema */
export interface SyncGroup extends Identified {
  id: string;
  name: string;
  color: string;
}

export interface SyncPreferences {
  syncPasswords: boolean;
  syncPrivateKeys: boolean;
}

export interface SyncDocument {
  schemaVersion: number;
  updatedAt: string;
  preferences: SyncPreferences;
  servers: SyncServerRecord[];
  tunnels: SyncTunnel[];
  groups: SyncGroup[];
}

export function emptySyncDocument(): SyncDocument {
  return {
    schemaVersion: SCHEMA_VERSION,
    updatedAt: '',
    preferences: { syncPasswords: false, syncPrivateKeys: false },
    servers: [],
    tunnels: [],
    groups: []
  };
}

function cmpId(a: string, b: string): number {
  if (a < b) {
    return -1;
  }
  if (a > b) {
    return 1;
  }
  return 0;
}

function sortById<T extends Identified>(items: T[]): T[] {
  const copy: T[] = [];
  for (const item of items) {
    copy.push(item);
  }
  copy.sort((left: T, right: T) => cmpId(left.id, right.id));
  return copy;
}

function encodeUtf8Len(text: string): number {
  let n: number = 0;
  for (let i = 0; i < text.length; i++) {
    const c: number = text.charCodeAt(i);
    if (c < 0x80) {
      n += 1;
    } else if (c < 0x800) {
      n += 2;
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
      n += 4;
      i++;
    } else {
      n += 3;
    }
  }
  return n;
}

export function canonicalizeDocument(doc: SyncDocument): SyncDocument {
  const out: SyncDocument = emptySyncDocument();
  out.schemaVersion = doc.schemaVersion;
  out.updatedAt = doc.updatedAt;
  out.preferences = {
    syncPasswords: doc.preferences.syncPasswords,
    syncPrivateKeys: doc.preferences.syncPrivateKeys
  };
  out.servers = sortById(doc.servers);
  out.tunnels = sortById(doc.tunnels);
  out.groups = sortById(doc.groups);
  return out;
}

/**
 * 写出前的自检，对齐对端 schema 的硬约束。返回 '' 表示可以写出。
 * 与对端不一致会导致桌面端整份文档解析失败，所以宁可本地拦下。
 */
export function validateDocumentLimits(doc: SyncDocument): string {
  if (doc.servers.length > HOST_COUNT_MAX) {
    return `主机数量超过上限（${HOST_COUNT_MAX}）`;
  }
  const serverIds: Map<string, boolean> = new Map();
  for (const item of doc.servers) {
    serverIds.set(item.profile.id, true);
    if (item.profile.name.length === 0) {
      return `主机 ${item.profile.id} 缺少名称`;
    }
    if (item.profile.port < 1 || item.profile.port > 65535) {
      return `主机 ${item.profile.id} 端口越界`;
    }
    if (item.profile.keepalive < 0 || item.profile.keepalive > 3600) {
      return `主机 ${item.profile.id} keepalive 越界`;
    }
    const secrets: SyncedServerSecrets | undefined = item.secrets;
    if (secrets !== undefined && secrets.privateKey !== undefined) {
      if (encodeUtf8Len(secrets.privateKey) > PRIVATE_KEY_MAX_BYTES) {
        return `私钥超过 ${PRIVATE_KEY_MAX_BYTES} 字节上限`;
      }
      // 对端要求三件套齐全，缺一会被 superRefine 拒绝
      if (secrets.privateKeyEncoding === undefined || secrets.privateKeyFormat === undefined ||
        secrets.privateKeyFingerprint === undefined) {
        return `主机 ${item.profile.id} 的私钥缺少 encoding/format/fingerprint`;
      }
    }
  }
  const groupIds: Map<string, boolean> = new Map();
  for (const item of doc.groups) {
    groupIds.set(item.id, true);
    if (item.name.length === 0) {
      return `分组 ${item.id} 缺少名称`;
    }
    if (!isHexColor(item.color)) {
      return `分组 ${item.id} 的颜色不合法（需 #RRGGBB）`;
    }
  }
  for (const item of doc.tunnels) {
    if (item.name.length === 0) {
      return `端口转发 ${item.id} 缺少名称`;
    }
    if (serverIds.get(item.serverId) !== true) {
      return `端口转发 ${item.id} 引用了不存在的主机`;
    }
    if (item.groupId !== null && groupIds.get(item.groupId) !== true) {
      return `端口转发 ${item.id} 引用了不存在的分组`;
    }
    if (item.type === 'relay' && serverIds.get(item.destServerId) !== true) {
      return `端口转发 ${item.id} 引用了不存在的目标主机`;
    }
  }
  return '';
}

export function isHexColor(value: string): boolean {
  if (value.length !== 7 || value.charAt(0) !== '#') {
    return false;
  }
  for (let i = 1; i < 7; i++) {
    const c: string = value.charAt(i).toLowerCase();
    const isDigit: boolean = c >= '0' && c <= '9';
    const isHex: boolean = c >= 'a' && c <= 'f';
    if (!isDigit && !isHex) {
      return false;
    }
  }
  return true;
}

/** SyncServerRecord → 线上对象：丢掉仅用于本地对齐的 id 字段 */
function serverToWire(item: SyncServerRecord): Record<string, Object> {
  const profile: Record<string, Object> = {};
  profile['id'] = item.profile.id;
  profile['name'] = item.profile.name;
  profile['host'] = item.profile.host;
  profile['port'] = item.profile.port;
  profile['username'] = item.profile.username;
  profile['authType'] = item.profile.authType;
  profile['hostFingerprint'] = item.profile.hostFingerprint;
  profile['keepalive'] = item.profile.keepalive;
  const wire: Record<string, Object> = {};
  wire['profile'] = profile;
  const secrets: SyncedServerSecrets | undefined = item.secrets;
  if (secrets !== undefined) {
    const out: Record<string, Object> = {};
    if (secrets.password !== undefined) {
      out['password'] = secrets.password;
    }
    if (secrets.passphrase !== undefined) {
      out['passphrase'] = secrets.passphrase;
    }
    if (secrets.privateKey !== undefined) {
      out['privateKey'] = secrets.privateKey;
      out['privateKeyEncoding'] = secrets.privateKeyEncoding ?? 'base64';
      out['privateKeyFormat'] = secrets.privateKeyFormat ?? 'openssh';
      out['privateKeyFingerprint'] = secrets.privateKeyFingerprint ?? '';
    }
    if (Object.keys(out).length > 0) {
      wire['secrets'] = out;
    }
  }
  return wire;
}

function tunnelToWire(item: SyncTunnel): Record<string, Object> {
  const wire: Record<string, Object> = {};
  wire['id'] = item.id;
  wire['name'] = item.name;
  wire['serverId'] = item.serverId;
  wire['groupId'] = item.groupId as Object;
  wire['type'] = item.type;
  wire['listenHost'] = item.listenHost;
  wire['listenPort'] = item.listenPort;
  wire['destHost'] = item.destHost;
  wire['destPort'] = item.destPort;
  wire['destServerId'] = item.destServerId;
  wire['autoReconnect'] = item.autoReconnect;
  wire['enabled'] = item.enabled;
  return wire;
}

function groupToWire(item: SyncGroup): Record<string, Object> {
  const wire: Record<string, Object> = {};
  wire['id'] = item.id;
  wire['name'] = item.name;
  wire['color'] = item.color;
  return wire;
}

export function serializeDocument(doc: SyncDocument): string {
  const canon: SyncDocument = canonicalizeDocument(doc);
  const limit: string = validateDocumentLimits(canon);
  if (limit.length > 0) {
    throw new Error(limit);
  }
  const wire: Record<string, Object> = {};
  wire['schemaVersion'] = SCHEMA_VERSION;
  wire['updatedAt'] = canon.updatedAt;
  const prefs: Record<string, Object> = {};
  prefs['syncPasswords'] = canon.preferences.syncPasswords;
  prefs['syncPrivateKeys'] = canon.preferences.syncPrivateKeys;
  wire['preferences'] = prefs;
  const servers: Object[] = [];
  for (const item of canon.servers) {
    servers.push(serverToWire(item));
  }
  wire['servers'] = servers;
  const tunnels: Object[] = [];
  for (const item of canon.tunnels) {
    tunnels.push(tunnelToWire(item));
  }
  wire['tunnels'] = tunnels;
  const groups: Object[] = [];
  for (const item of canon.groups) {
    groups.push(groupToWire(item));
  }
  wire['groups'] = groups;
  const json: string = JSON.stringify(wire);
  if (encodeUtf8Len(json) > DOCUMENT_MAX_BYTES) {
    throw new Error(`同步文档超过 ${DOCUMENT_MAX_BYTES} 字节上限`);
  }
  return json;
}

function asRecord(raw: Object | undefined): Record<string, Object> {
  if (raw === undefined || raw === null) {
    return {};
  }
  return raw as Record<string, Object>;
}

function readString(rec: Record<string, Object>, key: string): string {
  const value: Object | undefined = rec[key];
  return typeof value === 'string' ? value : '';
}

function readNumber(rec: Record<string, Object>, key: string): number {
  const value: Object | undefined = rec[key];
  return typeof value === 'number' ? value : 0;
}

function readOptString(rec: Record<string, Object>, key: string): string | undefined {
  const value: Object | undefined = rec[key];
  return typeof value === 'string' ? value : undefined;
}

function readArray(raw: Object | undefined): Object[] {
  if (raw === undefined || !Array.isArray(raw)) {
    return [];
  }
  return raw as Object[];
}

function parseSecrets(raw: Object | undefined): SyncedServerSecrets | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  const rec: Record<string, Object> = asRecord(raw);
  const out: SyncedServerSecrets = {
    password: readOptString(rec, 'password'),
    passphrase: readOptString(rec, 'passphrase'),
    privateKey: readOptString(rec, 'privateKey'),
    privateKeyEncoding: readOptString(rec, 'privateKeyEncoding'),
    privateKeyFormat: readOptString(rec, 'privateKeyFormat'),
    privateKeyFingerprint: readOptString(rec, 'privateKeyFingerprint')
  };
  if (out.password === undefined && out.passphrase === undefined && out.privateKey === undefined) {
    return undefined;
  }
  return out;
}

export function parseDocumentJson(json: string): SyncDocument {
  const parsed: Object = JSON.parse(json) as Object;
  const rec: Record<string, Object> = asRecord(parsed);
  const doc: SyncDocument = emptySyncDocument();
  const ver: Object | undefined = rec['schemaVersion'];
  doc.schemaVersion = typeof ver === 'number' ? ver : SCHEMA_VERSION;
  doc.updatedAt = readString(rec, 'updatedAt');
  const prefs: Record<string, Object> = asRecord(rec['preferences']);
  doc.preferences.syncPasswords = prefs['syncPasswords'] === true;
  doc.preferences.syncPrivateKeys = prefs['syncPrivateKeys'] === true;

  for (const raw of readArray(rec['servers'])) {
    const item: Record<string, Object> = asRecord(raw);
    const p: Record<string, Object> = asRecord(item['profile']);
    const id: string = readString(p, 'id');
    if (id.length === 0) {
      continue;
    }
    doc.servers.push({
      id: id,
      profile: {
        id: id,
        name: readString(p, 'name'),
        host: readString(p, 'host'),
        port: readNumber(p, 'port'),
        username: readString(p, 'username'),
        authType: readString(p, 'authType') as AuthType,
        hostFingerprint: readString(p, 'hostFingerprint'),
        keepalive: readNumber(p, 'keepalive')
      },
      secrets: parseSecrets(item['secrets'])
    });
  }

  for (const raw of readArray(rec['tunnels'])) {
    const t: Record<string, Object> = asRecord(raw);
    const id: string = readString(t, 'id');
    if (id.length === 0) {
      continue;
    }
    const groupRaw: Object | undefined = t['groupId'];
    doc.tunnels.push({
      id: id,
      name: readString(t, 'name'),
      serverId: readString(t, 'serverId'),
      groupId: typeof groupRaw === 'string' ? groupRaw as string : null,
      type: readString(t, 'type'),
      listenHost: readString(t, 'listenHost'),
      listenPort: readNumber(t, 'listenPort'),
      destHost: readString(t, 'destHost'),
      destPort: readNumber(t, 'destPort'),
      destServerId: readString(t, 'destServerId'),
      autoReconnect: t['autoReconnect'] === true,
      enabled: t['enabled'] === true
    });
  }

  for (const raw of readArray(rec['groups'])) {
    const g: Record<string, Object> = asRecord(raw);
    const id: string = readString(g, 'id');
    if (id.length === 0) {
      continue;
    }
    const color: string = readString(g, 'color');
    doc.groups.push({
      id: id,
      name: readString(g, 'name'),
      color: isHexColor(color) ? color : DEFAULT_GROUP_COLOR
    });
  }

  return canonicalizeDocument(doc);
}

export function documentsEqual(a: SyncDocument, b: SyncDocument): boolean {
  return serializeDocument(a) === serializeDocument(b);
}

/** 按敏感开关裁剪 servers[].secrets，关闭时不把明文带上云 */
export function applySensitiveFlags(doc: SyncDocument, syncPasswords: boolean,
  syncPrivateKeys: boolean): void {
  doc.preferences.syncPasswords = syncPasswords;
  doc.preferences.syncPrivateKeys = syncPrivateKeys;
  for (const server of doc.servers) {
    const secrets: SyncedServerSecrets | undefined = server.secrets;
    if (secrets === undefined) {
      continue;
    }
    if (!syncPasswords) {
      secrets.password = undefined;
      secrets.passphrase = undefined;
    }
    if (!syncPrivateKeys) {
      secrets.privateKey = undefined;
      secrets.privateKeyEncoding = undefined;
      secrets.privateKeyFormat = undefined;
      secrets.privateKeyFingerprint = undefined;
    }
    if (secrets.password === undefined && secrets.passphrase === undefined &&
      secrets.privateKey === undefined) {
      server.secrets = undefined;
    }
  }
}

/** 测试/体积估算用 */
export function estimateUtf8Bytes(text: string): number {
  return encodeUtf8Len(text);
}
