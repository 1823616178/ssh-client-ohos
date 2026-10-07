/**
 * SessionManager 单元测试（任务 C4 + N9 agent 接线）。
 *
 * 注入形态（对齐 C1 的 InMemoryRdbGateway 模式）：
 *   - FakeNativeSession：NativeSessionLike 的可脚本化实现（emit 手动投递事件、
 *     nextDelay 可编程、受理开关可控、调用全记录），由 FakeFactory 经
 *     NativeSessionFactory 注入，替代 SshNativeSession.create；
 *   - ManualScheduler：ReconnectScheduler 手动定时器（记录 delaySec、runNext/runAll
 *     立即触发，不真等秒），验证退避调度与倒计时；
 *   - 内存凭据表：SecretProvider 注入，替代 CredentialStore.getSecret；
 *   - FakeAgentAuth：AgentAuthPort 内存实现（N9 agent 认证路径）。
 *
 * 覆盖：connect→established 全流程迁移 / 8 会话并存事件互不串扰 /
 * bindPane-unbindPane（closeSession 级联释放、幂等）/ closeAll 幂等 /
 * 重连退避（建议秒数、倒计时、换句柄保 sessionId、超限终态、手动 close 取消）/
 * 认证失败错误码映射 / 凭据缺失与 agent 已解锁/未解锁两条路径 / hostKey 透传与 dirty 唤醒 /
 * P1 后台保活支撑（活跃计数口径、静默模式、切网收敛两条分支、策略挂起与恢复、会话数通知）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HostProfile, createDefaultHostProfile } from '../main/ets/common/model/models';
import { SshError, SshErrorCode } from '../main/ets/common/SshError';
import { SshEvent, SshEventListener, NativeAgentKeygenResult } from '../main/ets/napi/SshNative';
import { AgentAuthPort } from '../main/ets/napi/AgentAuth';
import { CredentialKind } from '../main/ets/repository/CredentialStore';
import {
  DEFAULT_RECONNECT_MAX_ATTEMPTS,
  NETWORK_PROBE_TIMEOUT_SEC,
  NativeSessionFactory,
  NativeSessionLike,
  ReconnectScheduler,
  SessionInfo,
  SessionManager
} from '../main/ets/service/SessionManager';

// ---------- fake：native 会话 ----------

interface KeyAuthCall {
  privateKey: string;
  passphrase: string;
}

interface AgentAuthCall {
  keyId: string;
}

/** 可脚本化发事件的 fake native 会话 */
class FakeNativeSession implements NativeSessionLike {
  readonly nativeHandle: number;
  private readonly listener: SshEventListener;
  connectCount: number = 0;
  connectHost: string = '';
  connectPort: number = 0;
  connectUsername: string = '';
  readonly passwordAuthCalls: string[] = [];
  readonly keyAuthCalls: KeyAuthCall[] = [];
  readonly agentAuthCalls: AgentAuthCall[] = [];
  keepaliveIntervalSec: number = -1;
  keepaliveMaxMisses: number = -1;
  reconnectPolicyDelays: number[] = [];
  reconnectPolicyMaxAttempts: number = -1;
  closeCount: number = 0;
  /** P1：probeNow 的入参记录（每次探测的判定窗口秒数） */
  readonly probeCalls: number[] = [];
  /** 受理开关：false = 对应方法受理失败（返回 false） */
  acceptConnect: boolean = true;
  acceptAuth: boolean = true;
  acceptProbe: boolean = true;
  /** 重连建议秒数脚本（null = 恒 -1）；测试按场景安装 */
  nextDelay: ((attempt: number) => number) | null = null;

  constructor(handle: number, listener: SshEventListener) {
    this.nativeHandle = handle;
    this.listener = listener;
  }

  connect(host: string, port: number, username: string): boolean {
    this.connectCount++;
    this.connectHost = host;
    this.connectPort = port;
    this.connectUsername = username;
    return this.acceptConnect;
  }

  authenticatePassword(password: string): boolean {
    this.passwordAuthCalls.push(password);
    return this.acceptAuth;
  }

  authenticatePublicKey(privateKey: ArrayBuffer | string, publicKey: string, passphrase: string): boolean {
    const keyText: string = typeof privateKey === 'string' ? privateKey : '<buffer>';
    this.keyAuthCalls.push({ privateKey: keyText, passphrase: passphrase });
    return this.acceptAuth;
  }

