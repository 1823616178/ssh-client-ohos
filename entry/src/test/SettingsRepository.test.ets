/**
 * SettingsRepository 单元测试（任务 C3）。
 *
 * 只覆盖可纯测的部分：SETTING_DEFS 键定义表的完整性——
 * 每个键都有类型与 typeof 匹配的默认值、键名唯一、键集合与 §6.6 清单 + 常用项对齐。
 * preferences 的真实读写依赖 context（设备沙箱），单测不覆盖，在 ohosTest / 真机联调中验证。
 */

import { describe, it, expect } from '@ohos/hypium';
import { SETTING_DEFS, SettingDef } from '../main/ets/repository/SettingsRepository';

/** 任务 C3 约定的键集合（键名 / 类型 / 默认值） */
interface ExpectedDef {
  key: string;
  type: string;
  defaultValue: string | number | boolean;
}

const EXPECTED_DEFS: ExpectedDef[] = [
  { key: 'themeMode', type: 'string', defaultValue: 'system' },
  { key: 'defaultFontSize', type: 'number', defaultValue: 14 },
  { key: 'keepAliveInBackground', type: 'boolean', defaultValue: true },
  { key: 'screenOffDisconnectMinutes', type: 'number', defaultValue: 0 },
  { key: 'hapticEnabled', type: 'boolean', defaultValue: true },
  { key: 'keyBarLayout', type: 'string', defaultValue: '' },
  { key: 'lastSessionId', type: 'string', defaultValue: '' },
  { key: 'syncPollIntervalMinutes', type: 'number', defaultValue: 15 },
  { key: 'hostGroupCollapsed', type: 'string', defaultValue: '{}' },
  { key: 'keyboardShortcuts', type: 'string', defaultValue: '' }
];

function findDef(key: string): SettingDef | null {
  for (let i = 0; i < SETTING_DEFS.length; i++) {
    if (SETTING_DEFS[i].key === key) {
      return SETTING_DEFS[i];
    }
  }
  return null;
}

export default function settingsRepositoryTest() {
  describe('SettingsRepositoryTest', () => {

    it('键定义表_键集合与约定一致', 0, () => {
      expect(SETTING_DEFS.length).assertEqual(EXPECTED_DEFS.length);
      for (let i = 0; i < EXPECTED_DEFS.length; i++) {
        const expected: ExpectedDef = EXPECTED_DEFS[i];
        const def: SettingDef | null = findDef(expected.key);
        expect(def !== null).assertTrue();
        if (def !== null) {
          expect(def.type).assertEqual(expected.type);
          expect(def.defaultValue).assertEqual(expected.defaultValue);
        }
      }
    });

    it('键定义表_每个键的默认值类型与声明类型匹配', 0, () => {
      for (let i = 0; i < SETTING_DEFS.length; i++) {
        const def: SettingDef = SETTING_DEFS[i];
        expect(typeof def.defaultValue).assertEqual(def.type);
        expect(def.key.length > 0).assertTrue();
        expect(def.comment.length > 0).assertTrue();
      }
    });

    it('键定义表_类型标签只取三种标量', 0, () => {
      for (let i = 0; i < SETTING_DEFS.length; i++) {
        const t: string = SETTING_DEFS[i].type;
        expect(t === 'string' || t === 'number' || t === 'boolean').assertTrue();
      }
    });

    it('键定义表_键名唯一', 0, () => {
      for (let i = 0; i < SETTING_DEFS.length; i++) {
        for (let j = i + 1; j < SETTING_DEFS.length; j++) {
          expect(SETTING_DEFS[i].key === SETTING_DEFS[j].key).assertFalse();
        }
      }
    });
  });
}
