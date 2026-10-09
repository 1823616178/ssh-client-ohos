/**
 * WindowLifecycle —— UIAbility 生命周期到多窗口服务的统一转发（EntryAbility 与
 * TerminalWindowAbility 共用，避免两份 Ability 各写一遍、日后漏改一边）。
 *
 *   onCreate            → AppBootstrap.ensureStarted（进程级一次）+ WindowRegistry 登记
 *   onWindowStageCreate → 本窗口 ScreenAwake 起服务、缓存主窗口对象、订阅窗口获焦
 *   onForeground/Background → 应用级前后台计数（WindowRegistry）+ 本窗口屏幕常亮
 *   onWindowStageDestroy → 本窗口 ScreenAwake / 焦点表释放、摘窗口对象
 *   onDestroy           → 引用计数减一，归零才关闭全部会话（AppBootstrap）
 */

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { MAIN_WINDOW_KEY } from '../../common/constants/WindowKeys';
import { Logger } from '../../common/utils/Logger';
import { FocusManager } from '../../view/terminal/FocusManager';
import { AppBootstrap } from '../AppBootstrap';
import { ScreenAwake } from '../ScreenAwake';
import { WindowRegistry } from './WindowRegistry';

const LOG_TAG: string = 'WindowLifecycle';

/** 主窗口底色（启动页到首帧之间露出的颜色，与改造前 EntryAbility 一致） */
export const WINDOW_BACKGROUND_COLOR: string = '#03060A';

export class WindowLifecycle {
  /** 每个窗口的 windowStageEvent 回调（off 时按引用摘除） */
  private static readonly stageCallbacks: Map<string, (event: window.WindowStageEventType) => void> = new Map();

  static onAbilityCreate(windowKey: string, context: common.UIAbilityContext): void {
    AppBootstrap.ensureStarted(windowKey, context);
    WindowRegistry.get().register(windowKey, context);
  }

  static onAbilityDestroy(windowKey: string): void {
    FocusManager.releaseWindow(windowKey);
    AppBootstrap.onWindowDestroyed(windowKey);
  }

  static onWindowStageCreate(windowKey: string, windowStage: window.WindowStage): void {
    // 屏幕常亮：终端页在前台且有活跃会话时不让系统自动息屏（避免走上 §7.5 的后台降级链）
    ScreenAwake.forWindow(windowKey).start(windowStage);
    windowStage.getMainWindow().then((win: window.Window) => {
      WindowRegistry.get().setWindow(windowKey, win);
      try {
        win.setWindowBackgroundColor(WINDOW_BACKGROUND_COLOR);
      } catch (_e) {
      }
    }).catch((_err: Object) => {
    });
    const callback = (event: window.WindowStageEventType): void => {
      if (event === window.WindowStageEventType.ACTIVE) {
        WindowRegistry.get().notifyWindowActive(windowKey);
      }
    };
    try {
      windowStage.on('windowStageEvent', callback);
      WindowLifecycle.stageCallbacks.set(windowKey, callback);
    } catch (err) {
      Logger.warn(`订阅窗口获焦事件失败（${windowKey}）：${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  static onWindowStageDestroy(windowKey: string, windowStage: window.WindowStage | null): void {
    const callback: ((event: window.WindowStageEventType) => void) | undefined =
      WindowLifecycle.stageCallbacks.get(windowKey);
    if (callback !== undefined && windowStage !== null) {
      try {
        windowStage.off('windowStageEvent', callback);
      } catch (_e) {
      }
    }
    WindowLifecycle.stageCallbacks.delete(windowKey);
    WindowRegistry.get().setWindow(windowKey, null);
    // 主窗口沿用改造前语义：只 stop（保留实例供下次 onWindowStageCreate 复用）
    if (windowKey === MAIN_WINDOW_KEY) {
      ScreenAwake.forWindow(windowKey).stop();
    } else {
      ScreenAwake.releaseWindow(windowKey);
    }
  }

  static onForeground(windowKey: string): void {
    WindowRegistry.get().notifyWindowForeground(windowKey, true);
    ScreenAwake.forWindow(windowKey).setForeground(true);
  }

  static onBackground(windowKey: string): void {
    WindowRegistry.get().notifyWindowForeground(windowKey, false);
    ScreenAwake.forWindow(windowKey).setForeground(false);
  }
}
