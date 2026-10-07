/**
 * SFTP 传输队列纯逻辑 —— 任务 U8（DESIGN §7.4）。
 *
 * 与 native 侧 cpp/ssh/sftp.h 的 TransferState 状态机对齐（改一侧必须同步另一侧）。
 * 零系统 API、零 NAPI：宿主 hypium 可全量覆盖；SftpViewModel 注入
 * SftpGateway 后驱动真实传输。
 */

export type TransferDirection = 'download' | 'upload';

export type TransferStateName =
  'queued' | 'running' | 'paused' | 'completed' | 'failed' | 'cancelled';

/** 传输任务（UI 订阅 fields；id 单调递增不复用） */
export interface TransferJob {
  id: number;
  direction: TransferDirection;
  remotePath: string;
  localPath: string;
  totalBytes: number;
  transferredBytes: number;
  state: TransferStateName;
  /** SftpError 调试名（none = 无错误） */
  errorCode: string;
  errorMessage: string;
}

export function canStartTransfer(state: TransferStateName): boolean {
  return state === 'queued';
}

export function canCancelTransfer(state: TransferStateName): boolean {
  return state === 'queued' || state === 'running' || state === 'paused';
}

export function canRetryTransfer(state: TransferStateName): boolean {
  return state === 'failed' || state === 'cancelled';
}

export function canPauseTransfer(state: TransferStateName): boolean {
  return state === 'running';
}

/** 进度推进：仅 running 允许；完成由 completeTransfer 显式宣告 */
export function progressTransferState(state: TransferStateName): TransferStateName {
  if (state !== 'running') {
    return state;
  }
  return 'running';
}

export function completeTransferState(
  state: TransferStateName,
  success: boolean
): TransferStateName {
  if (state !== 'running' && state !== 'paused') {
    return state;
  }
  return success ? 'completed' : 'failed';
}

export function cancelTransferState(state: TransferStateName): TransferStateName {
  if (!canCancelTransfer(state)) {
    return state;
  }
  return 'cancelled';
}

export function retryTransferState(state: TransferStateName): TransferStateName {
  if (!canRetryTransfer(state)) {
    return state;
  }
  return 'queued';
}

/** 进度百分比 0–100；totalBytes<=0 时返回 0 */
export function transferProgressPercent(job: TransferJob): number {
  if (job.totalBytes <= 0) {
    return job.state === 'completed' ? 100 : 0;
  }
  const ratio: number = job.transferredBytes / job.totalBytes;
  if (ratio <= 0) {
    return 0;
  }
  if (ratio >= 1) {
    return 100;
  }
  return Math.floor(ratio * 100);
}

/**
 * 纯队列：入队/启动/进度/终态/取消/重试。
 * 不并发启动多个（MVP：同一时刻一个 running，其余排队）；napi 就绪后
 * 可扩展并行度。
 */
export class TransferQueue {
  private jobs: TransferJob[] = [];
  private nextId: number = 1;

  enqueue(
    direction: TransferDirection,
    remotePath: string,
    localPath: string,
    totalBytes: number
  ): TransferJob {
    const job: TransferJob = {
      id: this.nextId++,
      direction: direction,
      remotePath: remotePath,
      localPath: localPath,
      totalBytes: totalBytes < 0 ? 0 : totalBytes,
      transferredBytes: 0,
      state: 'queued',
      errorCode: 'none',
      errorMessage: ''
    };
    this.jobs.push(job);
    return job;
  }

  list(): TransferJob[] {
    return this.jobs.slice();
  }

  get(id: number): TransferJob | null {
    for (const job of this.jobs) {
      if (job.id === id) {
        return job;
      }
    }
    return null;
  }

  /** 队列中下一个可启动任务（queued 且无 running 在途） */
  nextStartable(): TransferJob | null {
    if (this.hasRunning()) {
      return null;
    }
    for (const job of this.jobs) {
      if (job.state === 'queued') {
        return job;
      }
    }
    return null;
  }

  hasRunning(): boolean {
    for (const job of this.jobs) {
      if (job.state === 'running') {
        return true;
      }
    }
    return false;
  }

  /** 标记 running；false = 状态不允许或已有 running */
  markRunning(id: number): boolean {
    if (this.hasRunning()) {
      return false;
    }
    const job: TransferJob | null = this.get(id);
    if (job === null || !canStartTransfer(job.state)) {
      return false;
    }
    job.state = 'running';
    return true;
  }

  /** 更新进度（钳制到 total）；仅 running 生效 */
  updateProgress(id: number, transferred: number, total: number): boolean {
    const job: TransferJob | null = this.get(id);
    if (job === null || job.state !== 'running') {
      return false;
    }
    if (total > 0) {
      job.totalBytes = total;
    }
    let value: number = transferred < 0 ? 0 : transferred;
    if (job.totalBytes > 0 && value > job.totalBytes) {
      value = job.totalBytes;
    }
    job.transferredBytes = value;
    job.state = progressTransferState(job.state);
    return true;
  }

  markCompleted(id: number): boolean {
    const job: TransferJob | null = this.get(id);
    if (job === null) {
      return false;
    }
    const next: TransferStateName = completeTransferState(job.state, true);
    if (next === job.state && job.state !== 'completed') {
      return false;
    }
    job.state = next;
    if (job.totalBytes > 0) {
      job.transferredBytes = job.totalBytes;
    }
    job.errorCode = 'none';
    job.errorMessage = '';
    return true;
  }

  markFailed(id: number, errorCode: string, errorMessage: string): boolean {
    const job: TransferJob | null = this.get(id);
    if (job === null) {
      return false;
    }
    // 终态不重复改写；queued/running/paused 均可直接失败（native 未就绪时入队即 fail）
    if (job.state === 'completed' || job.state === 'failed' || job.state === 'cancelled') {
      return false;
    }
    job.state = 'failed';
    job.errorCode = errorCode.length > 0 ? errorCode : 'io_error';
    job.errorMessage = errorMessage;
    return true;
  }

  cancel(id: number): boolean {
    const job: TransferJob | null = this.get(id);
    if (job === null) {
      return false;
    }
    const next: TransferStateName = cancelTransferState(job.state);
    if (next === job.state) {
      return false;
    }
    job.state = next;
    return true;
  }

  /** 重试：failed/cancelled → queued，并清零进度与错误 */
  retry(id: number): boolean {
    const job: TransferJob | null = this.get(id);
    if (job === null) {
      return false;
    }
    const next: TransferStateName = retryTransferState(job.state);
    if (next === job.state) {
      return false;
    }
    job.state = next;
    job.transferredBytes = 0;
    job.errorCode = 'none';
    job.errorMessage = '';
    return true;
  }

  /** 移除终态任务（completed/failed/cancelled）；进行中返回 false */
  remove(id: number): boolean {
    const job: TransferJob | null = this.get(id);
    if (job === null) {
      return false;
    }
    if (job.state === 'queued' || job.state === 'running' || job.state === 'paused') {
      return false;
    }
    const idx: number = this.jobs.indexOf(job);
    if (idx >= 0) {
      this.jobs.splice(idx, 1);
    }
    return true;
  }
}
