/**
 * TerminalViewModel —— 终端页视图模型（任务 U4，DESIGN §4.3.1 / §4.4 / §7.1 / §7.2）。
 *
 * 职责（逻辑与 UI 分离，对齐 U1/U2 惯例；全部生产依赖经窄接口注入，单测以 fake 覆盖）：
 *   - 进入编排：解析路由参数（hostId / sessionId 二选一，同传时 sessionId 优先——
 *     HostListPage 对已有 established 会话的主机传 sessionId 复用）→ HostDao 取主机 →
 *     SessionManager.connect（或复用既有会话）→ bindPane 固定窗格 terminal-main
 *     （单窗格语义，多窗格树归 U4b）→ 订阅会话事件与 dirty 唤醒；
 *   - 终端装配：established 后经 TerminalFactory（生产 = SshTerminal.attach）绑定 shell
 *     通道，初始 80×24 占位——画布 onAreaChange 后的 resize 由 TerminalCanvas 内部
 *     autoResize 完成；终端句柄按 sessionId 缓存：会话切换不重建终端（画面/回滚保留，
 *     §7.2），重连换柄（sessionId 不变、native 句柄换新）后 detach 旧终端、attach 新
 *     终端、换绑画布 @Prop（触发 TerminalCanvas 全量重绘）；
 *   - 状态叠加层派生（deriveOverlay 纯函数）：终端画布常驻、状态以蒙层叠加，不做整页
 *     跳转式状态切换——「从主机列表点击到出现 shell 提示符全程无白屏、无跳变」的
 *     代码侧落地（真机观感验收另验）；
 *   - 事件分发：terminalTitle → 顶栏标题；terminalBell → 轻震钩子；terminalClose →
 *     「会话已结束」标记态；dirty（channelData / terminalOpen 等输出迹象）→
 *     onContentDirty 钩子（页面接到帧调度唤醒，语义等价 TerminalCanvas.notifyContentDirty，
 *     这是 T4 登记的硬依赖通路）。
 *
 * VM 自身不持有定时器：重连退避倒计时编排在 C4 SessionManager 内，VM 只读
 * reconnectCountdownSec / reconnectAttempt 派生蒙层，「立即重连 / 取消」经窄接口转发。
 *
 * 生命周期：页面 aboutToAppear → start()；返回按钮与 aboutToDisappear → dispose()
 * （幂等：注销监听 → detach 全部缓存终端 → unbindPane(paneId, true) 释放当前绑定
 * 会话——单窗格语义「返回列表即断连」，会话保留/后台保活归 §7.5 后续任务；切换走
 * 的会话不关闭，仅释放其终端句柄）。
 */

import { HostProfile } from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import { SshEvent, SshNativeSession } from '../napi/SshNative';
import { SshTerminal } from '../napi/SshTerminal';
import { AppDatabase } from '../repository/AppDatabase';
import { SessionManager } from '../service/SessionManager';

const LOG_TAG: string = 'TerminalVM';

/** 单窗格固定 paneId（U4；多窗格 Leaf 的 paneId 分配归 U4b） */
export const TERMINAL_MAIN_PANE_ID: string = 'terminal-main';
/** attach 初始 PTY 列数（占位值；画布量出版面后由 TerminalCanvas autoResize 校正） */
export const TERMINAL_INITIAL_COLS: number = 80;
/** attach 初始 PTY 行数（同列数说明） */
export const TERMINAL_INITIAL_ROWS: number = 24;
/** HostDao 查不到主机（快速连接临时主机不落库）时的默认终端类型 */
export const DEFAULT_TERM_TYPE: string = 'xterm-256color';

// ---------------------------------------------------------------- 路由参数解析（纯函数）

/** 终端页路由参数（二选一，同传时 sessionId 优先；两参皆空 = 非法） */
export interface TerminalRouteParams {
  readonly hostId: string;
  readonly sessionId: string;
}

/** 解析 router.getParams() 原始值；缺省/非字符串一律收敛为空串（绝不抛） */
export function parseTerminalRouteParams(raw: Object | null | undefined): TerminalRouteParams {
  if (raw === null || raw === undefined) {
    return { hostId: '', sessionId: '' };
  }
  const record: Record<string, Object> = raw as Record<string, Object>;
  const hostId: Object | undefined = record['hostId'];
  const sessionId: Object | undefined = record['sessionId'];
  return {
    hostId: typeof hostId === 'string' ? hostId : '',
    sessionId: typeof sessionId === 'string' ? sessionId : ''
  };
}

