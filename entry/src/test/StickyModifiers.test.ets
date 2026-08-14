/**
 * StickyModifiers 粘滞修饰键状态机测试（hypium，任务 T6）。
 *
 * 覆盖 DESIGN §4.4 派生的全部状态迁移：
 *   idle ⇄ pressed（点按切换/再点取消）、consume 复位 pressed、
 *   lock() 任意态 → locked、locked 不被 consume 复位、locked 再点取消、
 *   Ctrl/Alt 相互独立、snapshot/reset。
 */

import { describe, it, expect } from '@ohos/hypium';
import { StickyModifiers, StickyState } from '../main/ets/view/terminal/StickyModifiers';

export default function stickyModifiersTest() {
  describe('StickyModifiersTest', () => {

    it('初始idle双修饰均未激活', 0, () => {
      const s = new StickyModifiers();
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      expect(s.altState).assertEqual(StickyState.IDLE);
      expect(s.ctrlActive()).assertFalse();
      expect(s.altActive()).assertFalse();
      const snap = s.snapshot();
      expect(snap.ctrl).assertFalse();
      expect(snap.alt).assertFalse();
    });

    it('点按idle到pressed且active', 0, () => {
      const s = new StickyModifiers();
      s.tapCtrl();
      expect(s.ctrlState).assertEqual(StickyState.PRESSED);
      expect(s.ctrlActive()).assertTrue();
      expect(s.snapshot().ctrl).assertTrue();
      expect(s.altActive()).assertFalse(); // Alt 不受影响
    });

    it('pressed再点取消回idle', 0, () => {
      const s = new StickyModifiers();
      s.tapCtrl();
      s.tapCtrl();
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      expect(s.ctrlActive()).assertFalse();
    });

    it('consume把pressed复位为idle', 0, () => {
      const s = new StickyModifiers();
      s.tapCtrl();
      s.consume(); // 按键消费：一次性修饰用完
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      expect(s.ctrlActive()).assertFalse();
    });

    it('consume幂等且idle不受影响', 0, () => {
      const s = new StickyModifiers();
      s.consume();
      s.consume();
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      s.tapAlt();
      s.consume();
      s.consume(); // 多次消费不反复
      expect(s.altState).assertEqual(StickyState.IDLE);
    });

    it('lock从idle进入locked且consume保持', 0, () => {
      const s = new StickyModifiers();
      s.lockCtrl(); // 长按锁定（T7 键条入口）
      expect(s.ctrlState).assertEqual(StickyState.LOCKED);
      expect(s.ctrlActive()).assertTrue();
      s.consume();
      s.consume();
      expect(s.ctrlState).assertEqual(StickyState.LOCKED); // 锁定不被消费复位
      expect(s.ctrlActive()).assertTrue();
    });

    it('lock从pressed进入locked', 0, () => {
      const s = new StickyModifiers();
      s.tapAlt();
      s.lockAlt();
      expect(s.altState).assertEqual(StickyState.LOCKED);
      s.consume();
      expect(s.altState).assertEqual(StickyState.LOCKED);
    });

    it('locked再点取消回idle', 0, () => {
      const s = new StickyModifiers();
      s.lockCtrl();
      s.tapCtrl(); // 锁定态点按 = 取消
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      expect(s.ctrlActive()).assertFalse();
    });

    it('locked再次lock保持locked', 0, () => {
      const s = new StickyModifiers();
      s.lockAlt();
      s.lockAlt();
      expect(s.altState).assertEqual(StickyState.LOCKED);
    });

    it('Ctrl与Alt状态机相互独立', 0, () => {
      const s = new StickyModifiers();
      s.tapCtrl();
      s.lockAlt();
      expect(s.ctrlState).assertEqual(StickyState.PRESSED);
      expect(s.altState).assertEqual(StickyState.LOCKED);
      s.consume(); // 只复位 pressed 的 Ctrl
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      expect(s.altState).assertEqual(StickyState.LOCKED);
      const snap = s.snapshot();
      expect(snap.ctrl).assertFalse();
      expect(snap.alt).assertTrue();
    });

    it('reset全部复位', 0, () => {
      const s = new StickyModifiers();
      s.lockCtrl();
      s.tapAlt();
      s.reset();
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
      expect(s.altState).assertEqual(StickyState.IDLE);
      expect(s.ctrlActive()).assertFalse();
      expect(s.altActive()).assertFalse();
    });

    it('连续两次按键周期pressed各消费一次', 0, () => {
      const s = new StickyModifiers();
      s.tapCtrl();
      expect(s.snapshot().ctrl).assertTrue();
      s.consume(); // 第一键（如 Ctrl+C）
      expect(s.ctrlActive()).assertFalse();
      s.tapCtrl();
      expect(s.snapshot().ctrl).assertTrue();
      s.consume(); // 第二键
      expect(s.ctrlState).assertEqual(StickyState.IDLE);
    });
  });
}
