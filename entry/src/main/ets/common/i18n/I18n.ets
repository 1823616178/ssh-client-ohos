/**
 * 纯 i18n 助手（任务 P2 部分）。
 *
 * 纪律：
 * - 本模块零系统 API、零 ResourceManager，hypium 可直接覆盖。
 * - 中文为默认语言：`t(key, fallback)` 在缺键时返回调用方传入的中文 fallback，
 *   因此页面在键表尚未铺满时行为与硬编码完全一致。
 * - 语言来源约定：优先 `BuildProfile.language`（buildProfileFields 注入，可选），
 *   其次系统语言（`resolveLang` 的入参由调用方读取），再回落 `zh-CN`。
 *   页面接线阶段可先用默认 `t(key, chinese)`，键表就绪后再传 `resolveLang(...)`。
 * - Harmony 资源文件 `resources/base|en/element/string.json` 与本键表同名对齐，
 *   供后续接 ResourceManager / $r 做整包本地化；当前 UI 走本表以保测试纯度。
 */

/** 归一化后的语言码 */
export type LangCode = 'zh-CN' | 'en-US';

/**
 * 关键 Settings / About 字符串键表。
 * 键名与 `resources/base|en/element/string.json` 保持一致（点号在资源里用下划线）。
 */
export class I18nKeys {
  /** 设置页顶栏标题 */
  static readonly SETTINGS_TITLE: string = 'settings.title';
  /** 预留键：产品 UI 禁止全大写英文眉题，键值保持空串，页面不得展示 */
  static readonly SETTINGS_EYEBROW: string = 'settings.eyebrow';
  /** 「后台与续航」段标题 */
  static readonly SETTINGS_BACKGROUND_SECTION: string = 'settings.background.section';
  /** 「后台保持连接」条目 */
  static readonly SETTINGS_BACKGROUND_KEEP_ALIVE: string = 'settings.background.keepAlive';
  /** 「工具」段标题 */
  static readonly SETTINGS_TOOLS_SECTION: string = 'settings.tools.section';
  /** 「关于与合规」段标题 */
  static readonly SETTINGS_ABOUT_SECTION: string = 'settings.about.section';
  /** 「开源许可」导航标题 */
  static readonly SETTINGS_OPEN_SOURCE: string = 'settings.about.openSource';
  /** 「开源许可」导航副标题 */
  static readonly SETTINGS_OPEN_SOURCE_SUB: string = 'settings.about.openSourceSub';
  /** 通用「返回」无障碍/读屏文案 */
  static readonly NAV_BACK: string = 'nav.back';
}

/** 键 → 简体中文（默认语言，与当前 UI 硬编码一致） */
const ZH_STRINGS: Record<string, string> = {
  'settings.title': '设置',
  'settings.eyebrow': '',
  'settings.background.section': '后台与续航',
  'settings.background.keepAlive': '后台保持连接',
  'settings.tools.section': '工具',
  'settings.about.section': '关于与合规',
  'settings.about.openSource': '开源许可',
  'settings.about.openSourceSub': '第三方许可证摘要',
  'nav.back': '返回'
};

/** 键 → 英文（P2 英文资源；未覆盖的键经 t() 落回中文/fallback） */
const EN_STRINGS: Record<string, string> = {
  'settings.title': 'Settings',
  'settings.eyebrow': '',
  'settings.background.section': 'Background & battery',
  'settings.background.keepAlive': 'Keep alive in background',
  'settings.tools.section': 'Tools',
  'settings.about.section': 'About & compliance',
  'settings.about.openSource': 'Open-source licenses',
  'settings.about.openSourceSub': 'Third-party license summary',
  'nav.back': 'Back'
};

/**
 * 把任意语言输入归一化到 LangCode。
 * `en` / `en-US` / `en-GB` → en-US；其余（含空串、zh、zh-CN、未知）→ zh-CN。
 */
export function normalizeLang(lang: string | undefined): LangCode {
  if (lang === undefined || lang.length === 0) {
    return 'zh-CN';
  }
  return lang.toLowerCase().startsWith('en') ? 'en-US' : 'zh-CN';
}

/**
 * 解析当前生效语言：BuildProfile.language 优先，其次系统语言，最后 zh-CN。
 * 两个入参均可为空；不读全局状态，纯函数。
 */
export function resolveLang(buildProfileLang: string | undefined,
  systemLang: string | undefined): LangCode {
  if (buildProfileLang !== undefined && buildProfileLang.length > 0) {
    return normalizeLang(buildProfileLang);
  }
  return normalizeLang(systemLang);
}

/** 在指定语言表中查键；未命中返回 undefined */
export function lookupString(key: string, lang: LangCode): string | undefined {
  const table: Record<string, string> = lang === 'en-US' ? EN_STRINGS : ZH_STRINGS;
  const hit: string | undefined = table[key];
  return hit;
}

/**
 * 取文案：键在目标语言表中命中则返回译文；否则回落 `fallback`（中文）。
 * `lang` 省略时按 zh-CN 查表——即便中文表缺键，也返回调用方中文 fallback，行为不变。
 * en-US 缺键时再尝试中文表，仍无则 fallback，避免读屏出现空标签。
 */
export function t(key: string, fallback: string, lang?: string): string {
  const code: LangCode = normalizeLang(lang);
  const hit: string | undefined = lookupString(key, code);
  if (hit !== undefined && hit.length > 0) {
    return hit;
  }
  if (code === 'en-US') {
    const zhHit: string | undefined = lookupString(key, 'zh-CN');
    if (zhHit !== undefined && zhHit.length > 0) {
      return zhHit;
    }
  }
  return fallback;
}

/** 导出整表（调试 / 未来 ResourceManager 批量注入用；勿在热路径拷贝） */
export function stringTable(lang: LangCode): Record<string, string> {
  return lang === 'en-US' ? EN_STRINGS : ZH_STRINGS;
}
