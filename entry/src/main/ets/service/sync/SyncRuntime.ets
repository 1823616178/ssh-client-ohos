/**
 * 生产同步运行时（任务 S6 / S7 / U6）：单例协调器 + 触发器 + DAO 文档库。
 */

import { Logger } from '../../common/utils/Logger';
import {
  NetSnapshot,
  NetworkChangeListener,
  NetworkLostListener,
  NetworkWatcher
} from '../NetworkWatcher';
import { SettingsRepository } from '../../repository/SettingsRepository';
import { AppDatabase } from '../../repository/AppDatabase';
import { CredentialStore } from '../../repository/CredentialStore';

import { ApiClient, createProductionTransport } from './ApiClient';
import { VaultEnvelope } from './ApiTypes';
import { AuthSession, SettingsAuthStore } from './AuthSession';
import { SyncCoordinator, SyncDocumentStore } from './SyncCoordinator';
import { NativeVaultCrypto } from './VaultNative';
import {
  DEFAULT_GROUP_COLOR,
  emptySyncDocument,
  SyncDocument,
  SyncGroup,
  SyncServerRecord,
  SyncTunnel,
  SyncedServerSecrets
} from './SyncSerializer';
import { HostGroup, HostProfile, PortForwardRule, PortForwardType } from '../../common/model/models';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { setConfigSavedHook } from './SyncHooks';
import { SyncTriggers } from './SyncTriggers';
import { AccountSyncViewModel } from '../../viewmodel/AccountSyncViewModel';

const LOG_TAG: string = 'SyncRuntime';

/**
 * 桌面端专有字段的透传缓存：本地库没有对应列（隧道名 / 隧道分组 / destServerId /
 * autoReconnect / 分组颜色），若上行时凭空重造，每次手机同步都会把桌面端的这些值冲掉。
 * 这里按 id 记住最近一次见到的远端值，上行时原样带回。
 */
class Passthrough {
  private readonly map: Record<string, Object> = {};

  static load(): Passthrough {
    const p: Passthrough = new Passthrough();
    try {
      const raw: string = SettingsRepository.getSyncPassthrough();
      if (raw.length > 0) {
        const parsed: Record<string, Object> = ArkJSON.parse(raw) as Record<string, Object>;
        for (const key of Object.keys(parsed)) {
          p.map[key] = parsed[key];
        }
      }
    } catch (err) {
      Logger.warn('透传缓存解析失败，按空处理', LOG_TAG);
    }
    return p;
  }

  save(): void {
    try {
      SettingsRepository.setSyncPassthrough(ArkJSON.stringify(this.map));
    } catch (err) {
      Logger.warn('透传缓存写入失败', LOG_TAG);
    }
  }

  private rec(key: string): Record<string, Object> {
    const value: Object | undefined = this.map[key];
    return value === undefined ? {} : value as Record<string, Object>;
  }

  str(key: string, field: string, fallback: string): string {
    const value: Object | undefined = this.rec(key)[field];
    return typeof value === 'string' ? value : fallback;
  }

  bool(key: string, field: string): boolean {
    return this.rec(key)[field] === true;
  }

  nullableStr(key: string, field: string): string | null {
    const value: Object | undefined = this.rec(key)[field];
    return typeof value === 'string' ? value as string : null;
  }

  rememberTunnel(item: SyncTunnel): void {
    const r: Record<string, Object> = {};
    r['name'] = item.name;
    r['groupId'] = item.groupId as Object;
    r['destServerId'] = item.destServerId;
    r['autoReconnect'] = item.autoReconnect;
    r['type'] = item.type;
    this.map[`tunnel:${item.id}`] = r;
  }

  rememberGroup(item: SyncGroup): void {
    const r: Record<string, Object> = {};
    r['color'] = item.color;
    this.map[`group:${item.id}`] = r;
  }
}

