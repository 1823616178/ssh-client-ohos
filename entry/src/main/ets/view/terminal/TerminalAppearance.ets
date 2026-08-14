/**
 * 终端外观参数（任务 T4）。
 *
 * TerminalCanvas 的输入对象；字段是 AppearanceProfile（C3，models.ets）中
 * 渲染相关项的子集 + fontWeight/boldAsBright。A 系列任务（外观系统）落地时
 * 由 terminalAppearanceFromProfile 接入完整 profile（T8 已补 selectionColor
 * 选区背景色）。
 */
import { AppearanceProfile, CursorStyle, createDefaultAppearanceProfile } from '../../common/model/models';

export interface TerminalAppearance {
  fontFamily: string;
  /** 字号（vp；Canvas 默认单位模式下直接进 font 字符串） */
  fontSize: number;
  /** 行高倍数（cellHeight = fontSize × lineHeight） */
  lineHeight: number;
  /** 字间距（vp；≠0 时文本逐格绘制保对齐） */
  letterSpacing: number;
  fontWeight: number;
  /** bold 且前景为 ANSI 0–7 时改用 8–15 亮色 */
  boldAsBright: boolean;
  cursorStyle: CursorStyle;
  /** 光标闪烁开关：首版不实现闪烁定时（见 TerminalCanvas 头注），字段保留 */
  cursorBlink: boolean;
  /** 背景不透明度 0–1 */
  backgroundOpacity: number;
  /** 终端四周内边距（vp） */
  padding: number;
  /** 16 × #RRGGBB（ANSI 0–15） */
  palette: string[];
  foreground: string;
  background: string;
  cursorColor: string;
  /** 选区背景色（T8 选择模式叠加层；#RRGGBB） */
  selectionColor: string;
}

/** AppearanceProfile → 渲染所需子集 */
export function terminalAppearanceFromProfile(profile: AppearanceProfile): TerminalAppearance {
  return {
    fontFamily: profile.fontFamily,
    fontSize: profile.fontSize,
    lineHeight: profile.lineHeight,
    letterSpacing: profile.letterSpacing,
    fontWeight: profile.fontWeight,
    boldAsBright: profile.boldAsBright,
    cursorStyle: profile.cursorStyle,
    cursorBlink: profile.cursorBlink,
    backgroundOpacity: profile.backgroundOpacity,
    padding: profile.padding,
    // 独立副本：渲染缓存解析调色板时不许回写 profile
    palette: profile.palette.slice(),
    foreground: profile.foreground,
    background: profile.background,
    cursorColor: profile.cursorColor,
    selectionColor: profile.selectionColor
  };
}

/** 默认外观：取 C3 的 createDefaultAppearanceProfile（Harmony Dark，DESIGN §4.4 常用值） */
export function createDefaultTerminalAppearance(): TerminalAppearance {
  return terminalAppearanceFromProfile(createDefaultAppearanceProfile('terminal-default'));
}
