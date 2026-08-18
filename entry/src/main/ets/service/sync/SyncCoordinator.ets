/**
 * 同步协调器（任务 S6）+ 敏感开关（任务 S7）。
 *
 * 相位：signed_out / idle / syncing / synced / offline / conflict / error / auth_error。
 * 409 拉远端合并后重试一次。关闭密码/私钥开关时标记需要轮换（S7）。
 */

import { util } from '@kit.ArkTS';
import { Logger } from '../../common/utils/Logger';
import { SettingsRepository } from '../../repository/SettingsRepository';
import {
  AES_ALGORITHM,
  RECOVERY_KEY_CHECK_HEX_LEN,
  RECOVERY_KEY_PREFIX,
  RECOVERY_KEY_RAW_B64URL_LEN,
  REVISION_INITIAL,
  SCHEMA_VERSION,
  SCHEMA_VERSION_MAX,
  SyncPhaseName
} from '../../common/sync/SyncProtocol';
import { ApiClient, newIdempotencyKey } from './ApiClient';
import { ApiError, EncryptedDocument, VaultEnvelope } from './ApiTypes';
import { AuthSession } from './AuthSession';
import { applyConflictChoice, MergeResult, SyncConflict, mergeDocuments } from './SyncMerge';
import {
  SyncDocument,
  applySensitiveFlags,
  emptySyncDocument,
  parseDocumentJson,
  serializeDocument
} from './SyncSerializer';

const LOG_TAG: string = 'SyncCoord';

export interface SyncDocumentStore {
  load(): Promise<SyncDocument>;
  save(doc: SyncDocument): Promise<void>;
}

export interface RotateOutcome {
  envelope: VaultEnvelope;
  recoveryKey: string;
}

export interface SyncCrypto {
  /** 保险库是否已解锁（未解锁时协调器应转 'locked' 而非发起网络请求） */
  isReady(): boolean;
  encrypt(plain: string): EncryptedDocument;
  decrypt(doc: EncryptedDocument): string;
  rotate(password: string): RotateOutcome | null;
}

/** 探测云端 baseRevision：无文档时按 REVISION_INITIAL 处理（api-v1.md §6.1） */
export async function fetchBaseRevision(api: ApiClient): Promise<string> {
  try {
    const rev: string = await api.headDocument();
    return rev.length > 0 ? rev : `${REVISION_INITIAL}`;
  } catch (err) {
    if (err instanceof ApiError) {
      if (err.code === 'SYNC_DOCUMENT_NOT_FOUND') {
        return `${REVISION_INITIAL}`;
      }
      // ArkTS「throw 只认 Error 子类」（arkts-limited-throw）：捕获的 err 静态类型不是
      // Error，不能直接 rethrow，需重新构造一个
      throw new ApiError(err.code, err.status, err.message);
    }
    throw new Error('探测云端文档失败');
  }
}

export class SyncCoordinator {
  phase: SyncPhaseName = 'signed_out';
  lastError: string = '';
  conflicts: SyncConflict[] = [];
  pendingLocal: SyncDocument | null = null;
  pendingRemote: SyncDocument | null = null;
  pendingMerged: SyncDocument | null = null;
  rotateRequired: boolean = false;
  lastRecoveryKey: string = '';

  private readonly api: ApiClient;
  private readonly auth: AuthSession;
  private readonly store: SyncDocumentStore;
  private readonly crypto: SyncCrypto | null;
  private baseJson: string = '';
  private syncPasswords: boolean = false;
  private syncPrivateKeys: boolean = false;

  constructor(api: ApiClient, auth: AuthSession, store: SyncDocumentStore, crypto: SyncCrypto | null) {
    this.api = api;
    this.auth = auth;
    this.store = store;
    this.crypto = crypto;
    this.phase = auth.isSignedIn() ? 'idle' : 'signed_out';
    this.syncPasswords = SettingsRepository.isSyncPasswords();
    this.syncPrivateKeys = SettingsRepository.isSyncPrivateKeys();
  }

