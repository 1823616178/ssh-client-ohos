/**
 * 端口转发运行时 + ViewModel + DynamicForwardSession + ProxyJump 编排
 * 单元测试（任务 U9/N15/N16，hypium）。
 * 纯逻辑 + fake 网关/native，不触碰真实 socket / .so。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HostProfile, PortForwardRule, PortForwardType, createDefaultHostProfile } from '../main/ets/common/model/models';
import {
  ForwardAction,
  ForwardRuntimeStatus,
  PortForwardRuntime,
  canStartForwardRule,
  forwardRuleLabel
} from '../main/ets/service/portforward/PortForwardRuntime';
import {
  ListenGateway,
  LocalForwardSocket,
  LocalForwardSocketDeps,
  LocalForwardTarget,
  NativeForwardPort,
  NullListenGateway
} from '../main/ets/service/portforward/LocalForwardSocket';
import {
  DynamicForwardSession,
  DynamicLocalResult,
  socks5ApplyConnectResult
} from '../main/ets/service/portforward/DynamicForwardSession';
import {
  ForwardNativeEvent,
  ForwardRuleSource,
  PortForwardViewModel,
  PortForwardViewModelDeps
} from '../main/ets/viewmodel/PortForwardViewModel';
import {
  Socks5Handshake,
  socks5ErrorReply,
  socks5ProcessGreeting,
  socks5ProcessRequest,
  socks5SuccessReply
} from '../main/ets/service/portforward/Socks5';
import {
  JumpHostBrief,
  JumpHostLookup,
  ProxyJumpDialStep,
  ProxyJumpHopSpec,
  ProxyJumpOrchestration,
  hopsAreExecutable,
  orchestrateProxyJumpPlan,
  parseProxyJumpSpec,
  planProxyJumpDialSteps,
  planProxyJumpPath,
  proxyJumpGapSummary,
  proxyJumpOutcomeFromSteps
} from '../main/ets/service/portforward/ProxyJump';
import {
  NativeSessionLike,
  NativeSessionFactory,
  ReconnectScheduler,
  SessionInfo,
  SessionManager
} from '../main/ets/service/SessionManager';
import { SshEvent, SshEventListener, NativeAgentKeygenResult } from '../main/ets/napi/SshNative';
import { CredentialKind } from '../main/ets/repository/CredentialStore';
import { AgentAuthPort } from '../main/ets/napi/AgentAuth';

function makeRule(id: string, type: string, port: number): PortForwardRule {
  return {
    id: id,
    hostId: 'h1',
    type: type as PortForwardType,
    bindAddress: '127.0.0.1',
    localPort: port,
    remoteHost: type === 'dynamic' ? '' : '10.0.0.1',
    remotePort: type === 'dynamic' ? 0 : 22,
    enabled: true
  };
}

class FakeJumpLookup implements JumpHostLookup {
  private readonly byId: Map<string, JumpHostBrief> = new Map();

  put(brief: JumpHostBrief): void {
    this.byId.set(brief.id, brief);
  }

  getById(id: string): JumpHostBrief | null {
    const found: JumpHostBrief | undefined = this.byId.get(id);
    return found === undefined ? null : found;
  }
}

class FakeNativeForward implements NativeForwardPort {
  openCount: number = 0;
  lastHost: string = '';
  lastPort: number = 0;
  handleToReturn: number = 42;
  readonly writes: string[] = [];
  readonly closed: number[] = [];

  openDirectTcpip(_s: number, host: string, port: number): number {
    this.lastHost = host;
    this.lastPort = port;
    this.openCount++;
    return this.handleToReturn;
  }

  forwardWrite(_h: number, d: ArrayBuffer | string): boolean {
    if (typeof d === 'string') {
      this.writes.push(d);
    } else {
      this.writes.push(`ab:${d.byteLength}`);
    }
    return true;
  }

  forwardClose(h: number): boolean {
    this.closed.push(h);
    return true;
  }
}

/** N15 -R：扩展 remoteForwardListen 的 fake */
class FakeNativeForwardExt extends FakeNativeForward {
  remoteHandleToReturn: number = 77;
  lastRemoteBind: string = '';
  lastRemotePort: number = 0;
  remoteListenCount: number = 0;

  remoteForwardListen(_s: number, bind: string, port: number): number {
    this.remoteListenCount++;
    this.lastRemoteBind = bind;
    this.lastRemotePort = port;
    return this.remoteHandleToReturn;
  }
}

class RuleStore implements ForwardRuleSource {
  rules: PortForwardRule[] = [];

  listByHostId(hostId: string): PortForwardRule[] {
    return this.rules.filter((r: PortForwardRule) => r.hostId === hostId);
  }

  listAll(): PortForwardRule[] {
    return this.rules.slice();
  }

  getById(id: string): PortForwardRule | null {
    for (const r of this.rules) {
      if (r.id === id) {
        return r;
      }
    }
    return null;
  }
}

function actionKinds(actions: ForwardAction[]): string[] {
  const out: string[] = [];
  for (const a of actions) {
    out.push(a.kind);
  }
  return out;
}

/** SessionManager 测试用：最小 FakeNativeSession */
class JumpFakeNativeSession implements NativeSessionLike {
  readonly nativeHandle: number;
  private readonly listener: SshEventListener;
  connectCount: number = 0;
  connectHost: string = '';
  connectPort: number = 0;
  connectUsername: string = '';
  closeCount: number = 0;
  acceptConnect: boolean = true;
  /** N16：串联 API 是否挂上（supportsChainedJump 探测；与方法存在性解耦） */
  readonly hasChainedApi: boolean;
  chainedHandle: number = 0;
  chainedOk: boolean = true;

