/**
 * KeyManagerViewModel —— 私钥管理视图模型（任务 U3）。
 *
 * 依赖注入（单测全 fake）：
 *   - KeyMetaStore：元数据列表 JSON 读写（生产 = SettingsRepository）；
 *   - SecretStore：私钥/短语（生产 = CredentialStore，hostId = `sshkey:${id}`）；
 *   - newId：UUID 工厂。
 *
 * 纪律：私钥明文只在 import/unlock 调用栈内短暂存在，元数据结构不含私钥；
 * 日志不打印密钥内容。
 */

import { util } from '@kit.ArkTS';
import { Logger } from '../common/utils/Logger';
import {
  KeyEntryMeta,
  createKeyEntryMeta,
  detectPrivateKeyFormat,
  exportPublicKeyText,
  fingerprintForEntry,
  isOpenSshPublicKeyLine,
  keyEntryFingerprintDisplay,
  parseOpenSshPublicKey,
  privateKeyFormatLabel,
  validateKeyImport
} from '../common/utils/KeyManagerLogic';
import { CredentialKind, CredentialStore } from '../repository/CredentialStore';
import { SettingsRepository } from '../repository/SettingsRepository';
import { AgentAuthPort, NativeAgentAuthPort } from '../napi/AgentAuth';
import { NativeAgentKeygenResult } from '../napi/SshNative';

const LOG_TAG: string = 'KeyManagerVM';

/** CredentialStore 侧密钥命名空间（避免与真实 hostId 冲突） */
export function keySecretOwnerId(keyId: string): string {
  return `sshkey:${keyId}`;
}

export interface KeyMetaStore {
  readJson(): string;
  writeJson(json: string): void;
}

export interface KeySecretStore {
  setSecret(ownerId: string, kind: CredentialKind, value: string): Promise<void>;
  getSecret(ownerId: string, kind: CredentialKind): Promise<string | null>;
  removeAllSecrets(ownerId: string): Promise<void>;
}

export interface KeyManagerDeps {
  metaStore?: KeyMetaStore;
  secretStore?: KeySecretStore;
  agentAuth?: AgentAuthPort;
  newId?: () => string;
}

class SettingsKeyMetaStore implements KeyMetaStore {
  readJson(): string {
    return SettingsRepository.getSshKeyEntries();
  }

  writeJson(json: string): void {
    SettingsRepository.setSshKeyEntries(json);
  }
}

class CredentialSecretStore implements KeySecretStore {
  setSecret(ownerId: string, kind: CredentialKind, value: string): Promise<void> {
    return CredentialStore.setSecret(ownerId, kind, value);
  }

  getSecret(ownerId: string, kind: CredentialKind): Promise<string | null> {
    return CredentialStore.getSecret(ownerId, kind);
  }

  removeAllSecrets(ownerId: string): Promise<void> {
    return CredentialStore.removeAllSecrets(ownerId);
  }
}

export function parseKeyEntryList(json: string): KeyEntryMeta[] {
  if (json.trim().length === 0) {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(json) as Object;
    if (!Array.isArray(parsed)) {
      return [];
    }
    const result: KeyEntryMeta[] = [];
    const list: Object[] = parsed as Object[];
    for (let i = 0; i < list.length; i++) {
      const record: Record<string, Object> = list[i] as Record<string, Object>;
      const id: Object | undefined = record['id'];
      if (typeof id !== 'string' || id.length === 0) {
        continue;
      }
      result.push({
        id: id,
        name: typeof record['name'] === 'string' ? record['name'] as string : '',
        keyType: typeof record['keyType'] === 'string' ? record['keyType'] as string : '',
        fingerprint: typeof record['fingerprint'] === 'string' ? record['fingerprint'] as string : '',
        publicKey: typeof record['publicKey'] === 'string' ? record['publicKey'] as string : '',
        hasPassphrase: record['hasPassphrase'] === true,
        createdAt: typeof record['createdAt'] === 'string' ? record['createdAt'] as string : ''
      });
    }
    return result;
  } catch (err) {
    Logger.warn('密钥元数据 JSON 解析失败，按空列表处理', LOG_TAG);
    return [];
  }
}

export function serializeKeyEntryList(entries: KeyEntryMeta[]): string {
  return JSON.stringify(entries);
}

@ObservedV2
export class KeyManagerViewModel {
  @Trace entries: KeyEntryMeta[] = [];
  @Trace lastMessage: string = '';
  @Trace unlockableCount: number = 0;

