/**
 * MiniTerminalModel —— 首页「活动会话」列表 + 迷你终端窗口的纯逻辑（可单测）。
 *
 * 交互约定：
 *   - 左侧「活动会话」列出全部存活连接（连接中 / 运行中 / 断线重连中 / 异常），
 *     包括按返回键转入后台的、全页终端里各标签/分屏的会话；
 *   - 点按一行 = 把迷你终端窗口就地切到该会话（不跳页、不重连、回滚保留）；
 *   - 只有显式「⤢ 全页」才进入 TerminalPage；进入前迷你窗口先寄存终端并解绑，
 *     全页返回后迷你窗口按原会话重新取回；
 *   - md/lg：迷你窗口 = Index 中栏嵌入终端；sm：底部半屏面板（bindSheet）承载同一组件。
 *
 * 多窗口（平板 / 2in1 独立终端窗口，见 service/window/WindowRegistry）：
 *   - 会话所在窗口由窗格 id 前缀反推（windowKeyOfPaneId），迷你窗口所在窗口同理；
 *   - 正显示在其它窗口的会话：行标「独立窗口中」，点按行或 ⤢ 都是把那个窗口带到前台，
 *     迷你窗口绝不去抢它的窗格绑定（locateSession / decideSessionTap）；
 *   - 迷你窗口记住的会话被迁去独立窗口后，全页返回时不再等待，直接回到空态（'elsewhere'）。
 *
 * 本文件只放纯函数与无 UI 依赖的类；SessionManager 接线集中在 SessionActivityTracker.global()。
 */
import { windowKeyOfPaneId } from '../common/constants/WindowKeys';
import { SshEvent } from '../napi/SshNative';
import { SessionInfo, SessionManager } from '../service/SessionManager';
import {
  ActiveSessionLike,
  HostConnStatus,
  hostConnStatusLabel,
  sessionStateToStatus
} from './HostListViewModel';

/** 迷你终端窗口的窗格 id（与 TerminalCanvas.focusId 一致；不与全页首叶 terminal-main 冲突） */
export const MINI_TERMINAL_PANE_ID: string = 'index-side-terminal';

// ---------------------------------------------------------------- 迷你窗口目标

export type MiniTargetKind = 'none' | 'host' | 'session';

/** 迷你窗口要显示什么：按主机新拨一路 / 接管既有会话 */
export interface MiniTarget {
  readonly kind: MiniTargetKind;
  readonly id: string;
  /** 递增序号：同一目标再次请求（例如同主机再开一路）也能触发 @Watch */
  readonly seq: number;
}

export const MINI_TARGET_NONE: MiniTarget = { kind: 'none', id: '', seq: 0 };

/**
 * 编码为单个 @Prop 字符串：V1 多个 @Prop 同批更新时 @Watch 触发顺序不保证，
 * 合成一个字段可保证「种类 + id」原子到达。格式 `kind:id:seq`（id 可含冒号）。
 */
export function encodeMiniTarget(target: MiniTarget): string {
  if (target.kind === 'none' || target.id.length === 0) {
    return '';
  }
  return `${target.kind}:${target.id}:${target.seq}`;
}

export function parseMiniTarget(raw: string): MiniTarget {
  const first: number = raw.indexOf(':');
  const last: number = raw.lastIndexOf(':');
  if (first <= 0 || last <= first) {
    return MINI_TARGET_NONE;
  }
  const kindText: string = raw.substring(0, first);
  const id: string = raw.substring(first + 1, last);
  const seq: number = Number.parseInt(raw.substring(last + 1), 10);
  if (id.length === 0 || (kindText !== 'host' && kindText !== 'session')) {
    return MINI_TARGET_NONE;
  }
  const kind: MiniTargetKind = kindText === 'host' ? 'host' : 'session';
  return { kind: kind, id: id, seq: Number.isFinite(seq) ? seq : 0 };
}

/** 迷你窗口承载形态：md/lg 中栏常驻；sm 底部面板 */
export type MiniPresentation = 'sidebar' | 'sheet';

export function miniPresentationOf(useSidebar: boolean): MiniPresentation {
  return useSidebar ? 'sidebar' : 'sheet';
}

/**
 * 点按主机行（md/lg）：迷你窗口已在显示该主机的存活会话 → 保持（避免误触重复拨号）；
 * 否则新拨一路到迷你窗口（原会话寄存后台、出现在活动会话里）。
 */
