/**
 * ProxyJump —— N16 跳板机规划纯逻辑（DESIGN §3.3 / §7.3）。
 *
 * libssh2 无内建 ProxyJump；设计是在跳板会话上开 direct-tcpip 到下一跳:22，
 * 再把该通道读写注册为下级会话的 LIBSSH2_CALLBACK_SEND/RECV 传输层。
 * **当前 native SshSession 只支持真实 TCP fd，会话级串联尚未打通**
 * （native 注记见 forwardProxyJumpNotes / ssh/forward.h）。
 *
 * 本文件职责：
 *   - parseProxyJumpSpec：OpenSSH -J 子集 → hop 列表（与 native 同语义）
 *   - planProxyJumpPath：结合主机库解析出可执行的拨号顺序
 *   - SessionManager.connect 的编排注释见该文件（jumpHostId 拨号 stub）
 *
 * 纯逻辑：hypium 可全覆盖。
 */

export interface ProxyJumpHopSpec {
  username: string;
  host: string;
  port: number;
}

/** 主机库窄接口（生产 = AppDatabase.hosts()，测试 = fake） */
export interface JumpHostLookup {
  getById(id: string): JumpHostBrief | null;
}

export interface JumpHostBrief {
  id: string;
  host: string;
  port: number;
  username: string;
  jumpHostId: string | null;
}

/**
 * 解析 OpenSSH -J 规格子集：
 *   "h1" / "user@h1" / "h1:2222" / "user@h1:2222"
 *   多跳逗号分隔："u1@h1:22,u2@h2"
 * IPv6 字面量用方括号："[::1]:22"。
 * 非法片段使整规格失败 → 返回 []。
 */
export function parseProxyJumpSpec(spec: string): ProxyJumpHopSpec[] {
  const hops: ProxyJumpHopSpec[] = [];
  if (spec.length === 0) {
    return hops;
  }
  const tokens: string[] = spec.split(',');
  for (const raw of tokens) {
    const token: string = raw.trim();
    if (token.length === 0) {
      return [];
    }
    let rest: string = token;
    let username: string = '';
    const at: number = rest.lastIndexOf('@');
    if (at >= 0) {
      username = rest.slice(0, at);
      rest = rest.slice(at + 1);
    }
    if (rest.length === 0) {
      return [];
    }
    let host: string = '';
    let port: number = 22;
    if (rest.charAt(0) === '[') {
      const br: number = rest.indexOf(']');
      if (br <= 1) {
        return [];
      }
      host = rest.slice(1, br);
      if (br + 1 < rest.length) {
        if (rest.charAt(br + 1) !== ':' || br + 2 >= rest.length) {
          return [];
        }
        const portStr: string = rest.slice(br + 2);
        const parsed: number = parsePort(portStr);
        if (parsed <= 0) {
          return [];
        }
        port = parsed;
      }
    } else {
      const firstColon: number = rest.indexOf(':');
      const lastColon: number = rest.lastIndexOf(':');
      if (firstColon >= 0 && firstColon === lastColon) {
        host = rest.slice(0, firstColon);
        const parsed: number = parsePort(rest.slice(firstColon + 1));
        if (parsed <= 0) {
          return [];
        }
        port = parsed;
      } else if (firstColon >= 0) {
        // 多冒号且非 []：保守拒绝（避免误解析裸 IPv6）
        return [];
      } else {
        host = rest;
      }
    }
    if (host.length === 0) {
      return [];
    }
    hops.push({ username: username, host: host, port: port });
  }
  return hops;
}

function parsePort(s: string): number {
  if (s.length === 0 || s.length > 5) {
    return 0;
  }
  let n: number = 0;
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c < 48 || c > 57) {
      return 0;
    }
    n = n * 10 + (c - 48);
    if (n > 65535) {
      return 0;
    }
  }
  return n;
}

/**
 * 结合主机库把 jumpHostId 链展开成拨号顺序（从最近跳板到最终目标）。
 * target 为最终目标主机；jumpHostId 链沿 jumpHostId 回溯。
 * 成环 / 缺主机 / 链过深（>8）→ 返回 null。
 * 返回顺序：hop0（第一跳）… target（最后一项）。
 */
export function planProxyJumpPath(
  target: JumpHostBrief,
  lookup: JumpHostLookup
): JumpHostBrief[] | null {
  const chain: JumpHostBrief[] = [];
  const seen: Set<string> = new Set();
  let cursorId: string | null = target.jumpHostId;
  let depth: number = 0;
  while (cursorId !== null && cursorId.length > 0) {
    if (depth > 8) {
      return null;
    }
    if (seen.has(cursorId)) {
      return null; // 成环
    }
    seen.add(cursorId);
    const hop: JumpHostBrief | null = lookup.getById(cursorId);
    if (hop === null) {
      return null;
    }
    chain.push(hop);
    cursorId = hop.jumpHostId;
    depth++;
  }
  chain.reverse(); // 第一跳在前
  chain.push(target);
  return chain;
}

/** 规格 hops 是否可直接拨号（每跳 host 非空、port 合法） */
export function hopsAreExecutable(hops: ProxyJumpHopSpec[]): boolean {
  if (hops.length === 0) {
    return false;
  }
  for (const h of hops) {
    if (h.host.length === 0 || h.port <= 0 || h.port > 65535) {
      return false;
    }
  }
  return true;
}

/**
 * N16 执行缺口说明（与 native proxyJumpTransportNotes 同口径，UI/日志用）。
 * 完整串联待 SshSession 抽象传输层后落地；当前仅能：
 *   - 对第一跳真实 TCP 拨号；
 *   - 在已建立的跳板会话上 openDirectTcpip 到下一跳（数据面可用，
 *     但下级 SSH 会话尚不能把该通道当传输层）。
 */
