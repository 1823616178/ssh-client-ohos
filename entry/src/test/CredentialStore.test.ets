/**
 * CredentialStore 单元测试（任务 C2）。
 *
 * 只覆盖可纯测的部分：别名编码/解析往返、kind 枚举完整性、asset 错误码分类
 * （classifyAssetError 把「不存在 / 冲突 / 真故障」分开，数值与 SDK ErrorCode 对拍）。
 * asset 真实读写依赖 ASSET 系统服务（设备沙箱），单测不覆盖，列为真机待验项
 * （连同验收标准「hdc 导出沙箱无明文 / 卸载后凭据不可恢复」）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ALL_CREDENTIAL_KINDS,
  ASSET_ERROR_DUPLICATED,
  ASSET_ERROR_NOT_FOUND,
  AssetErrorCategory,
  CredentialKind,
  SecretAliasParts,
  classifyAssetError,
  isCredentialKind,
  parseSecretAlias,
  secretAlias
} from '../main/ets/repository/CredentialStore';

/** 测试用主机 id（UUID 形态，含连字符、不含冒号，与 HostProfile.id 一致） */
const TEST_HOST_ID: string = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

export default function credentialStoreTest() {
  describe('CredentialStoreAliasTest', () => {

    it('别名编码_三种kind格式正确', 0, () => {
      expect(secretAlias(TEST_HOST_ID, 'password')).assertEqual(`host_secret:${TEST_HOST_ID}:password`);
      expect(secretAlias(TEST_HOST_ID, 'passphrase')).assertEqual(`host_secret:${TEST_HOST_ID}:passphrase`);
      expect(secretAlias(TEST_HOST_ID, 'private_key')).assertEqual(`host_secret:${TEST_HOST_ID}:private_key`);
    });

    it('别名解析_编码往返还原hostId与kind', 0, () => {
      for (let i = 0; i < ALL_CREDENTIAL_KINDS.length; i++) {
        const kind: CredentialKind = ALL_CREDENTIAL_KINDS[i];
        const parts: SecretAliasParts | null = parseSecretAlias(secretAlias(TEST_HOST_ID, kind));
        expect(parts !== null).assertTrue();
        if (parts !== null) {
          expect(parts.hostId).assertEqual(TEST_HOST_ID);
          expect(parts.kind).assertEqual(kind);
        }
      }
    });

    it('别名解析_拒绝非法与越界输入', 0, () => {
      expect(parseSecretAlias('')).assertNull();
      // 预留命名空间不属于主机凭据（M5 sync token / vault key 不得被误解析）
      expect(parseSecretAlias('sync_token:abc')).assertNull();
      expect(parseSecretAlias('vault_key:abc')).assertNull();
      expect(parseSecretAlias('host_secret:')).assertNull();
      // 缺 kind 段 / 空 kind / 空 hostId / 未知 kind
      expect(parseSecretAlias(`host_secret:${TEST_HOST_ID}`)).assertNull();
      expect(parseSecretAlias(`host_secret:${TEST_HOST_ID}:`)).assertNull();
      expect(parseSecretAlias('host_secret::password')).assertNull();
      expect(parseSecretAlias(`host_secret:${TEST_HOST_ID}:bogus`)).assertNull();
    });

    it('kind枚举_完整唯一且isCredentialKind一致', 0, () => {
      expect(ALL_CREDENTIAL_KINDS.length).assertEqual(3);
      for (let i = 0; i < ALL_CREDENTIAL_KINDS.length; i++) {
        expect(isCredentialKind(ALL_CREDENTIAL_KINDS[i])).assertTrue();
        for (let j = i + 1; j < ALL_CREDENTIAL_KINDS.length; j++) {
          expect(ALL_CREDENTIAL_KINDS[i] === ALL_CREDENTIAL_KINDS[j]).assertFalse();
        }
      }
      expect(isCredentialKind('bogus')).assertFalse();
      expect(isCredentialKind('')).assertFalse();
    });
  });

  describe('CredentialStoreErrorClassifyTest', () => {

    it('错误分类_不存在与冲突分开_其余归FATAL', 0, () => {
      expect(classifyAssetError(ASSET_ERROR_NOT_FOUND)).assertEqual(AssetErrorCategory.NOT_FOUND);
      expect(classifyAssetError(ASSET_ERROR_DUPLICATED)).assertEqual(AssetErrorCategory.DUPLICATED);
      // 真故障样本：服务不可用 / 参数错误 / 数据库错误 / 保留值 0 / 非 BusinessError 的 -1
      const fatalCodes: number[] = [24000001, 401, 24000008, 0, -1];
      for (let i = 0; i < fatalCodes.length; i++) {
        expect(classifyAssetError(fatalCodes[i])).assertEqual(AssetErrorCategory.FATAL);
      }
    });

    it('错误分类_常量数值与SDK的asset.ErrorCode对拍', 0, () => {
      // 防漂移：与 @ohos.security.asset.d.ts 的 ErrorCode 枚举数值一致
      expect(ASSET_ERROR_NOT_FOUND).assertEqual(24000002);
      expect(ASSET_ERROR_DUPLICATED).assertEqual(24000003);
    });
  });
}
