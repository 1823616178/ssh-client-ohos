/**
 * ScrollPhysics —— 回滚视图的滚动物理与视口锚定（纯逻辑，Node/hypium 可测）。
 *
 *  - FlingAnimator：松手惯性。速度按指数衰减（τ≈325ms，iOS/Android 列表手感），
 *    每帧 step(now) 产出本帧位移（vp，可正可负），速度低于阈值即停；
 *  - anchorScrollOffset：回滚中远端继续输出时保持视口内容不动（offset 跟着
 *    scrollbackTotal 的增量一起增加）；回滚缓冲被清空/重排（epoch 变化）时回到底部；
 *  - shouldShowNewOutputBadge：回滚中有新输出 → 「新输出」角标。
 */

/** 指数衰减时间常数（ms） */
export const FLING_TIME_CONSTANT_MS: number = 325;
/** 起飞最低速度（vp/s）：慢速松手不产生惯性，避免误滑 */
export const FLING_MIN_START_VELOCITY: number = 300;
/** 停止速度（vp/s） */
export const FLING_STOP_VELOCITY: number = 20;
/** 速度上限（vp/s）：防止系统偶发超大速度值把视图一下甩到顶 */
export const FLING_MAX_VELOCITY: number = 8000;

export class FlingAnimator {
  private velocity: number = 0;
  private lastTime: number = 0;
  private active: boolean = false;

  /** 起飞：velocity 为 vp/s（正 = 手指向下，看更旧内容）。返回是否真的起飞。 */
  start(velocity: number, now: number): boolean {
    if (!Number.isFinite(velocity) || Math.abs(velocity) < FLING_MIN_START_VELOCITY) {
      this.stop();
      return false;
    }
    this.velocity = Math.max(-FLING_MAX_VELOCITY, Math.min(FLING_MAX_VELOCITY, velocity));
    this.lastTime = now;
    this.active = true;
    return true;
  }

  stop(): void {
    this.active = false;
    this.velocity = 0;
  }

  get running(): boolean {
    return this.active;
  }

  /** 推进到 now：返回本段位移（vp）。速度衰减到阈值以下自动停止。 */
  step(now: number): number {
    if (!this.active) {
      return 0;
    }
    const dt: number = Math.max(0, Math.min(now - this.lastTime, 100));
    this.lastTime = now;
    if (dt === 0) {
      return 0;
    }
    // v(t) = v0·e^(-t/τ)；区间位移 = v0·τ·(1 − e^(−dt/τ))
    const decay: number = Math.exp(-dt / FLING_TIME_CONSTANT_MS);
    const distance: number = this.velocity * (FLING_TIME_CONSTANT_MS / 1000) * (1 - decay);
    this.velocity *= decay;
    if (Math.abs(this.velocity) < FLING_STOP_VELOCITY) {
      this.stop();
    }
    return distance;
  }
}

/** 视口锚定输入（上一帧与本帧的回滚元信息） */
export interface ScrollAnchorInput {
  offset: number;
  prevTotal: number;
  total: number;
  prevEpoch: number;
  epoch: number;
  /** 本帧可回滚的行数（total − oldest） */
  maxOffset: number;
}

/**
 * 回滚中保持视口内容不动：新行进入回滚区（total 增加 d）时 offset 同步 +d，
 * 否则用户正在看的历史会被一行行「推走」。offset=0（贴底）保持贴底；
 * epoch 变化（clear / reflow 重排）时旧的绝对行号失效，回到底部。
 */
export function anchorScrollOffset(input: ScrollAnchorInput): number {
  if (input.offset <= 0) {
    return 0;
  }
  if (input.epoch !== input.prevEpoch) {
    return 0;
  }
  const grown: number = Math.max(0, input.total - input.prevTotal);
  return Math.max(0, Math.min(input.offset + grown, input.maxOffset));
}

/** 回滚中且内容 revision 前进 → 显示「新输出」角标 */
export function shouldShowNewOutputBadge(offset: number, prevRevision: number, revision: number): boolean {
  return offset > 0 && prevRevision >= 0 && revision !== prevRevision;
}

/**
 * 选择拖动贴边自动滚动：手指在视口上/下边缘 edgeVp 内时每帧滚动的行数
 * （越靠边越快，最多 maxLines）。负 = 向上（看更旧），正 = 向下；0 = 不滚。
 */
export function edgeAutoScrollLines(y: number, viewTop: number, viewBottom: number,
  edgeVp: number, maxLines: number): number {
  if (!(edgeVp > 0) || viewBottom <= viewTop) {
    return 0;
  }
  if (y < viewTop + edgeVp) {
    const depth: number = Math.min(1, (viewTop + edgeVp - y) / edgeVp);
    return -Math.max(1, Math.round(depth * maxLines));
  }
  if (y > viewBottom - edgeVp) {
    const depth: number = Math.min(1, (y - (viewBottom - edgeVp)) / edgeVp);
    return Math.max(1, Math.round(depth * maxLines));
  }
  return 0;
}
