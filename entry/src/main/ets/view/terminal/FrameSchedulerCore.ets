/**
 * 帧调度核心（任务 T4，纯 ArkTS 不依赖 ArkUI/displaySync，hypium 覆盖）。
 *
 * 架构约束（DESIGN §4.3.1 / 决策 D14）：全应用只有一条 displaySync 帧回调，
 * 每帧按注册序遍历所有「可见」实例各调一次回调；不可见标签页整帧跳过（零绘制）。
 * 本类只实现注册表/可见性/休眠决策，帧源（displaySync）经 FrameTicker 接口注入——
 * 测试用手动 ticker，真机用 view/FrameScheduler.ets 的 DisplaySyncTicker。
 *
 * 回调约定（FrameCallback）：返回 true = 本帧实际发生了绘制；
 * 实例内部应先比对 native revision，无变化直接返回 false（这是静止省电的第一层：
 * 帧循环常开但每帧只是一次标量比对，开销可忽略）。
 *
 * 静止省电的第二层——自动休眠（CPU≈0 的保证机制）：
 * 连续 idleFramesBeforeSleep 帧（默认 90，≈1s @60–120Hz 折中）所有可见实例都
 * 无绘制后 ticker.stop()，displaySync 完全摘出 vsync 管线。
 * ⚠️ 已知风险：T3 是拉模型，native → ArkTS 没有「网格变脏」推送事件，休眠期间
 * 到达的远端输出要等一次 wakeup() 才上屏。唤醒源：register / setVisible(true) /
 * wakeup()（TerminalCanvas 的 onAreaChange、外观变更、notifyContentDirty 都会调）。
 * U4 整合时须把会话事件流（channelData/terminalBell 等）接到对应画布的
 * notifyContentDirty()；若真机验证发现输出延迟不可接受，构造时传
 * autoSleep=false 退回第一层即可。
 *
 * 语义约定（全部有测试锚定）：
 *  - register：id 重复或空串抛 Error；注册即唤醒帧循环；
 *  - unregister：未知 id 返回 false；注销到最后一个实例后停帧循环；
 *  - setVisible：未知 id 静默忽略（组件 aboutToAppear 先注册再设可见性，
 *    顺序由组件保证；对未知 id 容错避免生命周期竞态崩 UI 主线程）；
 *  - 回调抛异常不中断帧循环：计入 callbackErrors，该实例按「有绘制」处理
 *    （保持帧循环活着让错误持续可见，而不是休眠掩盖）。
 */

/** 帧回调：true = 本帧实际绘制了内容 */
export type FrameCallback = () => boolean;

/** 帧源抽象：displaySync（真机）或手动驱动（测试） */
export interface FrameTicker {
  /** 绑定帧回调（构造期一次性调用） */
  setFrameCallback(cb: () => void): void;
  /** 开始接收帧回调（幂等） */
  start(): void;
  /** 停止接收帧回调（幂等） */
  stop(): void;
}

interface FrameEntry {
  callback: FrameCallback;
  visible: boolean;
}

/** 默认休眠阈值：连续约 1s（90 帧）无任何绘制后停帧循环 */
export const DEFAULT_IDLE_FRAMES_BEFORE_SLEEP = 90;

export class FrameSchedulerCore {
  private readonly ticker: FrameTicker;
  private readonly autoSleep: boolean;
  private readonly idleLimit: number;
  /** Map 保插入序 → 每帧按注册序派发（D14「按序遍历可见 Leaf」） */
  private readonly entries: Map<string, FrameEntry> = new Map();
  private running = false;
  private idleStreak = 0;
  private dispatching = false;
  /** 回调异常计数（诊断用；见文件头注语义约定） */
  callbackErrors = 0;

  constructor(ticker: FrameTicker, autoSleep: boolean = true,
    idleFramesBeforeSleep: number = DEFAULT_IDLE_FRAMES_BEFORE_SLEEP) {
    this.ticker = ticker;
    this.autoSleep = autoSleep;
    this.idleLimit = Math.max(1, Math.floor(idleFramesBeforeSleep));
    ticker.setFrameCallback(() => this.onFrame());
  }

  /** 注册帧回调（默认可见）；重复 id / 空 id 抛 Error */
  register(id: string, callback: FrameCallback): void {
    if (id.length === 0) {
      throw new Error('FrameSchedulerCore.register: id 不能为空');
    }
    if (this.entries.has(id)) {
      throw new Error(`FrameSchedulerCore.register: 重复注册 id=${id}`);
    }
    this.entries.set(id, { callback: callback, visible: true });
    this.wakeup();
  }

  /** 注销；false = 未知 id。最后一个实例注销后停帧循环 */
  unregister(id: string): boolean {
    const removed = this.entries.delete(id);
    if (removed && this.entries.size === 0) {
      this.stopTicker();
    }
    return removed;
  }

  /** 设置可见性（未知 id 静默忽略，语义见文件头注）；置可见会唤醒帧循环 */
  setVisible(id: string, visible: boolean): void {
    const entry = this.entries.get(id);
    if (entry === undefined) {
      return;
    }
    entry.visible = visible;
    if (visible) {
      this.wakeup();
    }
  }

  /** 唤醒帧循环（有注册实例且当前停止时才 start） */
  wakeup(): void {
    if (!this.running && this.entries.size > 0) {
      this.running = true;
      this.idleStreak = 0;
      this.ticker.start();
    }
  }

  has(id: string): boolean {
    return this.entries.has(id);
  }

  isVisible(id: string): boolean {
    return this.entries.get(id)?.visible === true;
  }

  /** 已注册实例数 */
  get size(): number {
    return this.entries.size;
  }

  /** 帧循环是否在跑（ticker 已 start） */
  get isRunning(): boolean {
    return this.running;
  }

  private onFrame(): void {
    if (this.dispatching) {
      return; // ticker 重入防御（回调里间接触发 start 的场景）
    }
    this.dispatching = true;
    let anyWork = false;
    try {
      this.entries.forEach((entry: FrameEntry) => {
        if (!entry.visible) {
          return;
        }
        let worked = true; // 异常按有绘制处理：保持帧循环活着（见文件头注）
        try {
          worked = entry.callback();
        } catch (e) {
          this.callbackErrors++;
        }
        anyWork = anyWork || worked;
      });
    } finally {
      this.dispatching = false;
    }
    if (anyWork) {
      this.idleStreak = 0;
      return;
    }
    this.idleStreak++;
    if (this.autoSleep && this.idleStreak >= this.idleLimit) {
      this.stopTicker();
    }
  }

  private stopTicker(): void {
    if (this.running) {
      this.ticker.stop();
      this.running = false;
    }
    this.idleStreak = 0;
  }
}