  authenticateAgent(keyId: string): boolean {
    this.agentAuthCalls.push({ keyId: keyId });
    return this.acceptAuth;
  }

  setKeepalive(intervalSec: number, maxMisses: number): boolean {
    this.keepaliveIntervalSec = intervalSec;
    this.keepaliveMaxMisses = maxMisses;
    return true;
  }

  probeNow(timeoutSec: number): boolean {
    this.probeCalls.push(timeoutSec);
    return this.acceptProbe;
  }

  setReconnectPolicy(delaysSec: number[], maxAttempts: number): boolean {
    this.reconnectPolicyDelays = delaysSec;
    this.reconnectPolicyMaxAttempts = maxAttempts;
    return true;
  }

  nextReconnectDelaySec(attempt: number): number {
    return this.nextDelay === null ? -1 : this.nextDelay(attempt);
  }

  close(): void {
    this.closeCount++;
  }

  /** 测试脚本入口：模拟 native 投递一个事件 */
  emit(event: SshEvent): void {
    this.listener(event);
  }
}

/** N9：可脚本化的应用内 agent fake */
class FakeAgentAuth implements AgentAuthPort {
  private readonly keys: Map<string, string> = new Map();
  readonly unlockCalls: string[] = [];
  /** unlock 受理开关（false = 粗检不通过） */
  acceptUnlock: boolean = true;

  isLocked(keyId: string): boolean {
    return !this.keys.has(keyId);
  }

  unlock(keyId: string, privateKey: string, passphrase: string): boolean {
    this.unlockCalls.push(keyId);
    if (!this.acceptUnlock || keyId.length === 0 || privateKey.length === 0) {
      return false;
    }
    this.keys.set(keyId, `${privateKey}|${passphrase}`);
    return true;
  }

  lock(keyId: string): boolean {
    return this.keys.delete(keyId);
  }

  lockAll(): void {
    this.keys.clear();
  }

  keyCount(): number {
    return this.keys.size;
  }

  keygenSupported(): boolean {
    return false;
  }

  keygen(_comment: string, _passphrase: string): NativeAgentKeygenResult | null {
    return null;
  }

  /** 测试预置：直接标记某 keyId 已解锁 */
  preload(keyId: string): void {
    this.keys.set(keyId, 'preloaded');
  }
}

class FakeFactory {
  readonly created: FakeNativeSession[] = [];
  private nextHandle: number = 100;

  readonly createNativeSession: NativeSessionFactory =
    (onEvent: SshEventListener): NativeSessionLike | null => {
      const fake: FakeNativeSession = new FakeNativeSession(this.nextHandle++, onEvent);
      this.created.push(fake);
      return fake;
    };

  latest(): FakeNativeSession {
    return this.created[this.created.length - 1];
  }
}

// ---------- fake：手动重连定时器 ----------

interface ScheduledTask {
  id: number;
  delaySec: number;
  task: () => void;
  cancelled: boolean;
  fired: boolean;
}

class ManualScheduler implements ReconnectScheduler {
  private nextId: number = 1;
  readonly tasks: ScheduledTask[] = [];

  schedule(delaySec: number, task: () => void): number {
    const id: number = this.nextId++;
    this.tasks.push({ id: id, delaySec: delaySec, task: task, cancelled: false, fired: false });
    return id;
  }

  cancel(timerId: number): void {
    for (const t of this.tasks) {
      if (t.id === timerId) {
        t.cancelled = true;
      }
    }
  }

  get pendingCount(): number {
    let n: number = 0;
    for (const t of this.tasks) {
      if (!t.cancelled && !t.fired) {
        n++;
      }
    }
    return n;
  }

  /** 触发最早登记的未决任务；false = 无任务可跑 */
  runNext(): boolean {
    for (const t of this.tasks) {
      if (!t.cancelled && !t.fired) {
        t.fired = true;
        t.task();
        return true;
      }
    }
    return false;
  }

  runAll(): void {
    while (this.runNext()) {
      // 逐个触发直到清空（倒计时 tick 链会逐格重排）
    }
  }
}

// ---------- 测试环境 ----------

class TestEnv {
  readonly factory: FakeFactory = new FakeFactory();
  readonly scheduler: ManualScheduler = new ManualScheduler();
  readonly secrets: Map<string, string> = new Map();
  readonly agent: FakeAgentAuth = new FakeAgentAuth();
  readonly manager: SessionManager;
  readonly dirtyLog: string[] = [];
  private idSeq: number = 0;

