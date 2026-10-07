/**
 * SettingsPage 的纯逻辑（任务 P1 收尾，DESIGN §7.5 / §8 `SettingsPage.ets`）。
 *
 * 页面本身只做「读设置 → 渲染 → 写设置 → 通知策略机」，可测的部分只有
 * 息屏断开分钟数与选项档位的互相换算，故单独放这里由 hypium 断言。
 */

import { KeepScreenOnMode } from '../repository/SettingsRepository';

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

// ---------------------------------------------------------------- 屏幕常亮

/** 屏幕常亮档位 */
export interface KeepScreenOnOption {
  readonly label: string;
  readonly mode: KeepScreenOnMode;
}

/**
 * 可选档位。默认落在 `session`：终端页开着又有会话在跑，说明用户正等着远端输出，
 * 此时息屏除了触发 §7.5 的后台降级链（进而断连接）没有别的作用。
 */
export const KEEP_SCREEN_ON_OPTIONS: KeepScreenOnOption[] = [
  { label: '不常亮', mode: 'never' },
  { label: '有会话时', mode: 'session' },
  { label: '始终', mode: 'always' }
];

/** 档位标签数组（分段控件用） */
export function keepScreenOnLabels(): string[] {
  const labels: string[] = [];
  for (const option of KEEP_SCREEN_ON_OPTIONS) {
    labels.push(option.label);
  }
  return labels;
}

/** 档位 → 下标（未知值按默认档 session） */
export function keepScreenOnOptionIndex(mode: KeepScreenOnMode): number {
  for (let i: number = 0; i < KEEP_SCREEN_ON_OPTIONS.length; i++) {
    if (KEEP_SCREEN_ON_OPTIONS[i].mode === mode) {
      return i;
    }
  }
  return 1;
}

/** 下标 → 档位（越界按默认档 session） */
export function keepScreenOnModeOf(index: number): KeepScreenOnMode {
  if (index < 0 || index >= KEEP_SCREEN_ON_OPTIONS.length) {
    return 'session';
  }
  return KEEP_SCREEN_ON_OPTIONS[index].mode;
}

/** 当前档位的一句话说明 */
export function keepScreenOnSummary(mode: KeepScreenOnMode): string {
  if (mode === 'always') {
    return '打开终端页就保持屏幕常亮';
  }
  if (mode === 'never') {
    return '不干预系统息屏（息屏后按上面的后台策略处理）';
  }
  return '终端页有活跃会话时保持屏幕常亮，避免自动息屏后被系统回收后台任务';
}
