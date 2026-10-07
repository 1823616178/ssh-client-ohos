/**
 * PhysicalKeyboard 外接键盘策略测试（hypium，任务 T10）。
 *
 * 覆盖：KeyboardType 数字→名称、物理键盘类型判定、严格/宽松软键盘抑制策略、
 * 触摸路径是否仍拉起软键盘。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  isPhysicalKeyboardTypeName,
  keyboardTypeToString,
  shouldShowSoftKeyboardOnTouch,
  shouldSuppressSoftKeyboard,
  shouldSuppressSoftKeyboardOnKeyEvent
} from '../main/ets/view/terminal/PhysicalKeyboard';

export default function physicalKeyboardTest() {
  describe('PhysicalKeyboardTest', () => {

    it('keyboardTypeToString_数字映射与未知回退', 0, () => {
      expect(keyboardTypeToString(0)).assertEqual('none');
      expect(keyboardTypeToString(1)).assertEqual('unknown');
      expect(keyboardTypeToString(2)).assertEqual('alphabetic_keypad');
      expect(keyboardTypeToString(4)).assertEqual('extension');
      expect(keyboardTypeToString(6)).assertEqual('full');
      expect(keyboardTypeToString(8)).assertEqual('remote');
      expect(keyboardTypeToString(99)).assertEqual('unknown');
    });

    it('isPhysicalKeyboardTypeName_外接类型', 0, () => {
      expect(isPhysicalKeyboardTypeName('full')).assertTrue();
      expect(isPhysicalKeyboardTypeName('FULL')).assertTrue();
      expect(isPhysicalKeyboardTypeName('extension')).assertTrue();
      expect(isPhysicalKeyboardTypeName('alphabetic_keypad')).assertTrue();
      expect(isPhysicalKeyboardTypeName('compact')).assertTrue();
      expect(isPhysicalKeyboardTypeName('remote')).assertTrue();
      expect(isPhysicalKeyboardTypeName('hardware')).assertTrue();
      expect(isPhysicalKeyboardTypeName('none')).assertFalse();
      expect(isPhysicalKeyboardTypeName('unknown')).assertFalse();
      expect(isPhysicalKeyboardTypeName('mini')).assertFalse();
      expect(isPhysicalKeyboardTypeName('')).assertFalse();
    });

    it('严格策略_物理键事件加物理类型才抑制', 0, () => {
      expect(shouldSuppressSoftKeyboard('full', true)).assertTrue();
      expect(shouldSuppressSoftKeyboard('extension', true, false)).assertTrue();
      expect(shouldSuppressSoftKeyboard('full', true, true)).assertFalse(); // 修饰键自身不抑制
      expect(shouldSuppressSoftKeyboard('full', false)).assertFalse(); // 无物理键事件
      expect(shouldSuppressSoftKeyboard('none', true)).assertFalse();
      expect(shouldSuppressSoftKeyboard('unknown', true)).assertFalse();
    });

    it('宽松策略_物理键到达即抑制_修饰键除外', 0, () => {
      expect(shouldSuppressSoftKeyboardOnKeyEvent(true, false)).assertTrue();
      expect(shouldSuppressSoftKeyboardOnKeyEvent(true, true)).assertFalse();
      expect(shouldSuppressSoftKeyboardOnKeyEvent(false, false)).assertFalse();
    });

    it('触摸路径_外接键盘活跃时不拉软键盘', 0, () => {
      expect(shouldShowSoftKeyboardOnTouch(false)).assertTrue();
      expect(shouldShowSoftKeyboardOnTouch(true)).assertFalse();
    });
  });
}