  constructor() {
    this.manager = new SessionManager({
      createNativeSession: this.factory.createNativeSession,
      getSecret: (hostId: string, kind: CredentialKind): Promise<string | null> => {
        const value: string | undefined = this.secrets.get(`${hostId}:${kind}`);
        return Promise.resolve(value === undefined ? null : value);
      },
      scheduler: this.scheduler,
      newSessionId: (): string => {
        this.idSeq++;
        return `s-${this.idSeq}`;
      },
      agentAuth: this.agent
    });
    this.manager.addDirtyListener((sessionId: string) => {
      this.dirtyLog.push(sessionId);
    });
  }

  setSecret(hostId: string, kind: CredentialKind, value: string): void {
    this.secrets.set(`${hostId}:${kind}`, value);
  }
}

function sampleHost(id: string, authType: string): HostProfile {
  const host: HostProfile = createDefaultHostProfile(id);
  host.name = `主机${id}`;
  host.host = '192.168.1.10';
  host.port = 2222;
  host.username = 'root';
  host.authType = authType === 'key' ? 'key' : authType === 'agent' ? 'agent' : 'password';
  host.keepalive = 45;
  return host;
}

function stateChange(to: string): SshEvent {
  const event: SshEvent = { type: 'stateChange', to: to };
  return event;
}

/** 断线 hint 事件（keepalive 超时，带错误码与重连建议） */
function disconnectHint(): SshEvent {
  const event: SshEvent = {
    type: 'stateChange',
    from: 'established',
    to: 'disconnected',
    reconnectHint: true,
    errorCode: 404,
    errorCodeName: 'keepalive_timeout',
    errorMessage: 'keepalive timeout'
  };
  return event;
}

/** 排空微任务队列（reconnect 走 async 取凭据，需等几个 microtask） */
async function flushAsync(): Promise<void> {
  for (let i: number = 0; i < 5; i++) {
    await Promise.resolve();
  }
}

function expectThrowsError(action: () => void): void {
  let threw: boolean = false;
  try {
    action();
  } catch (err) {
    threw = true;
  }
  expect(threw).assertTrue();
}

