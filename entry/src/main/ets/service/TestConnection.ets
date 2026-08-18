/**
 * 一次性测试连接（任务 U2，DESIGN §7.1 连接与认证）。
 *
 * 用途：HostEditPage「测试连接」按钮——在不落库、不进 SessionManager 会话注册表
 * （避免污染 U1 状态点）的前提下，验证表单中的主机/端口/用户名/凭据是否可用。
 *
 * 形态：独立一次性流程。SshNativeSession.create → connect → authenticate*（与 C4
 * 相同的「受理即发起」顺序，native 排队到握手后执行）→ 等待终态事件：
 *   - stateChange → established：成功；
 *   - stateChange → error / disconnected / closed：失败，errorCode 经
 *     SshError.fromNativeCode → toUserMessage 收口为中文文案；
 *   - 超时（默认 15s）：失败，SESSION_TIMEOUT；
 *   - hostKey 事件不算终态：记录 keyType / fingerprintSha256 / randomart 随结果返回，
 *     供页面展示指纹（TOFU 确认入库的完整闭环归 U4，见 HostEditViewModel 注释）。
 * 无论成败一律 close 会话（幂等），定时器撤销，资源零残留。
 *
 * 凭据纪律（验收「测试连接凭据不经过 UI 层长期驻留」的底层控制点）：
 * 请求对象携带明文，但 native 受理（connect/authenticate 同步返回 true）后底层已持有
 * 副本，本文件立即把请求对象中的三个凭据字段原地清零——此后事件等待、结果返回的全
 * 过程 ArkTS 侧不再持有明文；调用方（HostEditViewModel）另负责弃置表单草稿。
 *
 * 生产依赖（native 会话工厂 / 定时器）经窄接口注入，单测以 fake 全覆盖（对齐
 * C4 SessionManager 的注入惯例）。
 */

import { SshError, SshErrorCode } from '../common/SshError';
import { SshEvent, SshEventListener, SshNativeSession } from '../napi/SshNative';

/** 测试连接超时（毫秒）：覆盖 DNS/握手/认证全程，自定 15s */
export const TEST_CONNECT_TIMEOUT_MS: number = 15000;

/** 主机密钥信息（native hostKey 事件的子集，供指纹展示） */
export interface HostKeyInfo {
  readonly keyType: string;
  readonly fingerprintSha256: string;
  readonly randomart: string;
}

/**
 * 测试连接请求。authType 仅 password/key（agent 由调用方提前拦截）。
 * 凭据字段受理后被 runTestConnect 原地清零，调用方不应复用该对象。
 */
export interface TestConnectRequest {
  host: string;
  port: number;
  username: string;
  authType: 'password' | 'key';
  password: string;
  privateKey: string;
  passphrase: string;
}

/** 测试连接结果：成功/失败 + 中文文案 + 错误码 + 期间收到主机密钥（如有） */
export interface TestConnectResult {
  readonly success: boolean;
  readonly message: string;
  readonly errorCode: SshErrorCode | null;
  readonly hostKey: HostKeyInfo | null;
}

/** native 会话窄接口：测试连接用到的最小方法集（SshNativeSession 结构性满足） */
export interface TestConnectSessionLike {
  connect(host: string, port: number, username: string): boolean;
  authenticatePassword(password: string): boolean;
  authenticatePublicKey(privateKey: ArrayBuffer | string, publicKey: string, passphrase: string): boolean;
  close(): void;
}

/** native 会话工厂：生产 = SshNativeSession.create，测试 = fake 工厂 */
export type TestConnectSessionFactory = (onEvent: SshEventListener) => TestConnectSessionLike | null;

/** 超时定时器抽象：生产 = setTimeout/clearTimeout，测试 = 手动触发（不真等毫秒） */
export interface TestConnectTimer {
  schedule(delayMs: number, task: () => void): number;
  cancel(timerId: number): void;
}

