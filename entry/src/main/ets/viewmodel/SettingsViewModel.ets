/**
 * SettingsPage 的纯逻辑（任务 P1 收尾，DESIGN §7.5 / §8 `SettingsPage.ets`）。
 *
 * 页面本身只做「读设置 → 渲染 → 写设置 → 通知策略机」，可测的部分只有
 * 息屏断开分钟数与选项档位的互相换算，故单独放这里由 hypium 断言。
 */

/** 息屏断开档位 */
export interface ScreenOffOption {
  readonly label: string;
  /** 分钟数；0 = 关闭该策略 */
  readonly minutes: number;
}

/**
 * 可选档位（DESIGN §7.5「息屏 N 分钟后断开」，默认关）。
 * 只给常用档而不是自由输入：这个设置的目的是「别整夜挂着」，精确到分钟没有意义，
 * 档位化还能避免用户填 1 分钟把自己刚锁屏的会话断掉。
 */
export const SCREEN_OFF_OPTIONS: ScreenOffOption[] = [
  { label: '不断开', minutes: 0 },
  { label: '5 分钟', minutes: 5 },
  { label: '15 分钟', minutes: 15 },
  { label: '30 分钟', minutes: 30 },
  { label: '60 分钟', minutes: 60 }
];

/** 档位标签数组（分段控件用） */
export function screenOffLabels(): string[] {
  const labels: string[] = [];
  for (const option of SCREEN_OFF_OPTIONS) {
    labels.push(option.label);
  }
  return labels;
}

/**
 * 分钟数 → 档位下标。非法值（负数）与 0 一律归「不断开」；
 * 非档位值（例如老版本或人工写库留下的 7 分钟）取最接近的档位，不静默改写用户设置本身。
 */
export function screenOffOptionIndex(minutes: number): number {
  if (!Number.isFinite(minutes) || minutes <= 0) {
    return 0;
  }
  let bestIndex: number = 0;
  let bestDistance: number = Number.MAX_SAFE_INTEGER;
  for (let i: number = 0; i < SCREEN_OFF_OPTIONS.length; i++) {
    const distance: number = Math.abs(SCREEN_OFF_OPTIONS[i].minutes - minutes);
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

/** 档位下标 → 分钟数（越界按「不断开」处理） */
export function screenOffMinutesOf(index: number): number {
  if (index < 0 || index >= SCREEN_OFF_OPTIONS.length) {
    return 0;
  }
  return SCREEN_OFF_OPTIONS[index].minutes;
}

/** 当前设置的一句话说明（页面副标题，让用户知道关掉/打开各意味着什么） */
export function backgroundSummary(keepAlive: boolean, screenOffMinutes: number): string {
  const head: string = keepAlive
    ? '切到后台后继续保持连接'
    : '切到后台即优雅断开，回到应用自动重连';
  if (screenOffMinutes <= 0) {
    return head;
  }
  return `${head}；息屏满 ${screenOffMinutes} 分钟断开`;
}
