/**
 * 终端外观主题预设 —— 任务 A2（DESIGN §4.4）。
 *
 * 9 套内置主题的 20 个色位：palette[16] + foreground / background /
 * cursorColor / selectionColor。色值按各主题官方/社区通行配色整理，
 * 与 Harmony Design Token 暗色系一致的 Harmony Dark 为默认。
 *
 * 纯数据 + 纯函数：零 UI、零存储依赖；AppearanceViewModel 用
 * appearanceFromThemePreset 生成可落库的 AppearanceProfile。
 */

import {
  AppearanceProfile,
  CursorStyle,
  HARMONY_DARK_PALETTE,
  createDefaultAppearanceProfile
} from '../common/model/models';
import { buildTerminalFontFamily } from './FontService';

/** 20 色主题色位（调色板 16 + 四个特殊位）；解析/编辑时字段可写 */
export interface ThemeColorSet {
  palette: string[];
  foreground: string;
  background: string;
  cursorColor: string;
  selectionColor: string;
}

/** 内置主题预设 */
export interface ThemePreset {
  readonly id: string;
  readonly name: string;
  readonly colors: ThemeColorSet;
  /** true = 暗色系（AppearancePage 预览底色提示） */
  readonly dark: boolean;
}

function colors(
  palette: string[],
  foreground: string,
  background: string,
  cursorColor: string,
  selectionColor: string
): ThemeColorSet {
  return {
    palette: palette.slice(),
    foreground: foreground,
    background: background,
    cursorColor: cursorColor,
    selectionColor: selectionColor
  };
}

/**
 * 9 套内置主题（DESIGN §4.4 / TASKS A2）。
 * id 稳定（落库后不可改）；name 面向用户。
 */
export const THEME_PRESETS: ThemePreset[] = [
  {
    id: 'harmony-dark',
    name: 'Harmony Dark',
    dark: true,
    colors: colors(
      HARMONY_DARK_PALETTE,
      '#E8EEFB', '#0E131D', '#4D8DFF', '#26314A'
    )
  },
  {
    id: 'harmony-light',
    name: 'Harmony Light',
    dark: false,
    colors: colors(
      [
        '#1A2233', '#DC3F43', '#16A765', '#C9800C',
        '#2F6FE4', '#A14BC8', '#0E8FA8', '#C9D4E8',
        '#5D6B85', '#F4605F', '#34C77B', '#F5A524',
        '#4D8DFF', '#C678DD', '#3EC6D9', '#FFFFFF'
      ],
      '#1A2233', '#F2F5FB', '#2F6FE4', '#C5D4F0'
    )
  },
  {
    id: 'one-dark-pro',
    name: 'One Dark Pro',
    dark: true,
    colors: colors(
      [
        '#282C34', '#E06C75', '#98C379', '#E5C07B',
        '#61AFEF', '#C678DD', '#56B6C2', '#ABB2BF',
        '#5C6370', '#FF7B86', '#A8D58A', '#F0D08A',
        '#74BFFF', '#D89AE8', '#6ED7DE', '#FFFFFF'
      ],
      '#ABB2BF', '#282C34', '#528BFF', '#3E4451'
    )
  },
  {
    id: 'dracula',
    name: 'Dracula',
    dark: true,
    colors: colors(
      [
        '#21222C', '#FF5555', '#50FA7B', '#F1FA8C',
        '#BD93F9', '#FF79C6', '#8BE9FD', '#F8F8F2',
        '#6272A4', '#FF6E6E', '#69FF94', '#FFFFA5',
        '#D6ACFF', '#FF92DF', '#A4FFFF', '#FFFFFF'
      ],
      '#F8F8F2', '#282A36', '#F8F8F2', '#44475A'
    )
  },
  {
    id: 'nord',
    name: 'Nord',
    dark: true,
    colors: colors(
      [
        '#3B4252', '#BF616A', '#A3BE8C', '#EBCB8B',
        '#81A1C1', '#B48EAD', '#88C0D0', '#E5E9F0',
        '#4C566A', '#D08770', '#B5CEA0', '#F0D399',
        '#8FBCBB', '#C8A2C8', '#94D6DF', '#ECEFF4'
      ],
      '#ECEFF4', '#2E3440', '#88C0D0', '#434C5E'
    )
  },
  {
    id: 'solarized-dark',
    name: 'Solarized Dark',
    dark: true,
    colors: colors(
      [
        '#073642', '#DC322F', '#859900', '#B58900',
        '#268BD2', '#D33682', '#2AA198', '#EEE8D5',
        '#586E75', '#CB4B16', '#93A1A1', '#839496',
        '#6C71C4', '#D33682', '#2AA198', '#FDF6E3'
      ],
      '#839496', '#002B36', '#839496', '#073642'
    )
  },
  {
    id: 'solarized-light',
    name: 'Solarized Light',
    dark: false,
    colors: colors(
      [
        '#073642', '#DC322F', '#859900', '#B58900',
        '#268BD2', '#D33682', '#2AA198', '#EEE8D5',
        '#586E75', '#CB4B16', '#93A1A1', '#839496',
        '#6C71C4', '#D33682', '#2AA198', '#FDF6E3'
      ],
      '#657B83', '#FDF6E3', '#657B83', '#EEE8D5'
    )
  },
  {
    id: 'tokyo-night',
    name: 'Tokyo Night',
    dark: true,
    colors: colors(
      [
        '#15161E', '#F7768E', '#9ECE6A', '#E0AF68',
        '#7AA2F7', '#BB9AF7', '#7DCFFF', '#A9B1D6',
        '#414868', '#FF899D', '#B9F27C', '#FFAF5F',
        '#8DB0FF', '#C7A0F8', '#A5E6FF', '#C0CAF5'
      ],
      '#C0CAF5', '#1A1B26', '#C0CAF5', '#29304D'
    )
  },
  {
    id: 'github-light',
    name: 'GitHub Light',
    dark: false,
    colors: colors(
      [
        '#24292F', '#CF222E', '#116329', '#4D2D00',
        '#0969DA', '#8250DF', '#1B7C83', '#6E7781',
        '#57606A', '#A40E26', '#1A7F37', '#633C01',
        '#218BFF', '#A475F9', '#3192AA', '#8C959F'
      ],
      '#24292F', '#FFFFFF', '#24292F', '#B3E0FF'
    )
  }
];

