/**
 * 终端配色导入解析 —— 任务 A4（部分，纯函数）。
 *
 * 支持：
 *   - iTerm2 `.itermcolors`（XML plist，键名如 "Ansi 0 Color"，值为
 *     {Red,Green,Blue} 分量对象，分量 0–1 浮点）；
 *   - Windows Terminal 配色 JSON（scheme 对象：name + black/red/…/brightWhite
 *     + foreground/background/cursorColor/selectionBackground，#RRGGBB）。
 *
 * 非法输入返回 {ok:false, error}，绝不抛异常（UI 层据此 toast）。
 */

import { ThemeColorSet } from '../../theme/ThemePresets';
import { isHexColor, normalizeHexColor } from './HexColor';

export interface ThemeImportResult {
  readonly ok: boolean;
  /** 成功时的 20 色；失败时为 null */
  readonly colors: ThemeColorSet | null;
  /** 建议主题名（iTerm 无名称字段时为空串） */
  readonly name: string;
  /** 失败原因（中文，面向用户） */
  readonly error: string;
}

function fail(error: string): ThemeImportResult {
  return { ok: false, colors: null, name: '', error: error };
}

function success(themeColors: ThemeColorSet, name: string): ThemeImportResult {
  return { ok: true, colors: themeColors, name: name, error: '' };
}

function emptyColors(): ThemeColorSet {
  return {
    palette: [
      '#000000', '#000000', '#000000', '#000000',
      '#000000', '#000000', '#000000', '#000000',
      '#000000', '#000000', '#000000', '#000000',
      '#000000', '#000000', '#000000', '#000000'
    ],
    foreground: '#FFFFFF',
    background: '#000000',
    cursorColor: '#FFFFFF',
    selectionColor: '#333333'
  };
}

/** 0–1 浮点 → 0–255 整数 → #RRGGBB */
export function componentToHex(component: number): string {
  const clamped: number = Math.max(0, Math.min(1, component));
  const byte: number = Math.round(clamped * 255);
  const hex: string = byte.toString(16).toUpperCase();
  return hex.length === 1 ? `#0${hex}` : `#${hex}`;
}

/**
 * 从 iTerm2 plist XML 文本提取指定键的 RGB 分量。
 * 键形如 `Ansi 0 Color`；值块含 `<key>Red Component</key><real>0.1</real>`。
 * 解析失败返回 null。
 */
export function itermColorFromXml(xml: string, keyName: string): string | null {
  const keyTag: string = `<key>${keyName}</key>`;
  const keyIndex: number = xml.indexOf(keyTag);
  if (keyIndex < 0) {
    return null;
  }
  // 键之后最近的 <dict>…</dict>
  const dictStart: number = xml.indexOf('<dict>', keyIndex);
  const dictEnd: number = xml.indexOf('</dict>', keyIndex);
  if (dictStart < 0 || dictEnd < dictStart) {
    return null;
  }
  const dictBody: string = xml.substring(dictStart, dictEnd);
  const red: number | null = itermRealComponent(dictBody, 'Red Component');
  const green: number | null = itermRealComponent(dictBody, 'Green Component');
  const blue: number | null = itermRealComponent(dictBody, 'Blue Component');
  if (red === null || green === null || blue === null) {
    return null;
  }
  return componentToHex(red) + componentToHex(green).substring(1) +
    componentToHex(blue).substring(1);
}

function itermRealComponent(dictBody: string, componentKey: string): number | null {
  const marker: string = `<key>${componentKey}</key>`;
  const index: number = dictBody.indexOf(marker);
  if (index < 0) {
    return null;
  }
  const realStart: number = dictBody.indexOf('<real>', index);
  const realEnd: number = dictBody.indexOf('</real>', index);
  if (realStart < 0 || realEnd < realStart) {
    return null;
  }
  const raw: string = dictBody.substring(realStart + 6, realEnd).trim();
  const value: number = Number.parseFloat(raw);
  return Number.isFinite(value) ? value : null;
}

/** Windows Terminal / iTerm 键位 → ANSI 下标（0–15）与特殊位 */
const WT_COLOR_KEYS: string[] = [
  'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow',
  'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite'
];

const ITERM_ANSI_KEYS: string[] = [
  'Ansi 0 Color', 'Ansi 1 Color', 'Ansi 2 Color', 'Ansi 3 Color',
  'Ansi 4 Color', 'Ansi 5 Color', 'Ansi 6 Color', 'Ansi 7 Color',
  'Ansi 8 Color', 'Ansi 9 Color', 'Ansi 10 Color', 'Ansi 11 Color',
  'Ansi 12 Color', 'Ansi 13 Color', 'Ansi 14 Color', 'Ansi 15 Color'
];

/**
 * 解析 iTerm2 `.itermcolors`（XML plist 文本）。
 * 非 XML / 缺关键色位 → 失败结果。
 */