class DaoDocumentStore implements SyncDocumentStore {
  async load(): Promise<SyncDocument> {
    const doc: SyncDocument = emptySyncDocument();
    try {
      if (!AppDatabase.isReady()) {
        return doc;
      }
      const pass: Passthrough = Passthrough.load();
      const wantSecrets: boolean =
        SettingsRepository.isSyncPasswords() || SettingsRepository.isSyncPrivateKeys();
      const hostIds: Record<string, boolean> = {};
      for (const h of AppDatabase.hosts().listAll()) {
        hostIds[h.id] = true;
        const record: SyncServerRecord = {
          id: h.id,
          profile: {
            id: h.id,
            name: h.name.length > 0 ? h.name : h.host,
            host: h.host,
            port: h.port,
            username: h.username,
            authType: h.authType,
            hostFingerprint: h.hostFingerprint,
            keepalive: h.keepalive
          }
        };
        if (wantSecrets) {
          record.secrets = await loadHostSecrets(h.id);
        }
        doc.servers.push(record);
      }
      const groupIds: Record<string, boolean> = {};
      for (const g of AppDatabase.groups().listAll()) {
        groupIds[g.id] = true;
        doc.groups.push({
          id: g.id,
          name: g.name.length > 0 ? g.name : g.id,
          // 本地库没有颜色列，用上次见到的远端色，没有则给默认色（对端 color 是必填正则）
          color: pass.str(`group:${g.id}`, 'color', DEFAULT_GROUP_COLOR)
        });
      }
      for (const f of AppDatabase.forwards().listAll()) {
        // 对端 superRefine 要求隧道必须引用存在的主机，否则整份文档被拒
        if (hostIds[f.hostId] !== true) {
          continue;
        }
        const key: string = `tunnel:${f.id}`;
        const groupId: string | null = pass.nullableStr(key, 'groupId');
        doc.tunnels.push({
          id: f.id,
          name: pass.str(key, 'name', defaultTunnelName(f)),
          serverId: f.hostId,
          groupId: groupId !== null && groupIds[groupId] === true ? groupId : null,
          type: f.type,
          listenHost: f.bindAddress,
          listenPort: f.localPort,
          destHost: f.remoteHost,
          destPort: f.remotePort,
          destServerId: pass.str(key, 'destServerId', ''),
          autoReconnect: pass.bool(key, 'autoReconnect'),
          enabled: f.enabled
        });
      }
    } catch (err) {
      Logger.warn(`读取本地配置失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
    return doc;
  }

  async save(doc: SyncDocument): Promise<void> {
    if (!AppDatabase.isReady()) {
      return;
    }
    try {
      upsertAll(doc);
    } catch (err) {
      Logger.warn(`写回本地配置失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
    // 记住这一轮文档里桌面端专有的字段，供下次上行原样带回
    try {
      const pass: Passthrough = Passthrough.load();
      for (const t of doc.tunnels) {
        pass.rememberTunnel(t);
      }
      for (const g of doc.groups) {
        pass.rememberGroup(g);
      }
      pass.save();
    } catch (err) {
      Logger.warn('透传缓存更新失败', LOG_TAG);
    }
    await applyIncomingSecrets(doc);
  }
}

/** 本地没有隧道名时按类型+端口造一个（对端 name 是 min(1) 必填） */
function defaultTunnelName(rule: PortForwardRule): string {
  return `${rule.type}-${rule.localPort}`;
}

/** 读取主机的三种凭据；全部为空时返回 undefined */
async function loadHostSecrets(hostId: string): Promise<SyncedServerSecrets | undefined> {
  try {
    const password: string = (await CredentialStore.getSecret(hostId, 'password')) ?? '';
    const passphrase: string = (await CredentialStore.getSecret(hostId, 'passphrase')) ?? '';
    if (password.length === 0 && passphrase.length === 0) {
      return undefined;
    }
    const out: SyncedServerSecrets = {};
    if (password.length > 0) {
      out.password = password;
    }
    if (passphrase.length > 0) {
      out.passphrase = passphrase;
    }
    // privateKey 暂不上行：对端会用 ssh2 校验 privateKeyFingerprint，
    // 需要与 getPublicSSH() 一致的公钥导出，另行实现（见 CLAUDE.md 同步格式约定）
    return out;
  } catch (err) {
    Logger.warn(`读取主机凭据失败 host=${hostId}`, LOG_TAG);
    return undefined;
  }
}

/**
 * 把 V1 文档写回本地库。
 *
 * 关键约束：文档只承载交集字段，本机专有字段（groupId / appearanceId / jumpHostId /
 * initCommands / envVars / termType / 分组 order）在文档里根本不存在，写回时必须从
 * 现有行里原样保留，绝不能用默认值覆盖。appearance / snippets / knownHosts 不参与
 * 同步，此处一行都不碰。
 */
function upsertAll(doc: SyncDocument): void {
  Logger.info(`[SyncDB] 开始写回本地数据库：云端包含 ${doc.servers.length} 台主机，${doc.groups.length} 个分组，${doc.tunnels.length} 条端口转发`, LOG_TAG);

  const keepGroup: Record<string, boolean> = {};
  for (const item of doc.groups) {
    keepGroup[item.id] = true;
    const old: HostGroup | null = AppDatabase.groups().getById(item.id);
    if (old !== null) {
      // order 是本机专有排序，文档里没有，保留原值
      AppDatabase.groups().update({ id: item.id, name: item.name, order: old.order });
      Logger.info(`[SyncDB] 更新分组: id=${item.id}, name=${item.name}`, LOG_TAG);
    } else {
      AppDatabase.groups().insert({ id: item.id, name: item.name, order: 0 });
      Logger.info(`[SyncDB] 新增分组: id=${item.id}, name=${item.name}`, LOG_TAG);
    }
  }
  for (const old of AppDatabase.groups().listAll()) {
    if (keepGroup[old.id] !== true) {
      AppDatabase.groups().deleteById(old.id);
      Logger.info(`[SyncDB] 删除多余本地分组: id=${old.id}, name=${old.name}`, LOG_TAG);
    }
  }

  const keepHost: Record<string, boolean> = {};
  for (const item of doc.servers) {
    keepHost[item.id] = true;
    const old: HostProfile | null = AppDatabase.hosts().getById(item.id);
    const p = item.profile;
    if (old !== null) {
      AppDatabase.hosts().update({
        id: old.id,
        name: p.name,
        host: p.host,
        port: p.port,
        username: p.username,
        authType: p.authType,
        hostFingerprint: p.hostFingerprint,
        keepalive: p.keepalive,
        // 以下均为本机专有，文档不承载，保留现有值
        groupId: old.groupId,
        appearanceId: old.appearanceId,
        jumpHostId: old.jumpHostId,
        initCommands: old.initCommands,
        envVars: old.envVars,
        termType: old.termType
      });
      Logger.info(`[SyncDB] 更新主机: id=${old.id}, name=${p.name}, addr=${p.username}@${p.host}:${p.port}`, LOG_TAG);
    } else {
      AppDatabase.hosts().insert({
        id: p.id,
        name: p.name,
        host: p.host,
        port: p.port,
        username: p.username,
        authType: p.authType,
        hostFingerprint: p.hostFingerprint,
        keepalive: p.keepalive,
        groupId: null,
        appearanceId: null,
        jumpHostId: null,
        initCommands: [],
        envVars: {},
        termType: 'xterm-256color'
      });
      Logger.info(`[SyncDB] 新增入库主机: id=${p.id}, name=${p.name}, addr=${p.username}@${p.host}:${p.port}`, LOG_TAG);
    }
  }
  for (const old of AppDatabase.hosts().listAll()) {
    if (keepHost[old.id] !== true) {
      AppDatabase.hosts().deleteById(old.id);
      Logger.info(`[SyncDB] 删除多余本地主机: id=${old.id}, name=${old.name}`, LOG_TAG);
    }
  }

  const keepFwd: Record<string, boolean> = {};
  for (const item of doc.tunnels) {
    // 本 App 不支持 relay，落库时跳过，但透传缓存已记住，上行时会原样带回
    if (item.type !== 'local' && item.type !== 'remote' && item.type !== 'dynamic') {
      continue;
    }
    keepFwd[item.id] = true;
    const rule: PortForwardRule = {
      id: item.id,
      hostId: item.serverId,
      type: item.type as PortForwardType,
      bindAddress: item.listenHost,
      localPort: item.listenPort,
      remoteHost: item.destHost,
      remotePort: item.destPort,
      enabled: item.enabled
    };
    if (AppDatabase.forwards().getById(item.id) !== null) {
      AppDatabase.forwards().update(rule);
      Logger.info(`[SyncDB] 更新端口转发: id=${item.id}, ${item.type} :${item.listenPort}`, LOG_TAG);
    } else {
      AppDatabase.forwards().insert(rule);
      Logger.info(`[SyncDB] 新增端口转发: id=${item.id}, ${item.type} :${item.listenPort}`, LOG_TAG);
    }
  }
  for (const old of AppDatabase.forwards().listAll()) {
    if (keepFwd[old.id] !== true) {
      AppDatabase.forwards().deleteById(old.id);
      Logger.info(`[SyncDB] 删除多余本地端口转发: id=${old.id}`, LOG_TAG);
    }
  }
  Logger.info(`[SyncDB] 本地数据库写回完成，当前库内主机总数: ${AppDatabase.hosts().listAll().length}`, LOG_TAG);
}

async function applyIncomingSecrets(doc: SyncDocument): Promise<void> {
  if (!SettingsRepository.isSyncPasswords() && !SettingsRepository.isSyncPrivateKeys()) {
    return;
  }
  for (const server of doc.servers) {
    const secrets: SyncedServerSecrets | undefined = server.secrets;
    if (secrets === undefined) {
      continue;
    }
    try {
      if (SettingsRepository.isSyncPasswords()) {
        if (secrets.password !== undefined && secrets.password.length > 0) {
          await CredentialStore.setSecret(server.id, 'password', secrets.password);
        }
        if (secrets.passphrase !== undefined && secrets.passphrase.length > 0) {
          await CredentialStore.setSecret(server.id, 'passphrase', secrets.passphrase);
        }
      }
      // 远端私钥是 base64 且带 ssh2 指纹，解码与校验尚未实现，先不写回本地，
      // 避免把 base64 当成 PEM 存进凭据库
    } catch (err) {
      Logger.warn(`写回凭据失败 host=${server.id}`, LOG_TAG);
    }
  }
}

export class SyncRuntime {
  private static inst: SyncRuntime | null = null;

  readonly api: ApiClient;
  readonly auth: AuthSession;
  readonly coordinator: SyncCoordinator;
  readonly triggers: SyncTriggers;
  readonly vault: NativeVaultCrypto;
  private readonly authStore: SettingsAuthStore;
  // 监听器保持同一函数对象，注销时才摘得掉（NetworkWatcher 按引用比对）
  private readonly onNetAvailable: NetworkChangeListener = (_snapshot: NetSnapshot): void => {
    this.triggers.notifyNetworkAvailable();
  };
  private readonly onNetLost: NetworkLostListener = (): void => {
    this.triggers.notifyNetworkLost();
  };

  static get(): SyncRuntime {
    if (SyncRuntime.inst === null) {
      SyncRuntime.inst = new SyncRuntime();
    }
    return SyncRuntime.inst;
  }

  private constructor() {
    const store: SettingsAuthStore = new SettingsAuthStore();
    this.authStore = store;
    this.api = new ApiClient(createProductionTransport(), store);
    this.auth = new AuthSession(this.api, store);
    this.vault = new NativeVaultCrypto();
    this.coordinator = new SyncCoordinator(this.api, this.auth, new DaoDocumentStore(),
      this.vault);
    this.triggers = new SyncTriggers(this.coordinator);
  }

  async start(): Promise<void> {
    // token 落 asset，构造时同步读到的是空值；hydrate 后按真实登录状态纠正协调器初始相位
    await this.ensureHydrated();
    setConfigSavedHook((): void => {
      this.triggers.notifySaved();
    });
    const minutes: number = SettingsRepository.getSyncPollIntervalMinutes();
    this.triggers.startPolling(minutes > 0 ? minutes * 60 * 1000 : 0);
    this.watchNetwork();
    Logger.info('同步运行时已启动', LOG_TAG);
  }

  stop(): void {
    setConfigSavedHook(null);
    this.triggers.stop();
    this.unwatchNetwork();
    this.vault.close();
  }

  notifyForeground(): void {
    this.triggers.notifyForeground();
  }

  /**
   * 供页面 aboutToAppear 等待一次：start() 是 fire-and-forget，页面可能在 hydrate 完成前
   * 就已构造（会短暂读到空 token）；hydrate() 本身幂等，这里重复调用零成本。
   * 若用户已登录且保险库尚未解锁，尝试用系统 ASSET 存储的同步密码自动解锁。
   */
  async ensureHydrated(): Promise<void> {
    await this.authStore.hydrate();
    if (this.auth.isSignedIn() && this.coordinator.phase === 'signed_out') {
      this.coordinator.phase = 'idle';
    }
    if (this.auth.isSignedIn() && !this.vault.isReady()) {
      await this.tryAutoUnlockVault();
    }
  }

  /**
   * 尝试使用系统 ASSET 存储的同步密码自动解锁保险库（实现冷启动/退出页面后免重复输入）
   */
  async tryAutoUnlockVault(): Promise<boolean> {
    if (!this.auth.isSignedIn() || this.vault.isReady()) {
      return this.vault.isReady();
    }
    try {
      const savedPwd: string | null = await CredentialStore.getSyncPassword();
      if (savedPwd === null || savedPwd.length === 0) {
        return false;
      }
      const env: VaultEnvelope = await this.api.getVaultEnvelope();
      SettingsRepository.setSyncVaultId(env.id);
      if (this.vault.unlockPassword(savedPwd, env)) {
        Logger.info('已使用保存的同步密码自动解锁保险库', LOG_TAG);
        if (this.coordinator.phase === 'signed_out' || this.coordinator.phase === 'idle') {
          this.coordinator.phase = 'idle';
        }
        return true;
      }
      if (env.keyVersion > 1 && this.vault.unlockPassword(savedPwd, env, env.keyVersion - 1)) {
        Logger.info('已按旧 keyVersion 自动解锁保险库', LOG_TAG);
        return true;
      }
      Logger.warn('自动解锁失败：保存的同步密码与云端不匹配', LOG_TAG);
      return false;
    } catch (err) {
      Logger.warn(`自动解锁保险库异常: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  createViewModel(): AccountSyncViewModel {
    return new AccountSyncViewModel({
      api: this.api,
      auth: this.auth,
      coordinator: this.coordinator,
      triggers: this.triggers,
      vault: this.vault
    });
  }

  /**
   * 网络监听改走共享的 NetworkWatcher（P1）：会话层（切网收敛）与同步层（网络恢复补同步）
   * 是同一份系统订阅的两个消费方，各自 createNetConnection 会白注册两遍。
   * 行为等价：默认网可用/切换 → notifyNetworkAvailable，默认网丢失 → notifyNetworkLost。
   */
  private watchNetwork(): void {
    const watcher: NetworkWatcher = NetworkWatcher.get();
    watcher.start();
    watcher.addChangeListener(this.onNetAvailable);
    watcher.addLostListener(this.onNetLost);
  }

  private unwatchNetwork(): void {
    const watcher: NetworkWatcher = NetworkWatcher.get();
    watcher.removeChangeListener(this.onNetAvailable);
    watcher.removeLostListener(this.onNetLost);
  }
}