  /** 保存后防抖触发前先标脏（离线队列） */
  async markDirty(): Promise<void> {
    if (this.phase === 'signed_out') {
      return;
    }
    this.pendingLocal = await this.store.load();
  }

  markOffline(): void {
    if (this.phase === 'signed_out' || this.phase === 'conflict') {
      return;
    }
    this.phase = 'offline';
  }

  onSignedOut(): void {
    this.phase = 'signed_out';
    this.conflicts = [];
    this.pendingLocal = null;
    this.pendingRemote = null;
    this.pendingMerged = null;
    this.lastError = '';
  }

  /**
   * S7：改敏感开关。从开到关 → 必须轮换（调用方随后提供同步密码走 rotateAndClear）。
   */
  setSensitiveFlags(syncPasswords: boolean, syncPrivateKeys: boolean): void {
    const wasPw: boolean = this.syncPasswords;
    const wasKey: boolean = this.syncPrivateKeys;
    this.syncPasswords = syncPasswords;
    this.syncPrivateKeys = syncPrivateKeys;
    SettingsRepository.setSyncPasswords(syncPasswords);
    SettingsRepository.setSyncPrivateKeys(syncPrivateKeys);
    if ((wasPw && !syncPasswords) || (wasKey && !syncPrivateKeys)) {
      this.rotateRequired = true;
      Logger.info('敏感同步已关闭，需轮换保险库密钥', LOG_TAG);
    }
    void this.markDirty();
  }

  async syncNow(): Promise<void> {
    if (!this.auth.isSignedIn()) {
      this.phase = 'signed_out';
      return;
    }
    this.phase = 'syncing';
    this.lastError = '';
    try {
      await this.runSync();
      if (this.isTerminalPhase()) {
        // runSync 内部已就地决出终态（如 VAULT_NOT_FOUND / 未解锁 / schema 过高），不再覆盖
        return;
      }
      if (this.conflicts.length > 0) {
        this.phase = 'conflict';
      } else {
        this.phase = 'synced';
      }
    } catch (err) {
      await this.applyError(err);
    }
  }

  /**
   * this.phase 是否已在 runSync() 内部就地决出终态。
   * 独立成方法调用是刻意的：ArkTS 会把 this.phase 的类型窄化在赋值 'syncing' 那一刻，
   * 之后即便隔着 await 也不会因为被调用方法可能改写它而重新加宽，导致同一函数内直接比较
   * 会被判定为「字面量类型无交集」而编译失败；经方法调用返回可以拿回完整的 SyncPhaseName。
   */
  private isTerminalPhase(): boolean {
    return this.phase === 'error' || this.phase === 'locked';
  }

  async resolveAll(keepLocal: boolean): Promise<void> {
    if (this.pendingMerged === null || this.pendingLocal === null || this.pendingRemote === null) {
      return;
    }
    let doc: SyncDocument = this.pendingMerged;
    for (const c of this.conflicts) {
      doc = applyConflictChoice(doc, this.pendingLocal, this.pendingRemote, c, keepLocal);
    }
    this.conflicts = [];
    await this.store.save(doc);
    this.pendingMerged = null;
    this.pendingLocal = null;
    this.pendingRemote = null;
    await this.syncNow();
  }

  lastSyncLog: string = '';
  lastSyncSummary: string = '';

