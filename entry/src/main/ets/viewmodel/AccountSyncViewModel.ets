/**
 * 账号与同步页 VM（任务 U6 / U7）。
 */

import { Logger } from '../common/utils/Logger';
import { CredentialStore } from '../repository/CredentialStore';
import { SettingsRepository } from '../repository/SettingsRepository';
import {
  AES_NONCE_LEN,
  AES_TAG_LEN,
  ARGON2_HASH_LEN,
  ARGON2_ITERATIONS,
  ARGON2_MEMORY_KIB,
  ARGON2_PARALLELISM,
  KDF_SALT_LEN,
  SyncPhaseName
} from '../common/sync/SyncProtocol';
import { ApiClient, newIdempotencyKey } from '../service/sync/ApiClient';
import { ApiError, AuthResult, DeviceItem, RevisionItem, TokenProvider, VaultEnvelope } from
  '../service/sync/ApiTypes';
import { AuthSession, AuthStore } from '../service/sync/AuthSession';
import { SyncConflict } from '../service/sync/SyncMerge';
import { SyncCoordinator, SyncDocumentStore, fetchBaseRevision } from '../service/sync/SyncCoordinator';
import { emptySyncDocument, SyncDocument } from '../service/sync/SyncSerializer';
import { SyncTriggers } from '../service/sync/SyncTriggers';
import { NativeVaultCrypto, VaultCreateOutcome } from '../service/sync/VaultNative';

const LOG_TAG: string = 'AccountSyncVM';

export interface AccountSyncDeps {
  api: ApiClient;
  auth: AuthSession;
  coordinator: SyncCoordinator;
  triggers?: SyncTriggers;
  vault?: NativeVaultCrypto;
}

@ObservedV2
export class AccountSyncViewModel {
  @Trace email: string = '';
  @Trace password: string = '';
  @Trace invite: string = '';
  @Trace phase: SyncPhaseName = 'signed_out';
  @Trace statusText: string = '未登录';
  @Trace signedIn: boolean = false;
  @Trace userEmail: string = '';
  @Trace deviceId: string = '';
  @Trace devices: DeviceItem[] = [];
  @Trace conflicts: SyncConflict[] = [];
  @Trace errorText: string = '';
  @Trace recoveryKey: string = '';
  @Trace recoveryAck: boolean = false;
  @Trace syncPasswords: boolean = false;
  @Trace syncPrivateKeys: boolean = false;
  @Trace rotateHint: boolean = false;
  @Trace revisions: RevisionItem[] = [];
  @Trace currentPassword: string = '';
  @Trace newPassword: string = '';
  @Trace rotatePassword: string = '';
  @Trace deletePassword: string = '';
  @Trace renameDraft: string = '';
  @Trace vaultLocked: boolean = false;
  @Trace vaultMissing: boolean = false;
  @Trace unlockPassword: string = '';
  @Trace recoveryUnlock: string = '';
  @Trace createSyncPassword: string = '';
  @Trace createSyncPassword2: string = '';
  @Trace rotateAccountPassword: string = '';
  /** 云端信封的包裹 AAD 与其 keyVersion 不一致（旧版轮换缺陷），需重新包装 */
  @Trace envelopeNeedsRepair: boolean = false;
  @Trace repairAccountPassword: string = '';
  @Trace repairSyncPassword: string = '';
  @Trace lastSyncSummary: string = '';

  private readonly api: ApiClient;
  private readonly auth: AuthSession;
  private readonly coord: SyncCoordinator;
  private readonly triggers: SyncTriggers | null;
  private readonly vault: NativeVaultCrypto | null;

  constructor(deps: AccountSyncDeps) {
    this.api = deps.api;
    this.auth = deps.auth;
    this.coord = deps.coordinator;
    this.triggers = deps.triggers ?? null;
    this.vault = deps.vault ?? null;
    this.refreshFromAuth();
  }

