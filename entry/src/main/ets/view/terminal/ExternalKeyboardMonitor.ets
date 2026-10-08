/**
 * ExternalKeyboardMonitor —— 外接键盘插拔检测（T10 设备侧接线）。
 *
 * inputDevice.on('change') 监听设备增删 → 重新枚举 getDeviceList + getKeyboardType，
 * 与上一次的「物理字母键盘设备集合」比较（纯策略见 PhysicalKeyboard.diffPhysicalKeyboards）：
 *   - 有物理键盘被拔掉 → 广播 'removed'：画布清除「外接键盘活跃」，点按重新弹软键盘；
 *   - 新插入物理键盘 → 广播 'added'：直接进入外接键盘模式，不必等第一次按键。
 * 启动时的基线枚举**不**广播：个别机型会把机身按键报告成字母键盘，若据此置位，
 * 手机上点按终端将永远不弹软键盘——基线只用于后续比较。
 * 单例，首个订阅者到来时 on、最后一个离开时 off；任何系统调用失败只记日志。
 */
import { inputDevice } from '@kit.InputKit';
import { Logger } from '../../common/utils/Logger';
import { KeyboardChange, diffPhysicalKeyboards, isPhysicalKeyboardTypeName, keyboardTypeToString } from './PhysicalKeyboard';

const LOG_TAG: string = 'ExtKeyboard';

export type ExternalKeyboardListener = (change: KeyboardChange) => void;

export class ExternalKeyboardMonitor {
  private static instance: ExternalKeyboardMonitor | null = null;
  private readonly listeners: ExternalKeyboardListener[] = [];
  private registered: boolean = false;
  /** 上次枚举到的物理字母键盘 deviceId；null = 尚无基线 */
  private baseline: number[] | null = null;
  private readonly onChange = (_data: inputDevice.DeviceListener): void => {
    this.refresh();
  };

  static get(): ExternalKeyboardMonitor {
    if (ExternalKeyboardMonitor.instance === null) {
      ExternalKeyboardMonitor.instance = new ExternalKeyboardMonitor();
    }
    return ExternalKeyboardMonitor.instance;
  }

  subscribe(cb: ExternalKeyboardListener): () => void {
    this.listeners.push(cb);
    if (!this.registered) {
      this.registered = true;
      try {
        inputDevice.on('change', this.onChange);
      } catch (err) {
        Logger.warn(`订阅输入设备变化失败：${JSON.stringify(err)}`, LOG_TAG);
      }
      this.refresh();
    }
    return (): void => {
      const i: number = this.listeners.indexOf(cb);
      if (i >= 0) {
        this.listeners.splice(i, 1);
      }
      if (this.listeners.length === 0 && this.registered) {
        this.registered = false;
        try {
          inputDevice.off('change', this.onChange);
        } catch (err) {
          Logger.warn(`取消订阅输入设备变化失败：${JSON.stringify(err)}`, LOG_TAG);
        }
      }
    };
  }

  /** 重新枚举设备并广播（插拔回调与首次订阅时调用） */
  refresh(): void {
    this.enumerate().then((ids: number[] | null) => {
      if (ids === null) {
        return;
      }
      const previous: number[] | null = this.baseline;
      this.baseline = ids;
      if (previous === null) {
        return; // 基线不广播（见头注）
      }
      const change: KeyboardChange = diffPhysicalKeyboards(previous, ids);
      if (change === 'none') {
        return;
      }
      const snapshot: ExternalKeyboardListener[] = this.listeners.slice();
      for (const cb of snapshot) {
        cb(change);
      }
    });
  }

  private async enumerate(): Promise<number[] | null> {
    try {
      const ids: number[] = await inputDevice.getDeviceList();
      const physical: number[] = [];
      for (const id of ids) {
        try {
          const type: inputDevice.KeyboardType = await inputDevice.getKeyboardType(id);
          if (isPhysicalKeyboardTypeName(keyboardTypeToString(type as number))) {
            physical.push(id);
          }
        } catch (_err) {
          // 单个设备查询失败（已拔出的竞态）：跳过
        }
      }
      return physical;
    } catch (err) {
      Logger.warn(`枚举输入设备失败：${JSON.stringify(err)}`, LOG_TAG);
      return null;
    }
  }
}