  private async runSync(): Promise<void> {
    if (this.crypto === null) {
      Logger.error('[Sync] 同步密码学未就绪', LOG_TAG);
      throw new Error('同步密码学未就绪');
    }
    if (!this.crypto.isReady()) {
      Logger.warn('[Sync] 保险库处于锁定状态，无法同步文档', LOG_TAG);
      this.phase = 'locked';
      this.lastError = 'VAULT_LOCKED';
      this.lastSyncSummary = '保险库已锁定，未执行同步';
      return;
    }
    const local: SyncDocument = await this.store.load();
    applySensitiveFlags(local, this.syncPasswords, this.syncPrivateKeys);
    Logger.info(`[Sync] 1/4 读取本地文档：包含 ${local.servers.length} 台主机，${local.groups.length} 个分组，${local.tunnels.length} 条端口转发`, LOG_TAG);

    let remoteRev: string = '';
    try {
      remoteRev = await this.api.headDocument();
      Logger.info(`[Sync] 2/4 云端文档探测成功，最新版本号: ${remoteRev}`, LOG_TAG);
    } catch (err) {
      if (err instanceof ApiError && err.code === 'SYNC_DOCUMENT_NOT_FOUND') {
        Logger.info(`[Sync] 云端尚无文档（404），直接将本地文档上传为初始版本（本地主机数=${local.servers.length}）`, LOG_TAG);
        await this.uploadOrLock(local, `${REVISION_INITIAL}`);
        this.lastSyncSummary = `云端初始为空，已上传本地 ${local.servers.length} 台主机`;
        return;
      }
      if (err instanceof ApiError && err.code === 'VAULT_NOT_FOUND') {
        Logger.warn('[Sync] 云端尚未创建保险库，转入未建库状态', LOG_TAG);
        this.phase = 'locked';
        this.lastError = 'VAULT_NOT_FOUND';
        this.lastSyncSummary = '云端尚未创建保险库';
        return;
      }
      if (err instanceof ApiError) {
        Logger.error(`[Sync] 探测云端文档失败 (HTTP ${err.status}): ${err.message}`, LOG_TAG);
        throw new ApiError(err.code, err.status, err.message);
      }
      Logger.error(`[Sync] 探测云端文档发生未知异常: ${JSON.stringify(err)}`, LOG_TAG);
      throw new Error('探测云端文档失败');
    }

    const enc: EncryptedDocument = await this.api.getDocument();
    Logger.info(`[Sync] 3/4 下载并解密云端加密文档 (rev=${enc.revision}, keyVersion=${enc.keyVersion})...`, LOG_TAG);
    const decryptedJson: string = this.crypto.decrypt(enc);
    const remote: SyncDocument = parseDocumentJson(decryptedJson);

    const remoteServerList: string[] = remote.servers.map((s) => {
      const p = s.profile;
      return `${p.name.length > 0 ? p.name : p.host} (${p.username}@${p.host}:${p.port})`;
    });
    Logger.info(`[Sync] 云端解密成功！包含 ${remote.servers.length} 台主机: [${remoteServerList.join('; ')}], ${remote.groups.length} 个分组, ${remote.tunnels.length} 条端口转发`, LOG_TAG);

    if (remote.schemaVersion > SCHEMA_VERSION_MAX || remote.schemaVersion > SCHEMA_VERSION) {
      this.lastError = '远端文档版本更高，请升级应用';
      this.phase = 'error';
      this.lastSyncSummary = '远端文档版本过高，需升级应用';
      Logger.warn(`[Sync] 远端 schemaVersion=${remote.schemaVersion} 高于本机支持的最大版本`, LOG_TAG);
      return;
    }
    const base: SyncDocument = this.baseJson.length > 0 ?
      parseDocumentJson(this.baseJson) : emptySyncDocument();
    const merged: MergeResult = mergeDocuments(base, local, remote);
    Logger.info(`[Sync] 4/4 三方合并完成：最终包含 ${merged.document.servers.length} 台主机, ${merged.document.groups.length} 个分组, ${merged.document.tunnels.length} 条端口转发, 冲突数=${merged.conflicts.length}`, LOG_TAG);

    if (merged.conflicts.length > 0) {
      this.conflicts = merged.conflicts;
      this.pendingLocal = local;
      this.pendingRemote = remote;
      this.pendingMerged = merged.document;
      this.lastSyncSummary = `同步完成，但发现 ${merged.conflicts.length} 处冲突待处理`;
      return;
    }
    try {
      await this.upload(merged.document, enc.revision.length > 0 ? enc.revision : remoteRev);
      this.lastSyncSummary = `同步成功：云端拉取 ${remote.servers.length} 台，合并后共 ${merged.document.servers.length} 台主机`;
      Logger.info(`[Sync] 同步全流程成功完成！当前本地/云端一致，共 ${merged.document.servers.length} 台主机`, LOG_TAG);
    } catch (err) {
      if (err instanceof ApiError && err.code === 'SYNC_REVISION_CONFLICT') {
        Logger.warn('[Sync] 发生并发版本冲突 (409)，重新拉取最新文档重试...', LOG_TAG);
        const again: EncryptedDocument = await this.api.getDocument();
        const remote2: SyncDocument = parseDocumentJson(this.crypto.decrypt(again));
        const merge2: MergeResult = mergeDocuments(remote, local, remote2);
        if (merge2.conflicts.length > 0) {
          this.conflicts = merge2.conflicts;
          this.pendingLocal = local;
          this.pendingRemote = remote2;
          this.pendingMerged = merge2.document;
          this.lastSyncSummary = `重试合并发现 ${merge2.conflicts.length} 处冲突`;
          return;
        }
        await this.uploadOrLock(merge2.document, again.revision);
        this.lastSyncSummary = `重试合并同步成功，共 ${merge2.document.servers.length} 台主机`;
        return;
      }
      if (this.handleVaultKeyMismatch(err)) {
        this.lastSyncSummary = '密钥版本不匹配，需重新解锁';
        return;
      }
      if (err instanceof ApiError) {
        throw new ApiError(err.code, err.status, err.message);
      }
      throw new Error('上传同步文档失败');
    }
  }