// ---------------------------------------------------------------- 状态叠加层派生（纯函数）

/** 蒙层形态：none=无蒙层 / connecting=连接中指示 / reconnecting=断线倒计时 /
 *  error=错误（含断开无倒计时、启动失败）/ closed=会话已结束 */
export type OverlayKind = 'none' | 'connecting' | 'reconnecting' | 'error' | 'closed';

/** 状态叠加层模型（页面据此渲染蒙层；全部字段由 deriveOverlay 一次性产出） */
export interface OverlayModel {
  readonly kind: OverlayKind;
  /** 断线/结束期画面保留置灰（§7.2）：画布之上盖半透明灰层（仅在有终端画面时置灰） */
  readonly dimmed: boolean;
  /** 主文案 */
  readonly title: string;
  /** 次文案（倒计时/尝试次数或错误详情；空串不渲染） */
  readonly detail: string;
  /** 「取消重连」按钮（重连倒计时中） */
  readonly showCancelReconnect: boolean;
  /** 「立即重连」按钮（error 态） */
  readonly showReconnectNow: boolean;
  /** 「关闭」按钮（error / closed 态；页面语义 = 关闭会话并返回列表） */
  readonly showClose: boolean;
}

/** deriveOverlay 输入（全字段显式给出，纯函数可测） */
export interface OverlayInput {
  /** 会话状态名（C4 SshSessionStateName；'' = 尚无会话，启动受理中） */
  readonly state: string;
  readonly reconnectCountdownSec: number;
  readonly reconnectAttempt: number;
  readonly errorMessage: string;
  /** 当前画布是否已绑定终端（断线期画面保留的依据；false 时无画面可留，不置灰） */
  readonly hasTerminal: boolean;
  /** terminalClose / 外部关闭的标记态 */
  readonly terminalClosed: boolean;
  /** 进入阶段（尚无会话）的失败文案；非空时优先于一切会话状态 */
  readonly startError: string;
}

function makeOverlay(kind: OverlayKind, dimmed: boolean, title: string, detail: string,
  showCancelReconnect: boolean, showReconnectNow: boolean, showClose: boolean): OverlayModel {
  return {
    kind: kind,
    dimmed: dimmed,
    title: title,
    detail: detail,
    showCancelReconnect: showCancelReconnect,
    showReconnectNow: showReconnectNow,
    showClose: showClose
  };
}

/** 连接中阶段的次文案（按 C4 状态名细分，给用户可感知的进度反馈） */
function connectingStageDetail(state: string): string {
  switch (state) {
    case 'connecting':
      return '正在建立连接';
    case 'handshaking':
      return '正在进行 SSH 密钥交换';
    case 'authenticating':
      return '正在进行身份认证';
    default:
      return '正在准备连接';
  }
}

/**
 * 会话状态 × 重连计数字段 → 蒙层形态（九种 state 全覆盖）：
 *   - startError 非空 → error（无会话可重连，只有「关闭」）；
 *   - terminalClosed / closing / closed → closed（画面保留置灰 +「关闭」）；
 *   - established → none（无蒙层）；
 *   - disconnected 且倒计时中 → reconnecting（置灰 +「N 秒后自动重连（第 M 次）」+ 取消）；
 *   - disconnected 无倒计时（自动重连已取消）→ error 形态（「立即重连」+「关闭」）；
 *   - error → error（中文错误文案 +「立即重连」+「关闭」）；
 *   - 其余（'' / idle / connecting / handshaking / authenticating）→ connecting；
 *     已有终端画面的 connecting（重连受理后的新一次拨号）置灰并显示「正在重新连接…」。
 */
