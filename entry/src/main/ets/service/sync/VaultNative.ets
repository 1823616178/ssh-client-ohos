/**
 * native 保险库封装：vault key 只留在 so 句柄表。
 */

import { nativeCore, NativeVaultCreateResult, NativeVaultSeal } from '../../napi/SshNative';
import { AES_ALGORITHM, SCHEMA_VERSION } from '../../common/sync/SyncProtocol';
import { EncryptedDocument, VaultEnvelope } from './ApiTypes';
import { SyncCrypto } from './SyncCoordinator';

export interface VaultCreateOutcome {
  envelope: VaultEnvelope;
  recoveryKey: string;
}

export class NativeVaultCrypto implements SyncCrypto {
  private handle: number = 0;
  vaultId: string = '';
  keyVersion: number = 1;

  isReady(): boolean {
    return this.handle > 0;
  }

  create(password: string, keyVersion: number): VaultCreateOutcome | null {
    this.close();
    const raw: NativeVaultCreateResult | null = nativeCore().vaultCreate(password, keyVersion);
    if (raw === null || raw.handle <= 0) {
      return null;
    }
    this.handle = raw.handle;
    this.keyVersion = raw.keyVersion;
    return { envelope: envelopeFromCreate(raw, ''), recoveryKey: raw.recoveryKey };
  }

  /**
   * 用同步密码解锁。
   *
   * `wrapKeyVersion` 只影响解包时构造的 AAD（`VaultKeyPasswordAad`），默认取信封自己的
   * keyVersion。传入其它值是为了救回被旧版轮换缺陷写坏的信封——那种信封的 keyVersion 被
   * 单方面 +1，wrapped key 却仍绑定在旧版本的 AAD 上。文档加解密始终用信封的 keyVersion，
   * 与云端保持一致。
   */
  unlockPassword(password: string, env: VaultEnvelope, wrapKeyVersion?: number): boolean {
    this.close();
    const aadVersion: number = wrapKeyVersion === undefined ? env.keyVersion : wrapKeyVersion;
    const handle: number = nativeCore().vaultUnlockPassword(password, aadVersion, env.kdfSalt,
      env.passwordWrappedKey, env.passwordWrapNonce);
    if (handle <= 0) {
      return false;
    }
    this.handle = handle;
    this.keyVersion = env.keyVersion;
    this.vaultId = env.id;
    return true;
  }

  /** 用当前已解锁的 vault key，按 keyVersion 重新包装出一份 AAD 正确的信封（修复用） */
  rewrap(syncPassword: string, keyVersion: number): VaultCreateOutcome | null {
    if (this.handle <= 0) {
      return null;
    }
    const raw: NativeVaultCreateResult | null =
      nativeCore().vaultRewrap(this.handle, syncPassword, keyVersion);
    if (raw === null) {
      return null;
    }
    this.keyVersion = keyVersion;
    return { envelope: envelopeFromCreate(raw, this.vaultId), recoveryKey: raw.recoveryKey };
  }

  unlockRecovery(recoveryKey: string, env: VaultEnvelope): boolean {
    this.close();
    const handle: number = nativeCore().vaultUnlockRecovery(recoveryKey, env.keyVersion,
      env.recoveryWrappedKey, env.recoveryWrapNonce);
    if (handle <= 0) {
      return false;
    }
    this.handle = handle;
    this.keyVersion = env.keyVersion;
    this.vaultId = env.id;
    return true;
  }

  rotate(password: string): VaultCreateOutcome | null {
    if (this.handle <= 0) {
      return null;
    }
    const raw: NativeVaultCreateResult | null = nativeCore().vaultRotate(this.handle, password);
    if (raw === null || raw.handle <= 0) {
      return null;
    }
    this.handle = raw.handle;
    this.keyVersion = raw.keyVersion;
    return { envelope: envelopeFromCreate(raw, this.vaultId), recoveryKey: raw.recoveryKey };
  }

  close(): void {
    if (this.handle > 0) {
      nativeCore().vaultClose(this.handle);
      this.handle = 0;
    }
  }

  encrypt(plain: string): EncryptedDocument {
    if (this.handle <= 0) {
      throw new Error('保险库未解锁');
    }
    const seal: NativeVaultSeal | null =
      nativeCore().vaultEncrypt(this.handle, this.vaultId, SCHEMA_VERSION, this.keyVersion, plain);
    if (seal === null) {
      throw new Error('文档加密失败');
    }
    return {
      revision: '',
      schemaVersion: seal.schemaVersion,
      keyVersion: seal.keyVersion,
      algorithm: seal.algorithm.length > 0 ? seal.algorithm : AES_ALGORITHM,
      nonce: seal.nonce,
      ciphertext: seal.ciphertext,
      ciphertextHash: seal.ciphertextHash,
      updatedAt: ''
    };
  }

  decrypt(doc: EncryptedDocument): string {
    if (this.handle <= 0) {
      throw new Error('保险库未解锁');
    }
    const plain: string | null = nativeCore().vaultDecrypt(this.handle, this.vaultId,
      doc.schemaVersion, doc.keyVersion, doc.nonce, doc.ciphertext);
    if (plain === null) {
      throw new Error('文档解密失败');
    }
    return plain;
  }
}

function envelopeFromCreate(raw: NativeVaultCreateResult, id: string): VaultEnvelope {
  return {
    id: id,
    keyVersion: raw.keyVersion,
    passwordWrappedKey: raw.passwordWrappedKey,
    passwordWrapNonce: raw.passwordWrapNonce,
    recoveryWrappedKey: raw.recoveryWrappedKey,
    recoveryWrapNonce: raw.recoveryWrapNonce,
    kdfSalt: raw.kdfSalt,
    kdfMemory: 0,
    kdfIterations: 0,
    kdfParallelism: 0
  };
}