  refreshFromAuth(): void {
    this.signedIn = this.auth.isSignedIn();
    this.userEmail = this.auth.email();
    this.deviceId = this.auth.deviceId();
    this.phase = this.coord.phase;
    this.conflicts = this.coord.conflicts;
    this.rotateHint = this.coord.rotateRequired;
    this.syncPasswords = SettingsRepository.isSyncPasswords();
    this.syncPrivateKeys = SettingsRepository.isSyncPrivateKeys();
    this.lastSyncSummary = this.coord.lastSyncSummary;
    this.vaultLocked = this.signedIn && !this.vaultMissing && this.vault !== null &&
      !this.vault.isReady();
    if (this.vaultMissing && this.signedIn) {
      this.phase = 'locked';
      this.statusText = '尚未设置同步密码';
    } else if (this.vaultLocked) {
      this.phase = 'locked';
      this.statusText = this.phaseLabel('locked');
    } else {
      this.statusText = this.phaseLabel(this.phase);
    }
    this.errorText = this.coord.lastError;
  }

  async register(): Promise<void> {
    this.errorText = '';
    try {
      await this.auth.register(this.email.trim(), this.password, 'HarmonyOS', this.invite.trim());
      this.password = '';
      await this.probeVault();
      this.refreshFromAuth();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '注册失败';
      Logger.warn(`注册失败: ${this.errorText}`, LOG_TAG);
    }
  }

  async login(): Promise<void> {
    this.errorText = '';
    try {
      await this.auth.login(this.email.trim(), this.password, 'HarmonyOS');
      this.password = '';
      await this.probeVault();
      this.refreshFromAuth();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '登录失败';
    }
  }

  async unlockVault(): Promise<void> {
    this.errorText = '';
    const pwd: string = this.unlockPassword;
    this.unlockPassword = '';
    try {
      await this.unlockExistingVault(pwd);
      this.refreshFromAuth();
      if (!this.vaultLocked) {
        // 解锁成功：持久化同步密码到系统 ASSET 加密存储，冷启动自动解锁
        void CredentialStore.setSyncPassword(pwd).catch((e: Object) => {
          Logger.warn(`同步密码持久化失败: ${JSON.stringify(e)}`, LOG_TAG);
        });
        if (this.triggers !== null) {
          this.triggers.notifyLogin();
        }
        await this.sync();
      }
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '解锁失败';
    }
  }

  async createVault(): Promise<void> {
    this.errorText = '';
    const pwd: string = this.createSyncPassword;
    const again: string = this.createSyncPassword2;
    if (pwd.length < 10) {
      this.errorText = '同步密码至少 10 位';
      return;
    }
    if (pwd !== again) {
      this.errorText = '两次同步密码不一致';
      return;
    }
    this.createSyncPassword = '';
    this.createSyncPassword2 = '';
    try {
      await this.createNewVault(pwd);
      this.refreshFromAuth();
      // 创建成功：持久化同步密码到系统 ASSET 加密存储，冷启动自动解锁
      void CredentialStore.setSyncPassword(pwd).catch((e: Object) => {
        Logger.warn(`同步密码持久化失败: ${JSON.stringify(e)}`, LOG_TAG);
      });
      if (this.triggers !== null) {
        this.triggers.notifyLogin();
      }
      await this.sync();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '创建保险库失败';
    }
  }

  async unlockWithRecovery(): Promise<void> {
    if (this.vault === null) {
      return;
    }
    this.errorText = '';
    const key: string = this.recoveryUnlock;
    this.recoveryUnlock = '';
    try {
      const env: VaultEnvelope = await this.api.getVaultEnvelope();
      // 恢复解锁不走 Argon2（KEK 由恢复密钥 HKDF 派生），所以与 KDF 参数无关，
      // 但 keyVersion 仍参与包裹 AAD，信封坏掉一样会被误报成「恢复密钥无效」
      if (env.keyVersion < 1) {
        this.errorText = '云端数据版本异常，无法解锁，请重新登录或联系支持';
        this.refreshFromAuth();
        return;
      }
      if (!this.vault.unlockRecovery(key, env)) {
        this.errorText = '恢复密钥无效';
        this.refreshFromAuth();
        return;
      }
      SettingsRepository.setSyncVaultId(env.id);
      this.refreshFromAuth();
      await this.sync();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '恢复解锁失败';
    }
  }