export function deriveOverlay(input: OverlayInput): OverlayModel {
  if (input.startError.length > 0) {
    return makeOverlay('error', false, '无法进入终端', input.startError, false, false, true);
  }
  if (input.terminalClosed || input.state === 'closing' || input.state === 'closed') {
    return makeOverlay('closed', input.hasTerminal, '会话已结束', input.errorMessage, false, false, true);
  }
  switch (input.state) {
    case 'established':
      return makeOverlay('none', false, '', '', false, false, false);
    case 'disconnected':
      if (input.reconnectCountdownSec > 0) {
        return makeOverlay('reconnecting', input.hasTerminal, '连接已断开',
          `${input.reconnectCountdownSec} 秒后自动重连（第 ${input.reconnectAttempt} 次）`,
          true, false, false);
      }
      return makeOverlay('error', input.hasTerminal, '连接已断开',
        input.errorMessage.length > 0 ? input.errorMessage : '自动重连已取消',
        false, true, true);
    case 'error':
      return makeOverlay('error', input.hasTerminal, '连接失败',
        input.errorMessage.length > 0 ? input.errorMessage : '连接失败，可尝试重新连接',
        false, true, true);
    default:
      return makeOverlay('connecting', input.hasTerminal,
        input.hasTerminal ? '正在重新连接…' : '正在连接…',
        connectingStageDetail(input.state), false, false, false);
  }
}

// ---------------------------------------------------------------- 注入窄接口

/** 会话的 UI 面孔窄接口（生产 = C4 SessionInfo 结构性满足；按 string 读 state 容忍未知值） */
export interface TerminalSessionLike {
  readonly sessionId: string;
  readonly hostId: string;
  readonly hostName: string;
  readonly state: string;
  readonly errorMessage: string;
  readonly reconnectAttempt: number;
  readonly reconnectCountdownSec: number;
}

/** 终端窄接口：U4 只需 write（键条字节出口）/ resize / detach；生产 = SshTerminal 结构性满足 */
export interface TerminalLike {
  write(data: ArrayBuffer | string): boolean;
  resize(cols: number, rows: number): boolean;
  detach(): void;
}

/** attach 所需的最小 native 会话面孔（生产 = SshNativeSession 结构性满足；fake 可徒手构造） */
export interface NativeSessionHandleLike {
  readonly nativeHandle: number;
}

/** 终端工厂：生产 = SshTerminal.attach 包装，测试 = fake（记录 attach 次序与参数） */
export type TerminalFactory =
  (session: NativeSessionHandleLike, termType: string, cols: number, rows: number) => TerminalLike | null;

/** 会话事件监听器（对应 C4 SessionEventListener 的窄形态） */
export type TerminalSessionEventListener = (session: TerminalSessionLike, event: SshEvent) => void;

/** dirty 唤醒监听器（对应 C4 ContentDirtyListener） */
export type TerminalDirtyListener = (sessionId: string) => void;

/** 会话管理窄接口：U4 用到的 SessionManager 最小方法集（生产适配器见 C4SessionHost） */
export interface TerminalSessionHostLike {
  connect(host: HostProfile): Promise<TerminalSessionLike>;
  close(sessionId: string): void;
  getSession(sessionId: string): TerminalSessionLike | null;
  listSessions(): TerminalSessionLike[];
  bindPane(sessionId: string, paneId: string): void;
  unbindPane(paneId: string, closeSession: boolean): void;
  nativeSessionOf(sessionId: string): NativeSessionHandleLike | null;
  reconnectNow(sessionId: string): boolean;
  cancelAutoReconnect(sessionId: string): boolean;
  addEventListener(listener: TerminalSessionEventListener): void;
  removeEventListener(listener: TerminalSessionEventListener): void;
  addDirtyListener(listener: TerminalDirtyListener): void;
  removeDirtyListener(listener: TerminalDirtyListener): void;
}

/** 主机 DAO 窄接口（生产 = AppDatabase.hosts()，调用时惰性解析） */
export interface TerminalHostDaoLike {
  getById(id: string): HostProfile | null;
}

/** 生产会话宿主：C4 SessionManager 的窄接口适配 */
class C4SessionHost implements TerminalSessionHostLike {
  connect(host: HostProfile): Promise<TerminalSessionLike> {
    return SessionManager.get().connect(host);
  }

  close(sessionId: string): void {
    SessionManager.get().close(sessionId);
  }

  getSession(sessionId: string): TerminalSessionLike | null {
    return SessionManager.get().getSession(sessionId);
  }

  listSessions(): TerminalSessionLike[] {
    return SessionManager.get().listSessions();
  }

  bindPane(sessionId: string, paneId: string): void {
    SessionManager.get().bindPane(sessionId, paneId);
  }

  unbindPane(paneId: string, closeSession: boolean): void {
    SessionManager.get().unbindPane(paneId, closeSession);
  }

