/**
 * UrlDetector —— 终端行内链接识别（纯逻辑）。
 *
 * 只识别「明确是链接」的形态，宁缺毋滥：
 *   http:// https:// ftp:// file:// 与 www. 开头；
 * 末尾的句读（。，,.;:!?）与不成对的右括号/引号会被剥掉（`(see https://a.b/c).`
 * → `https://a.b/c`）。行跨软换行时调用方先把逻辑行拼起来再识别。
 */

export interface UrlMatch {
  /** 链接文本（www. 开头的会补 https:// 便于直接打开，见 openableUrl） */
  text: string;
  /** 在输入串里的起止 UTF-16 下标 [start, end) */
  start: number;
  end: number;
}

const URL_PATTERN: RegExp = /(?:https?:\/\/|ftp:\/\/|file:\/\/|www\.)[^\s<>"'`\u3000-\u303F\uFF01-\uFF0F]+/g;
const TRAILING_PUNCT: string = '.,;:!?。，；：！？、';

function stripTrailing(url: string): string {
  let s: string = url;
  let changed: boolean = true;
  while (changed && s.length > 0) {
    changed = false;
    const last: string = s.charAt(s.length - 1);
    if (TRAILING_PUNCT.indexOf(last) >= 0) {
      s = s.substring(0, s.length - 1);
      changed = true;
      continue;
    }
    if (last === ')' || last === ']' || last === '}') {
      const open: string = last === ')' ? '(' : (last === ']' ? '[' : '{');
      if (countChar(s, open) < countChar(s, last)) {
        s = s.substring(0, s.length - 1);
        changed = true;
      }
    }
  }
  return s;
}

function countChar(s: string, ch: string): number {
  let n: number = 0;
  for (let i = 0; i < s.length; i++) {
    if (s.charAt(i) === ch) {
      n++;
    }
  }
  return n;
}

/** 找出一行文本里的全部链接 */
export function detectUrls(line: string): UrlMatch[] {
  const result: UrlMatch[] = [];
  URL_PATTERN.lastIndex = 0;
  let m: RegExpExecArray | null = URL_PATTERN.exec(line);
  while (m !== null) {
    const raw: string = m[0];
    const text: string = stripTrailing(raw);
    // 只有前缀（如 "https://"）不算链接
    const minLen: number = text.startsWith('www.') ? 5 : text.indexOf('://') + 4;
    if (text.length >= minLen) {
      result.push({ text: text, start: m.index, end: m.index + text.length });
    }
    m = URL_PATTERN.exec(line);
  }
  return result;
}

/** 下标 index 处的链接（无则 null） */
export function urlAt(line: string, index: number): UrlMatch | null {
  const all: UrlMatch[] = detectUrls(line);
  for (const u of all) {
    if (index >= u.start && index < u.end) {
      return u;
    }
  }
  return null;
}

/** 可直接交给系统打开的形式（www. → https://www.） */
export function openableUrl(text: string): string {
  return text.startsWith('www.') ? `https://${text}` : text;
}

/** 选中文本是否「恰好就是一个链接」（气泡菜单显示「打开链接」用） */
export function singleUrlIn(text: string): string {
  const trimmed: string = text.trim();
  if (trimmed.length === 0 || /\s/.test(trimmed)) {
    return '';
  }
  const all: UrlMatch[] = detectUrls(trimmed);
  if (all.length === 1 && all[0].start === 0) {
    return openableUrl(all[0].text);
  }
  return '';
}