  constructor(handle: number, listener: SshEventListener, withChainedApi: boolean) {
    this.nativeHandle = handle;
    this.listener = listener;
    this.hasChainedApi = withChainedApi;
  }

  connectViaJumpChannel(forwardHandle: number): boolean {
    if (!this.hasChainedApi) {
      return false;
    }
    this.chainedHandle = forwardHandle;
    return this.chainedOk;
  }

  connect(host: string, port: number, username: string): boolean {
    this.connectCount++;
    this.connectHost = host;
    this.connectPort = port;
    this.connectUsername = username;
    return this.acceptConnect;
  }

  authenticatePassword(_password: string): boolean {
    return true;
  }

  authenticatePublicKey(_pk: ArrayBuffer | string, _pub: string, _pass: string): boolean {
    return true;
  }

  authenticateAgent(_keyId: string): boolean {
    return true;
  }

  setKeepalive(_sec: number, _misses: number): boolean {
    return true;
  }

  probeNow(_timeoutSec: number): boolean {
    return false;
  }

  setReconnectPolicy(_delays: number[], _max: number): boolean {
    return true;
  }

  nextReconnectDelaySec(_attempt: number): number {
    return -1;
  }

  close(): void {
    this.closeCount++;
  }

  emit(type: string): void {
    const evt: SshEvent = { type: type };
    this.listener(evt);
  }
}

class JumpFakeAgentAuth implements AgentAuthPort {
  isLocked(_keyId: string): boolean {
    return false;
  }

  unlock(_keyId: string, _privateKey: string, _passphrase: string): boolean {
    return true;
  }

  lock(_keyId: string): boolean {
    return true;
  }

  lockAll(): void {
  }

  keyCount(): number {
    return 0;
  }

  keygenSupported(): boolean {
    return false;
  }

  keygen(_comment: string, _passphrase: string): NativeAgentKeygenResult | null {
    return null;
  }
}

class JumpNoopScheduler implements ReconnectScheduler {
  schedule(_delaySec: number, _task: () => void): number {
    return -1;
  }

  cancel(_timerId: number): void {
  }
}

class JumpTestEnv {
  readonly created: JumpFakeNativeSession[] = [];
  private nextHandle: number = 200;
  private idSeq: number = 0;
  readonly openCalls: string[] = [];
  openChannelHandle: number = 0;
  readonly manager: SessionManager;
  withChainedApi: boolean = false;
  /** jumpHost 库：id → brief */
  readonly hosts: Map<string, HostProfile> = new Map();

  constructor() {
    const factory: NativeSessionFactory = (onEvent: SshEventListener): NativeSessionLike | null => {
      const fake: JumpFakeNativeSession = new JumpFakeNativeSession(
        this.nextHandle++,
        onEvent,
        this.withChainedApi
      );
      this.created.push(fake);
      return fake;
    };
    const agent: AgentAuthPort = new JumpFakeAgentAuth();
    const scheduler: ReconnectScheduler = new JumpNoopScheduler();
    const self: JumpTestEnv = this;
    this.manager = new SessionManager({
      createNativeSession: factory,
      getSecret: (_hostId: string, _kind: CredentialKind): Promise<string | null> =>
        Promise.resolve('secret'),
      scheduler: scheduler,
      newSessionId: (): string => {
        self.idSeq++;
        return `js-${self.idSeq}`;
      },
      agentAuth: agent,
      getJumpHost: (id: string): HostProfile | null => self.hosts.get(id) ?? null,
      supportsChainedJump: (): boolean => self.withChainedApi,
      openDirectTcpipOn: (hostId: string, host: string, port: number): number => {
        const label: string = `${hostId}|${host}|${port}`;
        self.openCalls.push(label);
        return self.openChannelHandle;
      }
    });
  }

  putHost(id: string, host: string, port: number, username: string, jumpHostId: string | null): void {
    const p: HostProfile = createDefaultHostProfile(id);
    p.name = id;
    p.host = host;
    p.port = port;
    p.username = username;
    p.authType = 'password';
    p.jumpHostId = jumpHostId;
    this.hosts.set(id, p);
  }

  latest(): JumpFakeNativeSession {
    return this.created[this.created.length - 1];
  }
}

