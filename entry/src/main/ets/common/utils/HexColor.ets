/**
 * #RRGGBB 颜色工具：校验、HSV 互转、预设去重。
 * 选色盘与外观草稿共用；纯函数，供 hypium 覆盖。
 */

export interface HsvColor {
  /** 色相 0–360 */
  h: number;
  /** 饱和度 0–1 */
  s: number;
  /** 明度 0–1 */
  v: number;
}

const HEX6_PATTERN: RegExp = /^#[0-9a-fA-F]{6}$/;

/** 严格 #RRGGBB（6 位十六进制） */
export function isHexColor(value: string): boolean {
  return HEX6_PATTERN.test(value);
}

/** 合法则规范成大写 #RRGGBB，否则原样返回 */
export function normalizeHexColor(value: string): string {
  return isHexColor(value) ? value.toUpperCase() : value;
}

/** 色相对应的纯饱和色，供饱和度/明度平面当底色 */
export function hueToHex(hue: number): string {
  return hsvToHex(hue, 1, 1);
}

export function hexToHsv(hex: string): HsvColor {
  const normalized: string = normalizeHexColor(hex);
  if (!isHexColor(normalized)) {
    return { h: 0, s: 0, v: 0 };
  }
  const r: number = parseInt(normalized.slice(1, 3), 16) / 255;
  const g: number = parseInt(normalized.slice(3, 5), 16) / 255;
  const b: number = parseInt(normalized.slice(5, 7), 16) / 255;
  const max: number = Math.max(r, g, b);
  const min: number = Math.min(r, g, b);
  const delta: number = max - min;
  let h: number = 0;
  if (delta > 0) {
    if (max === r) {
      h = 60 * (((g - b) / delta) % 6);
    } else if (max === g) {
      h = 60 * ((b - r) / delta + 2);
    } else {
      h = 60 * ((r - g) / delta + 4);
    }
  }
  if (h < 0) {
    h += 360;
  }
  return {
    h: h,
    s: max === 0 ? 0 : delta / max,
    v: max
  };
}

export function hsvToHex(hue: number, saturation: number, value: number): string {
  const h: number = ((hue % 360) + 360) % 360;
  const s: number = clamp01(saturation);
  const v: number = clamp01(value);
  const c: number = v * s;
  const sector: number = h / 60;
  const x: number = c * (1 - Math.abs(sector % 2 - 1));
  const m: number = v - c;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (sector < 1) {
    r = c;
    g = x;
  } else if (sector < 2) {
    r = x;
    g = c;
  } else if (sector < 3) {
    g = c;
    b = x;
  } else if (sector < 4) {
    g = x;
    b = c;
  } else if (sector < 5) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  return '#' + byteHex(r + m) + byteHex(g + m) + byteHex(b + m);
}

/** 保序去重，非法项丢弃，输出大写 #RRGGBB */
export function uniqueHexColors(values: string[]): string[] {
  const seen: Set<string> = new Set();
  const result: string[] = [];
  for (let i = 0; i < values.length; i++) {
    const hex: string = normalizeHexColor(values[i]);
    if (!isHexColor(hex) || seen.has(hex)) {
      continue;
    }
    seen.add(hex);
    result.push(hex);
  }
  return result;
}

export function clamp01(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

function byteHex(unit: number): string {
  const value: number = Math.max(0, Math.min(255, Math.round(unit * 255)));
  const hex: string = value.toString(16).toUpperCase();
  return hex.length === 1 ? `0${hex}` : hex;
}
