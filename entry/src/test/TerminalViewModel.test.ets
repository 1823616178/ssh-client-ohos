/**
 * TerminalViewModel 单元测试（任务 U4）。
 *
 * 注入形态（对齐 C4 SessionManager.test 的 fake 模式）：
 *   - FakeSessionHost：TerminalSessionHostLike 的可脚本化实现（会话表手工维护、
 *     native 句柄表可换、emit/emitDirty 手动投递、bind/unbind/connect/close/重连
 *     全部记入 ops 日志供次序断言）；
 *   - FakeFactory：TerminalFactory fake（attach 参数全记录，产出 FakeTerminal，
 *     attach 日志与宿主 ops 共用同一数组以断言「unbind → bind → attach」次序）；
 *   - FakeHostDao：TerminalHostDaoLike 内存表；
 *   - vibrate / onContentDirty 钩子计数。
 *
 * 覆盖：deriveOverlay 状态叠加层派生（九种 state × 重连计数字段 → 蒙层形态与文案）/
 * 路由参数解析（hostId/sessionId/同传/非法）/ hostId 进入全流程 / sessionId 复用 /
 * 会话切换换绑序列（unbind→bind→attach 次序、切回复用缓存终端）/ 重连换柄后
 * terminal 换绑（旧 detach 新 attach 各一次）/ dispose 幂等（unbind closeSession=true
 * 恰好一次、终端全 detach）/ terminalTitle/bell 派生与非当前会话忽略 / dirty 通路 /
 * 手动重连与取消转发 / sendInput 字节出口 /
 * U4b：首标签 terminal-main / 分屏再拨号与关叶兄弟上提 / 新标签 /
 * 抽屉切到已寄宿会话只聚焦不换绑 / dirty 可见非聚焦叶仍唤醒 /
 * 拖分隔条改矩形 / lg→sm→lg 树与会话保活 / 关末叶 shouldExit /
 * dispose 解绑全部叶。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HostProfile, createDefaultHostProfile } from '../main/ets/common/model/models';
import { SshEvent } from '../main/ets/napi/SshNative';
import {
  NativeSessionHandleLike,
  OverlayInput,
  OverlayModel,
  TERMINAL_MAIN_PANE_ID,
  TerminalFactory,
  TerminalHostDaoLike,
  TerminalLike,
  TerminalRouteParams,
  TerminalSessionEventListener,
  TerminalSessionHostLike,
  TerminalSessionLike,
  TerminalViewModel,
  deriveOverlay,
  parseTerminalRouteParams
} from '../main/ets/viewmodel/TerminalViewModel';

// ---------- fake：native 会话句柄 ----------

class FakeHandle implements NativeSessionHandleLike {
  readonly nativeHandle: number;

  constructor(handle: number) {
    this.nativeHandle = handle;
  }
}

// ---------- fake：终端 ----------

class FakeTerminal implements TerminalLike {
  detachCount: number = 0;
  writeCount: number = 0;
  lastWriteBytes: number = -1;
  resizeCount: number = 0;

  write(data: ArrayBuffer | string): boolean {
    this.writeCount++;
    this.lastWriteBytes = typeof data === 'string' ? data.length : data.byteLength;
    return true;
  }

  resize(cols: number, rows: number): boolean {
    this.resizeCount++;
    return true;
  }

  detach(): void {
    this.detachCount++;
  }
}

class FakeFactory {
  readonly terminals: FakeTerminal[] = [];
  /** attach 参数日志（与宿主 ops 同数组，断言跨对象次序） */
  readonly ops: string[] = [];

  readonly factory: TerminalFactory =
    (session: NativeSessionHandleLike, termType: string, cols: number,
      rows: number): TerminalLike | null => {
      this.ops.push(`attach:${session.nativeHandle}:${termType}:${cols}x${rows}`);
      const terminal: FakeTerminal = new FakeTerminal();
      this.terminals.push(terminal);
      return terminal;
    };
}

// ---------- fake：会话宿主 ----------

class FakeSessionInfo implements TerminalSessionLike {
  readonly sessionId: string;
  readonly hostId: string;
  readonly hostName: string;
  state: string = 'connecting';
  errorMessage: string = '';
  reconnectAttempt: number = 0;
  reconnectCountdownSec: number = 0;

  constructor(sessionId: string, hostId: string, hostName: string) {
    this.sessionId = sessionId;
    this.hostId = hostId;
    this.hostName = hostName;
  }
}

class FakeSessionHost implements TerminalSessionHostLike {
  readonly factory: FakeFactory = new FakeFactory();
  private readonly byId: Map<string, FakeSessionInfo> = new Map();
  private readonly order: string[] = [];
  private readonly handles: Map<string, NativeSessionHandleLike> = new Map();
  private readonly eventListeners: TerminalSessionEventListener[] = [];
  private readonly dirtyListeners: ((sessionId: string) => void)[] = [];
  /** 操作序列日志（bind/unbind/close/attach 全进同一数组，次序断言用） */
  get ops(): string[] {
    return this.factory.ops;
  }