  nativeSessionOf(sessionId: string): NativeSessionHandleLike | null {
    return SessionManager.get().nativeSessionOf(sessionId);
  }

  reconnectNow(sessionId: string): boolean {
    return SessionManager.get().reconnectNow(sessionId);
  }

  cancelAutoReconnect(sessionId: string): boolean {
    return SessionManager.get().cancelAutoReconnect(sessionId);
  }

  addEventListener(listener: TerminalSessionEventListener): void {
    SessionManager.get().addEventListener(listener);
  }

  removeEventListener(listener: TerminalSessionEventListener): void {
    SessionManager.get().removeEventListener(listener);
  }

  addDirtyListener(listener: TerminalDirtyListener): void {
    SessionManager.get().addDirtyListener(listener);
  }

  removeDirtyListener(listener: TerminalDirtyListener): void {
    SessionManager.get().removeDirtyListener(listener);
  }
}

/** 生产主机 DAO：转发 AppDatabase.hosts()（惰性解析，避免页面构造早于数据库就绪即崩） */
class AppDatabaseHostDao implements TerminalHostDaoLike {
  getById(id: string): HostProfile | null {
    return AppDatabase.hosts().getById(id);
  }
}

/** 生产终端工厂：SshTerminal.attach 薄包装（NativeSessionHandleLike 的生产实现即 SshNativeSession） */
const productionTerminalFactory: TerminalFactory =
  (session: NativeSessionHandleLike, termType: string, cols: number,
    rows: number): TerminalLike | null => {
    return SshTerminal.attach(session as SshNativeSession, termType, cols, rows);
  };

/** 可选依赖集：缺省项走生产实现；单测全部注入 fake */
export interface TerminalViewModelDeps {
  sessionHost?: TerminalSessionHostLike;
  hostDao?: TerminalHostDaoLike;
  terminalFactory?: TerminalFactory;
  /** 轻震钩子（terminalBell / 连接成功，§4.4 触感表）；生产 = vibrateLight 包装 */
  vibrate?: () => void;
  /** 内容脏钩子（输出迹象 → 唤醒帧循环；T4 硬依赖，语义等价 canvas.notifyContentDirty） */
  onContentDirty?: () => void;
}

/** 已 attach 终端的缓存条目：终端 + 绑定的 native 句柄（重连换柄检测依据） */
interface AttachedTerminal {
  terminal: TerminalLike;
  nativeHandle: number;
}

@ObservedV2
export class TerminalViewModel {
  /** 顶栏主机名（SessionInfo.hostName；快速连接临时主机 = user@host） */
  @Trace hostName: string = '';
  /** 顶栏终端标题（terminalTitle 事件，远端 OSC 设置；空 = 顶栏只显示主机名） */
  @Trace terminalTitle: string = '';
  /** 当前会话状态名（'' = 尚无会话/已摘除；顶栏状态点依据） */
  @Trace sessionState: string = '';
  /** 状态叠加层模型（蒙层唯一数据源） */
  @Trace overlay: OverlayModel = deriveOverlay({
    state: '',
    reconnectCountdownSec: 0,
    reconnectAttempt: 0,
    errorMessage: '',
    hasTerminal: false,
    terminalClosed: false,
    startError: ''
  });
  /** 当前画布应绑定的终端（@Trace 驱动 TerminalCanvas 的 @Prop 换绑 → 全量重绘） */
  @Trace terminal: TerminalLike | null = null;
  /** 抽屉会话列表快照（任何会话事件后整体替换刷新） */
  @Trace sessionList: TerminalSessionLike[] = [];
  /** 当前绑定会话（'' = 尚未建立/参数非法） */
  @Trace currentSessionId: string = '';

  private readonly injectedHost: TerminalSessionHostLike | null;
  private readonly injectedHostDao: TerminalHostDaoLike | null;
  private readonly factory: TerminalFactory;
  private readonly vibrateHook: () => void;
  private readonly dirtyHook: () => void;
  /** sessionId → 已 attach 终端（含切换走的会话：换回时复用，画面/回滚保留） */
  private readonly attachedTerminals: Map<string, AttachedTerminal> = new Map();
  /** sessionId → termType（attach 用；HostDao 尽力而为，缺省 DEFAULT_TERM_TYPE） */
  private readonly termTypes: Map<string, string> = new Map();
  private hostCache: TerminalSessionHostLike | null = null;
  private terminalClosed: boolean = false;
  private startError: string = '';
  private started: boolean = false;
  private disposed: boolean = false;
  private listenersOn: boolean = false;