/** 生产定时器：系统 setTimeout */
export class SystemTestConnectTimer implements TestConnectTimer {
  schedule(delayMs: number, task: () => void): number {
    return setTimeout(task, Math.max(0, delayMs));
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

/** 依赖集：factory 必填；timer/timeoutMs 缺省走生产值 */
export interface TestConnectDeps {
  factory: TestConnectSessionFactory;
  timer?: TestConnectTimer;
  timeoutMs?: number;
}

/** 测试连接执行器：页面 VM 注入的窄接口（测试时以 fake 替换，不触碰 native） */
export type TestConnectRunner = (request: TestConnectRequest) => Promise<TestConnectResult>;

function makeResult(success: boolean, message: string, errorCode: SshErrorCode | null,
  hostKey: HostKeyInfo | null): TestConnectResult {
  return { success: success, message: message, errorCode: errorCode, hostKey: hostKey };
}

/**
 * 执行一次性测试连接（全程不抛异常，结果经 Promise 返回）。
 * 会话创建与方法受理同步完成；终态经事件异步到达；settled 后迟到事件一律丢弃。
 */
export function runTestConnect(deps: TestConnectDeps, request: TestConnectRequest): Promise<TestConnectResult> {
  const timer: TestConnectTimer = deps.timer ?? new SystemTestConnectTimer();
  const timeoutMs: number = deps.timeoutMs ?? TEST_CONNECT_TIMEOUT_MS;
  return new Promise<TestConnectResult>((resolve: (result: TestConnectResult) => void) => {
    let settled: boolean = false;
    let timerId: number = -1;
    let session: TestConnectSessionLike | null = null;
    let hostKey: HostKeyInfo | null = null;

    const finish = (result: TestConnectResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timerId >= 0) {
        timer.cancel(timerId);
        timerId = -1;
      }
      if (session !== null) {
        session.close();
        session = null;
      }
      resolve(result);
    };

    /**
     * 进入 authenticating 后提交认证材料（只提交一次）。
     * 受理后 native 已持有凭据副本，立即原地清零请求对象中的明文，此后 ArkTS 侧零持有。
     */
    let authSubmitted: boolean = false;
    const submitAuth = (): void => {
      if (authSubmitted || settled || session === null) {
        return;
      }
      authSubmitted = true;
      const accepted: boolean = request.authType === 'password'
        ? session.authenticatePassword(request.password)
        : session.authenticatePublicKey(request.privateKey, '', request.passphrase);
      request.password = '';
      request.privateKey = '';
      request.passphrase = '';
      if (!accepted) {
        const code: SshErrorCode = request.authType === 'password'
          ? SshErrorCode.AUTH_PASSWORD_FAILED
          : SshErrorCode.AUTH_PUBLICKEY_FAILED;
        finish(makeResult(false, '认证请求未被受理', code, hostKey));
      }
    };

    const onEvent = (event: SshEvent): void => {
      if (event.type === 'hostKey') {
        // 首连指纹素材：随最终结果返回给页面展示；确认入库闭环归 U4
        hostKey = {
          keyType: event.keyType ?? '',
          fingerprintSha256: event.fingerprintSha256 ?? '',
          randomart: event.randomart ?? ''
        };
        return;
      }
      if (event.type !== 'stateChange') {
        return;
      }
      const to: string = event.to ?? '';
      if (to === 'authenticating') {
        // 认证只能在 authenticating 态发起（cpp/ssh/auth.cpp）；connect() 是受理语义，
        // 其返回时握手尚未完成，在那里同步发起必被拒。故推迟到本事件。
        submitAuth();
        return;
      }
      if (to === 'established') {
        finish(makeResult(true, '连接测试成功', null, hostKey));
        return;
      }
      if (to === 'error' || to === 'disconnected' || to === 'closed') {
        const code: SshErrorCode = event.errorCode !== undefined && event.errorCode > 0
          ? SshError.fromNativeCode(event.errorCode)
          : SshErrorCode.UNKNOWN;
        finish(makeResult(false, SshError.toUserMessage(code), code, hostKey));
      }
    };

    session = deps.factory(onEvent);
    if (session === null) {
      finish(makeResult(false, SshError.toUserMessage(SshErrorCode.INTERNAL_ERROR),
        SshErrorCode.INTERNAL_ERROR, null));
      return;
    }
    timerId = timer.schedule(timeoutMs, () => {
      const seconds: number = Math.floor(timeoutMs / 1000);
      finish(makeResult(false, `连接测试超时（${seconds} 秒内无响应）`, SshErrorCode.SESSION_TIMEOUT, hostKey));
    });
    if (!session.connect(request.host, request.port, request.username)) {
      finish(makeResult(false, '连接请求未被受理', SshErrorCode.INTERNAL_ERROR, null));
      return;
    }
  });
}

/** 生产执行器：直接驱动 SshNativeSession（不经 SessionManager 会话注册表） */
export function createProductionTestConnectRunner(): TestConnectRunner {
  return (request: TestConnectRequest): Promise<TestConnectResult> => {
    const factory: TestConnectSessionFactory =
      (onEvent: SshEventListener): TestConnectSessionLike | null => SshNativeSession.create(onEvent);
    return runTestConnect({ factory: factory }, request);
  };
}