  async logout(): Promise<void> {
    if (this.vault !== null) {
      this.vault.close();
    }
    // 清理已保存的同步密码
    void CredentialStore.removeSyncPassword().catch((_e: Object) => {});
    await this.auth.logout();
    this.coord.onSignedOut();
    this.devices = [];
    this.revisions = [];
    this.vaultMissing = false;
    this.envelopeNeedsRepair = false;
    this.refreshFromAuth();
  }

  async logoutAll(): Promise<void> {
    if (this.vault !== null) {
      this.vault.close();
    }
    // 清理已保存的同步密码
    void CredentialStore.removeSyncPassword().catch((_e: Object) => {});
    await this.auth.logoutAll();
    this.coord.onSignedOut();
    this.devices = [];
    this.revisions = [];
    this.vaultMissing = false;
    this.envelopeNeedsRepair = false;
    this.refreshFromAuth();
  }

  /** 登录后只探测信封，不用账号密码解库（api-v1：vault 与登录是独立密钥体系） */
  private async probeVault(): Promise<void> {
    this.vaultMissing = false;
    try {
      const env: VaultEnvelope = await this.api.getVaultEnvelope();
      SettingsRepository.setSyncVaultId(env.id);
      this.vaultMissing = false;
    } catch (err) {
      if (err instanceof ApiError && err.code === 'VAULT_NOT_FOUND') {
        this.vaultMissing = true;
        return;
      }
      throw err instanceof Error ? err : new Error('探测保险库失败');
    }
  }

  private async unlockExistingVault(syncPassword: string): Promise<void> {
    if (this.vault === null || syncPassword.length === 0) {
      throw new Error('请输入同步密码');
    }
    const env: VaultEnvelope = await this.api.getVaultEnvelope();
    // native 的 UnlockWithPassword 对「密码错」「信封坏」「KDF 参数不同」一律返回 false，
    // 先把后两类分流掉，剩下的才是真的密码错；诊断信息只记形状不记内容
    const shape: string = `keyVersion=${env.keyVersion} saltLen=${env.kdfSalt.length}` +
      ` wrappedLen=${env.passwordWrappedKey.length} nonceLen=${env.passwordWrapNonce.length}` +
      ` kdf=${env.kdfMemory}/${env.kdfIterations}/${env.kdfParallelism}`;
    Logger.info(`保险库信封: ${shape}`, LOG_TAG);
    const broken: string = envelopeIntegrityError(env);
    if (broken.length > 0) {
      throw new Error(broken);
    }
    if (!kdfParamsCompatible(env)) {
      // KDF 参数与本机常量不一致：多半是别的客户端用不同参数建的库，Argon2 会派生出错误的
      // KEK 而不是明确报错——提前拦截，避免呈现成误导性的「密码错误」
      throw new Error(`同步密码参数与本设备不兼容（云端 ${env.kdfMemory}/${env.kdfIterations}/` +
        `${env.kdfParallelism}，本机 ${ARGON2_MEMORY_KIB}/${ARGON2_ITERATIONS}/${ARGON2_PARALLELISM}），` +
        '该保险库可能由其他客户端创建');
    }
    if (!this.vault.unlockPassword(syncPassword, env)) {
      // 旧版轮换缺陷（rotate 失败时只把 keyVersion +1、没换密钥）会留下这种信封：
      // 长度与 KDF 参数全对，但 wrapped key 绑定在 keyVersion-1 的 AAD 上。
      // 用上一版本号再试一次，成功即可确认成因并救回保险库。
      if (env.keyVersion > 1 && this.vault.unlockPassword(syncPassword, env, env.keyVersion - 1)) {
        this.envelopeNeedsRepair = true;
        Logger.warn(`信封 keyVersion=${env.keyVersion} 的包裹 AAD 实为 ${env.keyVersion - 1}，` +
          '疑似旧版轮换缺陷写坏，已按旧版本号解锁，建议尽快修复信封', LOG_TAG);
      } else {
        // 形状与参数都对却解不开，只可能是密码不符或包裹 AAD 与信封声明的 keyVersion 不一致。
        // 把信封形状直接带到界面上，省去翻日志（这些都不是秘密）
        throw new Error(`同步密码无法解开保险库。信封形状正常（${shape}），` +
          '请确认输入的是创建保险库时设置的「同步密码」，而不是账号登录密码');
      }
    }
    SettingsRepository.setSyncVaultId(env.id);
    this.vaultMissing = false;
  }