export function parseITerm2Colors(xml: string): ThemeImportResult {
  if (xml.trim().length === 0 || xml.indexOf('<plist') < 0) {
    return fail('不是有效的 iTerm2 配色文件（缺少 plist 结构）');
  }
  const themeColors: ThemeColorSet = emptyColors();
  let missing: number = 0;
  for (let i = 0; i < ITERM_ANSI_KEYS.length; i++) {
    const hex: string | null = itermColorFromXml(xml, ITERM_ANSI_KEYS[i]);
    if (hex === null) {
      missing++;
    } else {
      themeColors.palette[i] = hex;
    }
  }
  const fg: string | null = itermColorFromXml(xml, 'Foreground Color');
  const bg: string | null = itermColorFromXml(xml, 'Background Color');
  const cursor: string | null = itermColorFromXml(xml, 'Cursor Color');
  const selection: string | null = itermColorFromXml(xml, 'Selection Color');
  if (fg !== null) {
    themeColors.foreground = fg;
  }
  if (bg !== null) {
    themeColors.background = bg;
  }
  if (cursor !== null) {
    themeColors.cursorColor = cursor;
  }
  if (selection !== null) {
    themeColors.selectionColor = selection;
  }
  if (missing > 0) {
    return fail(`iTerm2 配色缺少 ${missing} 个 ANSI 色位`);
  }
  return success(themeColors, '');
}

/**
 * 解析 Windows Terminal scheme JSON。
 * 接受单个 scheme 对象，或含 `schemes: [...]` 的整份 profiles.json 片段
 * （多 scheme 时取第一个）。
 */
export function parseWindowsTerminalColors(jsonText: string): ThemeImportResult {
  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(jsonText) as Object;
  } catch (err) {
    return fail('不是有效的 JSON 配色文件');
  }
  if (parsed === null) {
    return fail('Windows Terminal 配色内容为空');
  }
  const record: Record<string, Object> = parsed as Record<string, Object>;
  let scheme: Record<string, Object> | null = null;
  if (typeof record['name'] === 'string' || typeof record['background'] === 'string') {
    scheme = record;
  } else {
    const schemesValue: Object | undefined = record['schemes'];
    if (schemesValue !== undefined && Array.isArray(schemesValue)) {
      const list: Object[] = schemesValue as Object[];
      if (list.length === 0) {
        return fail('Windows Terminal 配色 schemes 为空');
      }
      scheme = list[0] as Record<string, Object>;
    }
  }
  if (scheme === null) {
    return fail('Windows Terminal 配色缺少 scheme 对象');
  }
  const themeColors: ThemeColorSet = emptyColors();
  let missing: number = 0;
  for (let i = 0; i < WT_COLOR_KEYS.length; i++) {
    const raw: Object | undefined = scheme[WT_COLOR_KEYS[i]];
    const text: string = typeof raw === 'string' ? raw : '';
    if (!isHexColor(text) && !isHexColor(`#${text.replace('#', '')}`)) {
      missing++;
      continue;
    }
    const hex: string = text.startsWith('#') ? normalizeHexColor(text) : normalizeHexColor(`#${text}`);
    themeColors.palette[i] = hex;
  }
  const fgRaw: Object | undefined = scheme['foreground'];
  const bgRaw: Object | undefined = scheme['background'];
  const cursorRaw: Object | undefined = scheme['cursorColor'];
  const selectionRaw: Object | undefined = scheme['selectionBackground'];
  if (typeof fgRaw === 'string' && isHexColor(fgRaw)) {
    themeColors.foreground = normalizeHexColor(fgRaw);
  }
  if (typeof bgRaw === 'string' && isHexColor(bgRaw)) {
    themeColors.background = normalizeHexColor(bgRaw);
  }
  if (typeof cursorRaw === 'string' && isHexColor(cursorRaw)) {
    themeColors.cursorColor = normalizeHexColor(cursorRaw);
  }
  if (typeof selectionRaw === 'string' && isHexColor(selectionRaw)) {
    themeColors.selectionColor = normalizeHexColor(selectionRaw);
  }
  const nameRaw: Object | undefined = scheme['name'];
  const name: string = typeof nameRaw === 'string' ? nameRaw : '';
  if (missing > 0) {
    return fail(`Windows Terminal 配色缺少 ${missing} 个 ANSI 色位`);
  }
  return success(themeColors, name);
}

/** 按扩展名/内容嗅探调用对应解析器；无法识别时失败 */
export function parseThemeImport(fileName: string, content: string): ThemeImportResult {
  const lower: string = fileName.toLowerCase();
  if (lower.endsWith('.itermcolors') || content.indexOf('<plist') >= 0) {
    return parseITerm2Colors(content);
  }
  if (lower.endsWith('.json') || content.trim().startsWith('{')) {
    return parseWindowsTerminalColors(content);
  }
  return fail('无法识别的配色文件格式（支持 .itermcolors 与 Windows Terminal JSON）');
}