  connectCalls: HostProfile[] = [];
  reconnectNowLog: string[] = [];
  cancelLog: string[] = [];
  connectError: Error | null = null;
  private idSeq: number = 0;
  private readonly hostsBySession: Map<string, HostProfile> = new Map();

  /** 测试脚本入口：登记一个既有会话（可指定状态与 native 句柄） */
  addSession(sessionId: string, hostId: string, hostName: string, state: string,
    handle: number | null): FakeSessionInfo {
    const info: FakeSessionInfo = new FakeSessionInfo(sessionId, hostId, hostName);
    info.state = state;
    this.byId.set(sessionId, info);
    this.order.push(sessionId);
    if (handle !== null) {
      this.handles.set(sessionId, new FakeHandle(handle));
    }
    return info;
  }

  /** 测试脚本入口：换 native 句柄（模拟 C4 重连「sessionId 不变、句柄换新」） */
  swapHandle(sessionId: string, handle: number): void {
    this.handles.set(sessionId, new FakeHandle(handle));
  }

  connect(host: HostProfile): Promise<TerminalSessionLike> {
    this.connectCalls.push(host);
    if (this.connectError !== null) {
      return Promise.reject(this.connectError);
    }
    this.idSeq++;
    const info: FakeSessionInfo = this.addSession(`s-new-${this.idSeq}`, host.id,
      host.name.length > 0 ? host.name : host.host, 'connecting', 100 + this.idSeq);
    this.hostsBySession.set(info.sessionId, host);
    return Promise.resolve(info);
  }

  hostOf(sessionId: string): HostProfile | null {
    const host: HostProfile | undefined = this.hostsBySession.get(sessionId);
    return host === undefined ? null : host;
  }

  close(sessionId: string): void {
    this.factory.ops.push(`close:${sessionId}`);
    const info: FakeSessionInfo | undefined = this.byId.get(sessionId);
    if (info !== undefined) {
      info.state = 'closed';
    }
  }

  getSession(sessionId: string): TerminalSessionLike | null {
    const info: FakeSessionInfo | undefined = this.byId.get(sessionId);
    return info === undefined ? null : info;
  }

  listSessions(): TerminalSessionLike[] {
    const result: TerminalSessionLike[] = [];
    for (const id of this.order) {
      const info: FakeSessionInfo | undefined = this.byId.get(id);
      if (info !== undefined) {
        result.push(info);
      }
    }
    return result;
  }

  bindPane(sessionId: string, paneId: string): void {
    this.factory.ops.push(`bind:${sessionId}:${paneId}`);
  }

  unbindPane(paneId: string, closeSession: boolean): void {
    this.factory.ops.push(`unbind:${paneId}:${closeSession}`);
  }

  nativeSessionOf(sessionId: string): NativeSessionHandleLike | null {
    const handle: NativeSessionHandleLike | undefined = this.handles.get(sessionId);
    return handle === undefined ? null : handle;
  }

  reconnectNow(sessionId: string): boolean {
    this.reconnectNowLog.push(sessionId);
    const info: FakeSessionInfo | undefined = this.byId.get(sessionId);
    if (info !== undefined) {
      info.state = 'connecting';
      info.reconnectCountdownSec = 0;
    }
    return true;
  }

  cancelAutoReconnect(sessionId: string): boolean {
    this.cancelLog.push(sessionId);
    const info: FakeSessionInfo | undefined = this.byId.get(sessionId);
    if (info !== undefined) {
      info.reconnectCountdownSec = 0;
    }
    return true;
  }

  addEventListener(listener: TerminalSessionEventListener): void {
    this.eventListeners.push(listener);
  }

  removeEventListener(listener: TerminalSessionEventListener): void {
    const index: number = this.eventListeners.indexOf(listener);
    if (index >= 0) {
      this.eventListeners.splice(index, 1);
    }
  }

  addDirtyListener(listener: (sessionId: string) => void): void {
    this.dirtyListeners.push(listener);
  }

  removeDirtyListener(listener: (sessionId: string) => void): void {
    const index: number = this.dirtyListeners.indexOf(listener);
    if (index >= 0) {
      this.dirtyListeners.splice(index, 1);
    }
  }

  /** 测试脚本入口：投递会话事件（stateChange 同步刷新 fake 状态，镜像 C4 行为） */
  emit(sessionId: string, event: SshEvent): void {
    const info: FakeSessionInfo | undefined = this.byId.get(sessionId);
    if (info === undefined) {
      return;
    }
    if (event.type === 'stateChange' && event.to !== undefined) {
      info.state = event.to;
      if (event.to === 'established') {
        info.reconnectAttempt = 0;
        info.reconnectCountdownSec = 0;
        info.errorMessage = '';
      }
    }
    for (const listener of this.eventListeners) {
      listener(info, event);
    }
  }

  emitDirty(sessionId: string): void {
    for (const listener of this.dirtyListeners) {
      listener(sessionId);
    }
  }
}

