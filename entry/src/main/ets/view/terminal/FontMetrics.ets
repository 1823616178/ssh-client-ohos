/**
 * 终端字体度量（任务 T5，DESIGN §4.4「字符宽度只在字体/字号变化时测一次并缓存」）。
 *
 * 单一事实源：T4 原内联在 TerminalCanvas.measureCells() 的度量逻辑收编到本模块，
 * TerminalCanvas 改为调用这里的函数（本模块不感知组件，hypium 可注入假 ctx 直测）。
 *
 * 缓存策略：
 *  - measureText('W') 的宽度与字体 ascent/descent 按「字族|字号|字重」缓存
 *    （模块级 Map，多 Canvas 实例共享；同一 font 字符串可跨实例复用）；
 *  - letterSpacing / lineHeight 不进缓存 key——它们不影响字形宽度，
 *    格宽 = 字宽 + letterSpacing、格高 = fontSize × lineHeight 由调用方换算；
 *  - 度量失败（字体未注册等，宽度非正或抛异常）不写缓存，下次调用自动重测；
 *  - 字体在运行期重新注册后可调 invalidateFontMeasureCache() 全量失效。
 *
 * 「改字号后一帧内重排」的机制链（TerminalCanvas 侧兑现）：外观 @Watch →
 * applyAppearance 同步重测 + 重排版 → needsFullRedraw + FrameScheduler.wakeup() →
 * 下一 vsync 帧全量上屏。度量本身是同步调用，不引入跨帧延迟。
 */
import { Logger } from '../../common/utils/Logger';
import { buildFontString } from './TerminalDrawCommands';

/** measureText 返回值的最小形状（Canvas SizeOptions 结构兼容） */
export interface TextMeasureResult {
  width: number;
  /** 字形与字体全局上伸/下伸；旧设备或测试假实现可缺省，调用方会走比例兜底。 */
  actualBoundingBoxAscent?: number;
  actualBoundingBoxDescent?: number;
  fontBoundingBoxAscent?: number;
  fontBoundingBoxDescent?: number;
}

/** 可注入的度量上下文：CanvasRenderingContext2D 的度量子集（测试用假实现注入） */
export interface TextMeasureContext {
  font: string;
  measureText(text: string): TextMeasureResult;
}

/** 一次完整度量的产出：四态 font 字符串 + 字形宽 */
export interface TerminalCellMetrics {
  fontNormal: string;
  fontBold: string;
  fontItalic: string;
  fontBoldItalic: string;
  /** 实测字形宽（vp，不含 letterSpacing）；measured=false 时为 0 */
  glyphWidthVp: number;
  /** alphabetic baseline 上下的代表性字形包围盒，用于在 cell 内垂直居中。 */
  fontAscentVp: number;
  fontDescentVp: number;
  /** false = measureText 失败/宽度非正（字体未注册），调用方走保底宽度且不落定缓存 key */
  measured: boolean;
}

/** CJK 对齐校验结果（供 UI/A3 提示「字体未对齐」） */
export interface CjkAlignmentResult {
  asciiWidthVp: number;
  cjkWidthVp: number;
  /** cjk / (2 × ascii)，对齐时应 ≈ 1 */
  ratio: number;
  aligned: boolean;
}

/** 度量探针：等宽字体 cell 宽 = 'W' 的 advance width */
const MEASURE_PROBE_ASCII = 'W';
/** 垂直探针：M 覆盖大写上伸，g 覆盖小写下伸，比字体全局框更接近视觉边界。 */
const MEASURE_PROBE_VERTICAL = 'Mg';
/** CJK 对齐校验探针 */
const MEASURE_PROBE_CJK = '中';
/** CJK 对齐容差：|cjk − 2×ascii| ≤ 2×ascii × 5% 视为对齐（Sarasa 设计保证严格 1:2，容差防浮点抖动） */
export const CJK_ALIGNMENT_TOLERANCE = 0.05;

/** 字形宽缓存：key 见 fontMeasureKey；只缓存成功度量 */
interface CachedFontMeasure {
  width: number;
  ascent: number;
  descent: number;
}

const widthCache: Map<string, CachedFontMeasure> = new Map();

/**
 * alphabetic baseline 相对 cell 几何中心的下移量。
 * 字体度量可用时严格按 (ascent-descent)/2 居中；不可用时采用常见 0.8/0.2
 * em 比例，仍比 Canvas 的 middle baseline 在 HarmonyOS 上稳定。
 */
export function computeBaselineOffsetFromCenter(fontSizeVp: number, ascentVp: number,
  descentVp: number): number {
  if (ascentVp > 0 && descentVp >= 0 && ascentVp + descentVp > 0) {
    return (ascentVp - descentVp) / 2;
  }
  return Math.max(0, fontSizeVp) * 0.3;
}

/** 度量缓存 key：字族 + 字号 + 字重 */
export function fontMeasureKey(fontFamily: string, fontSizeVp: number, fontWeight: number): string {
  return `${fontFamily}|${fontSizeVp}|${fontWeight}`;
}