export default function sessionManagerTest() {
  describe('SessionManagerTest', () => {

    it('connect全流程_受理参数正确且事件驱动状态迁移_close幂等', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw-1');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const fake: FakeNativeSession = env.factory.latest();
      // 受理参数：连接/keepalive/重连策略/密码认证
      expect(fake.connectCount).assertEqual(1);
      expect(fake.connectHost).assertEqual('192.168.1.10');
      expect(fake.connectPort).assertEqual(2222);
      expect(fake.connectUsername).assertEqual('root');
      expect(fake.keepaliveIntervalSec).assertEqual(45);
      expect(fake.keepaliveMaxMisses).assertEqual(3);
      expect(fake.reconnectPolicyDelays.length).assertEqual(0);
      expect(fake.reconnectPolicyMaxAttempts).assertEqual(DEFAULT_RECONNECT_MAX_ATTEMPTS);
      // 认证此刻还不能发起：native 只在 authenticating 态受理（见 dialNative 头注）
      expect(fake.passwordAuthCalls.length).assertEqual(0);
      // 受理即 connecting，后续状态由事件推进
      expect(info.state).assertEqual('connecting');
      expect(info.hostId).assertEqual('h1');
      expect(info.hostName).assertEqual('主机h1');
      expect(env.manager.listSessions().length).assertEqual(1);
      expect(env.manager.getNativeHandle(info.sessionId)).assertEqual(fake.nativeHandle);
      fake.emit(stateChange('handshaking'));
      expect(info.state).assertEqual('handshaking');
      fake.emit(stateChange('authenticating'));
      expect(info.state).assertEqual('authenticating');
      // 进入 authenticating 才提交密码，且只提交一次
      expect(fake.passwordAuthCalls.length).assertEqual(1);
      expect(fake.passwordAuthCalls[0]).assertEqual('pw-1');
      fake.emit(stateChange('authenticating'));
      expect(fake.passwordAuthCalls.length).assertEqual(1);
      fake.emit(stateChange('established'));
      expect(info.state).assertEqual('established');
      const open: SshEvent = { type: 'channelOpen', channelId: 7 };
      fake.emit(open);
      expect(info.channelId).assertEqual(7);
      const chClose: SshEvent = { type: 'channelClose', channelId: 7, reason: 'peer_eof' };
      fake.emit(chClose);
      expect(info.channelId).assertNull();
      // close 幂等：关 native、摘表、状态 closed
      env.manager.close(info.sessionId);
      expect(fake.closeCount).assertEqual(1);
      expect(info.state).assertEqual('closed');
      expect(env.manager.listSessions().length).assertEqual(0);
      expect(env.manager.getNativeHandle(info.sessionId)).assertNull();
      env.manager.close(info.sessionId);
      expect(fake.closeCount).assertEqual(1);
    });

    it('公钥认证_私钥与短语取自凭据库且不落SessionInfo', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('hk', 'private_key', 'PEM-DATA');
      env.setSecret('hk', 'passphrase', 'pp-1');
      const info: SessionInfo = await env.manager.connect(sampleHost('hk', 'key'));
      const fake: FakeNativeSession = env.factory.latest();
      // 同密码认证：材料暂存，进入 authenticating 才提交
      expect(fake.keyAuthCalls.length).assertEqual(0);
      fake.emit(stateChange('authenticating'));
      expect(fake.keyAuthCalls.length).assertEqual(1);
      expect(fake.keyAuthCalls[0].privateKey).assertEqual('PEM-DATA');
      expect(fake.keyAuthCalls[0].passphrase).assertEqual('pp-1');
      // 零残留：SessionInfo 序列化不得包含凭据明文
      const json: string = JSON.stringify(info);
      expect(json.indexOf('PEM-DATA') < 0).assertTrue();
      expect(json.indexOf('pp-1') < 0).assertTrue();
    });

    it('密码凭据缺失_connect抛错且不建native会话', 0, async () => {
      const env: TestEnv = new TestEnv();
      let threw: boolean = false;
      let code: number = 0;
      try {
        await env.manager.connect(sampleHost('h-missing', 'password'));
      } catch (err) {
        threw = true;
        if (err instanceof SshError) {
          code = err.code;
        }
      }
      expect(threw).assertTrue();
      // CREDENTIAL_MISSING 而非 AUTH_PASSWORD_FAILED：上层据此弹密码补录框
      expect(code).assertEqual(SshErrorCode.CREDENTIAL_MISSING);
      expect(env.factory.created.length).assertEqual(0);
      expect(env.manager.listSessions().length).assertEqual(0);
    });

    it('agent认证_已解锁密钥_走authenticateAgent成功路径', 0, async () => {
      const env: TestEnv = new TestEnv();
      // keyId 约定 = host.id；预置已解锁 → 不读凭据库、不 unlock
      env.agent.preload('h-agent');
      const info: SessionInfo = await env.manager.connect(sampleHost('h-agent', 'agent'));
      const fake: FakeNativeSession = env.factory.latest();
      expect(info.state).assertEqual('connecting');
      expect(fake.connectCount).assertEqual(1);
      expect(fake.agentAuthCalls.length).assertEqual(0);
      expect(env.agent.unlockCalls.length).assertEqual(0);
      fake.emit(stateChange('authenticating'));
      expect(fake.agentAuthCalls.length).assertEqual(1);
      expect(fake.agentAuthCalls[0].keyId).assertEqual('h-agent');
      // 私钥不经过 SessionInfo
      expect(fake.passwordAuthCalls.length).assertEqual(0);
      expect(fake.keyAuthCalls.length).assertEqual(0);
      fake.emit(stateChange('established'));
      expect(info.state).assertEqual('established');
    });

    it('agent认证_未解锁但从凭据库取私钥_unlock后认证', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h-agent2', 'private_key', 'OPENSSH-KEY');
      env.setSecret('h-agent2', 'passphrase', 'pp');
      const info: SessionInfo = await env.manager.connect(sampleHost('h-agent2', 'agent'));
      const fake: FakeNativeSession = env.factory.latest();
      // prepareAuth 阶段已 unlock 进 agent
      expect(env.agent.unlockCalls.length).assertEqual(1);
      expect(env.agent.unlockCalls[0]).assertEqual('h-agent2');
      expect(env.agent.isLocked('h-agent2')).assertFalse();
      fake.emit(stateChange('authenticating'));
      expect(fake.agentAuthCalls.length).assertEqual(1);
      expect(fake.agentAuthCalls[0].keyId).assertEqual('h-agent2');
      // 零残留：SessionInfo 序列化不含私钥/短语
      const json: string = JSON.stringify(info);
      expect(json.indexOf('OPENSSH-KEY') < 0).assertTrue();
      expect(json.indexOf('pp') < 0).assertTrue();
    });

    it('agent认证_未解锁且无私钥_CREDENTIAL_MISSING且不建会话', 0, async () => {
      const env: TestEnv = new TestEnv();
      let threw: boolean = false;
      let code: number = 0;
      let message: string = '';
      try {
        await env.manager.connect(sampleHost('h-agent-missing', 'agent'));
      } catch (err) {
        threw = true;
        if (err instanceof SshError) {
          code = err.code;
          message = err.message;
        }
      }
      expect(threw).assertTrue();
      expect(code).assertEqual(SshErrorCode.CREDENTIAL_MISSING);
      expect(message.indexOf('agent') >= 0).assertTrue();
      expect(env.factory.created.length).assertEqual(0);
      expect(env.manager.listSessions().length).assertEqual(0);
    });

    it('认证失败_stateChange错误码映射为中文文案', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const failed: SshEvent = {
        type: 'stateChange',
        from: 'authenticating',
        to: 'error',
        errorCode: 201,
        errorCodeName: 'auth_password_failed'
      };
      env.factory.latest().emit(failed);
      expect(info.state).assertEqual('error');
      expect(info.errorMessage).assertEqual('密码认证失败，请检查用户名和密码');
      expect(info.errorCodeName).assertEqual('auth_password_failed');
      // 无 hint：不进入重连编排
      expect(env.scheduler.pendingCount).assertEqual(0);
    });

    it('8会话并存_交错事件各自路由互不影响', 0, async () => {
      const env: TestEnv = new TestEnv();
      const infos: SessionInfo[] = [];
      for (let i: number = 0; i < 8; i++) {
        env.setSecret(`h${i}`, 'password', `pw${i}`);
        infos.push(await env.manager.connect(sampleHost(`h${i}`, 'password')));
      }
      expect(env.factory.created.length).assertEqual(8);
      expect(env.manager.listSessions().length).assertEqual(8);
      // 交错投递：偶数会话 established，奇数会话 channelOpen + channelData
      for (let i: number = 0; i < 8; i++) {
        const fake: FakeNativeSession = env.factory.created[i];
        if (i % 2 === 0) {
          fake.emit(stateChange('established'));
        } else {
          const open: SshEvent = { type: 'channelOpen', channelId: i + 1 };
          fake.emit(open);
          const data: SshEvent = { type: 'channelData', channelId: i + 1, stream: 0, data: new ArrayBuffer(2) };
          fake.emit(data);
        }
      }
      for (let i: number = 0; i < 8; i++) {
        if (i % 2 === 0) {
          expect(infos[i].state).assertEqual('established');
          expect(infos[i].channelId).assertNull();
        } else {
          expect(infos[i].state).assertEqual('connecting');
          expect(infos[i].channelId).assertEqual(i + 1);
        }
      }
      // dirty 唤醒按 sessionId 正确路由（4 条 channelData）
      expect(env.dirtyLog.length).assertEqual(4);
      expect(env.dirtyLog[0]).assertEqual(infos[1].sessionId);
      expect(env.dirtyLog[3]).assertEqual(infos[7].sessionId);
      // 关闭一半，剩余不受影响
      for (let i: number = 0; i < 8; i += 2) {
        env.manager.close(infos[i].sessionId);
      }
      expect(env.manager.listSessions().length).assertEqual(4);
      env.factory.created[3].emit(stateChange('established'));
      expect(infos[3].state).assertEqual('established');
    });

    it('窗格绑定_双向查询_冲突抛错_解绑级联释放且幂等', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw1');
      env.setSecret('h2', 'password', 'pw2');
      const info1: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const info2: SessionInfo = await env.manager.connect(sampleHost('h2', 'password'));
      // 绑定 + 双向查询
      env.manager.bindPane(info1.sessionId, 'pane-1');
      expect(env.manager.sessionIdOfPane('pane-1')).assertEqual(info1.sessionId);
      expect(env.manager.paneIdOfSession(info1.sessionId)).assertEqual('pane-1');
      expect(info1.paneId).assertEqual('pane-1');
      // 重复绑定同一对幂等
      env.manager.bindPane(info1.sessionId, 'pane-1');
      // 窗格已被占用 / 会话已绑其他窗格：抛错
      expectThrowsError(() => env.manager.bindPane(info2.sessionId, 'pane-1'));
      expectThrowsError(() => env.manager.bindPane(info1.sessionId, 'pane-2'));
      expectThrowsError(() => env.manager.bindPane('no-such', 'pane-9'));
      // 解绑不杀会话
      env.manager.unbindPane('pane-1', false);
      expect(info1.paneId).assertNull();
      expect(env.manager.sessionIdOfPane('pane-1')).assertNull();
      expect(env.manager.listSessions().length).assertEqual(2);
      // 重新绑定后关窗格：级联释放会话并摘表
      env.manager.bindPane(info1.sessionId, 'pane-1');
      env.manager.unbindPane('pane-1', true);
      expect(env.factory.created[0].closeCount).assertEqual(1);
      expect(env.manager.listSessions().length).assertEqual(1);
      expect(info1.state).assertEqual('closed');
      expect(env.manager.sessionIdOfPane('pane-1')).assertNull();
      // 重复 unbind 幂等
      env.manager.unbindPane('pane-1', true);
      expect(env.factory.created[0].closeCount).assertEqual(1);
      // 未绑定窗格直接 unbind 无效果
      env.manager.unbindPane('pane-never', true);
      expect(env.manager.listSessions().length).assertEqual(1);
    });

    it('closeAll_全部优雅关闭且幂等', 0, async () => {
      const env: TestEnv = new TestEnv();
      for (let i: number = 0; i < 3; i++) {
        env.setSecret(`h${i}`, 'password', `pw${i}`);
        await env.manager.connect(sampleHost(`h${i}`, 'password'));
      }
      env.manager.closeAll();
      expect(env.manager.listSessions().length).assertEqual(0);
      for (let i: number = 0; i < 3; i++) {
        expect(env.factory.created[i].closeCount).assertEqual(1);
      }
      env.manager.closeAll();
      for (let i: number = 0; i < 3; i++) {
        expect(env.factory.created[i].closeCount).assertEqual(1);
      }
    });

    it('断线hint_按建议秒数退避_倒计时递减_换句柄保sessionId_旧句柄迟到事件被丢弃', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const fake1: FakeNativeSession = env.factory.latest();
      fake1.emit(stateChange('established'));
      fake1.nextDelay = (attempt: number): number => attempt === 1 ? 5 : -1;
      fake1.emit(disconnectHint());
      // 进入退避：尝试次数 1、倒计时 = 建议秒数 5、错误文案已映射、旧句柄关闭
      expect(info.state).assertEqual('disconnected');
      expect(info.reconnectAttempt).assertEqual(1);
      expect(info.reconnectCountdownSec).assertEqual(5);
      expect(info.errorMessage).assertEqual('心跳检测超时，连接已断开（网络可能已中断）');
      expect(fake1.closeCount).assertEqual(1);
      expect(env.scheduler.pendingCount).assertEqual(1);
      // 倒计时逐秒递减（每秒一个 tick，调度间隔恒为 1）
      env.scheduler.runNext();
      expect(info.reconnectCountdownSec).assertEqual(4);
      env.scheduler.runNext();
      expect(info.reconnectCountdownSec).assertEqual(3);
      expect(env.factory.created.length).assertEqual(1);
      // 跑完剩余 tick：触发重连 → 新建 native 会话（sessionId 不变、句柄换新）
      env.scheduler.runAll();
      await flushAsync();
      expect(env.factory.created.length).assertEqual(2);
      const fake2: FakeNativeSession = env.factory.latest();
      expect(fake2.connectCount).assertEqual(1);
      // 重连同样推迟认证：新句柄进入 authenticating 才提交
      expect(fake2.passwordAuthCalls.length).assertEqual(0);
      fake2.emit(stateChange('authenticating'));
      expect(fake2.passwordAuthCalls.length).assertEqual(1);
      expect(info.state).assertEqual('authenticating');
      expect(info.reconnectCountdownSec).assertEqual(0);
      expect(env.manager.getNativeHandle(info.sessionId)).assertEqual(fake2.nativeHandle);
      expect(fake2.nativeHandle !== fake1.nativeHandle).assertTrue();
      // 新句柄事件推进到 established：计数/倒计时/错误复位
      fake2.emit(stateChange('established'));
      expect(info.state).assertEqual('established');
      expect(info.reconnectAttempt).assertEqual(0);
      expect(info.errorMessage).assertEqual('');
      // 旧句柄迟到事件被丢弃，不得污染新状态
      fake1.emit(stateChange('closed'));
      expect(info.state).assertEqual('established');
      // 退避期会话未被摘表（UI 面孔保持）
      expect(env.manager.listSessions().length).assertEqual(1);
    });

    it('重连超限_进error终态且不再调度', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const fake1: FakeNativeSession = env.factory.latest();
      fake1.emit(stateChange('established'));
      fake1.nextDelay = (attempt: number): number => -1;
      fake1.emit(disconnectHint());
      expect(info.state).assertEqual('error');
      expect(info.errorMessage.indexOf('自动重连已达上限') >= 0).assertTrue();
      expect(info.errorMessage.indexOf('心跳检测超时') >= 0).assertTrue();
      expect(info.reconnectCountdownSec).assertEqual(0);
      expect(env.scheduler.pendingCount).assertEqual(0);
      // 不关闭旧句柄也不新建（终态留 UI 展示，释放归 close/unbindPane）
      expect(fake1.closeCount).assertEqual(0);
      expect(env.factory.created.length).assertEqual(1);
    });

    it('手动close_取消在途重连定时器', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const fake1: FakeNativeSession = env.factory.latest();
      fake1.emit(stateChange('established'));
      fake1.nextDelay = (attempt: number): number => attempt === 1 ? 10 : -1;
      fake1.emit(disconnectHint());
      expect(env.scheduler.pendingCount).assertEqual(1);
      env.manager.close(info.sessionId);
      expect(env.scheduler.pendingCount).assertEqual(0);
      expect(info.state).assertEqual('closed');
      // 排空后不得新建会话
      env.scheduler.runAll();
      await flushAsync();
      expect(env.factory.created.length).assertEqual(1);
    });

    it('hostKey事件透传给事件监听器_TOFU交互不在本层', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const received: SshEvent[] = [];
      env.manager.addEventListener((session: SessionInfo, event: SshEvent) => {
        received.push(event);
      });
      const hostKey: SshEvent = {
        type: 'hostKey',
        keyType: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:abc',
        randomart: '+--[ED25519]--+'
      };
      env.factory.latest().emit(hostKey);
      expect(received.length).assertEqual(1);
      expect(received[0].type).assertEqual('hostKey');
      expect(received[0].fingerprintSha256).assertEqual('SHA256:abc');
      // hostKey 不触发 dirty 唤醒、不改变状态
      expect(env.dirtyLog.length).assertEqual(0);
      expect(info.state).assertEqual('connecting');
    });

    it('terminalData只触发dirty唤醒且按会话路由', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      const received: SshEvent[] = [];
      env.manager.addEventListener((_session: SessionInfo, event: SshEvent) => {
        received.push(event);
      });
      env.factory.latest().emit({ type: 'terminalData', terminal: 7 });
      expect(received.length).assertEqual(1);
      expect(received[0].type).assertEqual('terminalData');
      expect(env.dirtyLog.length).assertEqual(1);
      expect(env.dirtyLog[0]).assertEqual(info.sessionId);
      expect(info.state).assertEqual('connecting');
    });
  });

  // ================================================================ P1 后台保活支撑

  describe('SessionManagerBackgroundTest', () => {
    it('活跃会话计数含退避中不含策略挂起', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      expect(env.manager.activeSessionCount()).assertEqual(1); // connecting 也算活

      env.factory.latest().nextDelay = (_attempt: number): number => 5;
      env.factory.latest().emit(stateChange('established'));
      env.factory.latest().emit(disconnectHint());
      // 断线但已排上退避倒计时：仍算活（长时任务不该在这时还电）
      expect(info.reconnectCountdownSec).assertEqual(5);
      expect(env.manager.activeSessionCount()).assertEqual(1);

      env.manager.suspendAllForPolicy('测试挂起');
      expect(env.manager.activeSessionCount()).assertEqual(0);
      expect(env.manager.suspendedCount()).assertEqual(1);
    });

    it('静默模式抑制dirty唤醒但事件照常透传', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      await env.manager.connect(sampleHost('h1', 'password'));
      const received: SshEvent[] = [];
      env.manager.addEventListener((_session: SessionInfo, event: SshEvent) => {
        received.push(event);
      });

      env.manager.setQuiet(true);
      env.factory.latest().emit({ type: 'terminalData', terminal: 7 });
      expect(received.length).assertEqual(1); // 事件仍到达：数据一个字节都不能丢
      expect(env.dirtyLog.length).assertEqual(0); // 但不唤醒重绘

      env.manager.setQuiet(false);
      env.factory.latest().emit({ type: 'terminalData', terminal: 7 });
      expect(received.length).assertEqual(2);
      expect(env.dirtyLog.length).assertEqual(1);
    });

    it('切网时established会话走native探测', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      await env.manager.connect(sampleHost('h1', 'password'));
      env.factory.latest().emit(stateChange('established'));

      const affected: number = env.manager.notifyNetworkChanged();
      expect(affected).assertEqual(1);
      expect(env.factory.latest().probeCalls.length).assertEqual(1);
      expect(env.factory.latest().probeCalls[0]).assertEqual(NETWORK_PROBE_TIMEOUT_SEC);
    });

    it('切网时退避中的会话立刻重连不等倒计时', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      env.factory.latest().nextDelay = (_attempt: number): number => 30;
      env.factory.latest().emit(stateChange('established'));
      env.factory.latest().emit(disconnectHint());
      expect(info.reconnectCountdownSec).assertEqual(30);
      const createdBefore: number = env.factory.created.length;

      env.manager.notifyNetworkChanged();
      await flushAsync();
      // 倒计时清零、直接换新句柄重拨，而不是干等 30 s
      expect(info.reconnectCountdownSec).assertEqual(0);
      expect(env.factory.created.length).assertEqual(createdBefore + 1);
      expect(env.factory.latest().connectCount).assertEqual(1);
      expect(env.factory.latest().probeCalls.length).assertEqual(0);
    });

    it('策略挂起保留会话面孔与窗格绑定回前台原地重连', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      env.manager.bindPane(info.sessionId, 'pane-1');
      env.factory.latest().emit(stateChange('established'));
      const firstHandle: number = env.factory.latest().nativeHandle;

      const suspended: number = env.manager.suspendAllForPolicy('已按设置在后台断开');
      expect(suspended).assertEqual(1);
      expect(info.state).assertEqual('disconnected');
      expect(info.errorMessage).assertEqual('已按设置在后台断开');
      // 会话面孔与窗格绑定都还在（不是 close：用户回来还要看到这个终端）
      expect(env.manager.getSession(info.sessionId) !== null).assertTrue();
      expect(env.manager.sessionIdOfPane('pane-1')).assertEqual(info.sessionId);
      expect(env.manager.getNativeHandle(info.sessionId)).assertEqual(null);
      // 幂等：重复挂起不再计数
      expect(env.manager.suspendAllForPolicy('again')).assertEqual(0);

      const resumed: number = env.manager.resumeAllSuspended();
      await flushAsync();
      expect(resumed).assertEqual(1);
      expect(env.manager.suspendedCount()).assertEqual(0);
      // sessionId 不变、native 句柄换新，重连计数从零起算（策略断开不算失败）
      expect(env.manager.getSession(info.sessionId) !== null).assertTrue();
      expect(env.factory.latest().nativeHandle !== firstHandle).assertTrue();
      expect(info.reconnectAttempt).assertEqual(0);
      expect(info.errorMessage).assertEqual('');
    });

    it('会话数变化通知监听器', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const counts: number[] = [];
      env.manager.addSessionCountListener((): void => {
        counts.push(env.manager.activeSessionCount());
      });

      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      expect(counts.length).assertEqual(1);
      expect(counts[0]).assertEqual(1);

      env.factory.latest().emit(stateChange('established'));
      // established 仍是「活」，活跃与否没翻转 → 不重复通知
      expect(counts.length).assertEqual(1);

      env.manager.close(info.sessionId);
      expect(counts.length).assertEqual(2);
      expect(counts[1]).assertEqual(0);
    });

    it('手动重连解除策略挂起', 0, async () => {
      const env: TestEnv = new TestEnv();
      env.setSecret('h1', 'password', 'pw');
      const info: SessionInfo = await env.manager.connect(sampleHost('h1', 'password'));
      env.factory.latest().emit(stateChange('established'));
      env.manager.suspendAllForPolicy('后台断开');
      expect(env.manager.suspendedCount()).assertEqual(1);

      expect(env.manager.reconnectNow(info.sessionId)).assertTrue();
      await flushAsync();
      expect(env.manager.suspendedCount()).assertEqual(0);
      // 已由用户手动接管，回前台的批量恢复不该再动它
      expect(env.manager.resumeAllSuspended()).assertEqual(0);
    });
  });
}
