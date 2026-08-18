/**
 * TerminalViewModel —— 终端页视图模型（任务 U4 / U4b，DESIGN §4.3.1 / §4.4 / §7.1 / §7.2）。
 *
 * 职责（逻辑与 UI 分离，对齐 U1/U2 惯例；全部生产依赖经窄接口注入，单测以 fake 覆盖）：
 *   - 进入编排：解析路由参数（hostId / sessionId 二选一，同传时 sessionId 优先）→
 *     建首标签 + 首叶（paneId 固定 terminal-main，兼容 U4 单窗格绑定）→
 *     SessionManager.connect / 复用既有会话 → bindPane → 订阅事件与 dirty 唤醒；
 *   - 多标签 / 分屏编排（U4b）：持有 PaneTabSet；newTab / splitFocused 按聚焦叶的
 *     主机快照再拨号；closePane 兄弟上提；closeTab 批量释放；拖分隔条只改 ratio；
 *     两窗格在窄屏仍完整显示，3+ 窗格才降级聚焦叶；树与会话始终不动；
 *   - 焦点：全局单一聚焦叶；currentSessionId / terminal / overlay / 顶栏字段始终
 *     投影聚焦叶（KeyBar sendInput 直写 this.terminal 仍然正确）；FocusHost 可注入
 *     （生产 = FocusManager 适配，缺省 no-op 以免单测污染单例）；
 *   - 终端装配：established 后经 TerminalFactory 绑定 shell；句柄按 sessionId 缓存；
 *     重连换柄后 detach 旧、attach 新；每个可见叶各自一块 Canvas（autoResize 各自
 *     request_pty_size，拖分隔条不漏）；
 *   - 状态叠加层：deriveOverlay 纯函数；每叶一份，聚焦叶同步到 this.overlay；
 *   - dirty：任一**可见**叶的输出迹象都唤醒帧循环（不可见标签零绘制，D14）。
 *
 * 生命周期：aboutToAppear → start()；返回 / aboutToDisappear → dispose()
 * （注销监听 → detach 全部缓存终端 → 对所有叶 unbindPane(true)）。
 */

import { HostProfile } from '../common/model/models';
import { SshError, SshErrorCode } from '../common/SshError';
import { CredentialStore } from '../repository/CredentialStore';
import { Logger } from '../common/utils/Logger';
import { SshEvent, SshNativeSession } from '../napi/SshNative';
import { SshTerminal } from '../napi/SshTerminal';
import { AppDatabase } from '../repository/AppDatabase';
import { SessionManager } from '../service/SessionManager';
import {
  DividerRect,
  PANE_DIVIDER_SIZE_VP,
  PaneBreakpoint,
  PaneFocusDirection,
  PaneLayout,
  PaneLeaf,
  PaneRect,
  PaneTabSet,
  SplitDirection,
  breakpointOfWidth,
  createPaneLeaf,
  firstLeafOf,
  layoutPaneTree,
  layoutVisibleTree,
  leavesOf,
  neighborLeafInDirection
} from './PaneTree';

const LOG_TAG: string = 'TerminalVM';

/** 首叶固定 paneId（U4 单窗格绑定；后续叶由 PaneTabSet 工厂分配） */
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

/** 路由参数取值：只要字符串；包装对象（偶发）用 toString，拒绝 [object Object] */
function routeParamAsString(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return '';
  }
  const text: string = `${value}`;
  if (text.length === 0 || text === '[object Object]') {
    return '';
  }
  return text;
}