  constructor(deps?: TerminalViewModelDeps) {
    this.injectedHost = deps?.sessionHost ?? null;
    this.injectedHostDao = deps?.hostDao ?? null;
    this.factory = deps?.terminalFactory ?? productionTerminalFactory;
    this.vibrateHook = deps?.vibrate ?? ((): void => {});
    this.dirtyHook = deps?.onContentDirty ?? ((): void => {});
  }

  /** 会话事件入口（主线程，C4 透传） */
  private readonly eventListener: TerminalSessionEventListener =
    (session: TerminalSessionLike, event: SshEvent): void => {
      this.onSessionEvent(session, event);
    };

  /** dirty 唤醒入口：仅当前会话的输出迹象唤醒本页帧循环 */
  private readonly dirtyListener: TerminalDirtyListener = (sessionId: string): void => {
    if (!this.disposed && sessionId === this.currentSessionId) {
      this.dirtyHook();
    }
  };

  // ---------------------------------------------------------------- 进入编排

  /**
   * 页面进入（幂等；失败一律落 startError 蒙层，不抛出）：
   * sessionId 优先复用既有会话；否则 hostId → HostDao → connect 新会话。
   */
  async start(params: TerminalRouteParams): Promise<void> {
    if (this.started || this.disposed) {
      return;
    }
    this.started = true;
    if (params.sessionId.length > 0) {
      const info: TerminalSessionLike | null = this.sessionHost().getSession(params.sessionId);
      if (info === null) {
        this.failStart('会话不存在或已关闭，请返回主机列表重新连接');
        return;
      }
      this.adoptSession(info, this.lookupHost(info.hostId));
      return;
    }
    if (params.hostId.length === 0) {
      this.failStart('缺少连接目标（需要 hostId 或 sessionId）');
      return;
    }
    const host: HostProfile | null = this.lookupHost(params.hostId);
    if (host === null) {
      this.failStart('主机不存在或已被删除，请返回列表重试');
      return;
    }
    this.hostName = host.name.length > 0 ? host.name : host.host;
    try {
      const info: TerminalSessionLike = await this.sessionHost().connect(host);
      if (this.disposed) {
        // 等待受理期间页面已退出：会话未绑窗格，dispose 的 unbindPane 管不到，显式关闭
        this.sessionHost().close(info.sessionId);
        return;
      }
      this.adoptSession(info, host);
    } catch (err) {
      this.failStart(err instanceof Error ? err.message : '连接发起失败');
    }
  }

  /** 采用一个会话：绑窗格 → 注册监听 → 已 established 则立即装配终端 → 刷新蒙层 */
  private adoptSession(info: TerminalSessionLike, host: HostProfile | null): void {
    this.currentSessionId = info.sessionId;
    this.termTypes.set(info.sessionId, host === null ? DEFAULT_TERM_TYPE : host.termType);
    if (this.hostName.length === 0) {
      this.hostName = info.hostName.length > 0 ? info.hostName : (host === null ? '终端' : host.host);
    }
    this.registerListeners();
    try {
      this.sessionHost().bindPane(info.sessionId, TERMINAL_MAIN_PANE_ID);
    } catch (err) {
      // 窗格冲突属编程错误/旧实例泄漏：解监听后落错误蒙层，不把半绑定态带进页面
      this.unregisterListeners();
      this.currentSessionId = '';
      this.failStart(`终端窗格绑定失败：${err instanceof Error ? err.message : '未知原因'}`);
      return;
    }
    this.refreshSessionList();
    if (info.state === 'established') {
      this.ensureTerminalAttached(info.sessionId);
    }
    this.refreshOverlay();
  }

  private failStart(message: string): void {
    this.startError = message;
    this.refreshOverlay();
  }

  private lookupHost(hostId: string): HostProfile | null {
    if (hostId.length === 0) {
      return null;
    }
    try {
      return this.hostDao().getById(hostId);
    } catch (err) {
      Logger.error(`主机读取失败（hostId=${hostId}）: ${JSON.stringify(err)}`, LOG_TAG);
      return null;
    }
  }

  // ---------------------------------------------------------------- 会话切换（抽屉）