  /**
   * 修复被旧版轮换缺陷写坏的信封：用当前已解锁的 vault key 按云端 keyVersion 重新包装，
   * 经 PUT /vault/key-envelope 覆盖（不改 keyVersion，故无需 rotate 与清历史）。
   * 会生成新的恢复密钥——旧的那份随之作废，必须让用户重新抄写。
   */
  async repairEnvelope(): Promise<void> {
    this.errorText = '';
    const account: string = this.repairAccountPassword;
    const syncPwd: string = this.repairSyncPassword;
    this.repairAccountPassword = '';
    this.repairSyncPassword = '';
    if (this.vault === null || !this.vault.isReady()) {
      this.errorText = '请先解锁保险库再修复';
      return;
    }
    if (account.length === 0 || syncPwd.length === 0) {
      this.errorText = '请填写账号密码与同步密码';
      return;
    }
    try {
      const env: VaultEnvelope = await this.api.getVaultEnvelope();
      const fixed: VaultCreateOutcome | null = this.vault.rewrap(syncPwd, env.keyVersion);
      if (fixed === null) {
        this.errorText = '重新包装保险库密钥失败';
        return;
      }
      fixed.envelope.id = env.id;
      await this.api.rewrapVault(account, fixed.envelope);
      this.envelopeNeedsRepair = false;
      this.recoveryKey = fixed.recoveryKey;
      this.recoveryAck = false;
      // 修复成功：持久化同步密码
      void CredentialStore.setSyncPassword(syncPwd).catch((e: Object) => {
        Logger.warn(`同步密码持久化失败: ${JSON.stringify(e)}`, LOG_TAG);
      });
      Logger.info('保险库信封已修复', LOG_TAG);
      this.refreshFromAuth();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '修复信封失败';
    }
  }

  private async createNewVault(syncPassword: string): Promise<void> {
    if (this.vault === null) {
      throw new Error('保险库未就绪');
    }
    const created: VaultCreateOutcome | null = this.vault.create(syncPassword, 1);
    if (created === null) {
      throw new Error('创建保险库失败');
    }
    let id: string = '';
    try {
      id = await this.api.createVault(created.envelope, newIdempotencyKey());
    } catch (err) {
      // create() 已经在本地开了一个新 vault key 的句柄；建库没成功就必须关掉，
      // 否则 isReady() 会谎报「已解锁」，后续同步会用一把云端信封解不出的密钥加密文档
      this.vault.close();
      if (err instanceof ApiError && err.code === 'VAULT_EXISTS') {
        this.vaultMissing = false;
        throw new Error('云端已有保险库，请改用同步密码解锁');
      }
      throw err instanceof Error ? err : new Error('创建保险库失败');
    }
    SettingsRepository.setSyncVaultId(id);
    this.vault.vaultId = id;
    this.recoveryKey = created.recoveryKey;
    this.recoveryAck = false;
    this.vaultMissing = false;
  }

  async sync(): Promise<void> {
    await this.coord.syncNow();
    this.refreshFromAuth();
    if (this.signedIn) {
      try {
        this.devices = await this.api.listDevices();
      } catch (err) {
        Logger.warn(`设备列表失败: ${JSON.stringify(err)}`, LOG_TAG);
      }
      try {
        this.revisions = await this.api.listRevisions();
      } catch (err) {
        Logger.warn(`历史版本失败: ${JSON.stringify(err)}`, LOG_TAG);
      }
    }
  }

  async resolveKeepLocal(): Promise<void> {
    await this.coord.resolveAll(true);
    this.refreshFromAuth();
  }

  async resolveUseCloud(): Promise<void> {
    await this.coord.resolveAll(false);
    this.refreshFromAuth();
  }

  setSyncPasswords(value: boolean): void {
    this.syncPasswords = value;
    this.coord.setSensitiveFlags(value, this.syncPrivateKeys);
    this.refreshFromAuth();
  }