export function proxyJumpGapSummary(): string {
  return 'ProxyJump：native 传输层未抽象（SshSession 绑定 TCP fd），多级串联未打通；' +
    '当前可规划 hop 链并在跳板会话上开 direct-tcpip 数据通道。';
}

// ---------------------------------------------------------------- N16 拨号编排（SessionManager 用）

export type ProxyJumpDialStepKind =
  | 'dial'          // 拨号某一跳（真实 TCP + 认证）
  | 'openChannel'   // 在当前跳 openDirectTcpip 到下一跳
  | 'chainTransport'// 把通道注册为下级会话传输层（native 打通后）
  | 'gap'           // native 串联缺口 → 显式错误，不挂起
  | 'invalid';      // jumpHostId 链无法展开

export interface ProxyJumpDialStep {
  kind: ProxyJumpDialStepKind;
  hopId: string;
  host: string;
  port: number;
  username: string;
  message: string;
}

export interface ProxyJumpOrchestration {
  path: JumpHostBrief[] | null;
  steps: ProxyJumpDialStep[];
  /** true = 目标会话不可继续（错误态，不 dialNative，不挂起） */
  blocked: boolean;
  errorMessage: string;
  /** 第一跳拨号目标（可尝试真实 connect） */
  firstHop: JumpHostBrief | null;
  /** 第一跳之后紧接着要 openDirectTcpip 的目标 */
  nextAfterFirst: JumpHostBrief | null;
}

/**
 * 把 hop 链展开成拨号步骤序列。
 * transportReady=false 时：dial → openChannel → gap（立即停，后续跳不再规划）。
 * path 无效（null / 空 / 仅目标无跳板）→ 单步 invalid。
 */
export function planProxyJumpDialSteps(
  path: JumpHostBrief[] | null,
  transportReady: boolean
): ProxyJumpDialStep[] {
  const steps: ProxyJumpDialStep[] = [];
  if (path === null || path.length < 2) {
    const invalid: ProxyJumpDialStep = {
      kind: 'invalid',
      hopId: '',
      host: '',
      port: 0,
      username: '',
      message: '跳板路径无效：无法展开 jumpHostId 链（主机缺失/成环/过深）'
    };
    steps.push(invalid);
    return steps;
  }
  for (let i = 0; i < path.length - 1; i++) {
    const hop: JumpHostBrief = path[i];
    const next: JumpHostBrief = path[i + 1];
    const dial: ProxyJumpDialStep = {
      kind: 'dial',
      hopId: hop.id,
      host: hop.host,
      port: hop.port,
      username: hop.username,
      message: `拨号跳板 ${hop.username.length > 0 ? hop.username + '@' : ''}${hop.host}:${hop.port}`
    };
    steps.push(dial);
    const openCh: ProxyJumpDialStep = {
      kind: 'openChannel',
      hopId: hop.id,
      host: next.host,
      port: next.port,
      username: next.username,
      message: `在 ${hop.host} 上 openDirectTcpip → ${next.host}:${next.port}`
    };
    steps.push(openCh);
    if (!transportReady) {
      const gap: ProxyJumpDialStep = {
        kind: 'gap',
        hopId: hop.id,
        host: next.host,
        port: next.port,
        username: next.username,
        message: `${proxyJumpGapSummary()} 目标 ${next.host} 暂不可达：` +
          '请等待 native 会话级串联（LIBSSH2_CALLBACK_SEND/RECV）落地。'
      };
      steps.push(gap);
      return steps;
    }
    const chain: ProxyJumpDialStep = {
      kind: 'chainTransport',
      hopId: next.id,
      host: next.host,
      port: next.port,
      username: next.username,
      message: `注册通道为 ${next.host} 会话传输层`
    };
    steps.push(chain);
  }
  return steps;
}

/** 从步骤序列提取编排结论（blocked + 中文错误 + 第一跳） */
export function proxyJumpOutcomeFromSteps(
  path: JumpHostBrief[] | null,
  steps: ProxyJumpDialStep[]
): ProxyJumpOrchestration {
  const out: ProxyJumpOrchestration = {
    path: path,
    steps: steps,
    blocked: false,
    errorMessage: '',
    firstHop: null,
    nextAfterFirst: null
  };
  if (path !== null && path.length >= 2) {
    out.firstHop = path[0];
    out.nextAfterFirst = path[1];
  }
  for (const step of steps) {
    if (step.kind === 'invalid') {
      out.blocked = true;
      out.errorMessage = step.message;
      out.firstHop = null;
      out.nextAfterFirst = null;
      return out;
    }
    if (step.kind === 'gap') {
      out.blocked = true;
      out.errorMessage = step.message;
      return out;
    }
  }
  return out;
}

/**
 * 规划 + 步骤 + 结论一步到位（SessionManager.connect 编排入口的纯逻辑部分）。
 * transportReady=false 时 blocked=true 且 errorMessage 含 proxyJumpGapSummary 口径。
 */
export function orchestrateProxyJumpPlan(
  target: JumpHostBrief,
  lookup: JumpHostLookup,
  transportReady: boolean
): ProxyJumpOrchestration {
  const path: JumpHostBrief[] | null = planProxyJumpPath(target, lookup);
  const steps: ProxyJumpDialStep[] = planProxyJumpDialSteps(path, transportReady);
  return proxyJumpOutcomeFromSteps(path, steps);
}
