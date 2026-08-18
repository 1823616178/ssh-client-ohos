/**
 * T5 终端字体注册与度量的纯逻辑测试（hypium）。
 *
 * 覆盖（不触 ArkUI 运行时；registerFont 本身依赖运行时，不测注册动作）：
 *  - FontService：字族栈常量、buildTerminalFontFamily 拼接；
 *  - FontMetrics：fontMeasureKey 格式、度量缓存命中/失效/失败重测、
 *    isCjkAlignment 容差判定、verifyCjkAlignment 注入假 ctx 的端到端判定。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  FONT_STACK_ASCII,
  FONT_STACK_CJK,
  buildTerminalFontFamily
} from '../main/ets/theme/FontService';
import {
  TextMeasureContext,
  TextMeasureResult,
  computeBaselineOffsetFromCenter,
  fontMeasureKey,
  invalidateFontMeasureCache,
  isCjkAligned,
  measureTerminalCells,
  verifyCjkAlignment
} from '../main/ets/view/terminal/FontMetrics';

/** 假度量上下文：按字符脚本化返回宽度，并计数 measureText 调用 */
class FakeMeasureContext implements TextMeasureContext {
  font: string = '';
  calls: number = 0;
  private widths: Record<string, number>;

  constructor(widths: Record<string, number>) {
    this.widths = widths;
  }

  measureText(text: string): TextMeasureResult {
    this.calls++;
    const w = this.widths[text];
    return { width: w === undefined ? 0 : w };
  }
}

export default function fontServiceTest() {
  describe('FontServiceTest', () => {

    it('字族栈常量', 0, () => {
      expect(FONT_STACK_ASCII).assertEqual('JetBrains Mono');
      expect(FONT_STACK_CJK).assertEqual('Sarasa Term SC');
    });

    it('buildTerminalFontFamily_拼接', 0, () => {
      expect(buildTerminalFontFamily()).assertEqual('JetBrains Mono, Sarasa Term SC');
    });

    it('fontMeasureKey_字族字号字重', 0, () => {
      expect(fontMeasureKey('JetBrains Mono, Sarasa Term SC', 14, 400))
        .assertEqual('JetBrains Mono, Sarasa Term SC|14|400');
      expect(fontMeasureKey('A', 14, 400) !== fontMeasureKey('A', 15, 400)).assertTrue();
      expect(fontMeasureKey('A', 14, 400) !== fontMeasureKey('A', 14, 700)).assertTrue();
    });

    it('度量_缓存命中不重测', 0, () => {
      invalidateFontMeasureCache();
      const ctx = new FakeMeasureContext({ 'W': 8.4 });
      const family = 'CacheHit Family';
      const m1 = measureTerminalCells(ctx, family, 14, 400);
      expect(m1.measured).assertTrue();
      expect(m1.glyphWidthVp).assertEqual(8.4);
      expect(ctx.calls).assertEqual(2);
      expect(m1.fontNormal).assertEqual('normal normal 14vp "CacheHit Family", monospace');
      expect(m1.fontBold).assertEqual('normal bold 14vp "CacheHit Family", monospace');
      expect(m1.fontItalic).assertEqual('italic normal 14vp "CacheHit Family", monospace');
      expect(m1.fontBoldItalic).assertEqual('italic bold 14vp "CacheHit Family", monospace');
      // 同 key 再测：走缓存，measureText 不再调用
      const m2 = measureTerminalCells(ctx, family, 14, 400);
      expect(m2.glyphWidthVp).assertEqual(8.4);
      expect(ctx.calls).assertEqual(2);
    });

    it('字母基线_按字体包围盒居中且无度量时兜底', 0, () => {
      expect(computeBaselineOffsetFromCenter(14, 11, 3)).assertEqual(4);
      expect(computeBaselineOffsetFromCenter(14, 0, 0)).assertEqual(4.2);
      expect(computeBaselineOffsetFromCenter(-1, 0, 0)).assertEqual(0);
    });

    it('度量_key变化重测', 0, () => {
      invalidateFontMeasureCache();
      const ctx = new FakeMeasureContext({ 'W': 8.4 });
      measureTerminalCells(ctx, 'KeyChange Family', 14, 400);
      measureTerminalCells(ctx, 'KeyChange Family', 15, 400); // 字号变
      measureTerminalCells(ctx, 'KeyChange Family', 14, 700); // 字重变
      measureTerminalCells(ctx, 'KeyChange Family2', 14, 400); // 字族变
      expect(ctx.calls).assertEqual(8);
    });

    it('度量_缓存失效后重测', 0, () => {
      invalidateFontMeasureCache();
      const ctx = new FakeMeasureContext({ 'W': 8.4 });
      measureTerminalCells(ctx, 'Invalidate Family', 14, 400);
      expect(ctx.calls).assertEqual(2);
      invalidateFontMeasureCache();
      measureTerminalCells(ctx, 'Invalidate Family', 14, 400);
      expect(ctx.calls).assertEqual(4);
    });

    it('度量_失败不写缓存且下次重试', 0, () => {
      invalidateFontMeasureCache();
      const ctx = new FakeMeasureContext({}); // 任意字符宽度 0 = 度量失败
      const m1 = measureTerminalCells(ctx, 'Fail Family', 14, 400);
      expect(m1.measured).assertFalse();
      expect(m1.glyphWidthVp).assertEqual(0);
      expect(ctx.calls).assertEqual(2);
      // 失败不落缓存：字体注册完成后下一次调用会真正重测
      const ctx2 = new FakeMeasureContext({ 'W': 9.0 });
      const m2 = measureTerminalCells(ctx2, 'Fail Family', 14, 400);
      expect(m2.measured).assertTrue();
      expect(m2.glyphWidthVp).assertEqual(9.0);
    });

    it('对齐判定_容差边界', 0, () => {
      expect(isCjkAligned(8.4, 16.8)).assertTrue(); // 严格 1:2
      expect(isCjkAligned(8.4, 16.8 * 1.04)).assertTrue(); // +4% 容差内
      expect(isCjkAligned(8.4, 16.8 * 0.96)).assertTrue(); // -4% 容差内
      expect(isCjkAligned(8.4, 16.8 * 1.06)).assertFalse(); // 超 +5%
      expect(isCjkAligned(8.4, 16.8 * 0.94)).assertFalse(); // 超 -5%
      expect(isCjkAligned(0, 16.8)).assertFalse(); // 宽度非法不对齐
      expect(isCjkAligned(8.4, 0)).assertFalse();
    });

    it('对齐校验_注入假ctx', 0, () => {
      invalidateFontMeasureCache();
      const ctx = new FakeMeasureContext({ 'W': 8.4, '中': 16.8 });
      const r = verifyCjkAlignment(ctx, 'Align Family', 14, 400);
      expect(r.asciiWidthVp).assertEqual(8.4);
      expect(r.cjkWidthVp).assertEqual(16.8);
      expect(r.ratio).assertEqual(1);
      expect(r.aligned).assertTrue();
    });

    it('对齐校验_未对齐与度量失败', 0, () => {
      invalidateFontMeasureCache();
      const skewed = new FakeMeasureContext({ 'W': 8.4, '中': 20 });
      expect(verifyCjkAlignment(skewed, 'Skew Family', 14, 400).aligned).assertFalse();
      const dead = new FakeMeasureContext({});
      const r = verifyCjkAlignment(dead, 'Dead Family', 14, 400);
      expect(r.aligned).assertFalse();
      expect(r.ratio).assertEqual(0);
    });

  });
}