  setSyncPrivateKeys(value: boolean): void {
    this.syncPrivateKeys = value;
    this.coord.setSensitiveFlags(this.syncPasswords, value);
    this.refreshFromAuth();
  }

  ackRecovery(): void {
    this.recoveryAck = true;
    this.recoveryKey = '';
    this.coord.lastRecoveryKey = '';
  }

  async changePassword(): Promise<void> {
    this.errorText = '';
    try {
      const needReauth: boolean =
        await this.auth.changePassword(this.currentPassword, this.newPassword);
      this.currentPassword = '';
      this.newPassword = '';
      if (needReauth) {
        this.coord.onSignedOut();
        this.errorText = '密码已改，请重新登录';
      }
      this.refreshFromAuth();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '改密失败';
    }
  }

  async deleteAccount(): Promise<void> {
    this.errorText = '';
    try {
      await this.auth.deleteAccount(this.deletePassword);
      this.deletePassword = '';
      this.coord.onSignedOut();
      this.devices = [];
      this.revisions = [];
      this.refreshFromAuth();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '注销失败';
    }
  }

  async renameSelectedDevice(id: string): Promise<void> {
    const name: string = this.renameDraft.trim();
    if (name.length === 0) {
      return;
    }
    try {
      await this.api.renameDevice(id, name);
      this.renameDraft = '';
      this.devices = await this.api.listDevices();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '重命名失败';
    }
  }

  async revokeDevice(id: string): Promise<void> {
    try {
      await this.api.revokeDevice(id);
      this.devices = await this.api.listDevices();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '撤销失败';
    }
  }

  async restoreRevision(revision: string): Promise<void> {
    try {
      // 本地缓存的 revision 可能因重新登录（clearSession）或其他设备写入而过期，
      // 现取云端当前值做 If-Match，避免用陈旧值触发不必要的 409（api-v1.md §1.5）
      const ifMatch: string = await fetchBaseRevision(this.api);
      const newRev: string = await this.api.restoreRevision(revision, ifMatch, newIdempotencyKey());
      if (newRev.length > 0) {
        SettingsRepository.setSyncLastRevision(newRev);
      }
      await this.sync();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : '回滚失败';
    }
  }

  async rotateVault(): Promise<void> {
    const account: string = this.rotateAccountPassword;
    const syncPwd: string = this.rotatePassword;
    this.rotateAccountPassword = '';
    this.rotatePassword = '';
    const key: string = await this.coord.rotateAndClearHistory(account, syncPwd);
    if (key.length > 0) {
      this.recoveryKey = key;
      this.recoveryAck = false;
      // 轮换成功：持久化新的同步密码
      void CredentialStore.setSyncPassword(syncPwd).catch((e: Object) => {
        Logger.warn(`同步密码持久化失败: ${JSON.stringify(e)}`, LOG_TAG);
      });
    }
    this.refreshFromAuth();
  }

  conflictLabel(item: SyncConflict): string {
    const kind: string = item.kind === 'add-add' ? '双方新增' :
      (item.kind === 'delete-modify' ? '删除/修改' : '字段冲突');
    const sens: string = item.sensitive ? '（有变更）' : '';
    const entity: string = item.entity === 'server' ? '主机' :
      (item.entity === 'tunnel' ? '端口转发' : (item.entity === 'group' ? '分组' : '偏好'));
    return `${entity} ${item.id} · ${kind}${sens}`;
  }

  private phaseLabel(phase: SyncPhaseName): string {
    switch (phase) {
      case 'signed_out':
        return '未登录';
      case 'locked':
        return '保险库已锁定';
      case 'syncing':
        return '正在同步…';
      case 'synced':
        return '已同步';
      case 'conflict':
        return '有冲突待处理';
      case 'offline':
        return '离线';
      case 'auth_error':
        return '需要重新登录';
      case 'error':
        return '同步出错';
      default:
        return '空闲';
    }
  }
}

