/**
 * TerminalBell —— 响铃（BEL）节流（纯逻辑）。
 *
 * 远端可能一次刷出成百上千个 BEL（cat 二进制、tab 补全失败连按）：每个都震动会
 * 让手机连续嗡嗡响。策略：同一会话两次反馈至少间隔 minIntervalMs，且滑动窗口
 * windowMs 内最多 maxPerWindow 次；被节流的 BEL 只计数不反馈。
 * 视觉响铃（窗格闪一下）与震动共用同一个判定。
 */

export const BELL_MIN_INTERVAL_MS: number = 250;
export const BELL_WINDOW_MS: number = 3000;
export const BELL_MAX_PER_WINDOW: number = 4;

export class BellLimiter {
  private readonly minIntervalMs: number;
  private readonly windowMs: number;
  private readonly maxPerWindow: number;
  private readonly recent: number[] = [];
  private suppressedCount: number = 0;

  constructor(minIntervalMs: number = BELL_MIN_INTERVAL_MS, windowMs: number = BELL_WINDOW_MS,
    maxPerWindow: number = BELL_MAX_PER_WINDOW) {
    this.minIntervalMs = minIntervalMs;
    this.windowMs = windowMs;
    this.maxPerWindow = maxPerWindow;
  }

  /** 一次 BEL 到达：true = 本次应反馈（震动/闪烁） */
  shouldRing(now: number): boolean {
    while (this.recent.length > 0 && now - this.recent[0] >= this.windowMs) {
      this.recent.shift();
    }
    const last: number = this.recent.length > 0 ? this.recent[this.recent.length - 1] : Number.NEGATIVE_INFINITY;
    if (now - last < this.minIntervalMs || this.recent.length >= this.maxPerWindow) {
      this.suppressedCount++;
      return false;
    }
    this.recent.push(now);
    return true;
  }

  get suppressed(): number {
    return this.suppressedCount;
  }

  reset(): void {
    this.recent.length = 0;
    this.suppressedCount = 0;
  }
}
