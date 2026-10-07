/**
 * 光标闪烁纯函数测试（A3 residual，TerminalDrawCommands.cursorVisibleAt）。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  CURSOR_BLINK_PERIOD_MS,
  cursorVisibleAt
} from '../main/ets/view/terminal/TerminalDrawCommands';

export default function cursorBlinkTest() {
  describe('CursorBlinkTest', () => {

    it('cursorVisibleAt_未开启闪烁恒可见', 0, () => {
      expect(cursorVisibleAt(0, false, CURSOR_BLINK_PERIOD_MS)).assertTrue();
      expect(cursorVisibleAt(10000, false, CURSOR_BLINK_PERIOD_MS)).assertTrue();
      expect(cursorVisibleAt(999, false, 0)).assertTrue();
    });

    it('cursorVisibleAt_周期非法恒可见', 0, () => {
      expect(cursorVisibleAt(100, true, 0)).assertTrue();
      expect(cursorVisibleAt(100, true, -5)).assertTrue();
    });

    it('cursorVisibleAt_半周期奇偶翻转', 0, () => {
      const period: number = CURSOR_BLINK_PERIOD_MS; // 1060 → half=530
      const half: number = Math.floor(period / 2);
      expect(cursorVisibleAt(0, true, period)).assertTrue();
      expect(cursorVisibleAt(half - 1, true, period)).assertTrue();
      expect(cursorVisibleAt(half, true, period)).assertFalse();
      expect(cursorVisibleAt(period - 1, true, period)).assertFalse();
      expect(cursorVisibleAt(period, true, period)).assertTrue();
      expect(cursorVisibleAt(period + 10, true, period)).assertTrue();
    });

    it('cursorVisibleAt_自定义短周期', 0, () => {
      // period=100 → half=50：0..49 可见，50..99 不可见
      expect(cursorVisibleAt(49, true, 100)).assertTrue();
      expect(cursorVisibleAt(50, true, 100)).assertFalse();
      expect(cursorVisibleAt(99, true, 100)).assertFalse();
      expect(cursorVisibleAt(100, true, 100)).assertTrue();
    });
  });
}