export type HostTapAction = 'keep' | 'connect';

export function decideHostTap(miniHostId: string, miniSessionAlive: boolean, tappedHostId: string): HostTapAction {
  if (miniSessionAlive && miniHostId.length > 0 && miniHostId === tappedHostId) {
    return 'keep';
  }
  return 'connect';
}

/** 全页返回后迷你窗口取回原会话的决策输入 */
export interface MiniSessionProbe {
  readonly state: string;
  readonly paneId: string | null;
}

/**
 * - gone：会话已关闭/不存在 → 迷你窗口回到空态；
 * - already：已绑在迷你窗格（无需动作）；
 * - wait：仍被本窗口其他窗格持有（全页终端尚未完成 detach）→ 稍后重试；
 * - elsewhere：已被别的系统窗口接管（例如全页里「在新窗口打开」）→ 不等待、不抢，迷你窗口回到空态；
 * - adopt：未绑定 → 迷你窗口接管（取回寄存终端，画面/回滚保留）。
 */
export type MiniResumeAction = 'gone' | 'already' | 'wait' | 'elsewhere' | 'adopt';

export function decideMiniResume(probe: MiniSessionProbe | null, miniPaneId: string): MiniResumeAction {
  if (probe === null || probe.state === 'closed' || probe.state === 'closing') {
    return 'gone';
  }
  if (probe.paneId === miniPaneId) {
    return 'already';
  }
  if (probe.paneId !== null) {
    return windowKeyOfPaneId(probe.paneId) === windowKeyOfPaneId(miniPaneId) ? 'wait' : 'elsewhere';
  }
  return 'adopt';
}

// ---------------------------------------------------------------- 会话位置（多窗口）

/**
 * 会话当前显示在哪里（相对迷你窗口所在的系统窗口）：
 *   - background：没有窗格在显示（后台）；
 *   - mini：迷你窗口；
 *   - page：同一系统窗口里的其它窗格（全页终端）；
 *   - window：别的系统窗口（独立终端窗口 / 另一个主窗口实例），windowKey 指明是哪个。
 */
export type SessionPlace = 'background' | 'mini' | 'page' | 'window';

export interface SessionLocation {
  readonly place: SessionPlace;
  /** 会话所在窗口；background 时为迷你窗口所在窗口 */
  readonly windowKey: string;
}

export function locateSession(paneId: string | null, miniPaneId: string): SessionLocation {
  const here: string = windowKeyOfPaneId(miniPaneId);
  if (paneId === null || paneId.length === 0) {
    return { place: 'background', windowKey: here };
  }
  if (paneId === miniPaneId) {
    return { place: 'mini', windowKey: here };
  }
  const owner: string = windowKeyOfPaneId(paneId);
  return { place: owner === here ? 'page' : 'window', windowKey: owner };
}

/**
 * 活动会话行的点按 / ⤢：
 *   - focus-window：会话在别的系统窗口 → 把那个窗口带到前台（不抢绑定、不在本窗口再开）；
 *   - local：其余情况照常（点按 = 迷你窗口就地切换；⤢ = 本窗口全页）。
 */
export type SessionTapAction = 'local' | 'focus-window';

export function decideSessionTap(location: SessionLocation): SessionTapAction {
  return location.place === 'window' ? 'focus-window' : 'local';
}

/** 全页返回后取回会话的重试上限与间隔（全页 detach 通常在返回前同步完成，重试只是兜底） */
export const MINI_RESUME_RETRY_LIMIT: number = 10;
export const MINI_RESUME_RETRY_MS: number = 100;

// ---------------------------------------------------------------- 后台活动（新输出 / 响铃 / 标题）

export interface SessionActivityState {
  readonly unread: boolean;
  readonly bell: boolean;
  readonly title: string;
}

/** 行渲染所需的活动快照查询（生产 = SessionActivityTracker；单测可传任意实现） */
export interface SessionActivityLookup {
  stateOf(sessionId: string): SessionActivityState;
}

const EMPTY_ACTIVITY: SessionActivityState = { unread: false, bell: false, title: '' };

class MutableActivity {
  unread: boolean = false;
  bell: boolean = false;
  title: string = '';
}

/**
 * 会话后台活动记账：没有任何窗格在显示的会话收到输出 → 新输出圆点；响铃 → 🔔；
 * OSC 标题一律记下（列表副标题用）。只有状态翻转时才通知，避免每个数据块重建列表。
 */