  private readonly metaStore: KeyMetaStore;
  private readonly secretStore: KeySecretStore;
  private readonly agentAuth: AgentAuthPort;
  private readonly newId: () => string;
  /** 导入草稿：私钥明文只驻留本字段，保存后清空 */
  @Trace draftName: string = '';
  @Trace draftPrivateKey: string = '';
  @Trace draftPassphrase: string = '';
  @Trace draftPublicKey: string = '';

  constructor(deps?: KeyManagerDeps) {
    this.metaStore = deps?.metaStore ?? new SettingsKeyMetaStore();
    this.secretStore = deps?.secretStore ?? new CredentialSecretStore();
    this.agentAuth = deps?.agentAuth ?? new NativeAgentAuthPort();
    this.newId = deps?.newId ?? ((): string => util.generateRandomUUID());
    this.reload();
  }

  reload(): void {
    this.entries = parseKeyEntryList(this.metaStore.readJson());
  }

  private persist(): void {
    this.metaStore.writeJson(serializeKeyEntryList(this.entries));
  }

  setDraft(name: string, privateKey: string, passphrase: string, publicKey: string): void {
    this.draftName = name;
    this.draftPrivateKey = privateKey;
    this.draftPassphrase = passphrase;
    this.draftPublicKey = publicKey;
  }

  clearDraft(): void {
    this.draftName = '';
    this.draftPrivateKey = '';
    this.draftPassphrase = '';
    this.draftPublicKey = '';
  }

  /** 导入粘贴的私钥；成功返回 keyId，失败返回空串并写 lastMessage */
  async importDraft(): Promise<string> {
    const error: string = validateKeyImport(this.draftName, this.draftPrivateKey);
    if (error.length > 0) {
      this.lastMessage = error;
      return '';
    }
    const id: string = this.newId();
    const privateKey: string = this.draftPrivateKey;
    const passphrase: string = this.draftPassphrase;
    const publicKey: string = this.draftPublicKey.trim();
    const ownerId: string = keySecretOwnerId(id);
    try {
      await this.secretStore.setSecret(ownerId, 'private_key', privateKey);
      if (passphrase.length > 0) {
        await this.secretStore.setSecret(ownerId, 'passphrase', passphrase);
      }
    } catch (err) {
      this.lastMessage = '私钥写入安全存储失败';
      Logger.error('导入私钥写入 CredentialStore 失败', LOG_TAG);
      return '';
    }
    const parsed = parseOpenSshPublicKey(publicKey);
    const meta: KeyEntryMeta = createKeyEntryMeta(id, this.draftName.trim());
    meta.keyType = parsed.valid ? parsed.keyType : detectPrivateKeyFormat(privateKey);
    meta.publicKey = parsed.valid ? exportPublicKeyText(publicKey) : '';
    meta.fingerprint = fingerprintForEntry(meta.publicKey, privateKey);
    meta.hasPassphrase = passphrase.length > 0;
    meta.createdAt = `${Date.now()}`;
    this.entries = this.entries.concat([meta]);
    this.persist();
    this.clearDraft();
    this.lastMessage = `已导入「${meta.name}」（${privateKeyFormatLabel(detectPrivateKeyFormat(privateKey))}）`;
    Logger.info(`导入私钥条目 id=${id} format=${meta.keyType}`, LOG_TAG);
    return id;
  }

  /**
   * U3：native keygen 接入（OpenSSL EVP ed25519）。
   * 私钥导出为 PKCS#8 PEM（OpenSSH 私钥完整序列化过重，见 cpp/ssh/keygen.h）；
   * 公钥为 OpenSSH 单行，指纹经 formatOpenSshFingerprint 对齐 ssh-keygen -lf。
   */
  generateSupported(): boolean {
    return this.agentAuth.keygenSupported();
  }

  /** 生成按钮不可用时的说明（UI Toast / 旁注） */
  generateUnsupportedReason(): string {
    return '当前设备暂不支持在应用内生成密钥，请先在服务器上生成后粘贴导入。';
  }

