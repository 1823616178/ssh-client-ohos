/**
 * i18n 纯助手 + P6 HTTPS 明文告警助手 单元测试。
 *
 * - t()：键命中 / 缺键回落中文 / en-US 缺键落回中文表 / normalizeLang / resolveLang
 * - shouldShowCleartextWarning / isHttpsApiUrl / syncApiBaseUrl：
 *   https 跳过明文告警；http 仍告警；https 候选优先拼 /api/v1
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  I18nKeys,
  lookupString,
  normalizeLang,
  resolveLang,
  t
} from '../main/ets/common/i18n/I18n';
import {
  isHttpsApiUrl,
  shouldShowCleartextWarning,
  syncApiBaseUrl
} from '../main/ets/common/constants/BuildConfig';

export default function i18nTest() {
  describe('I18nTest', () => {
    it('t_中文表命中忽略fallback', 0, () => {
      expect(t(I18nKeys.SETTINGS_ABOUT_SECTION, 'FALLBACK')).assertEqual('关于与合规');
      expect(t(I18nKeys.SETTINGS_BACKGROUND_SECTION, 'FALLBACK')).assertEqual('后台与续航');
      expect(t(I18nKeys.NAV_BACK, 'FALLBACK')).assertEqual('返回');
    });

    it('t_缺键返回中文fallback', 0, () => {
      expect(t('settings.no.such.key', '中文兜底')).assertEqual('中文兜底');
    });

    it('t_en-US命中英文表', 0, () => {
      expect(t(I18nKeys.SETTINGS_ABOUT_SECTION, '关于与合规', 'en-US')).assertEqual('About & compliance');
      expect(t(I18nKeys.NAV_BACK, '返回', 'en')).assertEqual('Back');
      expect(t(I18nKeys.SETTINGS_BACKGROUND_KEEP_ALIVE, 'x', 'en-GB')).assertEqual('Keep alive in background');
    });

    it('t_en-US缺键先回落中文表再fallback', 0, () => {
      // 键仅存在于逻辑默认：en 查无 → zh 查无 → fallback
      expect(t('only.fallback.key', '仅fallback', 'en-US')).assertEqual('仅fallback');
      // 若将来某键只在中文表：en 应回落到中文文案（构造键：用 lookup 验证语义）
      expect(lookupString(I18nKeys.SETTINGS_TOOLS_SECTION, 'en-US')).assertEqual('Tools');
      expect(lookupString('not.in.any.table', 'zh-CN') === undefined).assertTrue();
    });

    it('normalizeLang_归一化到zh或en', 0, () => {
      expect(normalizeLang(undefined)).assertEqual('zh-CN');
      expect(normalizeLang('')).assertEqual('zh-CN');
      expect(normalizeLang('zh')).assertEqual('zh-CN');
      expect(normalizeLang('zh-CN')).assertEqual('zh-CN');
      expect(normalizeLang('en')).assertEqual('en-US');
      expect(normalizeLang('en-US')).assertEqual('en-US');
      expect(normalizeLang('EN-us')).assertEqual('en-US');
      expect(normalizeLang('fr-FR')).assertEqual('zh-CN');
    });

    it('resolveLang_BuildProfile优先其次系统语言', 0, () => {
      expect(resolveLang('en-US', 'zh-CN')).assertEqual('en-US');
      expect(resolveLang('', 'en-GB')).assertEqual('en-US');
      expect(resolveLang(undefined, 'en')).assertEqual('en-US');
      expect(resolveLang('', 'zh-CN')).assertEqual('zh-CN');
      expect(resolveLang(undefined, undefined)).assertEqual('zh-CN');
      expect(resolveLang('zh-CN', 'en-US')).assertEqual('zh-CN');
    });

    it('t_默认语言不传lang时行为不变', 0, () => {
      // 页面接线形态：t(key, 中文硬编码) —— 等价于当前 UI 文案
      expect(t(I18nKeys.SETTINGS_TITLE, '设置')).assertEqual('设置');
      expect(t(I18nKeys.SETTINGS_TOOLS_SECTION, '工具')).assertEqual('工具');
      expect(t(I18nKeys.SETTINGS_OPEN_SOURCE, '开源许可')).assertEqual('开源许可');
    });
  });

  describe('HttpsReadinessTest', () => {
    it('isHttpsApiUrl_大小写与方案', 0, () => {
      expect(isHttpsApiUrl('https://example.com')).assertTrue();
      expect(isHttpsApiUrl('HTTPS://example.com')).assertTrue();
      expect(isHttpsApiUrl('https://example.com:8443')).assertTrue();
      expect(isHttpsApiUrl('http://123.161.179.32:46926')).assertFalse();
      expect(isHttpsApiUrl('')).assertFalse();
      expect(isHttpsApiUrl('ftp://example.com')).assertFalse();
    });

    it('shouldShowCleartextWarning_https跳过http仍告警', 0, () => {
      expect(shouldShowCleartextWarning('http://123.161.179.32:46926')).assertTrue();
      expect(shouldShowCleartextWarning('')).assertTrue();
      expect(shouldShowCleartextWarning('https://sync.example.com')).assertFalse();
      expect(shouldShowCleartextWarning('https://sync.example.com:443')).assertFalse();
    });

    it('syncApiBaseUrl_https候选优先并拼api/v1', 0, () => {
      const configured: string = 'http://123.161.179.32:46926';
      expect(syncApiBaseUrl(configured)).assertEqual('http://123.161.179.32:46926/api/v1');
      expect(syncApiBaseUrl(configured, 'https://sync.example.com'))
        .assertEqual('https://sync.example.com/api/v1');
      // 非 https 候选忽略，仍用构建注入地址
      expect(syncApiBaseUrl(configured, 'http://evil.example.com'))
        .assertEqual('http://123.161.179.32:46926/api/v1');
      // 尾斜杠去重
      expect(syncApiBaseUrl('https://sync.example.com/'))
        .assertEqual('https://sync.example.com/api/v1');
      expect(syncApiBaseUrl(configured, '')).assertEqual('http://123.161.179.32:46926/api/v1');
    });
  });
}