/** 按 id 查预设；不存在返回 null */
export function themePresetById(id: string): ThemePreset | null {
  for (const preset of THEME_PRESETS) {
    if (preset.id === id) {
      return preset;
    }
  }
  return null;
}

/**
 * 预设 → AppearanceProfile（不落库）。
 * id/name 由调用方覆盖；字体等非色位项沿用 C3 默认（Harmony 常用值）。
 */
export function appearanceFromThemePreset(id: string, preset: ThemePreset): AppearanceProfile {
  const base: AppearanceProfile = createDefaultAppearanceProfile(id);
  base.name = preset.name;
  base.fontFamily = buildTerminalFontFamily();
  return applyThemeColors(base, preset.colors);
}

/** 把 20 色写入 profile（palette 返回独立副本） */
export function applyThemeColors(profile: AppearanceProfile, themeColors: ThemeColorSet): AppearanceProfile {
  profile.palette = themeColors.palette.slice();
  profile.foreground = themeColors.foreground;
  profile.background = themeColors.background;
  profile.cursorColor = themeColors.cursorColor;
  profile.selectionColor = themeColors.selectionColor;
  return profile;
}

/** 预设色位的合法数量校验（A2 验收：9 套 × 20 色齐全） */
export function isValidThemeColorSet(themeColors: ThemeColorSet): boolean {
  if (themeColors.palette.length !== 16) {
    return false;
  }
  const extras: string[] = [
    themeColors.foreground,
    themeColors.background,
    themeColors.cursorColor,
    themeColors.selectionColor
  ];
  for (let i = 0; i < themeColors.palette.length; i++) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(themeColors.palette[i])) {
      return false;
    }
  }
  for (let i = 0; i < extras.length; i++) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(extras[i])) {
      return false;
    }
  }
  return true;
}

/** 光标样式合法值（AppearancePage 分段控件共用） */
export const CURSOR_STYLE_OPTIONS: CursorStyle[] = ['block', 'bar', 'underline'];

export function cursorStyleLabel(style: CursorStyle): string {
  if (style === 'bar') {
    return '竖线';
  }
  if (style === 'underline') {
    return '下划线';
  }
  return '块';
}

// ---------------------------------------------------------------- A6：应用整体主题模式

/** 应用主题模式（与 SettingsRepository.ThemeMode 同域；纯逻辑层独立定义便于单测） */
export type AppThemeMode = 'system' | 'dark' | 'light';

/** OHOS colorMode 名（ConfigurationConstant.ColorMode 的语义映射，单测可断言） */
export type ColorModeName = 'not_set' | 'dark' | 'light';

export const THEME_MODE_OPTIONS: AppThemeMode[] = ['system', 'dark', 'light'];

/** 脏值归一：非 dark/light 一律 system（与 SettingsRepository.getThemeMode 同策略） */
export function normalizeThemeMode(value: string): AppThemeMode {
  if (value === 'dark' || value === 'light') {
    return value;
  }
  return 'system';
}

export function themeModeLabel(mode: AppThemeMode): string {
  if (mode === 'dark') {
    return '深色';
  }
  if (mode === 'light') {
    return '浅色';
  }
  return '跟随系统';
}

/**
 * themeMode → colorMode 语义名。
 * system → not_set（跟随系统，resources dark/ 自动覆盖）；
 * dark/light → 强制对应模式。EntryAbility / AppearancePage 据此 setColorMode。
 */
export function themeModeToColorModeName(mode: AppThemeMode): ColorModeName {
  if (mode === 'dark') {
    return 'dark';
  }
  if (mode === 'light') {
    return 'light';
  }
  return 'not_set';
}