  /**
   * 切换到指定会话（抽屉点击）：unbindPane 旧（false，会话保留）→ bindPane 新 →
   * 复用缓存终端或（established 且未装配/柄已换）重新 attach。与当前相同或未知会话为 no-op。
   */
  switchSession(sessionId: string): void {
    if (this.disposed || sessionId === this.currentSessionId) {
      return;
    }
    const info: TerminalSessionLike | null = this.sessionHost().getSession(sessionId);
    if (info === null) {
      return;
    }
    const previousSessionId: string = this.currentSessionId;
    this.sessionHost().unbindPane(TERMINAL_MAIN_PANE_ID, false);
    try {
      this.sessionHost().bindPane(sessionId, TERMINAL_MAIN_PANE_ID);
    } catch (err) {
      // 绑定失败：尽力恢复旧绑定，保持原会话不受影响
      Logger.error(`会话切换绑定失败（${sessionId}）: ${JSON.stringify(err)}`, LOG_TAG);
      if (previousSessionId.length > 0) {
        try {
          this.sessionHost().bindPane(previousSessionId, TERMINAL_MAIN_PANE_ID);
        } catch (restoreErr) {
          Logger.error(`恢复原窗格绑定失败: ${JSON.stringify(restoreErr)}`, LOG_TAG);
        }
      }
      return;
    }
    this.currentSessionId = sessionId;
    this.hostName = info.hostName.length > 0 ? info.hostName : this.hostName;
    this.terminalTitle = '';
    this.terminalClosed = false;
    this.startError = '';
    const host: HostProfile | null = this.lookupHost(info.hostId);
    if (host !== null) {
      this.termTypes.set(sessionId, host.termType);
    }
    const cached: AttachedTerminal | undefined = this.attachedTerminals.get(sessionId);
    this.terminal = cached === undefined ? null : cached.terminal;
    if (info.state === 'established') {
      this.ensureTerminalAttached(sessionId);
    }
    this.refreshOverlay();
  }

  // ---------------------------------------------------------------- 重连控制（转发 C4）

  /** 「立即重连」（error 蒙层）：取消在途退避并立即按原主机配置重拨（C4 reconnectNow） */
  reconnectNow(): void {
    if (this.disposed || this.currentSessionId.length === 0) {
      return;
    }
    if (this.sessionHost().reconnectNow(this.currentSessionId)) {
      this.terminalClosed = false;
      this.refreshOverlay();
    }
  }

  /** 「取消重连」（倒计时蒙层）：停掉自动重连，会话保持断开待用户抉择 */
  cancelAutoReconnect(): void {
    if (this.disposed || this.currentSessionId.length === 0) {
      return;
    }
    if (this.sessionHost().cancelAutoReconnect(this.currentSessionId)) {
      this.refreshOverlay();
    }
  }

  // ---------------------------------------------------------------- 输入出口（T7 键条）

