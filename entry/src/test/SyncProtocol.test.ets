/**
 * SyncProtocol 常量与 SYNC-PROTOCOL.md / 验收「无第二处定义」对齐（任务 S1）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  AAD_DOMAIN_SYNC_DOCUMENT,
  AAD_DOMAIN_VAULT_KEY_PASSWORD,
  AAD_DOMAIN_VAULT_KEY_RECOVERY,
  AES_ALGORITHM,
  AES_NONCE_LEN,
  AES_TAG_LEN,
  ARGON2_HASH_LEN,
  ARGON2_ITERATIONS,
  ARGON2_MEMORY_KIB,
  ARGON2_PARALLELISM,
  CIPHERTEXT_HASH_HEX_LEN,
  DOCUMENT_MAX_BYTES,
  HKDF_INFO_RECOVERY_KEK,
  HKDF_OUT_LEN,
  HOST_COUNT_MAX,
  KDF_SALT_LEN,
  PRIVATE_KEY_MAX_BYTES,
  RECOVERY_KEY_CHECK_HEX_LEN,
  RECOVERY_KEY_PREFIX,
  RECOVERY_KEY_RAW_B64URL_LEN,
  REVISION_INITIAL,
  SAVE_DEBOUNCE_MS,
  SCHEMA_VERSION,
  SCHEMA_VERSION_MAX,
  SYNC_PHASE_NAMES
} from '../main/ets/common/sync/SyncProtocol';

export default function syncProtocolTest() {
  describe('SyncProtocolTest', () => {

    it('KDF与AES与HKDF参数对齐规范', 0, () => {
      expect(SCHEMA_VERSION).assertEqual(1);
      expect(SCHEMA_VERSION_MAX).assertEqual(1000);
      expect(ARGON2_MEMORY_KIB).assertEqual(65536);
      expect(ARGON2_ITERATIONS).assertEqual(3);
      expect(ARGON2_PARALLELISM).assertEqual(1);
      expect(ARGON2_HASH_LEN).assertEqual(32);
      expect(KDF_SALT_LEN).assertEqual(16);
      expect(AES_ALGORITHM).assertEqual('AES-256-GCM');
      expect(AES_NONCE_LEN).assertEqual(12);
      expect(AES_TAG_LEN).assertEqual(16);
      expect(HKDF_INFO_RECOVERY_KEK).assertEqual('ssh-port-mapper/recovery-kek/v1');
      expect(HKDF_OUT_LEN).assertEqual(32);
    });

    // 域字符串与桌面端 ssh-tool 的 crypto-vault.ts 共用命名空间（两端同库），改动即破坏互通
    it('AAD域与恢复密钥格式对齐桌面端', 0, () => {
      expect(AAD_DOMAIN_SYNC_DOCUMENT).assertEqual('ssh-port-mapper/sync-document/v1');
      expect(AAD_DOMAIN_VAULT_KEY_PASSWORD).assertEqual('ssh-port-mapper/vault-key/password/v1');
      expect(AAD_DOMAIN_VAULT_KEY_RECOVERY).assertEqual('ssh-port-mapper/vault-key/recovery/v1');
      expect(RECOVERY_KEY_PREFIX).assertEqual('SPM1');
      expect(RECOVERY_KEY_RAW_B64URL_LEN).assertEqual(43);
      expect(RECOVERY_KEY_CHECK_HEX_LEN).assertEqual(12);
      expect(CIPHERTEXT_HASH_HEX_LEN).assertEqual(64);
    });

    it('体积上限与防抖与相位表', 0, () => {
      expect(DOCUMENT_MAX_BYTES).assertEqual(2097152);
      expect(PRIVATE_KEY_MAX_BYTES).assertEqual(262144);
      expect(HOST_COUNT_MAX).assertEqual(5000);
      expect(SAVE_DEBOUNCE_MS).assertEqual(3000);
      expect(REVISION_INITIAL).assertEqual(0);
      expect(SYNC_PHASE_NAMES.length).assertEqual(10);
      expect(SYNC_PHASE_NAMES[0]).assertEqual('signed_out');
      expect(SYNC_PHASE_NAMES[9]).assertEqual('auth_error');
    });
  });
}