export class SessionActivityTracker implements SessionActivityLookup {
  private static globalInstance: SessionActivityTracker | null = null;
  private readonly states: Map<string, MutableActivity> = new Map();
  private readonly listeners: Array<() => void> = [];
  private readonly isViewed: (sessionId: string) => boolean;

  constructor(isViewed: (sessionId: string) => boolean) {
    this.isViewed = isViewed;
  }

  /** 生产单例：「正在显示」= 会话绑在某个窗格上（迷你窗口或全页终端） */
  static global(): SessionActivityTracker {
    if (SessionActivityTracker.globalInstance === null) {
      const tracker: SessionActivityTracker = new SessionActivityTracker((sessionId: string): boolean => {
        return SessionManager.get().paneIdOfSession(sessionId) !== null;
      });
      SessionManager.get().addEventListener((session: SessionInfo, event: SshEvent): void => {
        tracker.onSessionEvent(session.sessionId, event.type, event.title ?? '', event.to ?? '');
      });
      SessionManager.get().addSessionCountListener((): void => {
        const ids: string[] = [];
        for (const info of SessionManager.get().listSessions()) {
          ids.push(info.sessionId);
        }
        tracker.prune(ids);
      });
      SessionActivityTracker.globalInstance = tracker;
    }
    return SessionActivityTracker.globalInstance;
  }

  /** 事件入口（与 SshEvent 解耦，便于单测） */
  onSessionEvent(sessionId: string, type: string, title: string, toState: string): void {
    switch (type) {
      case 'terminalData':
        this.onData(sessionId);
        break;
      case 'terminalBell':
        this.onBell(sessionId);
        break;
      case 'terminalTitle':
        this.onTitle(sessionId, title);
        break;
      case 'stateChange':
        if (toState === 'closed') {
          this.forget(sessionId);
        }
        break;
      default:
        break;
    }
  }

  onData(sessionId: string): void {
    if (this.isViewed(sessionId)) {
      return;
    }
    const state: MutableActivity = this.ensure(sessionId);
    if (!state.unread) {
      state.unread = true;
      this.notify();
    }
  }

  onBell(sessionId: string): void {
    if (this.isViewed(sessionId)) {
      return;
    }
    const state: MutableActivity = this.ensure(sessionId);
    if (!state.bell) {
      state.bell = true;
      this.notify();
    }
  }

  onTitle(sessionId: string, title: string): void {
    const state: MutableActivity = this.ensure(sessionId);
    if (state.title !== title) {
      state.title = title;
      this.notify();
    }
  }

  /** 用户看过（切到迷你窗口 / 打开全页）→ 清徽标，保留标题 */
  markSeen(sessionId: string): void {
    const state: MutableActivity | undefined = this.states.get(sessionId);
    if (state === undefined || (!state.unread && !state.bell)) {
      return;
    }
    state.unread = false;
    state.bell = false;
    this.notify();
  }

  stateOf(sessionId: string): SessionActivityState {
    const state: MutableActivity | undefined = this.states.get(sessionId);
    if (state === undefined) {
      return EMPTY_ACTIVITY;
    }
    return { unread: state.unread, bell: state.bell, title: state.title };
  }

  forget(sessionId: string): void {
    if (this.states.delete(sessionId)) {
      this.notify();
    }
  }

  /** 只保留仍存在的会话 */
  prune(liveSessionIds: string[]): void {
    const dead: string[] = [];
    this.states.forEach((_state: MutableActivity, sessionId: string) => {
      if (liveSessionIds.indexOf(sessionId) < 0) {
        dead.push(sessionId);
      }
    });
    for (const sessionId of dead) {
      this.states.delete(sessionId);
    }
    if (dead.length > 0) {
      this.notify();
    }
  }

  size(): number {
    return this.states.size;
  }

  /** 订阅状态翻转；返回退订函数 */
  addListener(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) {
        this.listeners.splice(index, 1);
      }
    };
  }

  private ensure(sessionId: string): MutableActivity {
    let state: MutableActivity | undefined = this.states.get(sessionId);
    if (state === undefined) {
      state = new MutableActivity();
      this.states.set(sessionId, state);
    }
    return state;
  }

  private notify(): void {
    for (const listener of this.listeners.slice()) {
      listener();
    }
  }
}

// ---------------------------------------------------------------- 活动会话行