  /**
   * 外部字节写当前终端（KeyBar onSendBytes 出口）：Uint8Array → 零偏移全量
   * ArrayBuffer（与 TerminalCanvas.sendInputBytes 同口径）。单窗格模式 focusId 为空时
   * TerminalCanvas.sendExternalInput 的焦点路由本就直通，故此处直写等价；
   * 多窗格焦点路由归 U4b。
   */
  sendInput(bytes: Uint8Array): void {
    const terminal: TerminalLike | null = this.terminal;
    if (this.disposed || terminal === null || bytes.length === 0) {
      return;
    }
    terminal.write(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  }

  // ---------------------------------------------------------------- 退出

  /**
   * 页面退出（幂等）：注销监听 → detach 全部缓存终端 → unbindPane(paneId, true)
   * 释放当前绑定会话。单窗格语义「返回列表即断连」；会话保留/后台保活归 §7.5。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.unregisterListeners();
    this.attachedTerminals.forEach((entry: AttachedTerminal) => {
      entry.terminal.detach();
    });
    this.attachedTerminals.clear();
    this.terminal = null;
    this.sessionHost().unbindPane(TERMINAL_MAIN_PANE_ID, true);
  }

  // ---------------------------------------------------------------- 事件分发

  private onSessionEvent(session: TerminalSessionLike, event: SshEvent): void {
    if (this.disposed) {
      return;
    }
    // 抽屉列表对任何会话变化敏感（状态点实时刷新）
    this.refreshSessionList();
    if (session.sessionId !== this.currentSessionId) {
      // 非当前会话：重连换柄导致的缓存终端过期，待切换到该会话时按柄比对重建
      return;
    }
    switch (event.type) {
      case 'stateChange':
        if (event.to === 'established') {
          // （重）连成功：装配/重装终端（重连换柄 → detach 旧、attach 新、换绑画布）+ 轻震
          this.terminalClosed = false;
          this.ensureTerminalAttached(session.sessionId);
          this.vibrateHook();
        } else if (event.to === 'closed') {
          this.terminalClosed = true;
        }
        this.refreshOverlay();
        break;
      case 'terminalOpen':
        this.terminalClosed = false;
        this.refreshOverlay();
        break;
      case 'terminalClose':
        this.terminalClosed = true;
        this.refreshOverlay();
        break;
      case 'terminalTitle':
        this.terminalTitle = event.title ?? '';
        break;
      case 'terminalBell':
        this.vibrateHook();
        break;
      default:
        // channelData 等仅经 dirty 通路上屏（T4 硬依赖），蒙层不敏感
        break;
    }
  }

  /**
   * 终端装配（幂等）：native 句柄未换 → 复用；已换（重连）→ detach 旧、attach 新。
   * 旧终端 detach 后其帧仍可安全读（T3 生命周期保护），断线期画面因此保留。
   */
  private ensureTerminalAttached(sessionId: string): void {
    const native: NativeSessionHandleLike | null = this.sessionHost().nativeSessionOf(sessionId);
    if (native === null) {
      return;
    }
    const existing: AttachedTerminal | undefined = this.attachedTerminals.get(sessionId);
    if (existing !== undefined && existing.nativeHandle === native.nativeHandle) {
      if (sessionId === this.currentSessionId && this.terminal === null) {
        this.terminal = existing.terminal; // 防御：画布绑定意外丢失时恢复
      }
      return;
    }
    if (existing !== undefined) {
      existing.terminal.detach();
    }
    const termType: string = this.termTypes.get(sessionId) ?? DEFAULT_TERM_TYPE;
    const created: TerminalLike | null =
      this.factory(native, termType, TERMINAL_INITIAL_COLS, TERMINAL_INITIAL_ROWS);
    if (created === null) {
      Logger.warn(`终端 attach 未受理（sessionId=${sessionId}），等待下次 established`, LOG_TAG);
      return;
    }
    this.attachedTerminals.set(sessionId, { terminal: created, nativeHandle: native.nativeHandle });
    if (sessionId === this.currentSessionId) {
      this.terminal = created; // 换绑画布 @Prop → TerminalCanvas 全量重绘
    }
  }

  // ---------------------------------------------------------------- 内部：状态刷新与依赖解析

  private refreshSessionList(): void {
    this.sessionList = this.sessionHost().listSessions();
  }

  private refreshOverlay(): void {
    const info: TerminalSessionLike | null =
      this.currentSessionId.length > 0 ? this.sessionHost().getSession(this.currentSessionId) : null;
    this.sessionState = info === null ? '' : info.state;
    this.overlay = deriveOverlay({
      state: this.sessionState,
      reconnectCountdownSec: info === null ? 0 : info.reconnectCountdownSec,
      reconnectAttempt: info === null ? 0 : info.reconnectAttempt,
      errorMessage: info === null ? '' : info.errorMessage,
      hasTerminal: this.terminal !== null,
      terminalClosed: this.terminalClosed,
      startError: this.startError
    });
  }

  private registerListeners(): void {
    if (this.listenersOn) {
      return;
    }
    this.listenersOn = true;
    this.sessionHost().addEventListener(this.eventListener);
    this.sessionHost().addDirtyListener(this.dirtyListener);
  }

  private unregisterListeners(): void {
    if (!this.listenersOn) {
      return;
    }
    this.listenersOn = false;
    this.sessionHost().removeEventListener(this.eventListener);
    this.sessionHost().removeDirtyListener(this.dirtyListener);
  }

  private sessionHost(): TerminalSessionHostLike {
    if (this.hostCache === null) {
      this.hostCache = this.injectedHost ?? new C4SessionHost();
    }
    return this.hostCache;
  }

  private hostDao(): TerminalHostDaoLike {
    return this.injectedHostDao ?? new AppDatabaseHostDao();
  }
}