  /** upload() 的包装：把 VAULT_KEY_VERSION_MISMATCH 转成 'locked' 而不是当普通失败抛出 */
  private async uploadOrLock(doc: SyncDocument, ifMatch: string): Promise<void> {
    try {
      await this.upload(doc, ifMatch);
    } catch (err) {
      if (this.handleVaultKeyMismatch(err)) {
        return;
      }
      if (err instanceof ApiError) {
        throw new ApiError(err.code, err.status, err.message);
      }
      throw new Error('上传同步文档失败');
    }
  }

  /** 云端已被别的设备轮换过密钥：本地 vault key 过期，需重新解锁而非当普通失败重试 */
  private handleVaultKeyMismatch(err: Object): boolean {
    if (err instanceof ApiError && err.code === 'VAULT_KEY_VERSION_MISMATCH') {
      this.phase = 'locked';
      this.lastError = 'VAULT_KEY_VERSION_MISMATCH';
      return true;
    }
    return false;
  }

  private async upload(doc: SyncDocument, ifMatch: string): Promise<void> {
    if (this.crypto === null) {
      throw new Error('同步密码学未就绪');
    }
    doc.schemaVersion = SCHEMA_VERSION;
    doc.updatedAt = new Date().toISOString();
    const json: string = serializeDocument(doc);
    const enc: EncryptedDocument = this.crypto.encrypt(json);
    const rev: string = await this.api.putDocument(enc, ifMatch, newIdempotencyKey());
    await this.store.save(doc);
    this.baseJson = json;
    SettingsRepository.setSyncLastRevision(rev);
  }

