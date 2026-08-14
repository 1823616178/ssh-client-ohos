/**
 * HostEditViewModel —— 主机编辑页视图模型（任务 U2，DESIGN §4.3.1 / §5.2 / §7.1）。
 *
 * 逻辑与 UI 分离（对齐 U1 HostListViewModel 惯例）：
 *   - 校验、文本解析、表单↔实体映射全部为不依赖 context 的纯函数，hypium 直接覆盖；
 *   - @ObservedV2 的 VM 只做状态持有与编排，生产依赖（五个 DAO / CredentialStore /
 *     测试连接执行器 / id 生成器）全部经窄接口注入，单测注入内存 fake；
 *   - DAO 引用在调用时惰性解析，避免「页面构造早于数据库就绪」时构造即崩。
 *
 * 表单模型：HostEditForm 持有全部非敏感字段（端口/keepalive 以文本态编辑，映射时
 * 解析）；凭据（密码/密码短语/私钥）不进入 HostEditForm——页面以 @State 持有，
 * 仅在调用 save/runTestConnection 时打包为 CredentialDraft 传入。
 *
 * 凭据生命周期控制点（验收「测试连接凭据不经过 UI 层长期驻留」）：
 *   1. 编辑加载只探测凭据存在性（getSecret 读出即弃，只留 hasSaved* 布尔标记），
 *      绝不回填明文——表单中不存在凭据字段；
 *   2. 保存/测试连接时凭据以 CredentialDraft 传入，VM 只用局部变量转发给
 *      CredentialStore / TestConnectRunner，写完后 finally 中原地清零草稿；
 *   3. 编辑态凭据三态：unchanged（未碰，不写库）/ modified（输入新值，写库；
 *      改成空串等价清除）/ cleared（点「清除已保存」，removeSecret）；
 *   4. VM 的任何字段都不存凭据明文（本类无可赋凭据的成员），测试断言
 *      JSON.stringify(vm) 无明文。
 *
 * 测试连接：一次性流程（service/TestConnection.ets），不经 C4 SessionManager 会话
 * 注册表；结果中文文案 + hostKey 指纹展示；「信任并入库」写入 known_hosts 为
 * TOFU 最小闭环——真实连接中的确认/拒绝交互（含不匹配对比视图）归 U4。
 *
 * 转发规则：PortForwardRule 需 hostId 外键，故新建主机（未保存）转发段禁用；
 * 编辑态规则在页面暂存为 ForwardRuleForm 列表，保存时统一同步
 * （新增 insert / 修改 update / 删除 deleteById）。U9 PortForwardPage 接管
 * 启停与流量展示，本页只做规则的增删改与校验。
 */

import { util } from '@kit.ArkTS';
import { Logger } from '../common/utils/Logger';
import { SshError, SshErrorCode } from '../common/SshError';
import {
  AppearanceProfile,
  AuthType,
  HostGroup,
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  PortForwardType,
  createDefaultHostProfile
} from '../common/model/models';
import { AppDatabase } from '../repository/AppDatabase';
import { CredentialKind, CredentialStore } from '../repository/CredentialStore';
import {
  HostKeyInfo,
  TestConnectRequest,
  TestConnectResult,
  TestConnectRunner,
  createProductionTestConnectRunner
} from '../service/TestConnection';

const LOG_TAG: string = 'HostEdit';

// ---------------------------------------------------------------- 表单与凭据模型

/** 主机编辑表单（全部非敏感字段；端口/keepalive 以文本态编辑，校验/映射时解析） */
export interface HostEditForm {
  name: string;
  host: string;
  portText: string;
  username: string;
  authType: AuthType;
  /** null = 未分组 */
  groupId: string | null;
  /** null = 无跳板 */
  jumpHostId: string | null;
  termType: string;
  keepaliveText: string;
  /** 每行一条命令 */
  initCommandsText: string;
  /** 每行一条 KEY=VALUE */
  envVarsText: string;
  /** null = 默认外观 */
  appearanceId: string | null;
}

/** 新建模式表单默认值（与 createDefaultHostProfile 对齐） */
export function createEmptyHostEditForm(): HostEditForm {
  return {
    name: '',
    host: '',
    portText: '22',
    username: '',
    authType: 'password',
    groupId: null,
    jumpHostId: null,
    termType: 'xterm-256color',
    keepaliveText: '30',
    initCommandsText: '',
    envVarsText: '',
    appearanceId: null
  };
}

/**
 * 凭据草稿：页面 @State 凭据字段的瞬时打包，仅在 save/runTestConnection 调用栈内
 * 有效；VM 用完（写入凭据库或交给测试连接执行器后）finally 原地清零。
 */
export interface CredentialDraft {
  password: string;
  passphrase: string;
  privateKey: string;
}

export function createEmptyCredentialDraft(): CredentialDraft {
  return { password: '', passphrase: '', privateKey: '' };
}