  /**
   * 生成 ed25519 密钥对并落库。
   * name 为空时用 comment 或默认名；passphrase 空 = 明文 PKCS#8。
   * 成功返回 keyId，失败返回空串并写 lastMessage。
   */
  async generateKeyPair(name: string, passphrase: string, comment: string): Promise<string> {
    if (!this.generateSupported()) {
      this.lastMessage = this.generateUnsupportedReason();
      return '';
    }
    const trimmedName: string = name.trim().length > 0
      ? name.trim()
      : (comment.trim().length > 0 ? comment.trim() : 'generated-ed25519');
    const result: NativeAgentKeygenResult | null = this.agentKeygenSafe(comment.trim(), passphrase);
    if (result === null || result.privateKeyPem.length === 0 ||
      !isOpenSshPublicKeyLine(result.publicKeyLine, 'ssh-ed25519')) {
      this.lastMessage = '密钥生成失败，请重试';
      Logger.error('native keygen 失败或公钥行非法', LOG_TAG);
      return '';
    }
    const id: string = this.newId();
    const ownerId: string = keySecretOwnerId(id);
    try {
      await this.secretStore.setSecret(ownerId, 'private_key', result.privateKeyPem);
      if (passphrase.length > 0) {
        await this.secretStore.setSecret(ownerId, 'passphrase', passphrase);
      }
    } catch (err) {
      this.lastMessage = '生成的私钥写入安全存储失败';
      Logger.error('keygen 私钥写入 CredentialStore 失败', LOG_TAG);
      return '';
    }
    const parsed = parseOpenSshPublicKey(result.publicKeyLine);
    const meta: KeyEntryMeta = createKeyEntryMeta(id, trimmedName);
    meta.keyType = result.keyType.length > 0 ? result.keyType : 'ssh-ed25519';
    meta.publicKey = parsed.valid ? exportPublicKeyText(result.publicKeyLine) : result.publicKeyLine.trim();
    meta.fingerprint = fingerprintForEntry(meta.publicKey, result.privateKeyPem);
    meta.hasPassphrase = passphrase.length > 0;
    meta.createdAt = `${Date.now()}`;
    this.entries = this.entries.concat([meta]);
    this.persist();
    this.lastMessage = `已生成「${meta.name}」，可用于主机认证`;
      (meta.fingerprint.length > 0 ? ` ${meta.fingerprint}` : '');
    Logger.info(`生成密钥条目 id=${id} type=${meta.keyType}`, LOG_TAG);
    return id;
  }

  /** native keygen 调用（捕获异常；fake 可注入） */
  private agentKeygenSafe(comment: string, passphrase: string): NativeAgentKeygenResult | null {
    try {
      return this.agentAuth.keygen(comment, passphrase);
    } catch (err) {
      Logger.error('agent.keygen 抛错', LOG_TAG);
      return null;
    }
  }

  /** 删除条目：元数据 + CredentialStore 级联 + agent 锁定（keyId = 条目 id） */
  async deleteEntry(id: string): Promise<boolean> {
    const ownerId: string = keySecretOwnerId(id);
    try {
      await this.secretStore.removeAllSecrets(ownerId);
    } catch (err) {
      Logger.warn('删除密钥时清理凭据失败（继续删元数据）', LOG_TAG);
    }
    // 不存在时 lock 返回 false，属幂等，不阻断删除
    this.agentAuth.lock(id);
    const next: KeyEntryMeta[] = [];
    for (const entry of this.entries) {
      if (entry.id !== id) {
        next.push(entry);
      }
    }
    this.entries = next;
    this.persist();
    this.lastMessage = '已删除密钥条目';
    return true;
  }

  /** 导出公钥文本；无公钥返回空串 */
  exportPublicKey(id: string): string {
    for (const entry of this.entries) {
      if (entry.id === id) {
        return exportPublicKeyText(entry.publicKey);
      }
    }
    return '';
  }

  /** 将条目私钥解锁进应用内 agent（keyId = 条目 id） */
  async unlockToAgent(id: string, passphraseHint: string): Promise<boolean> {
    const ownerId: string = keySecretOwnerId(id);
    const privateKey: string | null = await this.secretStore.getSecret(ownerId, 'private_key');
    if (privateKey === null) {
      this.lastMessage = '安全存储中没有该密钥的私钥内容';
      return false;
    }
    let passphrase: string = passphraseHint;
    if (passphrase.length === 0) {
      const stored: string | null = await this.secretStore.getSecret(ownerId, 'passphrase');
      passphrase = stored ?? '';
    }
    const ok: boolean = this.agentAuth.unlock(id, privateKey, passphrase);
    this.lastMessage = ok ? '已解锁，可在主机认证中使用' : '解锁失败，请确认密码短语后重试';
    this.unlockableCount = this.agentAuth.keyCount();
    return ok;
  }

  /** 列表展示指纹：有公钥 = SHA256:…；无私钥条目标明未计算 */
  displayFingerprint(entry: KeyEntryMeta): string {
    return keyEntryFingerprintDisplay(entry);
  }
}