/** 全量失效（字体重新注册等场景）；正常渲染路径不需要调 */
export function invalidateFontMeasureCache(): void {
  widthCache.clear();
}

/**
 * 度量终端 cell 字形宽（'W' 宽）并产出四态 font 字符串。
 * 缓存命中时不触碰 ctx；未命中时同步 measureText 一次。
 * 失败（异常/宽度非正）返回 measured=false 且不写缓存（下次自动重测）。
 */
export function measureTerminalCells(ctx: TextMeasureContext, fontFamily: string,
  fontSizeVp: number, fontWeight: number): TerminalCellMetrics {
  const metrics: TerminalCellMetrics = {
    fontNormal: buildFontString(false, false, fontWeight, fontSizeVp, fontFamily),
    fontBold: buildFontString(false, true, fontWeight, fontSizeVp, fontFamily),
    fontItalic: buildFontString(true, false, fontWeight, fontSizeVp, fontFamily),
    fontBoldItalic: buildFontString(true, true, fontWeight, fontSizeVp, fontFamily),
    glyphWidthVp: 0,
    fontAscentVp: 0,
    fontDescentVp: 0,
    measured: false
  };
  const key = fontMeasureKey(fontFamily, fontSizeVp, fontWeight);
  const cached = widthCache.get(key);
  if (cached !== undefined) {
    metrics.glyphWidthVp = cached.width;
    metrics.fontAscentVp = cached.ascent;
    metrics.fontDescentVp = cached.descent;
    metrics.measured = true;
    return metrics;
  }
  ctx.font = metrics.fontNormal;
  let width = 0;
  let ascent = 0;
  let descent = 0;
  try {
    const measured = ctx.measureText(MEASURE_PROBE_ASCII);
    width = measured.width;
    // 旧实现/设备没有 actualBoundingBox 时，先以字体全局框作后备。
    const measuredAscent = measured.fontBoundingBoxAscent;
    const measuredDescent = measured.fontBoundingBoxDescent;
    if (measuredAscent !== undefined && measuredAscent > 0) {
      ascent = measuredAscent;
    }
    if (measuredDescent !== undefined && measuredDescent >= 0) {
      descent = measuredDescent;
    }
    const vertical = ctx.measureText(MEASURE_PROBE_VERTICAL);
    const actualAscent = vertical.actualBoundingBoxAscent;
    const actualDescent = vertical.actualBoundingBoxDescent;
    if (actualAscent !== undefined && actualAscent > 0) {
      ascent = actualAscent;
    }
    if (actualDescent !== undefined && actualDescent >= 0) {
      descent = actualDescent;
    }
  } catch (e) {
    Logger.warn(`FontMetrics measureText 失败：${JSON.stringify(e)}`, 'Terminal');
  }
  if (width > 0) {
    widthCache.set(key, { width: width, ascent: ascent, descent: descent });
    metrics.glyphWidthVp = width;
    metrics.fontAscentVp = ascent;
    metrics.fontDescentVp = descent;
    metrics.measured = true;
  }
  return metrics;
}

/** CJK 1:2 对齐纯判定：'中' 宽 ≈ 2×'W' 宽（容差 tolerance，默认 ±5%） */
export function isCjkAligned(asciiWidthVp: number, cjkWidthVp: number,
  tolerance: number = CJK_ALIGNMENT_TOLERANCE): boolean {
  if (!(asciiWidthVp > 0) || !(cjkWidthVp > 0)) {
    return false;
  }
  const expected = 2 * asciiWidthVp;
  return Math.abs(cjkWidthVp - expected) <= expected * tolerance;
}

/**
 * 宽字符 2 格对齐校验：ASCII 宽走 measureTerminalCells（复用其缓存），
 * 再测 CJK 探针 '中'。结果供 UI 提示「字体未对齐」（TerminalCanvas 每换新 fontKey
 * 自动校验一次并记日志；A3 外观页可主动调用）。真机验证留 TASKS T5 待验清单。
 */
export function verifyCjkAlignment(ctx: TextMeasureContext, fontFamily: string,
  fontSizeVp: number, fontWeight: number): CjkAlignmentResult {
  const cells = measureTerminalCells(ctx, fontFamily, fontSizeVp, fontWeight);
  let cjkWidth = 0;
  if (cells.measured) {
    ctx.font = cells.fontNormal;
    try {
      cjkWidth = ctx.measureText(MEASURE_PROBE_CJK).width;
    } catch (e) {
      Logger.warn(`FontMetrics CJK 探针度量失败：${JSON.stringify(e)}`, 'Terminal');
    }
  }
  const asciiWidth = cells.glyphWidthVp;
  return {
    asciiWidthVp: asciiWidth,
    cjkWidthVp: cjkWidth,
    ratio: asciiWidth > 0 ? cjkWidth / (2 * asciiWidth) : 0,
    aligned: isCjkAligned(asciiWidth, cjkWidth)
  };
}