export default function portForwardTest(): void {
  describe('PortForwardRuntime', () => {
    it('startLocalWithoutNativeMarksRequired', 0, () => {
      const rt: PortForwardRuntime = new PortForwardRuntime();
      const rule: PortForwardRule = makeRule('f1', 'local', 18080);
      const actions: ForwardAction[] = rt.start(rule);
      const kinds: string[] = actionKinds(actions);
      expect(kinds.includes('listenStart')).assertTrue();
      expect(kinds.includes('logNativeMissing')).assertTrue();
      const st: ForwardRuntimeStatus | null = rt.statusOf('f1');
      expect(st?.state).assertEqual('listening');
      expect(st?.nativeChannelRequired).assertTrue();
      expect(rt.recentLogs().length).assertEqual(1);
      expect(rt.recentLogs()[0].message).assertEqual('需已连接的 SSH 会话才能打开转发通道');
    });

    it('startWithNativeDoesNotRequire', 0, () => {
      const rt: PortForwardRuntime = new PortForwardRuntime({ hasNativeChannel: true });
      const actions: ForwardAction[] = rt.start(makeRule('f1', 'local', 8080));
      expect(actionKinds(actions).includes('logNativeMissing')).assertFalse();
      expect(rt.statusOf('f1')?.nativeChannelRequired).assertFalse();
    });

    it('startInvalidPortErrors', 0, () => {
      const rt: PortForwardRuntime = new PortForwardRuntime();
      const actions: ForwardAction[] = rt.start(makeRule('bad', 'local', 0));
      expect(rt.statusOf('bad')?.state).assertEqual('error');
      expect(actionKinds(actions).includes('logError')).assertTrue();
    });

    it('startIdempotentAndStop', 0, () => {
      const rt: PortForwardRuntime = new PortForwardRuntime();
      rt.start(makeRule('f1', 'local', 9090));
      const again: ForwardAction[] = rt.start(makeRule('f1', 'local', 9090));
      expect(again.length).assertEqual(0);
      const stop: ForwardAction[] = rt.stop('f1');
      expect(actionKinds(stop)).assertDeepEquals(['listenStop']);
      expect(rt.statusOf('f1')?.state).assertEqual('stopped');
    });

    it('connectionAccounting', 0, () => {
      const rt: PortForwardRuntime = new PortForwardRuntime({ hasNativeChannel: true });
      rt.start(makeRule('f1', 'local', 7070));
      rt.onConnectionAccepted('f1');
      rt.onConnectionAccepted('f1');
      expect(rt.statusOf('f1')?.connections).assertEqual(2);
      rt.onConnectionClosed('f1', 100, 50);
      rt.onConnectionClosed('f1', 20, 0);
      const st: ForwardRuntimeStatus | null = rt.statusOf('f1');
      expect(st?.connections).assertEqual(0);
      expect(st?.bytesIn).assertEqual(120);
      expect(st?.bytesOut).assertEqual(50);
    });

    it('addTrafficAndListenReady', 0, () => {
      const rt: PortForwardRuntime = new PortForwardRuntime({ hasNativeChannel: true });
      rt.start(makeRule('r1', 'remote', 9000));
      rt.addTraffic('r1', 64, 32);
      rt.addTraffic('r1', 10, 0);
      expect(rt.statusOf('r1')?.bytesIn).assertEqual(74);
      expect(rt.statusOf('r1')?.bytesOut).assertEqual(32);
      rt.onListenReady('r1', 19000);
      expect(rt.statusOf('r1')?.listenLabel).assertEqual('remote :19000');
      expect(rt.statusOf('r1')?.state).assertEqual('listening');
    });

    it('canStartAndLabel', 0, () => {
      expect(canStartForwardRule(makeRule('a', 'local', 1))).assertTrue();
      const disabled: PortForwardRule = makeRule('b', 'local', 1);
      disabled.enabled = false;
      expect(canStartForwardRule(disabled)).assertFalse();
      expect(forwardRuleLabel(makeRule('c', 'local', 80)).indexOf('本地') >= 0).assertTrue();
      expect(forwardRuleLabel(makeRule('d', 'dynamic', 1080)).indexOf('SOCKS5') >= 0).assertTrue();
    });
  });

  describe('LocalForwardSocket', () => {
    it('startStopAndInboundLogsNativeMissing', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      let accepted: number = 0;
      let missing: number = 0;
      const sock: LocalForwardSocket = new LocalForwardSocket('r1', {
        gateway: gw,
        onAccepted: () => {
          accepted++;
        },
        onNativeMissing: () => {
          missing++;
        }
      });
      expect(sock.start('127.0.0.1', 19000)).assertTrue();
      expect(sock.isStarted).assertTrue();
      gw.simulateConnection('127.0.0.1:5555');
      expect(accepted).assertEqual(1);
      expect(missing).assertEqual(1);
      sock.stop();
      expect(sock.isStarted).assertFalse();
    });
  });

  describe('DynamicForwardSession', () => {
    it('connectIPv4OpensDirectTcpip', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      const nf: FakeNativeForward = new FakeNativeForward();
      nf.handleToReturn = 55;
      const replies: number[][] = [];
      const dyn: DynamicForwardSession = new DynamicForwardSession('d1', {
        gateway: gw,
        nativeForward: nf,
        sessionHandle: 9,
        onClientReply: (_info: string, bytes: number[]) => {
          replies.push(bytes);
        }
      });
      expect(dyn.start('127.0.0.1', 11080)).assertTrue();
      gw.simulateConnection('127.0.0.1:4000');
      // greeting
      const g: DynamicLocalResult = dyn.onLocalData(
        '127.0.0.1:4000',
        new Uint8Array([0x05, 0x01, 0x00])
      );
      expect(g.replies).assertDeepEquals([0x05, 0x00]);
      // CONNECT IPv4 127.0.0.1:80
      const r: DynamicLocalResult = dyn.onLocalData(
        '127.0.0.1:4000',
        new Uint8Array([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
      );
      expect(r.openedHandle).assertEqual(55);
      expect(nf.openCount).assertEqual(1);
      expect(nf.lastHost).assertEqual('127.0.0.1');
      expect(nf.lastPort).assertEqual(80);
      expect(r.replies).assertDeepEquals(socks5SuccessReply());
      expect(dyn.connDebug('127.0.0.1:4000')?.phase).assertEqual('connected');
      expect(dyn.ownsHandle(55)).assertTrue();
      expect(replies.length >= 2).assertTrue();
    });

    it('connectDomainOpensDirectTcpip', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      const nf: FakeNativeForward = new FakeNativeForward();
      nf.handleToReturn = 66;
      const dyn: DynamicForwardSession = new DynamicForwardSession('d2', {
        gateway: gw,
        nativeForward: nf,
        sessionHandle: 3
      });
      dyn.start('127.0.0.1', 11081);
      gw.simulateConnection('c1');
      dyn.onLocalData('c1', new Uint8Array([0x05, 0x01, 0x00]));
      // domain "ab" port 443
      const r: DynamicLocalResult = dyn.onLocalData(
        'c1',
        new Uint8Array([0x05, 0x01, 0x00, 0x03, 0x02, 0x61, 0x62, 0x01, 0xbb])
      );
      expect(nf.lastHost).assertEqual('ab');
      expect(nf.lastPort).assertEqual(443);
      expect(r.openedHandle).assertEqual(66);
      expect(r.replies[1]).assertEqual(0x00);
    });

    it('connectOpenFailsReturnsErrorReply', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      const nf: FakeNativeForward = new FakeNativeForward();
      nf.handleToReturn = 0; // 未受理
      const dyn: DynamicForwardSession = new DynamicForwardSession('d3', {
        gateway: gw,
        nativeForward: nf,
        sessionHandle: 3
      });
      dyn.start('127.0.0.1', 11082);
      gw.simulateConnection('c2');
      dyn.onLocalData('c2', new Uint8Array([0x05, 0x01, 0x00]));
      const r: DynamicLocalResult = dyn.onLocalData(
        'c2',
        new Uint8Array([0x05, 0x01, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x50])
      );
      expect(r.closed).assertTrue();
      expect(r.openedHandle).assertEqual(0);
      expect(r.replies).assertDeepEquals(socks5ErrorReply(0x05));
      expect(dyn.activeConnCount).assertEqual(0);
    });

    it('bindCommandErrorReplyNoOpen', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      const nf: FakeNativeForward = new FakeNativeForward();
      const dyn: DynamicForwardSession = new DynamicForwardSession('d4', {
        gateway: gw,
        nativeForward: nf,
        sessionHandle: 3
      });
      dyn.start('127.0.0.1', 11083);
      gw.simulateConnection('c3');
      dyn.onLocalData('c3', new Uint8Array([0x05, 0x01, 0x00]));
      // BIND(0x02)
      const r: DynamicLocalResult = dyn.onLocalData(
        'c3',
        new Uint8Array([0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0, 80])
      );
      expect(r.closed).assertTrue();
      expect(nf.openCount).assertEqual(0);
      expect(r.replies).assertDeepEquals(socks5ErrorReply(0x07));
    });

    it('payloadAfterConnectGoesToForwardWrite', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      const nf: FakeNativeForward = new FakeNativeForward();
      nf.handleToReturn = 88;
      const dyn: DynamicForwardSession = new DynamicForwardSession('d5', {
        gateway: gw,
        nativeForward: nf,
        sessionHandle: 3
      });
      dyn.start('127.0.0.1', 11084);
      gw.simulateConnection('c4');
      dyn.onLocalData('c4', new Uint8Array([0x05, 0x01, 0x00]));
      dyn.onLocalData('c4', new Uint8Array([0x05, 0x01, 0x00, 0x01, 1, 1, 1, 1, 0x00, 0x50]));
      const payload: DynamicLocalResult = dyn.onLocalData(
        'c4',
        new Uint8Array([0x48, 0x65, 0x6c, 0x6c, 0x6f])
      );
      expect(payload.openedHandle).assertEqual(0);
      expect(nf.writes.length).assertEqual(1);
      expect(nf.writes[0]).assertEqual('ab:5');
    });

    it('vmStartDynamicCreatesSession', 0, () => {
      const store: RuleStore = new RuleStore();
      store.rules.push(makeRule('dyn1', 'dynamic', 11090));
      const nf: FakeNativeForward = new FakeNativeForward();
      const gateways: Map<string, NullListenGateway> = new Map();
      const vm: PortForwardViewModel = new PortForwardViewModel({
        rules: store,
        nativeForward: nf,
        sessionHandle: 5,
        makeListenGateway: (id: string): ListenGateway => {
          const g: NullListenGateway = new NullListenGateway();
          gateways.set(id, g);
          return g;
        }
      });
      vm.load('h1');
      const actions: ForwardAction[] = vm.start('dyn1');
      expect(actionKinds(actions).includes('listenStart')).assertTrue();
      const dyn: DynamicForwardSession | null = vm.dynamicSessionOf('dyn1');
      expect(dyn !== null).assertTrue();
      expect(dyn?.isStarted).assertTrue();
      const g: NullListenGateway | undefined = gateways.get('dyn1');
      g?.simulateConnection('dc1');
      const r: DynamicLocalResult | null = dyn !== null
        ? dyn.onLocalData('dc1', new Uint8Array([0x05, 0x01, 0x00]))
        : null;
      expect(r?.replies).assertDeepEquals([0x05, 0x00]);
      if (dyn !== null) {
        dyn.onLocalData('dc1', new Uint8Array([0x05, 0x01, 0x00, 0x01, 8, 8, 8, 8, 0x01, 0xbb]));
        expect(nf.lastHost).assertEqual('8.8.8.8');
        expect(nf.lastPort).assertEqual(443);
        expect(vm.ownerOfHandle(nf.handleToReturn)).assertEqual('dynamic');
      }
    });

    it('socks5ApplyConnectResultHelper', 0, () => {
      const hs: Socks5Handshake = new Socks5Handshake();
      hs.feed(new Uint8Array([0x05, 0x01, 0x00]));
      hs.feed(new Uint8Array([0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0, 80]));
      const ok: DynamicLocalResult = socks5ApplyConnectResult(hs, 10);
      expect(ok.openedHandle).assertEqual(10);
      expect(ok.replies).assertDeepEquals(socks5SuccessReply());
      const hs2: Socks5Handshake = new Socks5Handshake();
      hs2.feed(new Uint8Array([0x05, 0x01, 0x00]));
      hs2.feed(new Uint8Array([0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0, 80]));
      const bad: DynamicLocalResult = socks5ApplyConnectResult(hs2, 0);
      expect(bad.closed).assertTrue();
      expect(bad.replies).assertDeepEquals(socks5ErrorReply(0x05));
    });
  });

  describe('PortForwardViewModel', () => {
    it('loadAndToggle', 0, () => {
      const store: RuleStore = new RuleStore();
      store.rules.push(makeRule('f1', 'local', 18081));
      const vm: PortForwardViewModel = new PortForwardViewModel({
        rules: store,
        runtime: new PortForwardRuntime({ hasNativeChannel: true }),
        makeListenGateway: (_id: string): ListenGateway => new NullListenGateway()
      });
      vm.load('h1');
      expect(vm.rows.length).assertEqual(1);
      expect(vm.rows[0].running).assertFalse();
      vm.toggle('f1');
      expect(vm.rows[0].running).assertTrue();
      expect(vm.rows[0].status?.state).assertEqual('listening');
      vm.toggle('f1');
      expect(vm.rows[0].running).assertFalse();
    });

    it('startRejectsDisabledRule', 0, () => {
      const store: RuleStore = new RuleStore();
      const rule: PortForwardRule = makeRule('f2', 'local', 1);
      rule.enabled = false;
      rule.localPort = 0;
      store.rules.push(rule);
      const vm: PortForwardViewModel = new PortForwardViewModel({ rules: store });
      vm.load('h1');
      const actions: ForwardAction[] = vm.start('f2');
      expect(actions.length).assertEqual(0);
      expect(vm.error.length > 0).assertTrue();
    });

    it('attachSessionEnablesNativeBridge', 0, () => {
      const nf: FakeNativeForward = new FakeNativeForward();
      const store: RuleStore = new RuleStore();
      store.rules.push(makeRule('f3', 'local', 18082));
      const deps: PortForwardViewModelDeps = {
        rules: store,
        nativeForward: nf,
        sessionHandle: 0,
        makeListenGateway: (_id: string): ListenGateway => new NullListenGateway()
      };
      const vm: PortForwardViewModel = new PortForwardViewModel(deps);
      expect(vm.nativeBridgeReady).assertFalse();
      vm.attachSession(7, nf);
      expect(vm.nativeBridgeReady).assertTrue();
      const actions: ForwardAction[] = vm.start('f3');
      const kinds: string[] = actionKinds(actions);
      expect(kinds.includes('logNativeMissing')).assertFalse();
      const st: ForwardRuntimeStatus | null = vm.runtime.statusOf('f3');
      expect(st?.nativeChannelRequired).assertFalse();
      vm.detachSession();
      expect(vm.nativeBridgeReady).assertFalse();
    });

    it('localSocketCallsNativeOpenDirectTcpip', 0, () => {
      const gw: NullListenGateway = new NullListenGateway();
      const nf: FakeNativeForward = new FakeNativeForward();
      nf.handleToReturn = 9;
      const target: LocalForwardTarget = { host: '10.0.0.1', port: 22 };
      const sockDeps: LocalForwardSocketDeps = {
        gateway: gw,
        nativeForward: nf,
        sessionHandle: 3,
        target: target
      };
      const sock: LocalForwardSocket = new LocalForwardSocket('r9', sockDeps);
      expect(sock.hasNativeBridge).assertTrue();
      expect(sock.start('127.0.0.1', 19009)).assertTrue();
      gw.simulateConnection('127.0.0.1:6000');
      expect(nf.openCount).assertEqual(1);
      expect(nf.lastHost).assertEqual('10.0.0.1');
      expect(nf.lastPort).assertEqual(22);
      expect(sock.activeChannelCount).assertEqual(1);
    });

    it('remoteEventsAccountConnectionsAndBytes', 0, () => {
      const store: RuleStore = new RuleStore();
      store.rules.push(makeRule('rr1', 'remote', 19001));
      const nf: FakeNativeForwardExt = new FakeNativeForwardExt();
      nf.remoteHandleToReturn = 77;
      const vm: PortForwardViewModel = new PortForwardViewModel({
        rules: store,
        nativeForward: nf,
        sessionHandle: 11,
        makeListenGateway: (_id: string): ListenGateway => new NullListenGateway()
      });
      vm.load('h1');
      vm.start('rr1');
      expect(nf.remoteListenCount).assertEqual(1);
      // listen 就绪
      const listenOk: ForwardNativeEvent = {
        type: 'forwardListen',
        forward: 77,
        success: true,
        boundPort: 19001
      };
      vm.handleNativeEvent(listenOk);
      expect(vm.runtime.statusOf('rr1')?.listenLabel).assertEqual('remote :19001');
      // accept 入站
      const acceptEv: ForwardNativeEvent = {
        type: 'forwardAccept',
        forward: 901,
        listen: 77,
        success: true,
        origin: ''
      };
      vm.handleNativeEvent(acceptEv);
      expect(vm.runtime.statusOf('rr1')?.connections).assertEqual(1);
      expect(vm.ruleOfHandle(901)).assertEqual('rr1');
      expect(vm.ownerOfHandle(901)).assertEqual('remote');
      // 远端数据入账
      const data: ArrayBuffer = new ArrayBuffer(40);
      const dataEv: ForwardNativeEvent = {
        type: 'forwardData',
        forward: 901,
        data: data
      };
      vm.handleNativeEvent(dataEv);
      expect(vm.runtime.statusOf('rr1')?.bytesIn).assertEqual(40);
      expect(vm.runtime.statusOf('rr1')?.connections).assertEqual(1);
      // 关闭：连接数回落，流量保留
      const closeEv: ForwardNativeEvent = {
        type: 'forwardClose',
        forward: 901,
        reason: 'peer_eof'
      };
      vm.handleNativeEvent(closeEv);
      expect(vm.runtime.statusOf('rr1')?.connections).assertEqual(0);
      expect(vm.runtime.statusOf('rr1')?.bytesIn).assertEqual(40);
      expect(vm.ownerOfHandle(901)).assertNull();
    });

    it('remoteListenFailureSetsError', 0, () => {
      const store: RuleStore = new RuleStore();
      store.rules.push(makeRule('rr2', 'remote', 19002));
      const nf: FakeNativeForwardExt = new FakeNativeForwardExt();
      nf.remoteHandleToReturn = 88;
      const vm: PortForwardViewModel = new PortForwardViewModel({
        rules: store,
        nativeForward: nf,
        sessionHandle: 11,
        makeListenGateway: (_id: string): ListenGateway => new NullListenGateway()
      });
      vm.load('h1');
      vm.start('rr2');
      const failListen: ForwardNativeEvent = {
        type: 'forwardListen',
        forward: 88,
        success: false,
        message: '远程监听失败'
      };
      vm.handleNativeEvent(failListen);
      expect(vm.runtime.statusOf('rr2')?.state).assertEqual('error');
      expect(vm.runtime.statusOf('rr2')?.errorMessage).assertEqual('远程监听失败');
    });
  });

  describe('Socks5', () => {
    it('greetingAcceptsNoAuth', 0, () => {
      const g = socks5ProcessGreeting(new Uint8Array([0x05, 0x01, 0x00]));
      expect(g.phase).assertEqual('request');
      expect(g.consumed).assertEqual(3);
      expect(g.reply).assertDeepEquals([0x05, 0x00]);
    });

    it('greetingNeedsMoreBytes', 0, () => {
      const g = socks5ProcessGreeting(new Uint8Array([0x05]));
      expect(g.consumed).assertEqual(0);
      expect(g.phase).assertEqual('greeting');
    });

    it('greetingRejectsBadVersion', 0, () => {
      const g = socks5ProcessGreeting(new Uint8Array([0x04, 0x01, 0x00]));
      expect(g.phase).assertEqual('error');
    });

    it('greetingRejectsNoNoAuth', 0, () => {
      const g = socks5ProcessGreeting(new Uint8Array([0x05, 0x01, 0x02]));
      expect(g.phase).assertEqual('error');
      expect(g.reply).assertDeepEquals([0x05, 0xFF]);
    });

    it('requestConnectIPv4', 0, () => {
      const req = new Uint8Array([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50]);
      const r = socks5ProcessRequest(req);
      expect(r.readyToConnect).assertTrue();
      expect(r.connectHost).assertEqual('127.0.0.1');
      expect(r.connectPort).assertEqual(80);
      expect(r.consumed).assertEqual(10);
    });

    it('requestConnectDomain', 0, () => {
      // domain "ab" port 443
      const req = new Uint8Array([
        0x05, 0x01, 0x00, 0x03, 0x02, 0x61, 0x62, 0x01, 0xbb
      ]);
      const r = socks5ProcessRequest(req);
      expect(r.readyToConnect).assertTrue();
      expect(r.connectHost).assertEqual('ab');
      expect(r.connectPort).assertEqual(443);
    });

    it('requestRejectsBind', 0, () => {
      const req = new Uint8Array([0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0, 80]);
      const r = socks5ProcessRequest(req);
      expect(r.phase).assertEqual('error');
      expect(r.reply).assertDeepEquals(socks5ErrorReply(0x07));
    });

    it('requestRejectsBadAtyp', 0, () => {
      const req = new Uint8Array([0x05, 0x01, 0x00, 0x09, 0, 0]);
      const r = socks5ProcessRequest(req);
      expect(r.phase).assertEqual('error');
      expect(r.reply).assertDeepEquals(socks5ErrorReply(0x08));
    });

    it('successReplyBytes', 0, () => {
      const ok = socks5SuccessReply();
      expect(ok.length).assertEqual(10);
      expect(ok[0]).assertEqual(0x05);
      expect(ok[1]).assertEqual(0x00);
    });

    it('handshakeFullFlow', 0, () => {
      const hs: Socks5Handshake = new Socks5Handshake();
      const feed1 = hs.feed(new Uint8Array([0x05, 0x01, 0x00]));
      expect(feed1.reply).assertDeepEquals([0x05, 0x00]);
      expect(feed1.readyToConnect).assertFalse();
      const feed2 = hs.feed(new Uint8Array([0x05, 0x01, 0x00, 0x01, 10, 0, 0, 2, 0x1F, 0x90]));
      expect(feed2.readyToConnect).assertTrue();
      expect(hs.connectHost).assertEqual('10.0.0.2');
      expect(hs.connectPort).assertEqual(8080);
      const reply: number[] = hs.completeConnect();
      expect(reply).assertDeepEquals(socks5SuccessReply());
      expect(hs.isComplete).assertTrue();
    });
  });

  describe('ProxyJump', () => {
    it('parseSpecSingleAndMulti', 0, () => {
      const one: ProxyJumpHopSpec[] = parseProxyJumpSpec('alice@h1:2222');
      expect(one.length).assertEqual(1);
      expect(one[0].username).assertEqual('alice');
      expect(one[0].host).assertEqual('h1');
      expect(one[0].port).assertEqual(2222);
      const multi: ProxyJumpHopSpec[] = parseProxyJumpSpec('u1@h1,u2@h2:22');
      expect(multi.length).assertEqual(2);
      expect(multi[1].host).assertEqual('h2');
      expect(parseProxyJumpSpec('').length).assertEqual(0);
      expect(parseProxyJumpSpec('u@').length).assertEqual(0);
    });

    it('hopsExecutable', 0, () => {
      expect(hopsAreExecutable(parseProxyJumpSpec('h1'))).assertTrue();
      expect(hopsAreExecutable([])).assertFalse();
    });

    it('planPathFollowsJumpHostId', 0, () => {
      const lookup: FakeJumpLookup = new FakeJumpLookup();
      const j1: JumpHostBrief = { id: 'j1', host: 'jump1', port: 22, username: 'u1', jumpHostId: null };
      const j2: JumpHostBrief = { id: 'j2', host: 'jump2', port: 22, username: 'u2', jumpHostId: 'j1' };
      const tgt: JumpHostBrief = { id: 'tgt', host: 'target', port: 22, username: 'root', jumpHostId: 'j2' };
      lookup.put(j1);
      lookup.put(j2);
      lookup.put(tgt);
      const path: JumpHostBrief[] | null = planProxyJumpPath(tgt, lookup);
      expect(path !== null).assertTrue();
      if (path !== null) {
        expect(path.length).assertEqual(3);
        expect(path[0].id).assertEqual('j1');
        expect(path[2].id).assertEqual('tgt');
      }
    });

    it('planPathDetectsCycle', 0, () => {
      const a: JumpHostBrief = { id: 'a', host: 'a', port: 22, username: '', jumpHostId: 'b' };
      const b: JumpHostBrief = { id: 'b', host: 'b', port: 22, username: '', jumpHostId: 'a' };
      const t: JumpHostBrief = { id: 't', host: 't', port: 22, username: '', jumpHostId: 'a' };
      const lookup: FakeJumpLookup = new FakeJumpLookup();
      lookup.put(a);
      lookup.put(b);
      const path: JumpHostBrief[] | null = planProxyJumpPath(t, lookup);
      expect(path).assertNull();
    });

    it('gapSummaryMentionsNative', 0, () => {
      expect(proxyJumpGapSummary().indexOf('native') >= 0).assertTrue();
    });

    it('dialStepsInvalidWhenPathNull', 0, () => {
      const steps: ProxyJumpDialStep[] = planProxyJumpDialSteps(null, false);
      expect(steps.length).assertEqual(1);
      expect(steps[0].kind).assertEqual('invalid');
      const orch: ProxyJumpOrchestration = proxyJumpOutcomeFromSteps(null, steps);
      expect(orch.blocked).assertTrue();
      expect(orch.errorMessage.indexOf('跳板路径无效') >= 0).assertTrue();
    });

    it('dialStepsGapWhenTransportNotReady', 0, () => {
      const path: JumpHostBrief[] = [
        { id: 'j1', host: 'bastion', port: 22, username: 'jump', jumpHostId: null },
        { id: 'tgt', host: 'target', port: 22, username: 'root', jumpHostId: 'j1' }
      ];
      const steps: ProxyJumpDialStep[] = planProxyJumpDialSteps(path, false);
      expect(steps.length).assertEqual(3);
      expect(steps[0].kind).assertEqual('dial');
      expect(steps[1].kind).assertEqual('openChannel');
      expect(steps[2].kind).assertEqual('gap');
      expect(steps[2].message.indexOf('native') >= 0).assertTrue();
      const orch: ProxyJumpOrchestration = proxyJumpOutcomeFromSteps(path, steps);
      expect(orch.blocked).assertTrue();
      expect(orch.firstHop?.host).assertEqual('bastion');
      expect(orch.nextAfterFirst?.host).assertEqual('target');
    });

    it('dialStepsChainWhenTransportReady', 0, () => {
      const path: JumpHostBrief[] = [
        { id: 'j1', host: 'bastion', port: 22, username: '', jumpHostId: null },
        { id: 'tgt', host: 'target', port: 22, username: '', jumpHostId: 'j1' }
      ];
      const steps: ProxyJumpDialStep[] = planProxyJumpDialSteps(path, true);
      expect(steps.length).assertEqual(3);
      expect(steps[2].kind).assertEqual('chainTransport');
      const orch: ProxyJumpOrchestration = proxyJumpOutcomeFromSteps(path, steps);
      expect(orch.blocked).assertFalse();
    });

    it('orchestrateProxyJumpPlanPure', 0, () => {
      const lookup: FakeJumpLookup = new FakeJumpLookup();
      lookup.put({ id: 'j1', host: 'b1', port: 22, username: 'u', jumpHostId: null });
      const tgt: JumpHostBrief = { id: 't', host: 'tgt', port: 22, username: 'r', jumpHostId: 'j1' };
      const gap: ProxyJumpOrchestration = orchestrateProxyJumpPlan(tgt, lookup, false);
      expect(gap.blocked).assertTrue();
      expect(gap.errorMessage.indexOf(proxyJumpGapSummary().slice(0, 10)) >= 0 ||
        gap.errorMessage.indexOf('ProxyJump') >= 0).assertTrue();
      const ready: ProxyJumpOrchestration = orchestrateProxyJumpPlan(tgt, lookup, true);
      expect(ready.blocked).assertFalse();
      const missing: ProxyJumpOrchestration = orchestrateProxyJumpPlan(
        { id: 't2', host: 'x', port: 22, username: '', jumpHostId: 'nope' },
        lookup,
        false
      );
      expect(missing.blocked).assertTrue();
      expect(missing.errorMessage.indexOf('无效') >= 0).assertTrue();
    });
  });

  describe('SessionManagerProxyJump', () => {
    it('jumpPlanFailureMissingHopSetsErrorNoHang', 0, async () => {
      const env: JumpTestEnv = new JumpTestEnv();
      env.putHost('tgt', 'target.internal', 22, 'root', 'missing-jump');
      const host: HostProfile | undefined = env.hosts.get('tgt');
      expect(host !== undefined).assertTrue();
      if (host === undefined) {
        return;
      }
      const info: SessionInfo = await env.manager.connect(host);
      expect(info.state).assertEqual('error');
      expect(info.errorMessage.indexOf('跳板路径无效') >= 0).assertTrue();
      expect(info.errorCodeName).assertEqual('proxy_jump_gap');
      // 不为错误路径创建 native 会话（dialNative 未走）
      expect(env.created.length).assertEqual(0);
    });

    it('jumpPlanSuccessDialsHopThenGapError', 0, async () => {
      const env: JumpTestEnv = new JumpTestEnv();
      env.putHost('j1', 'bastion.example', 2222, 'jump', null);
      env.putHost('tgt', 'target.internal', 22, 'root', 'j1');
      env.openChannelHandle = 303;
      env.withChainedApi = false;
      const host: HostProfile | undefined = env.hosts.get('tgt');
      expect(host !== undefined).assertTrue();
      if (host === undefined) {
        return;
      }
      const info: SessionInfo = await env.manager.connect(host);
      // 第一跳拨号已尝试（fake native 受理）
      expect(env.created.length >= 1).assertTrue();
      const hop: JumpFakeNativeSession = env.created[0];
      expect(hop.connectHost).assertEqual('bastion.example');
      expect(hop.connectPort).assertEqual(2222);
      expect(hop.connectUsername).assertEqual('jump');
      // openDirectTcpip 到下一跳被调用
      expect(env.openCalls.length).assertEqual(1);
      expect(env.openCalls[0].indexOf('target.internal') >= 0).assertTrue();
      // 传输层未打通：目标主机显式中文错误态，不 dialNative 目标
      expect(info.state).assertEqual('error');
      expect(info.errorCodeName).assertEqual('proxy_jump_gap');
      expect(info.errorMessage.indexOf('ProxyJump') >= 0).assertTrue();
      expect(info.errorMessage.indexOf('native') >= 0).assertTrue();
      expect(info.errorMessage.indexOf('target.internal') >= 0).assertTrue();
      // 跳板临时会话已关闭（不挂起）
      expect(hop.closeCount >= 1).assertTrue();
      // 目标会话未 dialNative（connectHost 不会是 target）
      for (const s of env.created) {
        expect(s.connectHost === 'target.internal').assertFalse();
      }
    });

    it('jumpOpenChannelRejectedSetsError', 0, async () => {
      const env: JumpTestEnv = new JumpTestEnv();
      env.putHost('j1', 'bastion', 22, 'jump', null);
      env.putHost('tgt', 'target', 22, 'root', 'j1');
      env.openChannelHandle = 0; // openDirectTcpip 未受理
      const host: HostProfile | undefined = env.hosts.get('tgt');
      if (host === undefined) {
        expect(host !== undefined).assertTrue();
        return;
      }
      const info: SessionInfo = await env.manager.connect(host);
      expect(info.state).assertEqual('error');
      expect(info.errorMessage.indexOf('跳板通道未受理') >= 0).assertTrue();
    });

    it('jumpWithChainedTransportProceedsToTargetDial', 0, async () => {
      const env: JumpTestEnv = new JumpTestEnv();
      env.withChainedApi = true;
      env.putHost('j1', 'bastion', 22, 'jump', null);
      env.putHost('tgt', 'target', 22, 'root', 'j1');
      env.openChannelHandle = 404;
      const host: HostProfile | undefined = env.hosts.get('tgt');
      if (host === undefined) {
        expect(host !== undefined).assertTrue();
        return;
      }
      const info: SessionInfo = await env.manager.connect(host);
      // 串联 API 存在 + open 受理 → 不 blocked，继续 dialNative 目标
      expect(info.state).assertEqual('connecting');
      expect(info.errorMessage).assertEqual('');
      const hop: JumpFakeNativeSession = env.created[0];
      expect(hop.chainedHandle).assertEqual(404);
      // 最后一次 connect 是目标主机
      const last: JumpFakeNativeSession = env.created[env.created.length - 1];
      expect(last.connectHost).assertEqual('target');
    });
  });
}
