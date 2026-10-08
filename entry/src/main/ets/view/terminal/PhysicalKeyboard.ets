/**
 * PhysicalKeyboard —— T10 外接键盘检测与软键盘抑制策略（纯逻辑，hypium 覆盖）。
 *
 * 设计（DESIGN §4.3.2 / D15）：2in1 接外接键盘时，`onKeyEvent` 物理键通路已能
 * 送达远端；同一时刻**软键盘不得弹出**，否则遮挡终端且与物理键双路输入。
 *
 * 本文件只交付可单测的策略判定，零 ArkUI / 零 multimodalInput 运行时依赖。
 * 设备侧 API 接线点在 TerminalCanvas.handleKeyInput / onPaneClick（头注有登记）：
 *
 *   import { keyboard } from '@kit.InputKit';            // 或 @ohos.multimodalInput.keyboard
 *   // KeyboardType（数字 → 名称用 keyboardTypeToString）：
 *   //   NONE=0 UNKNOWN=1 ALPHABETIC_KEYPAD=2 COMPACT=3 EXTENSION=4
 *   //   FEATURE=5 FULL=6 MINI=7 REMOTE=8（以 SDK 声明为准）
 *   const typeName = keyboardTypeToString(await keyboard.getKeyboardType());
 *   if (shouldSuppressSoftKeyboard(typeName, true)) {
 *     // 不调用 focusControl.requestFocus(imeSinkId)；
 *     // 已弹出时：ImeInputSink 内 TextInputController.close()（API 12+）
 *   }
 *
 * 策略语义（全部有测试锚定）：
 *   - 物理键事件到达 + 键盘类型为外接/物理 → 抑制软键盘（T10 验收）；
 *   - 仅修饰键自身（Ctrl/Alt/Shift/Meta 按下）不触发抑制——用户可能仍要
 *     触摸点击窗格用软键盘输入；
 *   - 无物理键事件 / 类型为 none/unknown → 不抑制（移动端原路径不变）。
 */

/**
 * inputDevice.KeyboardType 数字枚举 → 名称（以 SDK @ohos.multimodalInput.inputDevice 为准：
 * NONE=0 UNKNOWN=1 ALPHABETIC_KEYBOARD=2 DIGITAL_KEYBOARD=3 HANDWRITING_PEN=4
 * REMOTE_CONTROL=5；未知值回退 unknown）。
 * 旧实现按另一套假想枚举映射，4（手写笔）会被当成外接键盘而误抑制软键盘。
 */
export function keyboardTypeToString(ohosKeyboardType: number): string {
  switch (ohosKeyboardType) {
    case 0:
      return 'none';
    case 1:
      return 'unknown';
    case 2:
      return 'alphabetic_keyboard';
    case 3:
      return 'digital_keyboard';
    case 4:
      return 'handwriting_pen';
    case 5:
      return 'remote_control';
    default:
      return 'unknown';
  }
}

/**
 * 是否为「能替代软键盘打字的物理键盘」类型名（大小写不敏感）。
 * alphabetic_keyboard（SDK 名）；full / alphabetic_keypad / hardware 为历史别名。
 * 数字小键盘、手写笔、遥控器、none / unknown 不算。
 */
export function isPhysicalKeyboardTypeName(typeName: string): boolean {
  const n = typeName.toLowerCase();
  return n === 'alphabetic_keyboard' || n === 'full' || n === 'alphabetic_keypad' || n === 'hardware';
}

/** 设备列表的键盘类型名里是否存在物理字母键盘（外接键盘插拔后重新评估用） */
export function anyPhysicalKeyboard(typeNames: string[]): boolean {
  for (const name of typeNames) {
    if (isPhysicalKeyboardTypeName(name)) {
      return true;
    }
  }
  return false;
}

/** 物理键盘集合变化：added = 新插入（优先于同时发生的移除）/ removed = 有键盘被拔掉 */
export type KeyboardChange = 'added' | 'removed' | 'none';

/** 前后两次枚举的物理字母键盘 deviceId 集合 → 变化类型 */
export function diffPhysicalKeyboards(previous: number[], current: number[]): KeyboardChange {
  for (const id of current) {
    if (previous.indexOf(id) < 0) {
      return 'added';
    }
  }
  for (const id of previous) {
    if (current.indexOf(id) < 0) {
      return 'removed';
    }
  }
  return 'none';
}

/** 键盘变化 → 「外接键盘活跃」新值（added 置位、removed 清除、none 保持） */
export function nextExternalKeyboardActive(current: boolean, change: KeyboardChange): boolean {
  if (change === 'added') {
    return true;
  }
  if (change === 'removed') {
    return false;
  }
  return current;
}

/**
 * 核心策略：物理键盘事件到达时是否抑制软键盘。
 *
 * @param keyboardType keyboard.getKeyboardType() 的名称（或 keyboardTypeToString 结果）
 * @param physicalKeyEventArrived 本次是否来自物理键通路（onKeyEvent / onKeyPreIme）
 * @param isModifierOnly true = 仅修饰键自身（不抑制）
 */
export function shouldSuppressSoftKeyboard(keyboardType: string,
  physicalKeyEventArrived: boolean, isModifierOnly: boolean = false): boolean {
  if (!physicalKeyEventArrived || isModifierOnly) {
    return false;
  }
  return isPhysicalKeyboardTypeName(keyboardType);
}

/**
 * 宽松策略：尚拿不到 keyboard.getKeyboardType()（API/权限/时序）时的兜底——
 * 只要物理键事件已到达且不是修饰键，就抑制软键盘。
 * 与严格策略并存：TerminalCanvas 可先记「有物理键」，类型回读成功后再收紧。
 */
export function shouldSuppressSoftKeyboardOnKeyEvent(physicalKeyEventArrived: boolean,
  isModifierOnly: boolean): boolean {
  return physicalKeyEventArrived && !isModifierOnly;
}

/**
 * 触摸点击窗格时是否仍允许拉起软键盘。
 * 外接键盘活跃期间 false（T10：接键盘不弹软键盘）；用户后续通过
 * 功能键条/系统手势显式唤起 IME 时，调用方应先 clearExternalKeyboardActive()。
 */
export function shouldShowSoftKeyboardOnTouch(externalKeyboardActive: boolean): boolean {
  return !externalKeyboardActive;
}
