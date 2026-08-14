/**
 * 终端配色纯函数（任务 T4，hypium 覆盖）。
 *
 * 网格单元格里的 fgArgb/bgArgb 已由 native（libvterm）解析为 ARGB；
 * 本模块只处理「外观配置侧」的颜色：#RRGGBB 解析、16 色调色板校验、
 * bold-as-bright 映射（bold + ANSI 0–7 → 8–15）、ATTR_DIM 变暗、背景不透明度。
 *
 * ARGB 一律用无符号 32 位整数（0xAARRGGBB），与 CanvasRenderingContext2D
 * 的数值 fillStyle 语义一致。
 */

/** 调色板固定 16 色（ANSI 0–15，DESIGN §4.4） */
export const TERMINAL_PALETTE_SIZE = 16;

const HEX_COLOR_PATTERN = /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;

/**
 * '#RRGGBB' → 0xFFRRGGBB；'#AARRGGBB' → 原样解析。
 * 非法输入抛 Error——外观配置的合法性由 A 系列任务在入库前保证，
 * 渲染路径上不静默容错（配错颜色应当暴露而不是渲染成随机色）。
 */
export function hexColorToArgb(hex: string): number {
  if (!HEX_COLOR_PATTERN.test(hex)) {
    throw new Error(`非法颜色值（期望 #RRGGBB 或 #AARRGGBB）：${hex}`);
  }
  const body = hex.slice(1);
  const value = parseInt(body, 16);
  // >>> 0 保持无符号（0xFF000000 | value 在按位或后会落成 int32 负数）
  return body.length === 6 ? ((0xFF000000 | value) >>> 0) : (value >>> 0);
}

/** 16 色调色板 hex → ARGB；长度不为 16 或条目非法时抛 Error */
export function paletteToArgb(palette: string[]): number[] {
  if (palette.length !== TERMINAL_PALETTE_SIZE) {
    throw new Error(`调色板必须为 ${TERMINAL_PALETTE_SIZE} 色，实际 ${palette.length}`);
  }
  return palette.map((color: string) => hexColorToArgb(color));
}

/**
 * bold-as-bright：bold 且前景色恰等于 ANSI 0–7 调色板色时改用对应 8–15 亮色。
 * 真彩色不与调色板比对（native 已解析成 ARGB，这里按数值精确匹配反查）。
 */
export function applyBoldAsBright(fgArgb: number, bold: boolean, paletteArgb: number[],
  enabled: boolean): number {
  if (!enabled || !bold) {
    return fgArgb;
  }
  for (let i = 0; i < 8; i++) {
    if (paletteArgb[i] === fgArgb && i + 8 < paletteArgb.length) {
      return paletteArgb[i + 8];
    }
  }
  return fgArgb;
}

/** ATTR_DIM：前景向背景混合 50%（alpha 保留前景值） */
export function applyDim(fgArgb: number, bgArgb: number): number {
  const a = (fgArgb >>> 24) & 0xFF;
  const r = (((fgArgb >>> 16) & 0xFF) + ((bgArgb >>> 16) & 0xFF)) >> 1;
  const g = (((fgArgb >>> 8) & 0xFF) + ((bgArgb >>> 8) & 0xFF)) >> 1;
  const b = ((fgArgb & 0xFF) + (bgArgb & 0xFF)) >> 1;
  return (((a << 24) | (r << 16) | (g << 8) | b)) >>> 0;
}

/** 按不透明度缩放 alpha 通道（终端背景不透明度），opacity 钳到 [0, 1] */
export function withOpacity(argb: number, opacity: number): number {
  const clamped = Math.min(1, Math.max(0, opacity));
  const a = Math.round(((argb >>> 24) & 0xFF) * clamped);
  return (((a << 24) >>> 0) | (argb & 0x00FFFFFF)) >>> 0;
}