/** 首页「活动会话」一行 */
export interface ActiveSessionRow {
  readonly sessionId: string;
  readonly hostId: string;
  readonly title: string;
  /** 状态 + 远端标题 + 所在位置（迷你窗口 / 全页） */
  readonly subtitle: string;
  readonly status: HostConnStatus;
  readonly statusLabel: string;
  /** 当前正显示在迷你窗口 */
  readonly inMini: boolean;
  /** 正被本窗口的全页终端（其他窗格）持有 */
  readonly inFullPage: boolean;
  /** 正显示在别的系统窗口（多窗口；点按 = 切到那个窗口） */
  readonly inOtherWindow: boolean;
  readonly unread: boolean;
  readonly bell: boolean;
  readonly accessibilityText: string;
  /** ForEach 键：内容变化时换键，强制重建该行（V1 复用节点不会刷新旧 item 的字段） */
  readonly renderKey: string;
}

/**
 * 全部存活会话 → 行（保持 SessionManager 创建顺序，列表不因状态变化跳动）。
 * 终态（closed/closing/idle）不列；同名多连接追加「#2」「#3」便于区分。
 */
export function buildActiveSessionRows(sessions: ActiveSessionLike[], hostNames: Map<string, string>,
  miniSessionId: string, activity: SessionActivityLookup, miniPaneId: string): ActiveSessionRow[] {
  const rows: ActiveSessionRow[] = [];
  const titleCounts: Map<string, number> = new Map();
  for (const session of sessions) {
    const status: HostConnStatus = sessionStateToStatus(session.state);
    if (status === 'none') {
      continue;
    }
    const saved: string | undefined = hostNames.get(session.hostId);
    const baseTitle: string = saved !== undefined && saved.length > 0 ? saved :
      (session.hostName.length > 0 ? session.hostName : '终端');
    const seen: number = (titleCounts.get(baseTitle) ?? 0) + 1;
    titleCounts.set(baseTitle, seen);
    const title: string = seen > 1 ? `${baseTitle} #${seen}` : baseTitle;
    const place: SessionPlace = locateSession(session.paneId, miniPaneId).place;
    const inMini: boolean = place === 'mini' ||
      (place === 'background' && miniSessionId.length > 0 && session.sessionId === miniSessionId);
    const inFullPage: boolean = place === 'page';
    const inOtherWindow: boolean = place === 'window';
    const shown: boolean = inMini || inFullPage || inOtherWindow;
    const act: SessionActivityState = activity.stateOf(session.sessionId);
    // 正在显示的会话不挂徽标（tracker 也不会给它记，这里兜底过渡态）
    const unread: boolean = act.unread && !shown;
    const bell: boolean = act.bell && !shown;
    const statusLabel: string = hostConnStatusLabel(status);
    const parts: string[] = [statusLabel];
    if (act.title.length > 0) {
      parts.push(act.title);
    }
    if (inMini) {
      parts.push('迷你窗口中');
    } else if (inFullPage) {
      parts.push('全页终端中');
    } else if (inOtherWindow) {
      parts.push('独立窗口中');
    }
    const subtitle: string = parts.join(' · ');
    const badges: string[] = [];
    if (bell) {
      badges.push('有响铃');
    }
    if (unread) {
      badges.push('有新输出');
    }
    const a11y: string = `${title}，${subtitle}${badges.length > 0 ? '，' + badges.join('，') : ''}`;
    rows.push({
      sessionId: session.sessionId,
      hostId: session.hostId,
      title: title,
      subtitle: subtitle,
      status: status,
      statusLabel: statusLabel,
      inMini: inMini,
      inFullPage: inFullPage,
      inOtherWindow: inOtherWindow,
      unread: unread,
      bell: bell,
      accessibilityText: a11y,
      renderKey: `${session.sessionId}|${status}|${title}|${subtitle}|${inMini}|${unread}|${bell}`
    });
  }
  return rows;
}

/** 列表标题计数文案：「活动会话（3）」，有未读时附「· 2 个有新动态」 */
export function activeSessionsHeader(rows: ActiveSessionRow[]): string {
  let pending: number = 0;
  for (const row of rows) {
    if (row.unread || row.bell) {
      pending++;
    }
  }
  return pending > 0 ? `活动会话（${rows.length}）· ${pending} 个有新动态` : `活动会话（${rows.length}）`;
}