// ---------- fake：主机 DAO ----------

class FakeHostDao implements TerminalHostDaoLike {
  private readonly byId: Map<string, HostProfile> = new Map();

  put(host: HostProfile): void {
    this.byId.set(host.id, host);
  }

  getById(id: string): HostProfile | null {
    const host: HostProfile | undefined = this.byId.get(id);
    return host === undefined ? null : host;
  }
}

// ---------- 测试环境 ----------

class TestEnv {
  readonly host: FakeSessionHost = new FakeSessionHost();
  readonly dao: FakeHostDao = new FakeHostDao();
  vibrateCount: number = 0;
  dirtyCount: number = 0;
  readonly vm: TerminalViewModel;

  constructor() {
    this.vm = new TerminalViewModel({
      sessionHost: this.host,
      hostDao: this.dao,
      terminalFactory: this.host.factory.factory,
      vibrate: (): void => {
        this.vibrateCount++;
      },
      onContentDirty: (): void => {
        this.dirtyCount++;
      }
    });
  }
}

function sampleHost(id: string): HostProfile {
  const host: HostProfile = createDefaultHostProfile(id);
  host.name = `主机${id}`;
  host.host = '192.168.1.10';
  host.username = 'root';
  host.termType = 'xterm-256color';
  return host;
}

function overlayInput(state: string): OverlayInput {
  return {
    state: state,
    reconnectCountdownSec: 0,
    reconnectAttempt: 0,
    errorMessage: '',
    hasTerminal: false,
    terminalClosed: false,
    startError: ''
  };
}

function stateChange(to: string): SshEvent {
  const event: SshEvent = { type: 'stateChange', to: to };
  return event;
}

