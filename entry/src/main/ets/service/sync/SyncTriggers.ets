/**
 * 同步触发器（任务 S6）：登录 / 前台 / 保存防抖 / 手动 / 网络恢复 / 轮询。
 * 定时器可注入，单测用手动时钟。
 */

import { SAVE_DEBOUNCE_MS } from '../../common/sync/SyncProtocol';
import { SyncCoordinator } from './SyncCoordinator';

export type ScheduleFn = (ms: number, fn: () => void) => number;
export type CancelFn = (id: number) => void;

export function systemSchedule(ms: number, fn: () => void): number {
  return setTimeout(fn, ms);
}

export function systemCancel(id: number): void {
  clearTimeout(id);
}

export class SyncTriggers {
  readonly coord: SyncCoordinator;
  private readonly schedule: ScheduleFn;
  private readonly cancel: CancelFn;
  private readonly debounceMs: number;
  private debounceToken: number = 0;
  private pollToken: number = 0;
  private pollMs: number = 0;

  constructor(coord: SyncCoordinator, schedule?: ScheduleFn, cancel?: CancelFn,
    debounceMs?: number) {
    this.coord = coord;
    this.schedule = schedule ?? systemSchedule;
    this.cancel = cancel ?? systemCancel;
    this.debounceMs = debounceMs ?? SAVE_DEBOUNCE_MS;
  }

  /** 保存后：标脏并防抖上传 */
  notifySaved(): void {
    void this.coord.markDirty();
    this.armDebounce();
  }

  /** 登录成功后立即同步 */
  notifyLogin(): void {
    this.clearDebounce();
    void this.runIfAllowed();
  }

  /** 切前台：有离线脏数据或已登录则拉一次 */
  notifyForeground(): void {
    void this.runIfAllowed();
  }

  /** 网络恢复：离线相位自动补传 */
  notifyNetworkAvailable(): void {
    if (this.coord.phase === 'offline' || this.coord.pendingLocal !== null) {
      void this.runIfAllowed();
    }
  }

  notifyNetworkLost(): void {
    if (this.coord.phase === 'syncing' || this.coord.phase === 'idle' ||
      this.coord.phase === 'synced') {
      this.coord.markOffline();
    }
  }

  /** intervalMs <= 0 表示关闭轮询 */
  startPolling(intervalMs: number): void {
    this.stopPolling();
    this.pollMs = intervalMs;
    if (intervalMs <= 0) {
      return;
    }
    this.armPoll();
  }

  stopPolling(): void {
    if (this.pollToken !== 0) {
      this.cancel(this.pollToken);
      this.pollToken = 0;
    }
  }

  stop(): void {
    this.clearDebounce();
    this.stopPolling();
  }

  private armDebounce(): void {
    this.clearDebounce();
    this.debounceToken = this.schedule(this.debounceMs, (): void => {
      this.debounceToken = 0;
      void this.runIfAllowed();
    });
  }

  private clearDebounce(): void {
    if (this.debounceToken !== 0) {
      this.cancel(this.debounceToken);
      this.debounceToken = 0;
    }
  }

  private armPoll(): void {
    if (this.pollMs <= 0) {
      return;
    }
    this.pollToken = this.schedule(this.pollMs, (): void => {
      this.pollToken = 0;
      void this.runIfAllowed();
      this.armPoll();
    });
  }

  private async runIfAllowed(): Promise<void> {
    if (this.coord.phase === 'signed_out' || this.coord.phase === 'syncing' ||
      this.coord.phase === 'conflict' || this.coord.phase === 'locked') {
      return;
    }
    await this.coord.syncNow();
  }
}