/**
 * 信封里的 KDF 参数与本机 Argon2 编译期常量是否一致（`entry/src/main/cpp/crypto/sync_params.h`
 * 的唯一出处对应 `common/sync/SyncProtocol.ets`）。0 视为「未取到值」，不拦截，避免误判。
 * 不一致时 native 仍会跑完 Argon2 派生，只是 KEK 派生错误，AES-GCM 解密会失败但只报「密码错误」，
 * 这里提前给出更准确的诊断。
 */
export function kdfParamsCompatible(env: VaultEnvelope): boolean {
  if (env.kdfMemory === 0 && env.kdfIterations === 0 && env.kdfParallelism === 0) {
    return true;
  }
  return env.kdfMemory === ARGON2_MEMORY_KIB && env.kdfIterations === ARGON2_ITERATIONS &&
    env.kdfParallelism === ARGON2_PARALLELISM;
}

/** n 字节标准 base64（带 padding）的字符数 */
function base64Len(bytes: number): number {
  return 4 * Math.ceil(bytes / 3);
}

/**
 * 信封字段完整性自检（纯函数，可测）。
 *
 * native 的 UnlockWithPassword 对「密码错」和「信封本身就不对」返回同一个 false，
 * 于是任何字段缺失/截断都会呈现成「同步密码错误」，把人往错方向带。这里按协议里
 * 写死的字节长度先验一遍：salt 16B、nonce 12B、passwordWrappedKey 32B 密钥 + 16B GCM tag。
 * 返回 '' 表示信封形状正常；否则返回可直接展示的原因。
 */
export function envelopeIntegrityError(env: VaultEnvelope): string {
  if (env.keyVersion < 1) {
    // 服务端把 keyVersion 发成字符串/缺字段时 readNumber 会静默给 0，而 keyVersion 参与
    // 包裹 AAD，取 0 必然解不开——这种情况和密码错完全无关
    return `云端信封的 keyVersion 异常（${env.keyVersion}），无法解锁`;
  }
  if (env.kdfSalt.length === 0 || env.passwordWrappedKey.length === 0 ||
    env.passwordWrapNonce.length === 0) {
    return '云端信封字段缺失（kdfSalt / passwordWrappedKey / passwordWrapNonce），无法解锁';
  }
  if (env.kdfSalt.length !== base64Len(KDF_SALT_LEN)) {
    return `云端信封 kdfSalt 长度异常（${env.kdfSalt.length}，应为 ${base64Len(KDF_SALT_LEN)}）`;
  }
  if (env.passwordWrapNonce.length !== base64Len(AES_NONCE_LEN)) {
    return `云端信封 passwordWrapNonce 长度异常（${env.passwordWrapNonce.length}，应为 ${base64Len(AES_NONCE_LEN)}）`;
  }
  if (env.passwordWrappedKey.length !== base64Len(ARGON2_HASH_LEN + AES_TAG_LEN)) {
    return `云端信封 passwordWrappedKey 长度异常（${env.passwordWrappedKey.length}，应为 ${base64Len(ARGON2_HASH_LEN + AES_TAG_LEN)}）`;
  }
  return '';
}

export class MemoryDocumentStore implements SyncDocumentStore {
  doc: SyncDocument = emptySyncDocument();

  async load(): Promise<SyncDocument> {
    return this.doc;
  }

  async save(doc: SyncDocument): Promise<void> {
    this.doc = doc;
  }
}

export class MemoryAuthStore implements AuthStore, TokenProvider {
  access: string = '';
  refresh: string = '';
  device: string = '';
  mail: string = '';
  uid: string = '';

  getAccessToken(): string {
    return this.access;
  }

  getRefreshToken(): string {
    return this.refresh;
  }

  getDeviceId(): string {
    return this.device;
  }

  getEmail(): string {
    return this.mail;
  }

  getUserId(): string {
    return this.uid;
  }

  setTokens(access: string, refresh: string): void {
    this.access = access;
    this.refresh = refresh;
  }

  clearTokens(): void {
    this.clearSession();
  }

  saveSession(result: AuthResult): void {
    this.access = result.accessToken;
    this.refresh = result.refreshToken;
    this.device = result.device.id;
    this.mail = result.user.email;
    this.uid = result.user.id;
  }

  clearSession(): void {
    this.access = '';
    this.refresh = '';
    this.mail = '';
    this.uid = '';
  }
}