/** 弃置凭据草稿：三格原地清零（保存/测试连接/页面消失的统一出口） */
export function discardCredentialDraft(draft: CredentialDraft): void {
  draft.password = '';
  draft.passphrase = '';
  draft.privateKey = '';
}

/** 编辑态凭据三态：unchanged 不动 / modified 写库（空串=清除）/ cleared 删除 */
export type CredentialEditState = 'unchanged' | 'modified' | 'cleared';

// ---------------------------------------------------------------- 纯函数：解析

function isAllDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}

/** 端口文本 → 数值；空/非纯数字/越界（1–65535）返回 null */
export function parsePortText(text: string): number | null {
  const trimmed: string = text.trim();
  if (!isAllDigits(trimmed)) {
    return null;
  }
  const port: number = parseInt(trimmed, 10);
  if (Number.isNaN(port) || port < 1 || port > 65535) {
    return null;
  }
  return port;
}

/** keepalive 秒数文本 → 数值；空/非纯数字/越界（0–86400，0 = 关闭心跳）返回 null */
export function parseKeepaliveText(text: string): number | null {
  const trimmed: string = text.trim();
  if (!isAllDigits(trimmed)) {
    return null;
  }
  const value: number = parseInt(trimmed, 10);
  if (Number.isNaN(value) || value < 0 || value > 86400) {
    return null;
  }
  return value;
}

/** 登录后自动执行命令：每行一条，去首尾空白，丢弃空行 */
export function parseInitCommandsText(text: string): string[] {
  const result: string[] = [];
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length > 0) {
      result.push(line);
    }
  }
  return result;
}

/** 命令数组 → 每行一条文本（parseInitCommandsText 的逆操作） */
export function serializeInitCommands(commands: string[]): string {
  return commands.join('\n');
}

/** 环境变量 KEY 合法性：字母或下划线开头，其余字母/数字/下划线（shell 标识符） */
export function isEnvKeyIdentifier(key: string): boolean {
  if (key.length === 0) {
    return false;
  }
  const first: number = key.charCodeAt(0);
  const firstOk: boolean = (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first === 95;
  if (!firstOk) {
    return false;
  }
  for (let i = 1; i < key.length; i++) {
    const code: number = key.charCodeAt(i);
    const ok: boolean = (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) || code === 95;
    if (!ok) {
      return false;
    }
  }
  return true;
}

/** envVars 解析结果：error 为空串 = 成功（envVars 有效）；否则携带首条错误文案 */
export interface EnvVarsParseResult {
  readonly envVars: Record<string, string>;
  readonly error: string;
}

/**
 * 环境变量文本 → Record：每行 KEY=VALUE；空行忽略；KEY 须为合法标识符，
 * VALUE 允许为空（「KEY=」）；任一非法行即失败并给出带行号的中文文案。
 */
export function parseEnvVarsText(text: string): EnvVarsParseResult {
  const envVars: Record<string, string> = {};
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    const lineNo: number = i + 1;
    const sep: number = line.indexOf('=');
    if (sep < 0) {
      return { envVars: {}, error: `第 ${lineNo} 行：须为 KEY=VALUE 格式` };
    }
    const key: string = line.substring(0, sep).trim();
    const value: string = line.substring(sep + 1);
    if (!isEnvKeyIdentifier(key)) {
      return { envVars: {}, error: `第 ${lineNo} 行：KEY「${key}」不是合法标识符（字母/下划线开头）` };
    }
    envVars[key] = value;
  }
  return { envVars: envVars, error: '' };
}