/** 解析 router.getParams() 原始值；缺省/非字符串一律收敛为空串（绝不抛） */
export function parseTerminalRouteParams(raw: Object | null | undefined): TerminalRouteParams {
  if (raw === null || raw === undefined) {
    return { hostId: '', sessionId: '' };
  }
  const record: Record<string, Object> = raw as Record<string, Object>;
  return {
    hostId: routeParamAsString(record['hostId']),
    sessionId: routeParamAsString(record['sessionId'])
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
  /** 「关闭」按钮（error / closed 态；页面语义 = 关闭该窗格，末叶则退出） */
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

/** 空白「新连接」标签不属于连接阶段，不应显示“正在连接”蒙层。 */
const NO_OVERLAY: OverlayModel = makeOverlay('none', false, '', '', false, false, false);

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

// ---------------------------------------------------------------- 渲染快照（页面 ForEach 用）

/** 标签栏一项 */
export interface TabRenderItem {
  readonly tabId: string;
  readonly title: string;
  readonly active: boolean;
}

/** 当前可见叶（绝对矩形 + 该叶的终端/蒙层/焦点） */
export interface PaneRenderItem {
  readonly paneId: string;
  readonly sessionId: string;
  /** true = “+” 新建的连接选择标签；尚未创建或绑定 SSH 会话。 */
  readonly connectionPicker: boolean;
  /** 窗格当前绑定的主机；临时连接也从会话快照取回，供标签与外观按主机路由 */
  readonly hostId: string;
  /** 服务器标签：HostProfile.name 优先，回退 SessionInfo.hostName / host */
  readonly hostName: string;
  /** 次级标识：user@host:port；主机快照不可用时为空 */
  readonly endpoint: string;
  /** 该窗格自己的连接状态，不再错误复用聚焦窗格状态 */
  readonly state: string;
  readonly terminal: TerminalLike | null;
  readonly overlay: OverlayModel;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  readonly focused: boolean;
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

/** 焦点宿主（生产 = FocusManager 适配；缺省 no-op，单测不污染全局单例） */
export interface TerminalFocusHostLike {
  register(id: string): boolean;
  unregister(id: string): boolean;
  focus(id: string): boolean;
  addListener(cb: (id: string) => void): () => void;
}

class NoopFocusHost implements TerminalFocusHostLike {
  register(id: string): boolean {
    return id.length >= 0;
  }

  unregister(id: string): boolean {
    return id.length >= 0;
  }

  focus(id: string): boolean {
    return id.length >= 0;
  }

  addListener(cb: (id: string) => void): () => void {
    return (): void => {
      if (cb.length < 0) {
        return;
      }
    };
  }
}

/** 会话管理窄接口：U4/U4b 用到的 SessionManager 最小方法集（生产适配器见 C4SessionHost） */
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
  /** 会话主机快照（分屏/新标签复用；临时主机 DAO 没有时靠这条） */
  hostOf(sessionId: string): HostProfile | null;
  addEventListener(listener: TerminalSessionEventListener): void;
  removeEventListener(listener: TerminalSessionEventListener): void;
  addDirtyListener(listener: TerminalDirtyListener): void;
  removeDirtyListener(listener: TerminalDirtyListener): void;
}

/** 主机 DAO 窄接口（生产 = AppDatabase.hosts()，调用时惰性解析） */
export interface TerminalHostDaoLike {
  getById(id: string): HostProfile | null;
  listAll(): HostProfile[];
}

/** 连接选择面板的打开目标。replace=替换聚焦窗格但保留旧会话，row/column 对应左右/上下。 */
export type ConnectionOpenMode = 'replace' | 'tab' | 'row' | 'column';

/**
 * 凭据写入窄接口（生产 = CredentialStore.setSecret，落系统 ASSET 加密存储）。
 * 补录的密码必须持久化：§7.1 的自动重连会重新走 prepareAuth 取凭据，
 * 只在内存里存一份的话第一次断线重连就又没密码了。
 */
export interface TerminalSecretWriterLike {
  savePassword(hostId: string, password: string): Promise<void>;
}

/** 生产凭据写入：转发 CredentialStore（明文只进出 ASSET，不落沙箱、不进日志） */
class CredentialStoreSecretWriter implements TerminalSecretWriterLike {
  savePassword(hostId: string, password: string): Promise<void> {
    return CredentialStore.setSecret(hostId, 'password', password);
  }
}

/** 密码补录框的渲染模型（页面只读这一个对象） */
export interface PasswordPromptModel {
  readonly visible: boolean;
  /** 标题里显示的主机名 */
  readonly hostName: string;
  /** 提交中（禁用按钮、显示「连接中」） */
  readonly busy: boolean;
  /** 上一次提交的失败原因（空串不渲染） */
  readonly error: string;
}

const HIDDEN_PASSWORD_PROMPT: PasswordPromptModel = {
  visible: false,
  hostName: '',
  busy: false,
  error: ''
};

/** 密码错或认证超时：应重新弹出密码框，让用户改密再试。 */
export function isPasswordRetryError(event: SshEvent): boolean {
  const code: number = event.errorCode !== undefined ? event.errorCode : 0;
  if (code === SshErrorCode.AUTH_PASSWORD_FAILED || code === SshErrorCode.AUTH_TIMEOUT) {
    return true;
  }
  const name: string = event.errorCodeName !== undefined ? event.errorCodeName : '';
  return name === 'auth_password_failed' || name === 'auth_timeout';
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

  hostOf(sessionId: string): HostProfile | null {
    return SessionManager.get().hostOf(sessionId);
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

  listAll(): HostProfile[] {
    return AppDatabase.hosts().listAll();
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
  /**
   * UI 刷新钩子：V1 @Component 订阅不到 @ObservedV2/@Trace。
   * 页面用 @State 计数器在此回调里自增，驱动整页重绘。
   */
  onUiChange?: () => void;
  /** 焦点宿主（生产页注入 FocusManager 适配；缺省 no-op） */
  focusHost?: TerminalFocusHostLike;
  /** 凭据写入（生产 = CredentialStore；单测注入内存 fake，不碰 ASSET） */
  secretWriter?: TerminalSecretWriterLike;
}

/** 已 attach 终端的缓存条目：终端 + 绑定的 native 句柄（重连换柄检测依据） */
interface AttachedTerminal {
  terminal: TerminalLike;
  nativeHandle: number;
}

@ObservedV2
export class TerminalViewModel {
  /** 顶栏主机名（投影聚焦叶；快速连接临时主机 = user@host） */
  @Trace hostName: string = '';
  /** 顶栏终端标题（聚焦叶的 terminalTitle；空 = 顶栏只显示主机名） */
  @Trace terminalTitle: string = '';
  /** 聚焦叶会话状态名（'' = 尚无会话/已摘除；顶栏状态点依据） */
  @Trace sessionState: string = '';
  /** 聚焦叶的状态叠加层（空树时为 startError 蒙层） */
  @Trace overlay: OverlayModel = deriveOverlay({
    state: '',
    reconnectCountdownSec: 0,
    reconnectAttempt: 0,
    errorMessage: '',
    hasTerminal: false,
    terminalClosed: false,
    startError: ''
  });
  /** 聚焦叶画布应绑定的终端（KeyBar sendInput 出口；多叶时页面读 visiblePanes） */
  @Trace terminal: TerminalLike | null = null;
  /** 抽屉会话列表快照（任何会话事件后整体替换刷新） */
  @Trace sessionList: TerminalSessionLike[] = [];
  /** 连接选择面板的已保存主机快照 */
  @Trace hostList: HostProfile[] = [];
  /** 聚焦叶绑定会话（'' = 尚未建立/参数非法） */
  @Trace currentSessionId: string = '';
  /** 标签栏快照 */
  @Trace tabs: TabRenderItem[] = [];
  /** 当前激活标签（'' = 无标签） */
  @Trace activeTabId: string = '';
  /** 当前可见叶（sm 的 1–2 叶全量、3+ 叶仅聚焦；md/lg 激活标签全树） */
  @Trace visiblePanes: PaneRenderItem[] = [];
  /** 当前可见分隔条（sm 的双窗格也保留；3+ 窗格降级时为空） */
  @Trace dividers: DividerRect[] = [];
  /** 聚焦叶 paneId */
  @Trace focusedPaneId: string = '';
  /** 当前断点（由视口宽度派生；默认 sm，页面 onAreaChange 后校正） */
  @Trace breakpoint: PaneBreakpoint = 'sm';
  /** 关末叶/末标签后为 true，页面据此返回列表 */
  @Trace shouldExit: boolean = false;
  /** 密码补录框（凭据库里没有该主机密码时弹出，替代「无法进入终端」死路） */
  @Trace passwordPrompt: PasswordPromptModel = HIDDEN_PASSWORD_PROMPT;

  private readonly injectedHost: TerminalSessionHostLike | null;
  private readonly injectedHostDao: TerminalHostDaoLike | null;
  private readonly factory: TerminalFactory;
  private readonly vibrateHook: () => void;
  private readonly dirtyHook: () => void;
  private readonly uiHook: () => void;
  private readonly focusHost: TerminalFocusHostLike;
  private readonly secretWriter: TerminalSecretWriterLike;
  /** 等待密码补录的主机（补录成功后按它重新拨号；非补录期为 null） */
  private pendingPasswordHost: HostProfile | null = null;
  /** 补录成功后的落点；页面初次进入等价 replace，连接面板可指定标签或分屏。 */
  private pendingPasswordMode: ConnectionOpenMode = 'replace';
  /** 是否为页面初次进入；取消时只有初次进入需要落整页错误蒙层。 */
  private pendingPasswordInitial: boolean = false;
  /** 认证失败后补录对应的已有会话；空串 = 还没有会话，提交后走 connect。 */
  private pendingPasswordSessionId: string = '';
  private readonly tabSet: PaneTabSet = new PaneTabSet();
  /** sessionId → 已 attach 终端（含切换走的会话：换回时复用，画面/回滚保留） */
  private readonly attachedTerminals: Map<string, AttachedTerminal> = new Map();
  /** sessionId → termType（attach 用；HostDao 尽力而为，缺省 DEFAULT_TERM_TYPE） */
  private readonly termTypes: Map<string, string> = new Map();
  /** sessionId → terminalClose 标记 */
  private readonly closedBySession: Map<string, boolean> = new Map();
  /** 标签 → 上次聚焦叶（切回标签时恢复） */
  private readonly lastFocusByTab: Map<string, string> = new Map();
  private hostCache: TerminalSessionHostLike | null = null;
  /** 最近一次成功采用的主机（分屏/新标签在 DAO/hostOf 都落空时的兜底） */
  private lastHost: HostProfile | null = null;
  private startError: string = '';
  private started: boolean = false;
  private disposed: boolean = false;
  private listenersOn: boolean = false;
  private areaWidthVp: number = 0;
  private areaHeightVp: number = 0;
  private readonly unsubFocus: () => void;

  constructor(deps?: TerminalViewModelDeps) {
    this.injectedHost = deps?.sessionHost ?? null;
    this.injectedHostDao = deps?.hostDao ?? null;
    this.factory = deps?.terminalFactory ?? productionTerminalFactory;
    this.vibrateHook = deps?.vibrate ?? ((): void => {});
    this.dirtyHook = deps?.onContentDirty ?? ((): void => {});
    this.uiHook = deps?.onUiChange ?? ((): void => {});
    this.focusHost = deps?.focusHost ?? new NoopFocusHost();
    this.secretWriter = deps?.secretWriter ?? new CredentialStoreSecretWriter();
    this.unsubFocus = this.focusHost.addListener((id: string): void => {
      this.onExternalFocus(id);
    });
  }

  /** 会话事件入口（主线程，C4 透传） */
  private readonly eventListener: TerminalSessionEventListener =
    (session: TerminalSessionLike, event: SshEvent): void => {
      this.onSessionEvent(session, event);
    };

  /** dirty 唤醒入口：任一可见叶的输出迹象唤醒本页帧循环 */
  private readonly dirtyListener: TerminalDirtyListener = (sessionId: string): void => {
    if (!this.disposed && this.isSessionVisible(sessionId)) {
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
    this.refreshHostList();
    this.refreshSessionList();
    Logger.info(
      `终端页启动 hostId=${params.hostId.length > 0 ? '有' : '无'} sessionId=${params.sessionId.length > 0 ? '有' : '无'}`,
      LOG_TAG);
    if (params.sessionId.length > 0) {
      const info: TerminalSessionLike | null = this.sessionHost().getSession(params.sessionId);
      if (info === null) {
        this.failStart('会话不存在或已关闭，请返回主机列表重新连接');
        return;
      }
      this.adoptSession(info, this.hostForSession(info.sessionId) ?? this.lookupHost(info.hostId));
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
    this.lastHost = host;
    this.refreshOverlay();
    this.notifyUi();
    Logger.info(`发起连接 authType=${host.authType} port=${host.port}`, LOG_TAG);
    try {
      const info: TerminalSessionLike = await this.sessionHost().connect(host);
      if (this.disposed) {
        // 等待受理期间页面已退出：会话未绑窗格，dispose 的 unbindPane 管不到，显式关闭
        this.sessionHost().close(info.sessionId);
        return;
      }
      Logger.info(`连接已受理 state=${info.state}`, LOG_TAG);
      this.adoptSession(info, host);
    } catch (err) {
      this.handleConnectFailure(err, host);
    }
  }

  /** 从数据库刷新连接选择列表；页面从主机编辑页返回或打开面板时调用。 */
  reloadConnections(): void {
    if (this.disposed) {
      return;
    }
    this.refreshHostList();
    this.refreshSessionList();
    this.notifyUi();
  }

  /**
   * 拨号失败分流：凭据缺失且为密码认证 → 弹补录框（可恢复）；其余 → 错误蒙层（死路）。
   * 私钥缺失不弹框——私钥要走文件导入，不是一个输入框能解决的，仍落蒙层引导去主机配置。
   */
  private handleConnectFailure(err: Object, host: HostProfile): void {
    const missingCredential: boolean =
      err instanceof SshError && err.code === SshErrorCode.CREDENTIAL_MISSING;
    if (missingCredential && host.authType === 'password') {
      Logger.info('凭据库无该主机密码，弹出补录框', LOG_TAG);
      this.showPasswordPrompt(host, 'replace', this.tabSet.tabs.length === 0, '', '');
      return;
    }
    this.failStart(err instanceof Error ? err.message : '连接发起失败');
  }

  // ---------------------------------------------------------------- 密码补录

  /**
   * 提交补录的密码：先落 ASSET 凭据库（重连要复用，见 TerminalSecretWriterLike 头注），
   * 再按同一主机重新拨号。失败时留在框内并回显原因，用户可改了再试。
   * 密码只在本方法调用栈内以局部量存在，不写字段、不进日志。
   */
  async submitPassword(password: string): Promise<void> {
    const host: HostProfile | null = this.pendingPasswordHost;
    if (this.disposed || host === null || this.passwordPrompt.busy) {
      return;
    }
    if (password.length === 0) {
      this.setPromptError('请输入登录密码');
      return;
    }
    this.passwordPrompt = {
      visible: true,
      hostName: this.passwordPrompt.hostName,
      busy: true,
      error: ''
    };
    this.refreshViews();
    try {
      await this.secretWriter.savePassword(host.id, password);
    } catch (err) {
      Logger.error(`密码写入凭据库失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.setPromptError('密码保存失败，请重试');
      return;
    }
    if (this.disposed) {
      return;
    }
    const existingSessionId: string = this.pendingPasswordSessionId;
    if (existingSessionId.length > 0) {
      const existing: TerminalSessionLike | null = this.sessionHost().getSession(existingSessionId);
      if (existing !== null && (existing.state === 'error' || existing.state === 'disconnected')) {
        this.pendingPasswordHost = null;
        this.pendingPasswordSessionId = '';
        this.pendingPasswordInitial = false;
        this.passwordPrompt = HIDDEN_PASSWORD_PROMPT;
        this.sessionHost().reconnectNow(existingSessionId);
        this.refreshViews();
        return;
      }
    }
    try {
      const info: TerminalSessionLike = await this.sessionHost().connect(host);
      if (this.disposed) {
        this.sessionHost().close(info.sessionId);
        return;
      }
      const mode: ConnectionOpenMode = this.pendingPasswordMode;
      this.pendingPasswordHost = null;
      this.pendingPasswordSessionId = '';
      this.pendingPasswordInitial = false;
      this.passwordPrompt = HIDDEN_PASSWORD_PROMPT;
      Logger.info(`补录密码后连接已受理 state=${info.state}`, LOG_TAG);
      this.placeSession(info, host, mode);
    } catch (err) {
      this.setPromptError(err instanceof Error ? err.message : '连接发起失败');
    }
  }

  /** 取消补录：没有可用凭据，落错误蒙层（用户可从蒙层「关闭」退回列表） */
  cancelPasswordPrompt(): void {
    if (this.disposed) {
      return;
    }
    const initial: boolean = this.pendingPasswordInitial;
    this.pendingPasswordHost = null;
    this.pendingPasswordSessionId = '';
    this.pendingPasswordInitial = false;
    this.passwordPrompt = HIDDEN_PASSWORD_PROMPT;
    if (initial) {
      this.failStart('未提供登录密码，无法连接');
    } else {
      this.refreshViews();
    }
  }

  private setPromptError(message: string): void {
    this.passwordPrompt = {
      visible: true,
      hostName: this.passwordPrompt.hostName,
      busy: false,
      error: message
    };
    this.refreshViews();
  }

  private showPasswordPrompt(host: HostProfile, mode: ConnectionOpenMode, initial: boolean,
    sessionId: string, error: string): void {
    this.pendingPasswordHost = host;
    this.pendingPasswordMode = mode;
    this.pendingPasswordInitial = initial;
    this.pendingPasswordSessionId = sessionId;
    this.passwordPrompt = {
      visible: true,
      hostName: host.name.length > 0 ? host.name : host.host,
      busy: false,
      error: error
    };
    this.refreshViews();
  }

  /**
   * 已受理的密码会话在认证失败 / 认证超时时重新弹出密码框。
   * 取消自动重连，避免旧密码还在后台连、用户同时在改密。
   */
  private maybePromptPasswordAfterAuthFailure(session: TerminalSessionLike, event: SshEvent): void {
    if (!isPasswordRetryError(event) || this.passwordPrompt.busy) {
      return;
    }
    const host: HostProfile | null =
      this.hostForSession(session.sessionId) ?? this.lookupHost(session.hostId);
    if (host === null || host.authType !== 'password') {
      return;
    }
    this.sessionHost().cancelAutoReconnect(session.sessionId);
    const code: SshErrorCode = event.errorCode !== undefined && event.errorCode > 0
      ? SshError.fromNativeCode(event.errorCode)
      : SshErrorCode.AUTH_PASSWORD_FAILED;
    this.showPasswordPrompt(host, 'replace', false, session.sessionId, SshError.toUserMessage(code));
  }

  /** 采用一个会话：建首标签/首叶 → 绑窗格 → 注册监听 → 已 established 则立即装配终端 */
  private adoptSession(info: TerminalSessionLike, host: HostProfile | null): void {
    if (host !== null) {
      this.lastHost = host;
    }
    const title: string = info.hostName.length > 0 ? info.hostName :
      (host === null ? '终端' : (host.name.length > 0 ? host.name : host.host));
    if (this.tabSet.tabs.length === 0) {
      const added = this.tabSet.addTab(title, TERMINAL_MAIN_PANE_ID);
      added.leaf.sessionId = info.sessionId;
      this.focusedPaneId = added.leaf.paneId;
      this.lastFocusByTab.set(added.tab.tabId, added.leaf.paneId);
      this.focusHost.register(added.leaf.paneId);
      this.focusHost.focus(added.leaf.paneId);
    } else {
      const leaf: PaneLeaf | null = this.tabSet.findLeaf(this.focusedPaneId);
      if (leaf !== null) {
        leaf.sessionId = info.sessionId;
      }
    }
    this.currentSessionId = info.sessionId;
    this.termTypes.set(info.sessionId, host === null ? DEFAULT_TERM_TYPE : host.termType);
    if (this.hostName.length === 0) {
      this.hostName = title;
    }
    this.registerListeners();
    const paneId: string = this.focusedPaneId.length > 0 ? this.focusedPaneId : TERMINAL_MAIN_PANE_ID;
    try {
      this.sessionHost().bindPane(info.sessionId, paneId);
    } catch (err) {
      // 窗格冲突属编程错误/旧实例泄漏：解监听后落错误蒙层，不把半绑定态带进页面
      this.unregisterListeners();
      this.releaseAllLeaves(false);
      this.currentSessionId = '';
      this.focusedPaneId = '';
      this.failStart(`终端窗格绑定失败：${err instanceof Error ? err.message : '未知原因'}`);
      return;
    }
    this.refreshSessionList();
    if (info.state === 'established') {
      this.ensureTerminalAttached(info.sessionId);
    }
    Logger.info(`已采用会话 state=${info.state}`, LOG_TAG);
    this.refreshViews();
  }

  private failStart(message: string): void {
    // 这里过去是静默的：用户看到错误蒙层，日志里却什么都没有，真机排查无从下手
    Logger.error(`终端页进入失败：${message}`, LOG_TAG);
    this.startError = message;
    this.refreshOverlay();
    this.refreshViews();
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
   * 切换到指定会话（抽屉点击）：
   *   - 已寄宿在某叶 → 激活其所在标签并聚焦该叶（不改绑定）；
   *   - 否则替换聚焦叶：unbind 旧（false，会话保留）→ bind 新。
   * 与当前聚焦相同或未知会话为 no-op。
   */
  switchSession(sessionId: string): void {
    if (this.disposed || sessionId === this.currentSessionId) {
      return;
    }
    const info: TerminalSessionLike | null = this.sessionHost().getSession(sessionId);
    if (info === null) {
      return;
    }
    const existing: PaneLeaf | null = this.tabSet.leafBySession(sessionId);
    if (existing !== null) {
      this.focusPane(existing.paneId);
      return;
    }
    const focused: PaneLeaf | null = this.tabSet.findLeaf(this.focusedPaneId);
    if (focused === null) {
      return;
    }
    const previousSessionId: string = focused.sessionId;
    const paneId: string = focused.paneId;
    this.sessionHost().unbindPane(paneId, false);
    try {
      this.sessionHost().bindPane(sessionId, paneId);
    } catch (err) {
      Logger.error(`会话切换绑定失败（${sessionId}）: ${JSON.stringify(err)}`, LOG_TAG);
      if (previousSessionId.length > 0) {
        try {
          this.sessionHost().bindPane(previousSessionId, paneId);
        } catch (restoreErr) {
          Logger.error(`恢复原窗格绑定失败: ${JSON.stringify(restoreErr)}`, LOG_TAG);
        }
      }
      return;
    }
    focused.sessionId = sessionId;
    this.currentSessionId = sessionId;
    this.hostName = info.hostName.length > 0 ? info.hostName : this.hostName;
    this.terminalTitle = '';
    this.closedBySession.set(sessionId, false);
    this.startError = '';
    const host: HostProfile | null = this.hostForSession(sessionId) ?? this.lookupHost(info.hostId);
    if (host !== null) {
      this.termTypes.set(sessionId, host.termType);
      this.lastHost = host;
    }
    const paneTab = this.tabSet.tabOfPane(paneId);
    if (paneTab !== null && paneTab.root.kind === 'leaf') {
      paneTab.title = host !== null
        ? (host.name.length > 0 ? host.name : host.host)
        : (info.hostName.length > 0 ? info.hostName : '终端');
    }
    const cached: AttachedTerminal | undefined = this.attachedTerminals.get(sessionId);
    this.terminal = cached === undefined ? null : cached.terminal;
    if (info.state === 'established') {
      this.ensureTerminalAttached(sessionId);
    }
    this.refreshViews();
  }

  // ---------------------------------------------------------------- 多标签 / 分屏

  /**
   * 新建一个独立的连接选择标签。这里故意不拨号：页面先在新标签内展示连接信息，
   * 用户选择服务器后再以 replace 模式把会话绑定到这片空叶，原标签保持不变。
   */
  openConnectionTab(): void {
    if (this.disposed) {
      return;
    }
    const added = this.tabSet.addTab('新连接');
    this.focusHost.register(added.leaf.paneId);
    this.focusedPaneId = added.leaf.paneId;
    this.lastFocusByTab.set(added.tab.tabId, added.leaf.paneId);
    this.focusHost.focus(added.leaf.paneId);
    this.hostName = '新连接';
    this.terminalTitle = '';
    this.startError = '';
    this.shouldExit = false;
    this.refreshHostList();
    this.refreshSessionList();
    this.refreshViews();
    this.dirtyHook();
  }

  /** 视口宽度 → 断点（树不动，只刷新可见矩形） */
  setViewportWidth(widthVp: number): void {
    if (this.disposed) {
      return;
    }
    const next: PaneBreakpoint = breakpointOfWidth(widthVp);
    if (next === this.breakpoint) {
      return;
    }
    this.breakpoint = next;
    this.refreshLayout();
  }

  /** 窗格区尺寸（vp）；0 面积也刷新快照，等页面 onAreaChange 校正 */
  setPaneAreaSize(widthVp: number, heightVp: number): void {
    if (this.disposed) {
      return;
    }
    const w: number = Math.max(0, widthVp);
    const h: number = Math.max(0, heightVp);
    if (w === this.areaWidthVp && h === this.areaHeightVp) {
      return;
    }
    this.areaWidthVp = w;
    this.areaHeightVp = h;
    Logger.info(`窗格区尺寸 ${w}x${h}`, LOG_TAG);
    this.refreshLayout();
  }

  /**
   * 拖分隔条：改 ratio 并走轻量几何快照路径。
   * forceSnapshot 只在松手时使用，确保亚像素内未改变矩形的最终 ratio 也进入公开快照。
   */
  setDividerRatio(splitId: string, ratio: number, forceSnapshot: boolean = false): void {
    if (this.disposed) {
      return;
    }
    if (this.tabSet.setRatio(splitId, ratio) !== null) {
      this.refreshDividerGeometry(forceSnapshot);
    }
  }

  /** 双窗格布局方向切换；不改叶、不重连，会话与终端实例原地保留。 */
  setActiveSplitDirection(direction: SplitDirection): void {
    if (this.disposed) {
      return;
    }
    const tab = this.tabSet.activeTab();
    if (tab === null || tab.root.kind !== 'split' || tab.root.direction === direction) {
      return;
    }
    tab.root.direction = direction;
    this.refreshLayout();
  }

  /** 聚焦指定叶（未知 id 为 no-op）；同步 FocusHost 与顶栏投影 */
  focusPane(paneId: string): void {
    if (this.disposed) {
      return;
    }
    const leaf: PaneLeaf | null = this.tabSet.findLeaf(paneId);
    if (leaf === null) {
      return;
    }
    const tab = this.tabSet.tabOfPane(paneId);
    if (tab !== null) {
      this.tabSet.activateTab(tab.tabId);
      this.lastFocusByTab.set(tab.tabId, paneId);
    }
    const changed: boolean = this.focusedPaneId !== paneId;
    this.focusedPaneId = paneId;
    this.focusHost.focus(paneId);
    this.terminalTitle = changed ? '' : this.terminalTitle;
    this.refreshViews();
    this.dirtyHook();
  }

  /** 激活标签（恢复该标签上次聚焦叶，否则首叶） */
  activateTab(tabId: string): void {
    if (this.disposed || !this.tabSet.activateTab(tabId)) {
      return;
    }
    const tab = this.tabSet.findTab(tabId);
    if (tab === null) {
      return;
    }
    const remembered: string | undefined = this.lastFocusByTab.get(tabId);
    const rememberedLeaf: PaneLeaf | null =
      remembered === undefined ? null : this.tabSet.findLeaf(remembered);
    if (rememberedLeaf !== null) {
      this.focusPane(rememberedLeaf.paneId);
      return;
    }
    const leaves: PaneLeaf[] = leavesOf(tab.root);
    if (leaves.length > 0) {
      this.focusPane(leaves[0].paneId);
    }
  }

  /** 连接选择面板：按保存的主机打开到聚焦窗格 / 新标签 / 左右或上下分屏。 */
  async openHost(hostId: string, mode: ConnectionOpenMode): Promise<void> {
    if (this.disposed) {
      return;
    }
    const host: HostProfile | null = this.lookupHost(hostId);
    if (host === null) {
      Logger.warn(`连接选择目标不存在（hostId=${hostId}）`, LOG_TAG);
      return;
    }
    await this.openHostProfile(host, mode);
  }

  /**
   * 连接选择面板：复用活跃会话。
   * replace 且已在某窗格 → 只聚焦（同一 PTY 不能绑两个窗格）；
   * 新标签 / 分屏 → 按同一主机再拨一路独立会话，允许同一连接开两次。
   */
  openSession(sessionId: string, mode: ConnectionOpenMode): void {
    if (this.disposed) {
      return;
    }
    const info: TerminalSessionLike | null = this.sessionHost().getSession(sessionId);
    if (info === null) {
      return;
    }
    const existing: PaneLeaf | null = this.tabSet.leafBySession(sessionId);
    if (existing !== null && mode === 'replace') {
      this.focusPane(existing.paneId);
      return;
    }
    if (existing !== null) {
      const host: HostProfile | null = this.hostForSession(sessionId) ?? this.lookupHost(info.hostId);
      if (host === null) {
        Logger.warn(`活跃会话缺少主机快照（sessionId=${sessionId}）`, LOG_TAG);
        return;
      }
      this.openHostProfile(host, mode).catch((err: Object) => {
        Logger.error(`同一主机再次打开失败: ${JSON.stringify(err)}`, LOG_TAG);
      });
      return;
    }
    const host: HostProfile | null = this.hostForSession(sessionId) ?? this.lookupHost(info.hostId);
    if (host === null) {
      Logger.warn(`活跃会话缺少主机快照（sessionId=${sessionId}）`, LOG_TAG);
      return;
    }
    this.placeSession(info, host, mode);
  }

  /**
   * 把源标签拖进当前画面成分屏。
   * 源标签就是当前标签：按聚焦叶主机再拨一路，实现「同一连接再开一次」。
   * 源是别的标签：摘下其窗格树接到当前根上，不关会话。
   */
  dockTabAsSplit(sourceTabId: string, direction: SplitDirection): void {
    if (this.disposed) {
      return;
    }
    const source = this.tabSet.findTab(sourceTabId);
    const target = this.tabSet.activeTab();
    if (source === null || target === null) {
      return;
    }
    if (source.tabId === target.tabId) {
      this.splitFocused(direction).catch((err: Object) => {
        Logger.error(`拖标签分屏（同标签再拨）失败: ${JSON.stringify(err)}`, LOG_TAG);
      });
      return;
    }
    const incoming = source.root;
    const incomingFocus: PaneLeaf | null = firstLeafOf(incoming);
    const removed = this.tabSet.closeTab(source.tabId);
    if (removed === null) {
      return;
    }
    this.lastFocusByTab.delete(source.tabId);
    if (this.tabSet.dockTree(target.tabId, incoming, direction) === null) {
      this.tabSet.tabs.push(removed);
      this.tabSet.activeTabId = target.tabId;
      return;
    }
    this.tabSet.activateTab(target.tabId);
    if (incomingFocus !== null) {
      this.focusPane(incomingFocus.paneId);
    } else {
      this.refreshViews();
    }
  }

  /** 新标签：保留原快捷键语义，默认仍按聚焦叶主机新拨一个独立会话。 */
  async newTab(): Promise<void> {
    const host: HostProfile | null = this.hostForFocused();
    if (this.disposed || host === null) {
      return;
    }
    await this.openHostProfile(host, 'tab');
  }

  /** 分屏快捷入口：保留原语义，按聚焦叶主机新拨会话。 */
  async splitFocused(direction: SplitDirection): Promise<void> {
    const host: HostProfile | null = this.hostForFocused();
    if (this.disposed || host === null) {
      return;
    }
    await this.openHostProfile(host, direction);
  }

  private async openHostProfile(host: HostProfile, mode: ConnectionOpenMode): Promise<void> {
    try {
      const info: TerminalSessionLike = await this.sessionHost().connect(host);
      if (this.disposed) {
        this.sessionHost().close(info.sessionId);
        return;
      }
      this.refreshSessionList();
      this.placeSession(info, host, mode);
    } catch (err) {
      const missingCredential: boolean =
        err instanceof SshError && err.code === SshErrorCode.CREDENTIAL_MISSING;
      if (missingCredential && host.authType === 'password') {
        this.showPasswordPrompt(host, mode, this.tabSet.tabs.length === 0, '', '');
        return;
      }
      Logger.error(`连接目标打开失败（mode=${mode}）: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /**
   * 当前窗格已有会话时，replace 升级为新标签，避免把旧连接顶掉。
   * 空的「新连接」选择页仍走 replace，把会话填进这片空叶。
   */
  private resolvePlacementMode(mode: ConnectionOpenMode): ConnectionOpenMode {
    if (mode !== 'replace') {
      return mode;
    }
    const focused: PaneLeaf | null = this.tabSet.findLeaf(this.focusedPaneId);
    if (focused === null || focused.sessionId.length === 0) {
      return 'replace';
    }
    return 'tab';
  }

  /** 把已受理会话放到目标位置；会话拨号与布局变更分离，失败时不会留下空白窗格。 */
  private placeSession(info: TerminalSessionLike, host: HostProfile, mode: ConnectionOpenMode): void {
    if (this.disposed) {
      this.sessionHost().close(info.sessionId);
      return;
    }
    if (this.tabSet.tabs.length === 0) {
      this.adoptSession(info, host);
      return;
    }
    const placement: ConnectionOpenMode = this.resolvePlacementMode(mode);
    if (placement === 'replace') {
      this.switchSession(info.sessionId);
      return;
    }
    const title: string = host.name.length > 0 ? host.name : host.host;
    if (placement === 'tab') {
      const added = this.tabSet.addTab(title);
      this.focusHost.register(added.leaf.paneId);
      this.focusedPaneId = added.leaf.paneId;
      this.lastFocusByTab.set(added.tab.tabId, added.leaf.paneId);
      this.focusHost.focus(added.leaf.paneId);
      this.bindLeafSession(added.leaf, info, host);
      this.focusPane(added.leaf.paneId);
      return;
    }
    const focused: PaneLeaf | null = this.tabSet.findLeaf(this.focusedPaneId);
    if (focused === null) {
      this.sessionHost().close(info.sessionId);
      return;
    }
    const newLeaf: PaneLeaf = createPaneLeaf(this.tabSet.newPaneId());
    if (this.tabSet.splitLeaf(focused.paneId, placement, newLeaf) === null) {
      this.sessionHost().close(info.sessionId);
      return;
    }
    this.focusHost.register(newLeaf.paneId);
    this.bindLeafSession(newLeaf, info, host);
    this.focusPane(newLeaf.paneId);
  }

  /** 关闭聚焦叶（末叶则 shouldExit） */
  closeFocusedPane(): void {
    this.closePane(this.focusedPaneId);
  }

  /** 关闭指定叶：unbind+关会话、兄弟上提、焦点按 nextFocusAfterClose */
  closePane(paneId: string): void {
    if (this.disposed || paneId.length === 0) {
      return;
    }
    const leaf: PaneLeaf | null = this.tabSet.findLeaf(paneId);
    if (leaf === null) {
      return;
    }
    const result = this.tabSet.closeLeaf(paneId);
    if (result === null) {
      return;
    }
    this.releaseLeafResources(leaf, true);
    this.lastFocusByTab.delete(result.tabId);
    if (result.nextFocusPaneId.length > 0) {
      const next: PaneLeaf | null = this.tabSet.findLeaf(result.nextFocusPaneId);
      if (next !== null) {
        const nextTab = this.tabSet.tabOfPane(next.paneId);
        if (nextTab !== null) {
          this.lastFocusByTab.set(nextTab.tabId, next.paneId);
        }
        this.focusedPaneId = next.paneId;
        this.focusHost.focus(next.paneId);
      }
    } else {
      this.focusedPaneId = '';
      this.currentSessionId = '';
      this.terminal = null;
      this.shouldExit = this.tabSet.tabs.length === 0;
    }
    this.refreshViews();
  }

  /** 关闭整标签（先释放全部叶会话）；关末标签则 shouldExit */
  closeTab(tabId: string): void {
    if (this.disposed) {
      return;
    }
    const tab = this.tabSet.findTab(tabId);
    if (tab === null) {
      return;
    }
    const leaves: PaneLeaf[] = leavesOf(tab.root);
    for (const leaf of leaves) {
      this.releaseLeafResources(leaf, true);
    }
    this.tabSet.closeTab(tabId);
    this.lastFocusByTab.delete(tabId);
    const active = this.tabSet.activeTab();
    if (active === null) {
      this.focusedPaneId = '';
      this.currentSessionId = '';
      this.terminal = null;
      this.shouldExit = true;
    } else {
      const remembered: string | undefined = this.lastFocusByTab.get(active.tabId);
      const rememberedLeaf: PaneLeaf | null =
        remembered === undefined ? null : this.tabSet.findLeaf(remembered);
      const nextLeaves: PaneLeaf[] = leavesOf(active.root);
      const next: PaneLeaf | null = rememberedLeaf !== null ? rememberedLeaf :
        (nextLeaves.length > 0 ? nextLeaves[0] : null);
      if (next !== null) {
        this.focusedPaneId = next.paneId;
        this.focusHost.focus(next.paneId);
      }
    }
    this.refreshViews();
  }

  /** 全标签叶子数（单测断言树保活用） */
  leafCount(): number {
    return this.tabSet.allLeaves().length;
  }

  /**
   * 应用快捷键入口（画布命中后转发；复制/粘贴由画布自己处理）。
   * 一律视为已消费：即使该方向没有邻居，也不把组合键送给远端。
   */
  handleShortcut(action: string): boolean {
    if (this.disposed) {
      return false;
    }
    switch (action) {
      case 'newTab':
        this.newTab().catch((err: Object) => {
          Logger.error(`快捷键新标签失败: ${JSON.stringify(err)}`, LOG_TAG);
        });
        return true;
      case 'closePane':
        this.closeFocusedPane();
        return true;
      case 'closeTab':
        if (this.activeTabId.length > 0) {
          this.closeTab(this.activeTabId);
        }
        return true;
      case 'nextTab':
        this.cycleTab(1);
        return true;
      case 'prevTab':
        this.cycleTab(-1);
        return true;
      case 'splitRow':
        this.splitFocused('row').catch((err: Object) => {
          Logger.error(`快捷键左右分屏失败: ${JSON.stringify(err)}`, LOG_TAG);
        });
        return true;
      case 'splitColumn':
        this.splitFocused('column').catch((err: Object) => {
          Logger.error(`快捷键上下分屏失败: ${JSON.stringify(err)}`, LOG_TAG);
        });
        return true;
      case 'focusLeft':
        this.focusInDirection('left');
        return true;
      case 'focusRight':
        this.focusInDirection('right');
        return true;
      case 'focusUp':
        this.focusInDirection('up');
        return true;
      case 'focusDown':
        this.focusInDirection('down');
        return true;
      case 'copy':
      case 'paste':
        return false;
      default:
        return false;
    }
  }

  /** 循环切标签（delta = +1 下一个 / -1 上一个） */
  cycleTab(delta: number): void {
    if (this.disposed || this.tabSet.tabs.length === 0) {
      return;
    }
    let index: number = 0;
    for (let i = 0; i < this.tabSet.tabs.length; i++) {
      if (this.tabSet.tabs[i].tabId === this.tabSet.activeTabId) {
        index = i;
        break;
      }
    }
    const count: number = this.tabSet.tabs.length;
    const next: number = ((index + delta) % count + count) % count;
    this.activateTab(this.tabSet.tabs[next].tabId);
  }

  /** 按布局矩形把焦点移到 direction 上最近的邻居（无邻居则焦点不动） */
  focusInDirection(direction: PaneFocusDirection): void {
    if (this.disposed) {
      return;
    }
    const tab = this.tabSet.activeTab();
    if (tab === null) {
      return;
    }
    const width: number = this.areaWidthVp > 0 ? this.areaWidthVp : 1000;
    const height: number = this.areaHeightVp > 0 ? this.areaHeightVp : 600;
    const layout = layoutPaneTree(tab.root, width, height, PANE_DIVIDER_SIZE_VP);
    const nextId: string = neighborLeafInDirection(layout.leaves, this.focusedPaneId, direction);
    if (nextId.length > 0) {
      this.focusPane(nextId);
    }
  }

  // ---------------------------------------------------------------- 重连控制（转发 C4）

  /** 「立即重连」（error 蒙层）：作用于聚焦会话 */
  reconnectNow(): void {
    this.reconnectNowAt(this.currentSessionId);
  }

  reconnectNowAt(sessionId: string): void {
    if (this.disposed || sessionId.length === 0) {
      return;
    }
    if (this.sessionHost().reconnectNow(sessionId)) {
      this.closedBySession.set(sessionId, false);
      this.refreshViews();
    }
  }

  /** 「取消重连」（倒计时蒙层）：停掉自动重连，会话保持断开待用户抉择 */
  cancelAutoReconnect(): void {
    this.cancelAutoReconnectAt(this.currentSessionId);
  }

  cancelAutoReconnectAt(sessionId: string): void {
    if (this.disposed || sessionId.length === 0) {
      return;
    }
    if (this.sessionHost().cancelAutoReconnect(sessionId)) {
      this.refreshViews();
    }
  }

  // ---------------------------------------------------------------- 输入出口（T7 键条）

  /**
   * 外部字节写聚焦终端（KeyBar onSendBytes 出口）：Uint8Array → 零偏移全量
   * ArrayBuffer（与 TerminalCanvas.sendInputBytes 同口径）。this.terminal 始终
   * 投影聚焦叶，多窗格下键条只打聚焦会话。
   */
  sendInput(bytes: Uint8Array): void {
    const terminal: TerminalLike | null = this.terminal;
    if (this.disposed || terminal === null || bytes.length === 0) {
      return;
    }
    // 键条不经过 TerminalCanvas.sendInputBytes，同样要在写入前预热全局帧循环。
    this.dirtyHook();
    const accepted: boolean =
      terminal.write(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    if (!accepted) {
      Logger.warn(`键条输入未被终端通道受理（bytes=${bytes.length}）`, LOG_TAG);
    }
  }

  // ---------------------------------------------------------------- 退出

  /**
   * 页面退出（幂等）：注销监听 → detach 全部缓存终端 → 所有叶 unbindPane(true)。
   * 「返回列表即断连」；会话保留/后台保活归 §7.5。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.unsubFocus();
    this.unregisterListeners();
    this.attachedTerminals.forEach((entry: AttachedTerminal) => {
      entry.terminal.detach();
    });
    this.attachedTerminals.clear();
    this.terminal = null;
    this.releaseAllLeaves(true);
    this.tabSet.clear();
    this.focusedPaneId = '';
    this.currentSessionId = '';
  }

  // ---------------------------------------------------------------- 事件分发

  private onSessionEvent(session: TerminalSessionLike, event: SshEvent): void {
    if (this.disposed) {
      return;
    }
    // 终端字节流已在 native 内完成 feed/publish；terminalData 只用于唤醒帧调度器，
    // 不应为每个数据块重建标签、窗格与蒙层。对应 dirtyListener 会紧接着执行。
    if (event.type === 'terminalData') {
      return;
    }
    this.refreshSessionList();
    const inTree: boolean = this.tabSet.leafBySession(session.sessionId) !== null;
    if (!inTree) {
      return;
    }
    const focused: boolean = session.sessionId === this.currentSessionId;
    switch (event.type) {
      case 'stateChange':
        if (event.to === 'established') {
          this.closedBySession.set(session.sessionId, false);
          this.ensureTerminalAttached(session.sessionId);
          if (focused) {
            this.vibrateHook();
          }
        } else if (event.to === 'closed') {
          this.closedBySession.set(session.sessionId, true);
        } else if (event.to === 'error' || event.to === 'disconnected') {
          this.maybePromptPasswordAfterAuthFailure(session, event);
        }
        break;
      case 'terminalOpen':
        this.closedBySession.set(session.sessionId, false);
        break;
      case 'terminalClose':
        this.closedBySession.set(session.sessionId, true);
        break;
      case 'terminalTitle':
        if (focused) {
          this.terminalTitle = event.title ?? '';
        }
        break;
      case 'terminalBell':
        if (focused) {
          this.vibrateHook();
        }
        break;
      default:
        break;
    }
    this.refreshViews();
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
        this.terminal = existing.terminal;
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
      this.terminal = created;
    }
  }

  // ---------------------------------------------------------------- 内部：绑定 / 释放 / 投影

  private bindLeafSession(leaf: PaneLeaf, info: TerminalSessionLike, host: HostProfile): void {
    leaf.sessionId = info.sessionId;
    this.termTypes.set(info.sessionId, host.termType);
    this.lastHost = host;
    try {
      this.sessionHost().bindPane(info.sessionId, leaf.paneId);
    } catch (err) {
      Logger.error(`窗格绑定失败（${leaf.paneId}）: ${JSON.stringify(err)}`, LOG_TAG);
      this.sessionHost().close(info.sessionId);
      this.closePane(leaf.paneId);
      return;
    }
    this.registerListeners();
    if (info.state === 'established') {
      this.ensureTerminalAttached(info.sessionId);
    }
    const tab = this.tabSet.tabOfPane(leaf.paneId);
    if (tab !== null && tab.title.length === 0) {
      tab.title = info.hostName.length > 0 ? info.hostName : host.host;
    }
  }

  private releaseLeafResources(leaf: PaneLeaf, closeSession: boolean): void {
    this.focusHost.unregister(leaf.paneId);
    if (leaf.sessionId.length === 0) {
      return;
    }
    if (closeSession) {
      const cached: AttachedTerminal | undefined = this.attachedTerminals.get(leaf.sessionId);
      if (cached !== undefined) {
        cached.terminal.detach();
        this.attachedTerminals.delete(leaf.sessionId);
      }
      this.closedBySession.delete(leaf.sessionId);
    }
    this.sessionHost().unbindPane(leaf.paneId, closeSession);
  }

  private releaseAllLeaves(closeSession: boolean): void {
    const leaves: PaneLeaf[] = this.tabSet.allLeaves();
    for (const leaf of leaves) {
      this.focusHost.unregister(leaf.paneId);
      this.sessionHost().unbindPane(leaf.paneId, closeSession);
    }
  }

  private hostForSession(sessionId: string): HostProfile | null {
    if (sessionId.length === 0) {
      return null;
    }
    const fromHost: HostProfile | null = this.sessionHost().hostOf(sessionId);
    if (fromHost !== null) {
      return fromHost;
    }
    const info: TerminalSessionLike | null = this.sessionHost().getSession(sessionId);
    if (info === null) {
      return null;
    }
    return this.lookupHost(info.hostId);
  }

  private hostForFocused(): HostProfile | null {
    const leaf: PaneLeaf | null = this.tabSet.findLeaf(this.focusedPaneId);
    if (leaf !== null) {
      const host: HostProfile | null = this.hostForSession(leaf.sessionId);
      if (host !== null) {
        return host;
      }
    }
    return this.lastHost;
  }

  private isSessionVisible(sessionId: string): boolean {
    for (const pane of this.visiblePanes) {
      if (pane.sessionId === sessionId) {
        return true;
      }
    }
    return false;
  }

  private onExternalFocus(id: string): void {
    if (this.disposed || id.length === 0 || id === this.focusedPaneId) {
      return;
    }
    if (this.tabSet.findLeaf(id) === null) {
      return;
    }
    const tab = this.tabSet.tabOfPane(id);
    if (tab !== null) {
      this.tabSet.activateTab(tab.tabId);
      this.lastFocusByTab.set(tab.tabId, id);
    }
    this.focusedPaneId = id;
    this.terminalTitle = '';
    this.refreshViews();
  }

  // ---------------------------------------------------------------- 内部：状态刷新与依赖解析

  private notifyUi(): void {
    this.uiHook();
  }

  private refreshViews(): void {
    this.refreshTabs();
    this.refreshFocusedProjection();
    this.refreshLayout(false);
    this.notifyUi();
  }

  private refreshTabs(): void {
    const items: TabRenderItem[] = [];
    for (const tab of this.tabSet.tabs) {
      const item: TabRenderItem = {
        tabId: tab.tabId,
        title: tab.title.length > 0 ? tab.title : '终端',
        active: tab.tabId === this.tabSet.activeTabId
      };
      items.push(item);
    }
    this.tabs = items;
    this.activeTabId = this.tabSet.activeTabId;
  }

  private refreshFocusedProjection(): void {
    const leaf: PaneLeaf | null =
      this.focusedPaneId.length > 0 ? this.tabSet.findLeaf(this.focusedPaneId) : null;
    if (leaf === null) {
      this.currentSessionId = '';
      this.terminal = null;
      this.refreshOverlay();
      return;
    }
    this.currentSessionId = leaf.sessionId;
    if (leaf.sessionId.length === 0) {
      this.terminal = null;
      this.hostName = '新连接';
      this.terminalTitle = '';
      this.sessionState = '';
      this.overlay = NO_OVERLAY;
      return;
    }
    const cached: AttachedTerminal | undefined =
      leaf.sessionId.length > 0 ? this.attachedTerminals.get(leaf.sessionId) : undefined;
    this.terminal = cached === undefined ? null : cached.terminal;
    const info: TerminalSessionLike | null =
      leaf.sessionId.length > 0 ? this.sessionHost().getSession(leaf.sessionId) : null;
    if (info !== null && info.hostName.length > 0) {
      this.hostName = info.hostName;
    }
    this.refreshOverlay();
  }

  /**
   * 拖动专用的热路径：只重算树的矩形并复用现有窗格业务快照。
   *
   * 常规 refreshLayout 会为每个输入采样重新查询 SessionHost / HostDao、重建主机名、
   * endpoint 与 overlay；这些字段拖动时完全不变。这里把开销收敛为一次纯布局和两个
   * 小对象复制，并在 floor 后几何未跨过 1vp 时不通知 UI。
   */
  private refreshDividerGeometry(forceSnapshot: boolean): void {
    const tab = this.tabSet.activeTab();
    if (tab === null) {
      this.refreshLayout();
      return;
    }
    const layout: PaneLayout = layoutVisibleTree(tab.root, this.focusedPaneId, this.breakpoint,
      this.areaWidthVp, this.areaHeightVp, PANE_DIVIDER_SIZE_VP);
    if (layout.leaves.length !== this.visiblePanes.length) {
      this.refreshLayout();
      return;
    }

    const currentPanes: PaneRenderItem[] = [];
    let geometryChanged: boolean = layout.dividers.length !== this.dividers.length;
    for (const rect of layout.leaves) {
      let current: PaneRenderItem | null = null;
      for (const item of this.visiblePanes) {
        if (item.paneId === rect.paneId) {
          current = item;
          break;
        }
      }
      if (current === null) {
        this.refreshLayout();
        return;
      }
      if (current.x !== rect.x || current.y !== rect.y ||
        current.w !== rect.w || current.h !== rect.h) {
        geometryChanged = true;
      }
      currentPanes.push(current);
    }

    if (!geometryChanged) {
      for (let i = 0; i < layout.dividers.length; i++) {
        if (!this.sameDividerGeometry(this.dividers[i], layout.dividers[i])) {
          geometryChanged = true;
          break;
        }
      }
    }
    if (!geometryChanged && !forceSnapshot) {
      return;
    }
    const panes: PaneRenderItem[] = [];
    for (let i = 0; i < layout.leaves.length; i++) {
      panes.push(this.copyPaneWithRect(currentPanes[i], layout.leaves[i]));
    }
    this.visiblePanes = panes;
    this.dividers = layout.dividers;
    this.notifyUi();
  }

  private copyPaneWithRect(current: PaneRenderItem, rect: PaneRect): PaneRenderItem {
    const item: PaneRenderItem = {
      paneId: current.paneId,
      sessionId: current.sessionId,
      connectionPicker: current.connectionPicker,
      hostId: current.hostId,
      hostName: current.hostName,
      endpoint: current.endpoint,
      state: current.state,
      terminal: current.terminal,
      overlay: current.overlay,
      x: rect.x,
      y: rect.y,
      w: rect.w,
      h: rect.h,
      focused: current.focused
    };
    return item;
  }

  /** ratio 故意不参与比较：同一像素内的输入采样无需触发 ArkUI 重排。 */
  private sameDividerGeometry(current: DividerRect, next: DividerRect): boolean {
    return current.splitId === next.splitId && current.direction === next.direction &&
      current.x === next.x && current.y === next.y && current.w === next.w &&
      current.h === next.h && current.span === next.span;
  }

  private refreshLayout(notify: boolean = true): void {
    const tab = this.tabSet.activeTab();
    if (tab === null) {
      this.visiblePanes = [];
      this.dividers = [];
      if (notify) {
        this.notifyUi();
      }
      return;
    }
    const layout = layoutVisibleTree(tab.root, this.focusedPaneId, this.breakpoint,
      this.areaWidthVp, this.areaHeightVp, PANE_DIVIDER_SIZE_VP);
    const panes: PaneRenderItem[] = [];
    for (const rect of layout.leaves) {
      const leaf: PaneLeaf | null = this.tabSet.findLeaf(rect.paneId);
      const sessionId: string = leaf === null ? '' : leaf.sessionId;
      const connectionPicker: boolean = leaf !== null && sessionId.length === 0;
      const cached: AttachedTerminal | undefined =
        sessionId.length > 0 ? this.attachedTerminals.get(sessionId) : undefined;
      const term: TerminalLike | null = cached === undefined ? null : cached.terminal;
      const info: TerminalSessionLike | null =
        sessionId.length > 0 ? this.sessionHost().getSession(sessionId) : null;
      const host: HostProfile | null = sessionId.length > 0 ? this.hostForSession(sessionId) : null;
      const paneHostId: string = host !== null ? host.id : (info === null ? '' : info.hostId);
      const paneHostName: string = host !== null
        ? (host.name.length > 0 ? host.name : host.host)
        : (info !== null && info.hostName.length > 0 ? info.hostName :
          (connectionPicker ? '新连接' : '终端'));
      const endpoint: string = host === null ? '' :
        `${host.username}@${host.host}${host.port === 22 ? '' : `:${host.port}`}`;
      const item: PaneRenderItem = {
        paneId: rect.paneId,
        sessionId: sessionId,
        connectionPicker: connectionPicker,
        hostId: paneHostId,
        hostName: paneHostName,
        endpoint: endpoint,
        state: info === null ? '' : info.state,
        terminal: term,
        overlay: connectionPicker ? NO_OVERLAY : this.overlayForSession(sessionId, term !== null),
        x: rect.x,
        y: rect.y,
        w: rect.w,
        h: rect.h,
        focused: rect.paneId === this.focusedPaneId
      };
      panes.push(item);
    }
    this.visiblePanes = panes;
    this.dividers = layout.dividers;
    if (notify) {
      this.notifyUi();
    }
  }

  private overlayForSession(sessionId: string, hasTerminal: boolean): OverlayModel {
    if (this.startError.length > 0 && this.tabSet.tabs.length === 0) {
      return deriveOverlay({
        state: '',
        reconnectCountdownSec: 0,
        reconnectAttempt: 0,
        errorMessage: '',
        hasTerminal: false,
        terminalClosed: false,
        startError: this.startError
      });
    }
    const info: TerminalSessionLike | null =
      sessionId.length > 0 ? this.sessionHost().getSession(sessionId) : null;
    const closed: boolean = sessionId.length > 0 && this.closedBySession.get(sessionId) === true;
    return deriveOverlay({
      state: info === null ? '' : info.state,
      reconnectCountdownSec: info === null ? 0 : info.reconnectCountdownSec,
      reconnectAttempt: info === null ? 0 : info.reconnectAttempt,
      errorMessage: info === null ? '' : info.errorMessage,
      hasTerminal: hasTerminal,
      terminalClosed: closed,
      startError: ''
    });
  }

  private refreshOverlay(): void {
    const info: TerminalSessionLike | null =
      this.currentSessionId.length > 0 ? this.sessionHost().getSession(this.currentSessionId) : null;
    this.sessionState = info === null ? '' : info.state;
    const closed: boolean = this.currentSessionId.length > 0 &&
      this.closedBySession.get(this.currentSessionId) === true;
    this.overlay = deriveOverlay({
      state: this.sessionState,
      reconnectCountdownSec: info === null ? 0 : info.reconnectCountdownSec,
      reconnectAttempt: info === null ? 0 : info.reconnectAttempt,
      errorMessage: info === null ? '' : info.errorMessage,
      hasTerminal: this.terminal !== null,
      terminalClosed: closed,
      startError: this.startError
    });
  }

  private refreshSessionList(): void {
    this.sessionList = this.sessionHost().listSessions();
  }

  private refreshHostList(): void {
    try {
      this.hostList = this.hostDao().listAll();
    } catch (err) {
      Logger.warn(`主机列表读取失败，连接选择仅显示活跃会话：${JSON.stringify(err)}`, LOG_TAG);
      this.hostList = [];
    }
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
