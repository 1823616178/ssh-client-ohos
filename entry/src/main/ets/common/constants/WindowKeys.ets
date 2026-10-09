/**
 * 多窗口约定常量与纯函数（多窗口改造：EntryAbility 主窗口 + TerminalWindowAbility 终端窗口）。
 *
 * windowKey 是「一个 UIAbility 实例 = 一个系统窗口」的进程内标识：
 *   - 主窗口（EntryAbility，单实例）固定 MAIN_WINDOW_KEY；
 *   - 终端窗口（TerminalWindowAbility，launchType=specified）用 specified key 本身
 *     （`session:<sessionId>` / `new:<uuid>`），由发起方算好经 want 参数带入，
 *     AbilityStage.onAcceptWant 与 Ability.onCreate 读到的是同一个串。
 *
 * 进程内全局单例（SessionManager / FocusManager 注册表 / TerminalActionHub）都按 paneId
 * 记账：主窗口沿用原有 id（零行为变化），其它窗口加 `${windowKey}:` 前缀避免撞车。
 *
 * 本文件零系统依赖（可在 Node 单测里直接加载）。
 */

/** 主窗口（EntryAbility）的 windowKey */
export const MAIN_WINDOW_KEY: string = 'main';

/** 主窗口 Ability 名（module.json5 mainElement） */
export const MAIN_ABILITY_NAME: string = 'EntryAbility';

/** 终端窗口 Ability 名（module.json5 abilities[].name） */
export const TERMINAL_WINDOW_ABILITY_NAME: string = 'TerminalWindowAbility';

/** specified key 前缀：按会话复用窗口 / 每次新开 */
export const SPECIFIED_KEY_SESSION_PREFIX: string = 'session:';
export const SPECIFIED_KEY_NEW_PREFIX: string = 'new:';

/** 窗口级 LocalStorage 键（Ability 创建、loadContent 传入，页面经 getSharedLocalStorage 读） */
export const STORAGE_KEY_WINDOW: string = 'windowKey';
export const STORAGE_KEY_HOST_ID: string = 'launchHostId';
/** 逗号分隔的 sessionId 列表（首个为主会话，其余各开一个标签） */
export const STORAGE_KEY_SESSION_IDS: string = 'launchSessionIds';
/** 启动参数是否已被终端页消费（同一窗口里再 push 的终端页不重复采用） */
export const STORAGE_KEY_LAUNCH_CONSUMED: string = 'launchConsumed';

/** want.parameters 键 */
export const WANT_PARAM_WINDOW_KEY: string = 'windowKey';
export const WANT_PARAM_HOST_ID: string = 'hostId';
export const WANT_PARAM_SESSION_ID: string = 'sessionId';
export const WANT_PARAM_SESSION_IDS: string = 'sessionIds';

/** 窗格 id 前缀：主窗口为空串（沿用原 id），其它窗口 `${windowKey}:` */
export function paneIdPrefixOf(windowKey: string): string {
  if (windowKey.length === 0 || windowKey === MAIN_WINDOW_KEY) {
    return '';
  }
  return `${windowKey}:`;
}

/**
 * 由窗格 id 反推所在窗口（paneIdPrefixOf 的逆）：主窗口 id 不含冒号；其它窗口
 * id = `${windowKey}:${内层 id}`，内层 id（pane-N / terminal-main 等）不含冒号。
 */
export function windowKeyOfPaneId(paneId: string): string {
  const index: number = paneId.lastIndexOf(':');
  return index <= 0 ? MAIN_WINDOW_KEY : paneId.substring(0, index);
}

/** 终端窗口启动参数（want.parameters 解析结果） */
export interface TerminalWindowLaunch {
  /** 发起方指定的 windowKey（= specified key）；'' = 未指定 */
  readonly windowKey: string;
  readonly hostId: string;
  /** 首个为主会话；可为空（按 hostId 新拨） */
  readonly sessionIds: string[];
}

function paramAsString(value: Object | undefined | null): string {
  if (value === undefined || value === null) {
    return '';
  }
  return typeof value === 'string' ? value : '';
}

/** 逗号分隔串 → 去空去重的 id 列表（保持顺序） */
export function splitSessionIds(raw: string): string[] {
  const result: string[] = [];
  for (const part of raw.split(',')) {
    const id: string = part.trim();
    if (id.length > 0 && result.indexOf(id) < 0) {
      result.push(id);
    }
  }
  return result;
}

/** 解析 want.parameters（缺省 / 非字符串一律收敛为空，绝不抛） */
export function parseTerminalWindowParams(params: Record<string, Object> | undefined | null): TerminalWindowLaunch {
  if (params === undefined || params === null) {
    return { windowKey: '', hostId: '', sessionIds: [] };
  }
  const ids: string[] = splitSessionIds(paramAsString(params[WANT_PARAM_SESSION_IDS]));
  const single: string = paramAsString(params[WANT_PARAM_SESSION_ID]);
  if (single.length > 0 && ids.indexOf(single) < 0) {
    ids.unshift(single);
  }
  return {
    windowKey: paramAsString(params[WANT_PARAM_WINDOW_KEY]),
    hostId: paramAsString(params[WANT_PARAM_HOST_ID]),
    sessionIds: ids
  };
}

/**
 * 发起方计算 specified key：reuseWindow 且只带一个会话 → `session:<id>`（同一会话再次
 * 请求时系统把已有窗口拉到前台并回调 onNewWant）；其余一律 `new:<id>` 新开窗口。
 * 「标签移到新窗口」必须传 reuseWindow=false：源窗口自己可能就是 `session:<同一 id>`。
 */
export function specifiedKeyFor(sessionIds: string[], reuseWindow: boolean, newId: () => string): string {
  if (reuseWindow && sessionIds.length === 1) {
    return `${SPECIFIED_KEY_SESSION_PREFIX}${sessionIds[0]}`;
  }
  return `${SPECIFIED_KEY_NEW_PREFIX}${newId()}`;
}

/** AbilityStage.onAcceptWant：优先采用发起方带入的 windowKey，缺省按会话或新开 */
export function acceptWantKey(params: Record<string, Object> | undefined | null, newId: () => string): string {
  const launch: TerminalWindowLaunch = parseTerminalWindowParams(params);
  if (launch.windowKey.length > 0) {
    return launch.windowKey;
  }
  return specifiedKeyFor(launch.sessionIds, launch.sessionIds.length === 1, newId);
}

/** 构造终端窗口 want.parameters（与 parseTerminalWindowParams 互逆） */
export function buildTerminalWindowParams(windowKey: string, hostId: string,
  sessionIds: string[]): Record<string, Object> {
  const params: Record<string, Object> = {};
  params[WANT_PARAM_WINDOW_KEY] = windowKey;
  if (hostId.length > 0) {
    params[WANT_PARAM_HOST_ID] = hostId;
  }
  if (sessionIds.length > 0) {
    params[WANT_PARAM_SESSION_ID] = sessionIds[0];
    params[WANT_PARAM_SESSION_IDS] = sessionIds.join(',');
  }
  return params;
}