  async rotateAndClearHistory(accountPassword: string, syncPassword: string): Promise<string> {
    if (!this.auth.isSignedIn() || this.crypto === null) {
      return '';
    }
    if (!this.crypto.isReady()) {
      this.phase = 'locked';
      this.lastError = 'VAULT_LOCKED';
      return '';
    }
    this.phase = 'syncing';
    try {
      const local: SyncDocument = await this.store.load();
      applySensitiveFlags(local, this.syncPasswords, this.syncPrivateKeys);
      const json: string = serializeDocument(local);
      const wrapPwd: string = syncPassword.length > 0 ? syncPassword : accountPassword;
      const rotated: RotateOutcome | null = this.crypto.rotate(wrapPwd);
      if (rotated === null) {
        throw new Error('保险库轮换失败（未解锁或密码错误）');
      }
      this.lastRecoveryKey = rotated.recoveryKey;
      const enc: EncryptedDocument = this.crypto.encrypt(json);
      // AAD 绑定 keyVersion（aad.hpp），文档必须用 rotate 后的新版本重新加密后再对齐一次
      enc.keyVersion = rotated.envelope.keyVersion;
      const baseRevision: string = await fetchBaseRevision(this.api);
      const newRev: string = await this.api.rotateVault(accountPassword, rotated.envelope, enc,
        baseRevision, newIdempotencyKey());
      if (newRev.length > 0) {
        SettingsRepository.setSyncLastRevision(newRev);
      }
      try {
        await this.api.clearRevisions(SettingsRepository.getSyncLastRevision());
      } catch (_err) {
        // rotate 已原子清空历史；再调一次以防旧服务端未清
      }
      this.rotateRequired = false;
      this.phase = 'synced';
      Logger.info('保险库已轮换，云端历史已清空', LOG_TAG);
      return this.lastRecoveryKey;
    } catch (err) {
      await this.applyError(err);
      return '';
    }
  }

  private async applyError(err: Object): Promise<void> {
    if (err instanceof ApiError) {
      if (err.code.indexOf('AUTH_') === 0) {
        this.phase = 'auth_error';
      } else {
        this.phase = 'error';
      }
      this.lastError = err.code;
      return;
    }
    this.phase = 'offline';
    this.lastError = err instanceof Error ? err.message : '同步失败';
    if (this.pendingLocal === null) {
      this.pendingLocal = await this.store.load();
    }
  }
}

/** 测试用恢复密钥格式串（格式对齐 SPM1）；生产恢复密钥由 native vaultCreate/vaultRotate 产出 */
export function newRecoveryKeyPlaceholder(): string {
  const raw: string =
    util.generateRandomUUID().replace(/-/g, '') + util.generateRandomUUID().replace(/-/g, '');
  const mid: string = raw.substring(0, RECOVERY_KEY_RAW_B64URL_LEN);
  const check: string = raw.substring(0, RECOVERY_KEY_CHECK_HEX_LEN).toUpperCase();
  return `${RECOVERY_KEY_PREFIX}-${mid}-${check}`;
}

/** 测试用：明文当密文，hash 用固定 64 hex（不走 native）；rotate 自增 keyVersion 模拟真实轮换 */
export class PlainCrypto implements SyncCrypto {
  private version: number = 1;

  isReady(): boolean {
    return true;
  }

  encrypt(plain: string): EncryptedDocument {
    return {
      revision: '',
      schemaVersion: SCHEMA_VERSION,
      keyVersion: this.version,
      algorithm: AES_ALGORITHM,
      nonce: 'AAAAAAAAAAAAAAAA',
      ciphertext: plain,
      ciphertextHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      updatedAt: ''
    };
  }

  decrypt(doc: EncryptedDocument): string {
    return doc.ciphertext;
  }

  rotate(_password: string): RotateOutcome | null {
    this.version = this.version + 1;
    return {
      envelope: {
        id: '',
        keyVersion: this.version,
        passwordWrappedKey: 'A',
        passwordWrapNonce: 'B',
        recoveryWrappedKey: 'C',
        recoveryWrapNonce: 'D',
        kdfSalt: 'E',
        kdfMemory: 0,
        kdfIterations: 0,
        kdfParallelism: 0
      },
      recoveryKey: newRecoveryKeyPlaceholder()
    };
  }
}