/** envVars Record → 每行 KEY=VALUE 文本（parseEnvVarsText 的逆操作） */
export function serializeEnvVars(envVars: Record<string, string>): string {
  const lines: string[] = [];
  const keys: string[] = Object.keys(envVars);
  for (let i = 0; i < keys.length; i++) {
    lines.push(`${keys[i]}=${envVars[keys[i]]}`);
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------- 纯函数：表单校验

/** 逐字段错误文案（空串 = 无错误；页面显示在对应输入框下） */
export interface HostEditErrors {
  name: string;
  host: string;
  port: string;
  username: string;
  termType: string;
  keepalive: string;
  envVars: string;
}

export function emptyHostEditErrors(): HostEditErrors {
  return { name: '', host: '', port: '', username: '', termType: '', keepalive: '', envVars: '' };
}

export function hasHostEditErrors(errors: HostEditErrors): boolean {
  return errors.name.length > 0 || errors.host.length > 0 || errors.port.length > 0 ||
    errors.username.length > 0 || errors.termType.length > 0 || errors.keepalive.length > 0 ||
    errors.envVars.length > 0;
}

/** 表单校验：名称/主机/用户名必填；端口 1–65535；keepalive 0–86400；termType 非空白；envVars 逐行解析 */
export function validateHostEditForm(form: HostEditForm): HostEditErrors {
  const errors: HostEditErrors = emptyHostEditErrors();
  if (form.name.trim().length === 0) {
    errors.name = '请输入名称';
  }
  if (form.host.trim().length === 0) {
    errors.host = '请输入主机地址';
  }
  if (parsePortText(form.portText) === null) {
    errors.port = '端口须为 1–65535 的整数';
  }
  if (form.username.trim().length === 0) {
    errors.username = '请输入用户名';
  }
  if (form.termType.trim().length === 0) {
    errors.termType = '终端类型不能为空';
  }
  if (parseKeepaliveText(form.keepaliveText) === null) {
    errors.keepalive = 'keepalive 须为 0–86400 的整数（秒，0 = 关闭）';
  }
  const envResult: EnvVarsParseResult = parseEnvVarsText(form.envVarsText);
  if (envResult.error.length > 0) {
    errors.envVars = envResult.error;
  }
  return errors;
}

// ---------------------------------------------------------------- 纯函数：转发规则

/** 转发规则表单（文本态端口；ruleId 空串 = 新建未保存） */
export interface ForwardRuleForm {
  ruleId: string;
  type: PortForwardType;
  bindAddress: string;
  localPortText: string;
  remoteHost: string;
  remotePortText: string;
  enabled: boolean;
}

export function createEmptyForwardRuleForm(): ForwardRuleForm {
  return {
    ruleId: '',
    type: 'local',
    bindAddress: '127.0.0.1',
    localPortText: '',
    remoteHost: '',
    remotePortText: '',
    enabled: true
  };
}

/** 实体 → 表单（编辑态加载；remote 类型的 localPort 语义为远端监听端口，见 models） */
export function forwardRuleToForm(rule: PortForwardRule): ForwardRuleForm {
  return {
    ruleId: rule.id,
    type: rule.type,
    bindAddress: rule.bindAddress,
    localPortText: rule.localPort > 0 ? `${rule.localPort}` : '',
    remoteHost: rule.remoteHost,
    remotePortText: rule.remotePort > 0 ? `${rule.remotePort}` : '',
    enabled: rule.enabled
  };
}

/** 转发规则逐字段错误文案（按类型只用其中一部分字段，见 validateForwardRuleForm） */
export interface ForwardRuleErrors {
  bindAddress: string;
  localPort: string;
  remoteHost: string;
  remotePort: string;
}

export function emptyForwardRuleErrors(): ForwardRuleErrors {
  return { bindAddress: '', localPort: '', remoteHost: '', remotePort: '' };
}

export function hasForwardRuleErrors(errors: ForwardRuleErrors): boolean {
  return errors.bindAddress.length > 0 || errors.localPort.length > 0 ||
    errors.remoteHost.length > 0 || errors.remotePort.length > 0;
}

const ERR_PORT_RANGE: string = '端口须为 1–65535 的整数';

/**
 * 按类型分别校验（§7.3 三种转发形态）：
 *   local   —— bindAddress + localPort（本地监听）+ remoteHost + remotePort 全要；
 *   remote  —— localPort（远端监听）+ remoteHost + remotePort（bindAddress 不适用）；
 *   dynamic —— bindAddress + localPort（SOCKS5 监听，无固定目标）。
 */
export function validateForwardRuleForm(form: ForwardRuleForm): ForwardRuleErrors {
  const errors: ForwardRuleErrors = emptyForwardRuleErrors();
  if (form.type === 'local' || form.type === 'dynamic') {
    if (form.bindAddress.trim().length === 0) {
      errors.bindAddress = '监听地址不能为空';
    }
  }
  if (parsePortText(form.localPortText) === null) {
    errors.localPort = ERR_PORT_RANGE;
  }
  if (form.type === 'local' || form.type === 'remote') {
    if (form.remoteHost.trim().length === 0) {
      errors.remoteHost = '目标主机不能为空';
    }
    if (parsePortText(form.remotePortText) === null) {
      errors.remotePort = ERR_PORT_RANGE;
    }
  }
  return errors;
}

/**
 * 表单 → 实体（先校验，非法返回 null；不适用的字段归位空值：
 * remote 的 bindAddress = ''，dynamic 的 remoteHost = '' / remotePort = 0）。
 */
export function forwardFormToRule(form: ForwardRuleForm, hostId: string, ruleId: string): PortForwardRule | null {
  if (hasForwardRuleErrors(validateForwardRuleForm(form))) {
    return null;
  }
  const localPort: number | null = parsePortText(form.localPortText);
  if (localPort === null) {
    return null;
  }
  const isLocal: boolean = form.type === 'local';
  const needsRemote: boolean = form.type === 'local' || form.type === 'remote';
  let remotePort: number = 0;
  if (needsRemote) {
    const parsed: number | null = parsePortText(form.remotePortText);
    if (parsed === null) {
      return null;
    }
    remotePort = parsed;
  }
  return {
    id: ruleId,
    hostId: hostId,
    type: form.type,
    bindAddress: form.type === 'remote' ? '' : form.bindAddress.trim(),
    localPort: localPort,
    remoteHost: needsRemote ? form.remoteHost.trim() : '',
    remotePort: remotePort,
    enabled: form.enabled
  };
}

// ---------------------------------------------------------------- 纯函数：表单 ↔ HostProfile 映射

/** HostProfile → 表单（编辑加载；envVars/initCommands 序列化为多行文本；不含凭据） */
export function hostProfileToForm(profile: HostProfile): HostEditForm {
  return {
    name: profile.name,
    host: profile.host,
    portText: `${profile.port}`,
    username: profile.username,
    authType: profile.authType,
    groupId: profile.groupId,
    jumpHostId: profile.jumpHostId,
    termType: profile.termType,
    keepaliveText: `${profile.keepalive}`,
    initCommandsText: serializeInitCommands(profile.initCommands),
    envVarsText: serializeEnvVars(profile.envVars),
    appearanceId: profile.appearanceId
  };
}

/**
 * 表单 → HostProfile（内部再跑一次校验，非法返回 null）。
 * id 与 hostFingerprint 由调用方决定：新建传新 UUID 与 ''，编辑传原值保留指纹。
 */
export function hostEditFormToProfile(form: HostEditForm, id: string, hostFingerprint: string): HostProfile | null {
  if (hasHostEditErrors(validateHostEditForm(form))) {
    return null;
  }
  const port: number | null = parsePortText(form.portText);
  const keepalive: number | null = parseKeepaliveText(form.keepaliveText);
  if (port === null || keepalive === null) {
    return null;
  }
  const profile: HostProfile = createDefaultHostProfile(id);
  profile.name = form.name.trim();
  profile.host = form.host.trim();
  profile.port = port;
  profile.username = form.username.trim();
  profile.authType = form.authType;
  profile.hostFingerprint = hostFingerprint;
  profile.keepalive = keepalive;
  profile.groupId = form.groupId;
  profile.appearanceId = form.appearanceId;
  profile.jumpHostId = form.jumpHostId;
  profile.initCommands = parseInitCommandsText(form.initCommandsText);
  profile.envVars = parseEnvVarsText(form.envVarsText).envVars;
  profile.termType = form.termType.trim();
  return profile;
}

// ---------------------------------------------------------------- 依赖窄接口（生产 = AppDatabase / CredentialStore，单测注入 fake）

export interface HostEditHostDaoLike {
  getById(id: string): HostProfile | null;
  listAll(): HostProfile[];
  insert(host: HostProfile): void;
  update(host: HostProfile): void;
}

export interface HostEditGroupDaoLike {
  listAll(): HostGroup[];
}

export interface HostEditAppearanceDaoLike {
  listAll(): AppearanceProfile[];
}

export interface HostEditForwardDaoLike {
  listByHostId(hostId: string): PortForwardRule[];
  insert(rule: PortForwardRule): void;
  update(rule: PortForwardRule): void;
  deleteById(id: string): void;
}

export interface HostEditKnownHostDaoLike {
  getByHostPortKey(host: string, port: number, keyType: string): KnownHostEntry | null;
  insert(entry: KnownHostEntry): void;
}

export type HostEditSecretGetter = (hostId: string, kind: CredentialKind) => Promise<string | null>;
export type HostEditSecretSetter = (hostId: string, kind: CredentialKind, value: string) => Promise<void>;
export type HostEditSecretRemover = (hostId: string, kind: CredentialKind) => Promise<void>;

/** 可选依赖集：缺省项走生产实现（惰性解析）；单测全部注入 fake */
export interface HostEditViewModelDeps {
  hostDao?: HostEditHostDaoLike;
  groupDao?: HostEditGroupDaoLike;
  appearanceDao?: HostEditAppearanceDaoLike;
  forwardDao?: HostEditForwardDaoLike;
  knownHostDao?: HostEditKnownHostDaoLike;
  getSecret?: HostEditSecretGetter;
  setSecret?: HostEditSecretSetter;
  removeSecret?: HostEditSecretRemover;
  newId?: () => string;
  testRunner?: TestConnectRunner;
}

/** 保存结果：ok 成功 / invalid 校验不过 / failed 存储故障（详见日志） */
export type HostEditSaveOutcome = 'ok' | 'invalid' | 'failed';

// ---------------------------------------------------------------- 视图模型

@ObservedV2
export class HostEditViewModel {
  /** 加载中（编辑模式初载含凭据存在性探测，为异步） */
  @Trace loading: boolean = true;
  /** 加载失败文案（空串 = 正常） */
  @Trace loadError: string = '';
  /** 是否编辑既有主机（false = 新建） */
  @Trace isEdit: boolean = false;
  /** 保存进行中（按钮防抖） */
  @Trace saving: boolean = false;
  /** 分组下拉数据源 */
  @Trace groups: HostGroup[] = [];
  /** 跳板主机下拉数据源（编辑态已排除自身） */
  @Trace jumpCandidates: HostProfile[] = [];
  /** 外观下拉数据源 */
  @Trace appearances: AppearanceProfile[] = [];
  /** 转发规则表单列表（编辑态加载/维护；新建主机未保存时禁用，见页面提示） */
  @Trace ruleForms: ForwardRuleForm[] = [];
  /** 主表单逐字段错误（validate 后整体替换驱动刷新） */
  @Trace errors: HostEditErrors = emptyHostEditErrors();
  /** 转发规则逐条错误（与 ruleForms 同序对齐） */
  @Trace forwardErrors: ForwardRuleErrors[] = [];
  /** 凭据存在性标记（加载时探测；true 时输入框显示「已保存」占位，不回填明文） */
  @Trace hasSavedPassword: boolean = false;
  @Trace hasSavedPassphrase: boolean = false;
  @Trace hasSavedPrivateKey: boolean = false;
  /** 测试连接进行中 */
  @Trace testing: boolean = false;
  /** 测试连接结果文案（空串 = 尚未测试） */
  @Trace testMessage: string = '';
  @Trace testSuccess: boolean = false;
  /** 测试期间收到的主机密钥（指纹展示素材；null = 未收到） */
  @Trace testHostKey: HostKeyInfo | null = null;
  /** 指纹是否已入 known_hosts（「信任并入库」后置位） */
  @Trace hostKeyTrusted: boolean = false;

  /** 当前编辑的主机 id（新建保存成功后回填；空串 = 尚未落库） */
  private hostId: string = '';
  /** 编辑加载时的既有指纹（保存时原样保留，TOFU 指纹不由本表单编辑） */
  private originalFingerprint: string = '';
  /** 待删除的已持久化转发规则 id（保存时统一 deleteById） */
  private deletedRuleIds: string[] = [];
  private passwordState: CredentialEditState = 'unchanged';
  private passphraseState: CredentialEditState = 'unchanged';
  private privateKeyState: CredentialEditState = 'unchanged';
  /** 最近一次测试连接的目标（hostKey 入库用；非敏感） */
  private lastTestedHost: string = '';
  private lastTestedPort: number = 0;

  private readonly injectedHostDao: HostEditHostDaoLike | null;
  private readonly injectedGroupDao: HostEditGroupDaoLike | null;
  private readonly injectedAppearanceDao: HostEditAppearanceDaoLike | null;
  private readonly injectedForwardDao: HostEditForwardDaoLike | null;
  private readonly injectedKnownHostDao: HostEditKnownHostDaoLike | null;
  private readonly injectedGetSecret: HostEditSecretGetter | null;
  private readonly injectedSetSecret: HostEditSecretSetter | null;
  private readonly injectedRemoveSecret: HostEditSecretRemover | null;
  private readonly newId: () => string;
  private readonly testRunner: TestConnectRunner;

  constructor(deps?: HostEditViewModelDeps) {
    this.injectedHostDao = deps?.hostDao ?? null;
    this.injectedGroupDao = deps?.groupDao ?? null;
    this.injectedAppearanceDao = deps?.appearanceDao ?? null;
    this.injectedForwardDao = deps?.forwardDao ?? null;
    this.injectedKnownHostDao = deps?.knownHostDao ?? null;
    this.injectedGetSecret = deps?.getSecret ?? null;
    this.injectedSetSecret = deps?.setSecret ?? null;
    this.injectedRemoveSecret = deps?.removeSecret ?? null;
    this.newId = deps?.newId ?? ((): string => util.generateRandomUUID());
    this.testRunner = deps?.testRunner ?? createProductionTestConnectRunner();
  }

  /**
   * 加载（新建传空串）：拉取下拉数据源；编辑模式额外加载主机、转发规则，
   * 并探测凭据存在性（读出即弃，只留布尔标记，绝不回填明文）。
   * 返回表单初始值；主机不存在/加载失败返回 null（loadError 置文案）。
   */
  async load(hostId: string): Promise<HostEditForm | null> {
    this.loading = true;
    this.loadError = '';
    try {
      this.groups = this.groupDao().listAll();
      this.appearances = this.appearanceDao().listAll();
      if (hostId.length === 0) {
        this.isEdit = false;
        this.hostId = '';
        this.jumpCandidates = this.hostDao().listAll();
        this.loading = false;
        return createEmptyHostEditForm();
      }
      const profile: HostProfile | null = this.hostDao().getById(hostId);
      if (profile === null) {
        this.loadError = '主机不存在或已被删除';
        this.loading = false;
        return null;
      }
      this.isEdit = true;
      this.hostId = profile.id;
      this.originalFingerprint = profile.hostFingerprint;
      this.jumpCandidates = this.hostDao().listAll()
        .filter((host: HostProfile) => host.id !== hostId);
      this.ruleForms = this.forwardDao().listByHostId(hostId)
        .map((rule: PortForwardRule) => forwardRuleToForm(rule));
      this.deletedRuleIds = [];
      this.hasSavedPassword = await this.probeSecret(hostId, 'password');
      this.hasSavedPassphrase = await this.probeSecret(hostId, 'passphrase');
      this.hasSavedPrivateKey = await this.probeSecret(hostId, 'private_key');
      this.loading = false;
      return hostProfileToForm(profile);
    } catch (err) {
      Logger.error(`主机编辑加载失败（hostId=${hostId}）: ${JSON.stringify(err)}`, LOG_TAG);
      this.loadError = '加载失败，详见日志';
      this.loading = false;
      return null;
    }
  }

  /** 凭据存在性探测：明文读出即弃（只留布尔）；读取故障记日志按「未保存」处理，不阻塞编辑 */
  private async probeSecret(hostId: string, kind: CredentialKind): Promise<boolean> {
    try {
      return (await this.getSecret()(hostId, kind)) !== null;
    } catch (err) {
      Logger.warn(`凭据存在性探测失败（kind=${kind}）: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  // ---------------------------------------------------------------- 校验

  /** 全量校验（主表单 + 转发规则），结果写入 errors/forwardErrors 供页面逐字段展示 */
  validate(form: HostEditForm): boolean {
    this.errors = validateHostEditForm(form);
    const ruleErrors: ForwardRuleErrors[] = [];
    for (let i = 0; i < this.ruleForms.length; i++) {
      ruleErrors.push(validateForwardRuleForm(this.ruleForms[i]));
    }
    this.forwardErrors = ruleErrors;
    if (hasHostEditErrors(this.errors)) {
      return false;
    }
    for (let i = 0; i < ruleErrors.length; i++) {
      if (hasForwardRuleErrors(ruleErrors[i])) {
        return false;
      }
    }
    return true;
  }

  // ---------------------------------------------------------------- 凭据编辑状态（页面 onChange/「清除已保存」回传）

  markCredentialModified(kind: CredentialKind): void {
    this.setCredentialState(kind, 'modified');
  }

  markCredentialCleared(kind: CredentialKind): void {
    this.setCredentialState(kind, 'cleared');
  }

  credentialStateOf(kind: CredentialKind): CredentialEditState {
    if (kind === 'password') {
      return this.passwordState;
    }
    if (kind === 'passphrase') {
      return this.passphraseState;
    }
    return this.privateKeyState;
  }

  private setCredentialState(kind: CredentialKind, state: CredentialEditState): void {
    if (kind === 'password') {
      this.passwordState = state;
    } else if (kind === 'passphrase') {
      this.passphraseState = state;
    } else {
      this.privateKeyState = state;
    }
  }

  // ---------------------------------------------------------------- 保存

  /**
   * 保存：校验 → HostDao 落库（新建生成 UUID）→ 有改动的凭据写 CredentialStore
   * （清空 = removeSecret）→ 凭据草稿 finally 清零 → 转发规则统一同步。
   * 新建保存成功后转为编辑态（hostId 回填，转发段随之可用）。
   */
  async save(form: HostEditForm, creds: CredentialDraft): Promise<HostEditSaveOutcome> {
    if (!this.validate(form)) {
      return 'invalid';
    }
    this.saving = true;
    try {
      const isNew: boolean = !this.isEdit;
      const id: string = isNew ? this.newId() : this.hostId;
      const profile: HostProfile | null = hostEditFormToProfile(form, id, this.originalFingerprint);
      if (profile === null) {
        this.saving = false;
        return 'invalid';
      }
      if (isNew) {
        this.hostDao().insert(profile);
      } else {
        this.hostDao().update(profile);
      }
      try {
        await this.persistCredentials(id, creds);
      } finally {
        // 验收点：凭据写完（无论成败）立即弃置，VM/表单不再持有明文
        discardCredentialDraft(creds);
      }
      this.syncForwardRules(id);
      if (isNew) {
        this.isEdit = true;
        this.hostId = id;
      }
      this.saving = false;
      return 'ok';
    } catch (err) {
      Logger.error(`主机保存失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.saving = false;
      return 'failed';
    }
  }

  /** 三格凭据按编辑状态写入/删除；返回后更新存在性标记并复位编辑状态 */
  private async persistCredentials(hostId: string, creds: CredentialDraft): Promise<void> {
    this.hasSavedPassword = await this.persistOneCredential(hostId, 'password',
      creds.password, this.passwordState, this.hasSavedPassword);
    this.passwordState = 'unchanged';
    this.hasSavedPassphrase = await this.persistOneCredential(hostId, 'passphrase',
      creds.passphrase, this.passphraseState, this.hasSavedPassphrase);
    this.passphraseState = 'unchanged';
    this.hasSavedPrivateKey = await this.persistOneCredential(hostId, 'private_key',
      creds.privateKey, this.privateKeyState, this.hasSavedPrivateKey);
    this.privateKeyState = 'unchanged';
  }

  /** 单格凭据持久化；返回最新的存在性标记 */
  private async persistOneCredential(hostId: string, kind: CredentialKind, value: string,
    state: CredentialEditState, hadSaved: boolean): Promise<boolean> {
    if (state === 'modified') {
      if (value.length > 0) {
        await this.setSecret()(hostId, kind, value);
        return true;
      }
      // 改成空串等价于清除
      if (hadSaved) {
        await this.removeSecret()(hostId, kind);
      }
      return false;
    }
    if (state === 'cleared') {
      if (hadSaved) {
        await this.removeSecret()(hostId, kind);
      }
      return false;
    }
    return hadSaved;
  }

  /** 转发规则统一同步：先删后写（新增 insert / 已有 update）；表单回填持久化 id */
  private syncForwardRules(hostId: string): void {
    const dao: HostEditForwardDaoLike = this.forwardDao();
    for (let i = 0; i < this.deletedRuleIds.length; i++) {
      dao.deleteById(this.deletedRuleIds[i]);
    }
    this.deletedRuleIds = [];
    const persistedForms: ForwardRuleForm[] = [];
    for (let i = 0; i < this.ruleForms.length; i++) {
      const ruleForm: ForwardRuleForm = this.ruleForms[i];
      const isNew: boolean = ruleForm.ruleId.length === 0;
      const ruleId: string = isNew ? this.newId() : ruleForm.ruleId;
      const rule: PortForwardRule | null = forwardFormToRule(ruleForm, hostId, ruleId);
      if (rule === null) {
        continue; // validate 已先行拦截，理论不可达；防御性跳过
      }
      if (isNew) {
        dao.insert(rule);
      } else {
        dao.update(rule);
      }
      persistedForms.push(forwardRuleToForm(rule));
    }
    this.ruleForms = persistedForms;
  }

  // ---------------------------------------------------------------- 转发规则表单操作（页面事件入口）

  /** 新增一条空白规则（仅编辑态；新建主机未保存时转发段禁用） */
  addRuleForm(): void {
    if (!this.isEdit) {
      return;
    }
    const next: ForwardRuleForm[] = this.ruleForms.slice();
    next.push(createEmptyForwardRuleForm());
    this.ruleForms = next;
  }

  /** 移除一条规则；已持久化的记入待删清单，保存时统一 deleteById */
  removeRuleForm(index: number): void {
    if (index < 0 || index >= this.ruleForms.length) {
      return;
    }
    const ruleId: string = this.ruleForms[index].ruleId;
    if (ruleId.length > 0) {
      this.deletedRuleIds.push(ruleId);
    }
    const next: ForwardRuleForm[] = this.ruleForms.slice();
    next.splice(index, 1);
    this.ruleForms = next;
  }

  /** 切换规则类型（整体替换数组驱动刷新；类型决定显示/校验哪些字段） */
  setRuleFormType(index: number, type: PortForwardType): void {
    if (index < 0 || index >= this.ruleForms.length) {
      return;
    }
    this.ruleForms[index].type = type;
    this.ruleForms = this.ruleForms.slice();
  }

  /** 切换启用开关（整体替换数组驱动刷新） */
  setRuleFormEnabled(index: number, enabled: boolean): void {
    if (index < 0 || index >= this.ruleForms.length) {
      return;
    }
    this.ruleForms[index].enabled = enabled;
    this.ruleForms = this.ruleForms.slice();
  }

  // ---------------------------------------------------------------- 测试连接（一次性，不经 SessionManager 注册表）

  /**
   * 测试连接：校验表单 → 凭据现取现用（优先草稿；空串且已保存时从凭据库取，
   * 全程只经局部变量，不入任何状态字段）→ 注入的执行器跑一次性连接 →
   * 结果中文文案与 hostKey 指纹落入 @Trace 字段供页面展示。
   * 出口 finally 清零凭据草稿（页面随后同步清空 @State 三格）。
   */
  async runTestConnection(form: HostEditForm, creds: CredentialDraft): Promise<void> {
    if (this.testing) {
      return;
    }
    this.testMessage = '';
    this.testSuccess = false;
    this.testHostKey = null;
    this.hostKeyTrusted = false;
    if (!this.validate(form)) {
      this.testMessage = '请先修正表单中的错误';
      return;
    }
    if (form.authType === 'agent') {
      this.testMessage = '应用内 agent 暂未开放，无法测试连接';
      return;
    }
    try {
      const port: number | null = parsePortText(form.portText);
      if (port === null) {
        this.testMessage = '请先修正表单中的错误';
        return;
      }
      // 凭据解析：局部变量现取现用，绝不赋值给 VM 字段
      let password: string = creds.password;
      let privateKey: string = creds.privateKey;
      let passphrase: string = creds.passphrase;
      if (form.authType === 'password') {
        if (password.length === 0 && this.isEdit && this.hasSavedPassword) {
          password = (await this.getSecret()(this.hostId, 'password')) ?? '';
        }
        if (password.length === 0) {
          this.testMessage = '请填写登录密码（或编辑已保存的主机时使用已存凭据）';
          return;
        }
      } else {
        if (privateKey.length === 0 && this.isEdit && this.hasSavedPrivateKey) {
          privateKey = (await this.getSecret()(this.hostId, 'private_key')) ?? '';
        }
        if (passphrase.length === 0 && this.isEdit && this.hasSavedPassphrase) {
          passphrase = (await this.getSecret()(this.hostId, 'passphrase')) ?? '';
        }
        if (privateKey.length === 0) {
          this.testMessage = '请粘贴私钥（或编辑已保存的主机时使用已存私钥）';
          return;
        }
      }
      const request: TestConnectRequest = {
        host: form.host.trim(),
        port: port,
        username: form.username.trim(),
        authType: form.authType,
        password: password,
        privateKey: privateKey,
        passphrase: passphrase
      };
      this.testing = true;
      this.lastTestedHost = request.host;
      this.lastTestedPort = request.port;
      const result: TestConnectResult = await this.testRunner(request);
      this.testSuccess = result.success;
      this.testMessage = result.message;
      this.testHostKey = result.hostKey;
    } catch (err) {
      Logger.error(`测试连接失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.testSuccess = false;
      this.testMessage = err instanceof SshError
        ? err.toUserMessage()
        : SshError.toUserMessage(SshErrorCode.INTERNAL_ERROR);
    } finally {
      this.testing = false;
      // 验收点：测试结束（无论成败）立即弃置草稿明文
      discardCredentialDraft(creds);
    }
  }

  /**
   * 「信任该指纹并入库」：把测试连接收到的主机密钥写入 known_hosts（TOFU 最小闭环）。
   * 已有记录时指纹一致视为已信任；不一致的覆盖/拒绝交互归 U4（真实连接中的
   * 首连确认与不匹配对比视图）。返回是否已处于信任态。
   */
  trustTestedHostKey(): boolean {
    const key: HostKeyInfo | null = this.testHostKey;
    if (key === null || this.lastTestedHost.length === 0 || this.lastTestedPort === 0) {
      return false;
    }
    try {
      const dao: HostEditKnownHostDaoLike = this.knownHostDao();
      const existing: KnownHostEntry | null =
        dao.getByHostPortKey(this.lastTestedHost, this.lastTestedPort, key.keyType);
      if (existing !== null) {
        this.hostKeyTrusted = existing.fingerprint === key.fingerprintSha256;
        return this.hostKeyTrusted;
      }
      const entry: KnownHostEntry = {
        id: this.newId(),
        host: this.lastTestedHost,
        port: this.lastTestedPort,
        keyType: key.keyType,
        fingerprint: key.fingerprintSha256,
        addedAt: new Date().toISOString()
      };
      dao.insert(entry);
      this.hostKeyTrusted = true;
      Logger.info(`主机指纹已入库（${this.lastTestedHost}:${this.lastTestedPort} ${key.keyType}）`, LOG_TAG);
      return true;
    } catch (err) {
      Logger.error(`主机指纹入库失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  // ---------------------------------------------------------------- 依赖惰性解析

  private hostDao(): HostEditHostDaoLike {
    return this.injectedHostDao ?? AppDatabase.hosts();
  }

  private groupDao(): HostEditGroupDaoLike {
    return this.injectedGroupDao ?? AppDatabase.groups();
  }

  private appearanceDao(): HostEditAppearanceDaoLike {
    return this.injectedAppearanceDao ?? AppDatabase.appearances();
  }

  private forwardDao(): HostEditForwardDaoLike {
    return this.injectedForwardDao ?? AppDatabase.forwards();
  }

  private knownHostDao(): HostEditKnownHostDaoLike {
    return this.injectedKnownHostDao ?? AppDatabase.knownHosts();
  }

  private getSecret(): HostEditSecretGetter {
    return this.injectedGetSecret ??
      ((hostId: string, kind: CredentialKind): Promise<string | null> =>
        CredentialStore.getSecret(hostId, kind));
  }

  private setSecret(): HostEditSecretSetter {
    return this.injectedSetSecret ??
      ((hostId: string, kind: CredentialKind, value: string): Promise<void> =>
        CredentialStore.setSecret(hostId, kind, value));
  }

  private removeSecret(): HostEditSecretRemover {
    return this.injectedRemoveSecret ??
      ((hostId: string, kind: CredentialKind): Promise<void> =>
        CredentialStore.removeSecret(hostId, kind));
  }
}