export default function terminalViewModelTest() {
  describe('TerminalViewModelTest', () => {

    it('蒙层派生_九种状态与重连计数的形态与文案', 0, () => {
      // 启动失败：startError 优先于一切
      const withStartError: OverlayInput = {
        state: '', reconnectCountdownSec: 0, reconnectAttempt: 0, errorMessage: '',
        hasTerminal: false, terminalClosed: false, startError: '主机不存在或已被删除'
      };
      let o: OverlayModel = deriveOverlay(withStartError);
      expect(o.kind).assertEqual('error');
      expect(o.dimmed).assertFalse();
      expect(o.detail).assertEqual('主机不存在或已被删除');
      expect(o.showClose).assertTrue();
      expect(o.showReconnectNow).assertFalse();

      // '' / idle / connecting / handshaking / authenticating → connecting（无画面不置灰）
      const connectingStates: string[] = ['', 'idle', 'connecting', 'handshaking', 'authenticating'];
      for (const state of connectingStates) {
        o = deriveOverlay(overlayInput(state));
        expect(o.kind).assertEqual('connecting');
        expect(o.dimmed).assertFalse();
        expect(o.title).assertEqual('正在连接…');
        expect(o.showCancelReconnect).assertFalse();
        expect(o.showReconnectNow).assertFalse();
        expect(o.showClose).assertFalse();
      }
      expect(deriveOverlay(overlayInput('connecting')).detail).assertEqual('正在建立连接');
      expect(deriveOverlay(overlayInput('handshaking')).detail).assertEqual('正在进行 SSH 密钥交换');
      expect(deriveOverlay(overlayInput('authenticating')).detail).assertEqual('正在进行身份认证');
      expect(deriveOverlay(overlayInput('')).detail).assertEqual('正在准备连接');

      // 已有画面的 connecting（重连受理后新一次拨号）：置灰 + 重新连接文案
      const dialWithTerminal: OverlayInput = {
        state: 'connecting', reconnectCountdownSec: 0, reconnectAttempt: 1, errorMessage: '',
        hasTerminal: true, terminalClosed: false, startError: ''
      };
      o = deriveOverlay(dialWithTerminal);
      expect(o.kind).assertEqual('connecting');
      expect(o.dimmed).assertTrue();
      expect(o.title).assertEqual('正在重新连接…');

      // established → 无蒙层
      o = deriveOverlay(overlayInput('established'));
      expect(o.kind).assertEqual('none');
      expect(o.dimmed).assertFalse();

      // disconnected + 倒计时 → reconnecting（置灰 + 倒计时/次数 + 取消）
      const countdown: OverlayInput = {
        state: 'disconnected', reconnectCountdownSec: 5, reconnectAttempt: 2,
        errorMessage: '心跳检测超时，连接已断开（网络可能已中断）',
        hasTerminal: true, terminalClosed: false, startError: ''
      };
      o = deriveOverlay(countdown);
      expect(o.kind).assertEqual('reconnecting');
      expect(o.dimmed).assertTrue();
      expect(o.title).assertEqual('连接已断开');
      expect(o.detail).assertEqual('5 秒后自动重连（第 2 次）');
      expect(o.showCancelReconnect).assertTrue();
      expect(o.showReconnectNow).assertFalse();
      expect(o.showClose).assertFalse();

      // disconnected 无倒计时（自动重连已取消）→ error 形态 + 立即重连/关闭
      const cancelled: OverlayInput = {
        state: 'disconnected', reconnectCountdownSec: 0, reconnectAttempt: 1,
        errorMessage: '', hasTerminal: true, terminalClosed: false, startError: ''
      };
      o = deriveOverlay(cancelled);
      expect(o.kind).assertEqual('error');
      expect(o.title).assertEqual('连接已断开');
      expect(o.detail).assertEqual('自动重连已取消');
      expect(o.showReconnectNow).assertTrue();
      expect(o.showClose).assertTrue();

      // error → 中文错误文案 + 立即重连/关闭；无画面不置灰
      const errorNoTerminal: OverlayInput = {
        state: 'error', reconnectCountdownSec: 0, reconnectAttempt: 0,
        errorMessage: '密码认证失败，请检查用户名和密码',
        hasTerminal: false, terminalClosed: false, startError: ''
      };
      o = deriveOverlay(errorNoTerminal);
      expect(o.kind).assertEqual('error');
      expect(o.title).assertEqual('连接失败');
      expect(o.detail).assertEqual('密码认证失败，请检查用户名和密码');
      expect(o.dimmed).assertFalse();
      expect(o.showReconnectNow).assertTrue();
      expect(o.showClose).assertTrue();

      // closing / closed / terminalClosed 标记 → closed 蒙层
      const closedState: OverlayInput = overlayInput('closed');
      o = deriveOverlay(closedState);
      expect(o.kind).assertEqual('closed');
      expect(o.showClose).assertTrue();
      expect(o.showReconnectNow).assertFalse();
      const closingState: OverlayInput = overlayInput('closing');
      expect(deriveOverlay(closingState).kind).assertEqual('closed');
      const closedFlag: OverlayInput = {
        state: 'established', reconnectCountdownSec: 0, reconnectAttempt: 0, errorMessage: '',
        hasTerminal: true, terminalClosed: true, startError: ''
      };
      o = deriveOverlay(closedFlag);
      expect(o.kind).assertEqual('closed');
      expect(o.dimmed).assertTrue();
      expect(o.title).assertEqual('会话已结束');
    });

    it('路由参数解析_hostId与sessionId与同传优先与非法值', 0, () => {
      expect(parseTerminalRouteParams(null).hostId).assertEqual('');
      expect(parseTerminalRouteParams(undefined).sessionId).assertEqual('');
      const byHost: Record<string, Object> = {};
      byHost['hostId'] = 'h1';
      let params: TerminalRouteParams = parseTerminalRouteParams(byHost);
      expect(params.hostId).assertEqual('h1');
      expect(params.sessionId).assertEqual('');
      const bySession: Record<string, Object> = {};
      bySession['sessionId'] = 's-9';
      params = parseTerminalRouteParams(bySession);
      expect(params.sessionId).assertEqual('s-9');
      expect(params.hostId).assertEqual('');
      // 同传两参均保留（sessionId 优先的取舍在 VM.start）
      const both: Record<string, Object> = {};
      both['hostId'] = 'h1';
      both['sessionId'] = 's-1';
      params = parseTerminalRouteParams(both);
      expect(params.hostId).assertEqual('h1');
      expect(params.sessionId).assertEqual('s-1');
      // 非字符串值收敛为空串
      const dirty: Record<string, Object> = {};
      dirty['hostId'] = 42;
      dirty['sessionId'] = true;
      params = parseTerminalRouteParams(dirty);
      expect(params.hostId).assertEqual('');
      expect(params.sessionId).assertEqual('');
    });

    it('hostId进入_取主机连接绑窗格_established后attach并清蒙层', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      await env.vm.start({ hostId: 'h1', sessionId: '' });
      // 拨号受理 + 窗格绑定 + 蒙层为连接中
      expect(env.host.connectCalls.length).assertEqual(1);
      expect(env.host.connectCalls[0].id).assertEqual('h1');
      const sessionId: string = env.vm.currentSessionId;
      expect(sessionId.length > 0).assertTrue();
      expect(env.host.ops[0]).assertEqual(`bind:${sessionId}:${TERMINAL_MAIN_PANE_ID}`);
      expect(env.vm.overlay.kind).assertEqual('connecting');
      expect(env.vm.hostName).assertEqual('主机h1');
      expect(env.vm.sessionList.length).assertEqual(1);
      // established → attach（初始 80x24、termType 取主机配置）+ 轻震 + 无蒙层
      env.host.emit(sessionId, stateChange('established'));
      expect(env.host.ops[1]).assertEqual(`attach:101:xterm-256color:80x24`);
      expect(env.vm.terminal === env.host.factory.terminals[0]).assertTrue();
      expect(env.vm.overlay.kind).assertEqual('none');
      expect(env.vm.sessionState).assertEqual('established');
      expect(env.vibrateCount).assertEqual(1);
    });

    it('sessionId进入_复用既有会话不重复拨号_同传sessionId优先', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '生产机', 'established', 201);
      await env.vm.start({ hostId: 'h1', sessionId: 's-1' });
      expect(env.host.connectCalls.length).assertEqual(0);
      expect(env.vm.currentSessionId).assertEqual('s-1');
      expect(env.vm.hostName).assertEqual('生产机');
      // 复用 established 会话：start 内即 attach（bind 先于 attach）
      expect(env.host.ops[0]).assertEqual(`bind:s-1:${TERMINAL_MAIN_PANE_ID}`);
      expect(env.host.ops[1]).assertEqual('attach:201:xterm-256color:80x24');
      expect(env.vm.overlay.kind).assertEqual('none');
    });

    it('参数非法与主机缺失_落startError蒙层_不拨号不绑定', 0, async () => {
      const env: TestEnv = new TestEnv();
      await env.vm.start({ hostId: '', sessionId: '' });
      expect(env.vm.overlay.kind).assertEqual('error');
      expect(env.vm.overlay.showClose).assertTrue();
      expect(env.vm.overlay.showReconnectNow).assertFalse();
      expect(env.vm.overlay.detail.indexOf('缺少连接目标') >= 0).assertTrue();
      expect(env.host.connectCalls.length).assertEqual(0);
      expect(env.host.ops.length).assertEqual(0);
      // start 幂等：二次调用无副作用
      await env.vm.start({ hostId: 'h1', sessionId: '' });
      expect(env.host.connectCalls.length).assertEqual(0);

      const env2: TestEnv = new TestEnv();
      await env2.vm.start({ hostId: 'ghost', sessionId: '' });
      expect(env2.vm.overlay.detail.indexOf('主机不存在') >= 0).assertTrue();
      expect(env2.host.connectCalls.length).assertEqual(0);

      const env3: TestEnv = new TestEnv();
      await env3.vm.start({ hostId: '', sessionId: 'no-such' });
      expect(env3.vm.overlay.detail.indexOf('会话不存在') >= 0).assertTrue();
    });

    it('connect受理失败_错误文案进蒙层_不留绑定', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.connectError = new Error('凭据库中没有该主机的登录密码');
      await env.vm.start({ hostId: 'h1', sessionId: '' });
      expect(env.vm.overlay.kind).assertEqual('error');
      expect(env.vm.overlay.detail).assertEqual('凭据库中没有该主机的登录密码');
      expect(env.vm.currentSessionId).assertEqual('');
      expect(env.host.ops.length).assertEqual(0);
    });

    it('会话切换_unbind再bind再attach_切回复用缓存终端不重建', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.dao.put(sampleHost('h2'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 301);
      env.host.addSession('s-2', 'h2', '主机h2', 'established', 302);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      expect(env.host.ops.length).assertEqual(2); // bind + attach
      // 切换到 s-2：unbind(false) → bind → attach 次序
      env.vm.switchSession('s-2');
      expect(env.host.ops[2]).assertEqual(`unbind:${TERMINAL_MAIN_PANE_ID}:false`);
      expect(env.host.ops[3]).assertEqual(`bind:s-2:${TERMINAL_MAIN_PANE_ID}`);
      expect(env.host.ops[4]).assertEqual('attach:302:xterm-256color:80x24');
      expect(env.vm.currentSessionId).assertEqual('s-2');
      expect(env.vm.hostName).assertEqual('主机h2');
      expect(env.vm.terminal === env.host.factory.terminals[1]).assertTrue();
      // 切回 s-1：复用缓存终端（attach 不再增加），unbind/bind 照常
      env.vm.switchSession('s-1');
      expect(env.host.factory.terminals.length).assertEqual(2);
      expect(env.host.ops[5]).assertEqual(`unbind:${TERMINAL_MAIN_PANE_ID}:false`);
      expect(env.host.ops[6]).assertEqual(`bind:s-1:${TERMINAL_MAIN_PANE_ID}`);
      expect(env.vm.terminal === env.host.factory.terminals[0]).assertTrue();
      // 切换到当前会话 / 未知会话：no-op
      env.vm.switchSession('s-1');
      env.vm.switchSession('ghost');
      expect(env.host.ops.length).assertEqual(7);
    });

    it('重连换柄_established后旧终端detach新终端attach各一次并换绑画布', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 401);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      const first: FakeTerminal = env.host.factory.terminals[0];
      expect(env.vm.terminal === first).assertTrue();
      // 断线退避（画面保留：终端不换绑、蒙层置灰）
      const info: FakeSessionInfo =
        env.host.getSession('s-1') as FakeSessionInfo;
      info.reconnectAttempt = 1;
      info.reconnectCountdownSec = 5;
      env.host.emit('s-1', stateChange('disconnected'));
      expect(env.vm.overlay.kind).assertEqual('reconnecting');
      expect(env.vm.overlay.dimmed).assertTrue();
      expect(env.vm.overlay.detail).assertEqual('5 秒后自动重连（第 1 次）');
      expect(env.vm.terminal === first).assertTrue();
      // C4 重连：sessionId 不变、native 句柄换新 → established
      env.host.swapHandle('s-1', 402);
      env.host.emit('s-1', stateChange('established'));
      expect(first.detachCount).assertEqual(1);
      expect(env.host.factory.terminals.length).assertEqual(2);
      expect(env.host.ops[env.host.ops.length - 1]).assertEqual('attach:402:xterm-256color:80x24');
      expect(env.vm.terminal === env.host.factory.terminals[1]).assertTrue();
      expect(env.vm.overlay.kind).assertEqual('none');
      // 同柄重复 established：幂等（不再 detach/attach）
      env.host.emit('s-1', stateChange('established'));
      expect(first.detachCount).assertEqual(1);
      expect(env.host.factory.terminals.length).assertEqual(2);
    });

    it('退出dispose_幂等_unbindClose恰好一次_全部终端detach', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.dao.put(sampleHost('h2'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 501);
      env.host.addSession('s-2', 'h2', '主机h2', 'established', 502);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.switchSession('s-2'); // 两个终端都已装配
      env.vm.dispose();
      env.vm.dispose(); // 幂等二次调用
      const unbindOps: string[] =
        env.host.ops.filter((op: string) => op === `unbind:${TERMINAL_MAIN_PANE_ID}:true`);
      expect(unbindOps.length).assertEqual(1);
      expect(env.host.factory.terminals[0].detachCount).assertEqual(1);
      expect(env.host.factory.terminals[1].detachCount).assertEqual(1);
      expect(env.vm.terminal).assertNull();
      // dispose 后事件与 dirty 一律忽略
      env.host.emit('s-2', stateChange('established'));
      env.host.emitDirty('s-2');
      expect(env.dirtyCount).assertEqual(0);
      expect(env.host.factory.terminals.length).assertEqual(2);
    });

    it('terminalTitle与bell派生_非当前会话事件被忽略_terminalClose标记态', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 601);
      env.host.addSession('s-2', 'h2', '主机h2', 'established', 602);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      const title: SshEvent = { type: 'terminalTitle', title: 'vim ~/.bashrc' };
      env.host.emit('s-1', title);
      expect(env.vm.terminalTitle).assertEqual('vim ~/.bashrc');
      env.host.emit('s-1', { type: 'terminalBell' });
      expect(env.vibrateCount).assertEqual(1);
      // 非当前会话的标题/铃声不影响本页
      env.host.emit('s-2', { type: 'terminalTitle', title: '别的会话' });
      env.host.emit('s-2', { type: 'terminalBell' });
      expect(env.vm.terminalTitle).assertEqual('vim ~/.bashrc');
      expect(env.vibrateCount).assertEqual(1);
      // terminalClose → 「会话已结束」标记态；terminalOpen 清除
      env.host.emit('s-1', { type: 'terminalClose' });
      expect(env.vm.overlay.kind).assertEqual('closed');
      expect(env.vm.overlay.showClose).assertTrue();
      env.host.emit('s-1', { type: 'terminalOpen' });
      expect(env.vm.overlay.kind).assertEqual('none');
    });

    it('dirty通路_仅当前会话触发onContentDirty', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.host.addSession('s-1', 'h1', '主机h1', 'connecting', 701);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.host.emitDirty('s-1');
      expect(env.dirtyCount).assertEqual(1);
      env.host.emitDirty('s-other');
      expect(env.dirtyCount).assertEqual(1);
    });

    it('手动重连与取消_转发会话宿主并刷新蒙层', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      const info: FakeSessionInfo = env.host.addSession('s-1', 'h1', '主机h1', 'established', 801);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      // 进入断线倒计时
      info.reconnectAttempt = 1;
      info.reconnectCountdownSec = 10;
      env.host.emit('s-1', stateChange('disconnected'));
      expect(env.vm.overlay.kind).assertEqual('reconnecting');
      // 取消自动重连：转发 + 蒙层变 error 形态（倒计时清零）
      env.vm.cancelAutoReconnect();
      expect(env.host.cancelLog.length).assertEqual(1);
      expect(env.host.cancelLog[0]).assertEqual('s-1');
      expect(env.vm.overlay.kind).assertEqual('error');
      expect(env.vm.overlay.showReconnectNow).assertTrue();
      // 立即重连：转发 + 蒙层回 connecting（fake 把状态推进为 connecting）
      env.vm.reconnectNow();
      expect(env.host.reconnectNowLog.length).assertEqual(1);
      expect(env.host.reconnectNowLog[0]).assertEqual('s-1');
      expect(env.vm.overlay.kind).assertEqual('connecting');
      expect(env.vm.overlay.title).assertEqual('正在重新连接…');
    });

    it('sendInput_字节写当前终端_空字节与退出后忽略', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 901);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      const terminal: FakeTerminal = env.host.factory.terminals[0];
      env.vm.sendInput(new Uint8Array([0x03])); // Ctrl+C
      expect(terminal.writeCount).assertEqual(1);
      expect(terminal.lastWriteBytes).assertEqual(1);
      env.vm.sendInput(new Uint8Array(0));
      expect(terminal.writeCount).assertEqual(1);
      env.vm.dispose();
      env.vm.sendInput(new Uint8Array([0x03]));
      expect(terminal.writeCount).assertEqual(1);
    });

    it('进入后首标签首叶是terminal-main且投影到聚焦字段', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 911);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      expect(env.vm.tabs.length).assertEqual(1);
      expect(env.vm.tabs[0].active).assertTrue();
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.visiblePanes.length).assertEqual(1);
      expect(env.vm.visiblePanes[0].paneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.visiblePanes[0].sessionId).assertEqual('s-1');
      expect(env.vm.leafCount()).assertEqual(1);
      expect(env.vm.currentSessionId).assertEqual('s-1');
    });

    it('分屏_再拨号绑新叶_关新叶兄弟上提会话释放', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1001);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      env.vm.setPaneAreaSize(900, 400);
      await env.vm.splitFocused('row');
      expect(env.host.connectCalls.length).assertEqual(1);
      expect(env.vm.leafCount()).assertEqual(2);
      expect(env.vm.visiblePanes.length).assertEqual(2);
      expect(env.vm.dividers.length).assertEqual(1);
      const newSessionId: string = env.vm.currentSessionId;
      expect(newSessionId !== 's-1').assertTrue();
      expect(env.host.ops.indexOf(`bind:${newSessionId}:${env.vm.focusedPaneId}`) >= 0).assertTrue();
      env.host.emit(newSessionId, stateChange('established'));
      expect(env.host.factory.terminals.length).assertEqual(2);
      const newPaneId: string = env.vm.focusedPaneId;
      env.vm.closePane(newPaneId);
      expect(env.vm.leafCount()).assertEqual(1);
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.currentSessionId).assertEqual('s-1');
      expect(env.vm.dividers.length).assertEqual(0);
      expect(env.host.ops.indexOf(`unbind:${newPaneId}:true`) >= 0).assertTrue();
    });

    it('新标签_独立会话_切回原标签恢复聚焦叶', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1101);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      await env.vm.newTab();
      expect(env.vm.tabs.length).assertEqual(2);
      expect(env.vm.leafCount()).assertEqual(2);
      const tab2: string = env.vm.activeTabId;
      const session2: string = env.vm.currentSessionId;
      expect(session2 !== 's-1').assertTrue();
      env.vm.activateTab(env.vm.tabs[0].tabId);
      expect(env.vm.currentSessionId).assertEqual('s-1');
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      env.vm.activateTab(tab2);
      expect(env.vm.currentSessionId).assertEqual(session2);
    });

    it('抽屉切到已寄宿会话_只聚焦不换绑', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1201);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      await env.vm.splitFocused('row');
      const session2: string = env.vm.currentSessionId;
      const pane2: string = env.vm.focusedPaneId;
      const opsBefore: number = env.host.ops.length;
      env.vm.switchSession('s-1');
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.currentSessionId).assertEqual('s-1');
      expect(env.host.ops.length).assertEqual(opsBefore); // 无新 unbind/bind
      env.vm.switchSession(session2);
      expect(env.vm.focusedPaneId).assertEqual(pane2);
      expect(env.host.ops.length).assertEqual(opsBefore);
    });

    it('dirty通路_可见非聚焦叶也唤醒_不可见标签不唤醒', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1301);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      await env.vm.splitFocused('row');
      const session2: string = env.vm.currentSessionId;
      env.dirtyCount = 0;
      env.host.emitDirty('s-1'); // 同标签另一可见叶
      expect(env.dirtyCount).assertEqual(1);
      await env.vm.newTab();
      const session3: string = env.vm.currentSessionId;
      env.dirtyCount = 0;
      env.host.emitDirty('s-1'); // 已切走的标签，不可见
      expect(env.dirtyCount).assertEqual(0);
      env.host.emitDirty(session3);
      expect(env.dirtyCount).assertEqual(1);
      env.host.emitDirty(session2);
      expect(env.dirtyCount).assertEqual(1);
    });

    it('拖分隔条_改ratio后两侧宽度跟随_钳制生效', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1401);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      env.vm.setPaneAreaSize(200, 80);
      await env.vm.splitFocused('row');
      const splitId: string = env.vm.dividers[0].splitId;
      env.vm.setDividerRatio(splitId, 0.25);
      expect(env.vm.dividers[0].ratio).assertEqual(0.25);
      // 可用 192，A = floor(48)=48
      expect(env.vm.visiblePanes[0].w).assertEqual(48);
      env.vm.setDividerRatio(splitId, 0);
      expect(env.vm.dividers[0].ratio).assertEqual(0.1);
    });

    it('断点降级_lg到sm只见聚焦叶_切回lg树与会话完好', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1501);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      env.vm.setPaneAreaSize(900, 400);
      await env.vm.splitFocused('row');
      const pane2: string = env.vm.focusedPaneId;
      const session2: string = env.vm.currentSessionId;
      expect(env.vm.visiblePanes.length).assertEqual(2);
      expect(env.vm.dividers.length).assertEqual(1);
      env.vm.setViewportWidth(400); // sm
      expect(env.vm.breakpoint).assertEqual('sm');
      expect(env.vm.visiblePanes.length).assertEqual(1);
      expect(env.vm.visiblePanes[0].paneId).assertEqual(pane2);
      expect(env.vm.dividers.length).assertEqual(0);
      expect(env.vm.leafCount()).assertEqual(2);
      env.vm.setViewportWidth(900);
      expect(env.vm.breakpoint).assertEqual('lg');
      expect(env.vm.visiblePanes.length).assertEqual(2);
      expect(env.vm.dividers.length).assertEqual(1);
      expect(env.vm.leafCount()).assertEqual(2);
      expect(env.host.getSession('s-1') !== null).assertTrue();
      expect(env.host.getSession(session2) !== null).assertTrue();
    });

    it('关末叶_shouldExit_dispose解绑全部叶各一次', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1601);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      await env.vm.splitFocused('row');
      const pane2: string = env.vm.focusedPaneId;
      env.vm.closePane(pane2);
      expect(env.vm.shouldExit).assertFalse();
      env.vm.closeFocusedPane();
      expect(env.vm.shouldExit).assertTrue();
      expect(env.vm.leafCount()).assertEqual(0);

      const env2: TestEnv = new TestEnv();
      env2.dao.put(sampleHost('h1'));
      env2.host.addSession('s-1', 'h1', '主机h1', 'established', 1602);
      await env2.vm.start({ hostId: '', sessionId: 's-1' });
      env2.vm.setViewportWidth(900);
      await env2.vm.splitFocused('row');
      const paneB: string = env2.vm.focusedPaneId;
      env2.vm.dispose();
      const unbindTrue: string[] = env2.host.ops.filter((op: string) =>
        op.indexOf('unbind:') === 0 && op.indexOf(':true') > 0);
      expect(unbindTrue.length).assertEqual(2);
      expect(unbindTrue.indexOf(`unbind:${TERMINAL_MAIN_PANE_ID}:true`) >= 0).assertTrue();
      expect(unbindTrue.indexOf(`unbind:${paneB}:true`) >= 0).assertTrue();
    });

    it('快捷键_切标签循环_关窗格_方向切焦点', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1801);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(900);
      env.vm.setPaneAreaSize(900, 400);
      await env.vm.newTab();
      const tab2: string = env.vm.activeTabId;
      expect(env.vm.handleShortcut('prevTab')).assertTrue();
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.handleShortcut('nextTab')).assertTrue();
      expect(env.vm.activeTabId).assertEqual(tab2);
      env.vm.activateTab(env.vm.tabs[0].tabId);
      await env.vm.splitFocused('row');
      const rightPane: string = env.vm.focusedPaneId;
      expect(env.vm.handleShortcut('focusLeft')).assertTrue();
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.handleShortcut('focusRight')).assertTrue();
      expect(env.vm.focusedPaneId).assertEqual(rightPane);
      expect(env.vm.handleShortcut('closePane')).assertTrue();
      expect(env.vm.leafCount()).assertEqual(1);
      expect(env.vm.focusedPaneId).assertEqual(TERMINAL_MAIN_PANE_ID);
      expect(env.vm.handleShortcut('copy')).assertFalse();
      expect(env.vm.handleShortcut('paste')).assertFalse();
    });

    it('四窗格_各自会话互不串扰_标题只更新聚焦叶', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.dao.put(sampleHost('h1'));
      env.host.addSession('s-1', 'h1', '主机h1', 'established', 1701);
      await env.vm.start({ hostId: '', sessionId: 's-1' });
      env.vm.setViewportWidth(1000);
      env.vm.setPaneAreaSize(1000, 600);
      await env.vm.splitFocused('row');
      env.vm.focusPane(TERMINAL_MAIN_PANE_ID);
      await env.vm.splitFocused('column');
      env.vm.focusPane(env.vm.visiblePanes[env.vm.visiblePanes.length - 1].paneId);
      await env.vm.splitFocused('row');
      expect(env.vm.leafCount()).assertEqual(4);
      expect(env.vm.visiblePanes.length).assertEqual(4);
      const ids: string[] = [];
      for (const pane of env.vm.visiblePanes) {
        if (pane.sessionId.length > 0 && ids.indexOf(pane.sessionId) < 0) {
          ids.push(pane.sessionId);
        }
      }
      expect(ids.length).assertEqual(4);
      env.vm.focusPane(TERMINAL_MAIN_PANE_ID);
      env.host.emit('s-1', { type: 'terminalTitle', title: 'vim' });
      expect(env.vm.terminalTitle).assertEqual('vim');
      // 非聚焦叶标题不改顶栏
      const other: string = ids[1] === 's-1' ? ids[2] : ids[1];
      env.host.emit(other, { type: 'terminalTitle', title: 'htop' });
      expect(env.vm.terminalTitle).assertEqual('vim');
    });
  });
}
