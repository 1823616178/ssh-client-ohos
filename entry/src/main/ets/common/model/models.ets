/**
 * 核心实体模型（DESIGN §5.2，任务 C3）。
 *
 * HostProfile / AppearanceProfile / Snippet / KnownHostEntry 的字段严格以 §5.2 代码块为准；
 * HostGroup / PortForwardRule 被 §6.3 同步文档引用但文档未给完整字段，这里按合理最小集定义，
 * 后续 C1 建表须与本文件保持一致。
 *
 * 全部为 interface + 字面量联合类型，不使用 any/unknown。
 * 除 KnownHostEntry 外每个实体附「创建默认值」工厂函数（KnownHostEntry 由首连 TOFU 时的
 * 真实主机密钥数据构造，没有有意义的默认值）；默认值取 §4.4 提到的常用值。
 */

/** 认证方式 */
export type AuthType = 'password' | 'key' | 'agent';

/** 光标样式 */
export type CursorStyle = 'block' | 'bar' | 'underline';

/** 端口转发类型：本地 -L / 远程 -R / 动态 -D（SOCKS5，§7.3） */
export type PortForwardType = 'local' | 'remote' | 'dynamic';

/** 主机配置（DESIGN §5.2） */
export interface HostProfile {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  authType: AuthType;
  /** 主机指纹（TOFU） */
  hostFingerprint: string;
  /** keepalive 秒数（§7.1 默认 30） */
  keepalive: number;
  groupId: string | null;
  /** 引用 AppearanceProfile */
  appearanceId: string | null;
  /** ProxyJump 跳板主机 */
  jumpHostId: string | null;
  /** 连接后自动执行 */
  initCommands: string[];
  envVars: Record<string, string>;
  /** 终端类型，默认 xterm-256color */
  termType: string;
}

/** 外观配置（DESIGN §5.2）；主题为独立实体，可被多个 HostProfile 引用并同步到云端 */
export interface AppearanceProfile {
  id: string;
  name: string;
  fontFamily: string;
  /** 8–32 */
  fontSize: number;
  /** 1.0–2.0 */
  lineHeight: number;
  letterSpacing: number;
  fontWeight: number;
  ligatures: boolean;
  boldAsBright: boolean;
  cursorStyle: CursorStyle;
  cursorBlink: boolean;
  /** 0–1 */
  backgroundOpacity: number;
  /** 终端四周内边距（vp） */
  padding: number;
  /** 16 个 #RRGGBB */
  palette: string[];
  foreground: string;
  background: string;
  cursorColor: string;
  selectionColor: string;
}

/** 命令片段（DESIGN §5.2） */
export interface Snippet {
  id: string;
  name: string;
  content: string;
  groupId: string | null;
}

/** known_hosts 条目（DESIGN §5.2）；addedAt 为 ISO 时间串 */
export interface KnownHostEntry {
  id: string;
  host: string;
  port: number;
  keyType: string;
  fingerprint: string;
  addedAt: string;
}

/** 主机分组（§6.3 引用，最小集） */
export interface HostGroup {
  id: string;
  name: string;
  /** 排序序号，越小越靠前 */
  order: number;
}

/** 端口转发规则（§6.3 引用，最小集；§7.3 三种转发形态） */
export interface PortForwardRule {
  id: string;
  /** 所属主机 */
  hostId: string;
  type: PortForwardType;
  /** 本地监听地址（local / dynamic 用） */
  bindAddress: string;
  /** 本地监听端口（local / dynamic 用；remote 语义下为远端监听端口） */
  localPort: number;
  /** 目标主机（local 用） */
  remoteHost: string;
  /** 目标端口（local 用） */
  remotePort: number;
  enabled: boolean;
}

/**
 * Harmony Dark 默认 16 色调色板（#RRGGBB，ANSI 0–15）。
 * 在 §4.2 Design Token 暗色系（页面底 #0E131D、主文字 #E8EEFB、强调 #4D8DFF、
 * 语义色 #34C77B / #F5A524 / #F4605F）基础上扩展成完整 16 色，属常见暗色终端配色；
 * 任务 A2（主题预设）会校准最终色值。
 */
export const HARMONY_DARK_PALETTE: string[] = [
  '#1B2536', // 0  黑
  '#F4605F', // 1  红
  '#34C77B', // 2  绿
  '#F5A524', // 3  黄
  '#4D8DFF', // 4  蓝
  '#C678DD', // 5  品红
  '#3EC6D9', // 6  青
  '#C9D4E8', // 7  白
  '#6B7891', // 8  亮黑
  '#FF7A79', // 9  亮红
  '#4FD88F', // 10 亮绿
  '#FFB84D', // 11 亮黄
  '#70A6FF', // 12 亮蓝
  '#D794F0', // 13 亮品红
  '#5ADBE8', // 14 亮青
  '#E8EEFB'  // 15 亮白
];

/** 创建默认主机配置（id 由调用方生成，UUID v4，见 §6.3 设计约定） */
export function createDefaultHostProfile(id: string): HostProfile {
  return {
    id: id,
    name: '',
    host: '',
    port: 22,
    username: '',
    authType: 'password',
    hostFingerprint: '',
    keepalive: 30,
    groupId: null,
    appearanceId: null,
    jumpHostId: null,
    initCommands: [],
    envVars: {},
    termType: 'xterm-256color'
  };
}

/** 创建默认外观配置：Harmony Dark 配色 + §4.4 常用值（JetBrains Mono / 14 / 1.2 / 块光标闪烁 / 不透明 / 内边距 8vp） */
export function createDefaultAppearanceProfile(id: string): AppearanceProfile {
  return {
    id: id,
    name: 'Harmony Dark',
    fontFamily: 'JetBrains Mono',
    fontSize: 14,
    lineHeight: 1.2,
    letterSpacing: 0,
    fontWeight: 400,
    ligatures: false,
    boldAsBright: true,
    cursorStyle: 'block',
    cursorBlink: true,
    backgroundOpacity: 1,
    padding: 8,
    // 返回独立副本，避免多个实例共享同一份可变数组
    palette: HARMONY_DARK_PALETTE.slice(),
    foreground: '#E8EEFB',
    background: '#0E131D',
    cursorColor: '#4D8DFF',
    selectionColor: '#26314A'
  };
}

/** 创建默认命令片段 */
export function createDefaultSnippet(id: string): Snippet {
  return {
    id: id,
    name: '',
    content: '',
    groupId: null
  };
}

/** 创建默认主机分组 */
export function createDefaultHostGroup(id: string): HostGroup {
  return {
    id: id,
    name: '',
    order: 0
  };
}

/** 创建默认端口转发规则：本地转发、绑定回环地址、默认启用 */
export function createDefaultPortForwardRule(id: string, hostId: string): PortForwardRule {
  return {
    id: id,
    hostId: hostId,
    type: 'local',
    bindAddress: '127.0.0.1',
    localPort: 0,
    remoteHost: '',
    remotePort: 0,
    enabled: true
  };
}
