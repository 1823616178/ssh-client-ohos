/**
 * 全应用单一 displaySync 帧调度器（任务 T4，DESIGN §4.3.1 / 决策 D14）。
 *
 * 为什么必须单例：一个窗格一条 displaySync 回调会互相错拍，4 个分屏就是
 * 4 条独立帧循环，在 120 Hz 设备上打满 CPU（风险 R-10）。这里持有全应用
 * 唯一的 DisplaySync 实例；注册表/可见性/自动休眠逻辑在
 * view/terminal/FrameSchedulerCore.ets（纯 ArkTS、可注入 ticker，hypium 覆盖），
 * 本文件只负责 displaySync 绑定与全局单例。
 */
import { displaySync } from '@kit.ArkGraphics2D';
import { FrameCallback, FrameSchedulerCore, FrameTicker } from './terminal/FrameSchedulerCore';

/** displaySync 帧源：start/stop 即把回调挂进/摘出 vsync 管线 */
class DisplaySyncTicker implements FrameTicker {
  private readonly sync: displaySync.DisplaySync = displaySync.create();

  constructor() {
    // 跟随屏幕刷新率：不显式设置时 DisplaySync 帧率上限默认 60，
    // 120 Hz 设备需要抬高 expected 才能跑满（低刷屏上系统自动钳到设备上限）
    this.sync.setExpectedFrameRateRange({ min: 30, max: 120, expected: 120 });
  }

  setFrameCallback(cb: () => void): void {
    this.sync.on('frame', () => {
      cb();
    });
  }

  start(): void {
    this.sync.start();
  }

  stop(): void {
    this.sync.stop();
  }
}

/**
 * 全局帧调度器单例。TerminalCanvas 在 aboutToAppear 注册、aboutToDisappear 注销；
 * 不可见标签页由持有者调 setVisible(id, false)，调度器整帧跳过（零绘制）。
 * 休眠语义与唤醒约定见 FrameSchedulerCore 头注。
 */
export class FrameScheduler {
  private static instance: FrameScheduler | null = null;
  private readonly core: FrameSchedulerCore;

  private constructor() {
    this.core = new FrameSchedulerCore(new DisplaySyncTicker());
  }

  static get(): FrameScheduler {
    if (FrameScheduler.instance === null) {
      FrameScheduler.instance = new FrameScheduler();
    }
    return FrameScheduler.instance;
  }

  register(id: string, callback: FrameCallback): void {
    this.core.register(id, callback);
  }

  unregister(id: string): boolean {
    return this.core.unregister(id);
  }

  setVisible(id: string, visible: boolean): void {
    this.core.setVisible(id, visible);
  }

  /** 有内容可能变化时唤醒（休眠期间远端输出的上屏入口，U4 接线用） */
  wakeup(): void {
    this.core.wakeup();
  }
}
