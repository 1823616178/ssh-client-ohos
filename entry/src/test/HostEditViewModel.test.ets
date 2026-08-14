/**
 * HostEditViewModel / TestConnection 单元测试（任务 U2）。
 *
 * 全部用例不依赖 context：校验/解析/映射直接测纯函数；视图模型层注入内存 fake
 * （FakeHostDao / FakeForwardDao / FakeKnownHostDao / FakeSecretStore / FakeRunner，
 * 对齐 C1 InMemoryRdbGateway 与 C4 fake 注入惯例）；测试连接服务以 FakeTestSession +
 * ManualTimer 替代 native 会话与系统定时器。
 *
 * 覆盖：必填校验 / 端口与 keepalive 边界 / termType / initCommands 解析与序列化 /
 * envVars 逐行解析（KEY=VALUE 与合法标识符）/ 三种转发类型各自的合法与非法样本 /
 * 表单↔HostProfile 映射往返 / 保存编排（新建 UUID、凭据写入值与清空顺序、
 * 编辑态凭据三态、转发规则增删改同步）/ 编辑加载不回填明文 / 测试连接
 * （成功/失败/超时/不受理、hostKey 指纹捕获、凭据现取现用与弃置、指纹入库）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  createDefaultHostProfile
} from '../main/ets/common/model/models';
import { SshError, SshErrorCode } from '../main/ets/common/SshError';
import { SshEvent, SshEventListener } from '../main/ets/napi/SshNative';
import { CredentialKind } from '../main/ets/repository/CredentialStore';
import {
  CredentialDraft,
  ForwardRuleErrors,
  ForwardRuleForm,
  HostEditErrors,
  HostEditForm,
  HostEditHostDaoLike,
  HostEditKnownHostDaoLike,
  HostEditForwardDaoLike,
  HostEditSecretGetter,
  HostEditSecretRemover,
  HostEditSecretSetter,
  HostEditViewModel,
  HostEditViewModelDeps,
  createEmptyCredentialDraft,
  createEmptyForwardRuleForm,
  createEmptyHostEditForm,
  forwardFormToRule,
  hasForwardRuleErrors,
  hasHostEditErrors,
  hostEditFormToProfile,
  hostProfileToForm,
  isEnvKeyIdentifier,
  parseEnvVarsText,
  parseInitCommandsText,
  parseKeepaliveText,
  parsePortText,
  serializeInitCommands,
  validateForwardRuleForm,
  validateHostEditForm
} from '../main/ets/viewmodel/HostEditViewModel';
import {
  HostKeyInfo,
  TestConnectDeps,
  TestConnectRequest,
  TestConnectResult,
  TestConnectRunner,
  TestConnectSessionLike,
  TestConnectTimer,
  runTestConnect
} from '../main/ets/service/TestConnection';

// ---------- 内存 fake ----------

class FakeHostDao implements HostEditHostDaoLike {
  hosts: HostProfile[] = [];
  readonly insertedIds: string[] = [];
  readonly updatedIds: string[] = [];

  getById(id: string): HostProfile | null {
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].id === id) {
        return this.hosts[i];
      }
    }
    return null;
  }

  listAll(): HostProfile[] {
    return this.hosts;
  }

  insert(host: HostProfile): void {
    this.insertedIds.push(host.id);
    this.hosts.push(host);
  }

  update(host: HostProfile): void {
    this.updatedIds.push(host.id);
    this.hosts = this.hosts.filter((h: HostProfile) => h.id !== host.id);
    this.hosts.push(host);
  }
}

class FakeForwardDao implements HostEditForwardDaoLike {
  rules: PortForwardRule[] = [];
  readonly insertedIds: string[] = [];
  readonly updatedIds: string[] = [];
  readonly deletedIds: string[] = [];

  listByHostId(hostId: string): PortForwardRule[] {
    return this.rules.filter((rule: PortForwardRule) => rule.hostId === hostId);
  }

  insert(rule: PortForwardRule): void {
    this.insertedIds.push(rule.id);
    this.rules.push(rule);
  }

  update(rule: PortForwardRule): void {
    this.updatedIds.push(rule.id);
    this.rules = this.rules.filter((r: PortForwardRule) => r.id !== rule.id);
    this.rules.push(rule);
  }

  deleteById(id: string): void {
    this.deletedIds.push(id);
    this.rules = this.rules.filter((r: PortForwardRule) => r.id !== id);
  }
}

class FakeKnownHostDao implements HostEditKnownHostDaoLike {
  entries: KnownHostEntry[] = [];

  getByHostPortKey(host: string, port: number, keyType: string): KnownHostEntry | null {
    for (let i = 0; i < this.entries.length; i++) {
      const entry: KnownHostEntry = this.entries[i];
      if (entry.host === host && entry.port === port && entry.keyType === keyType) {
        return entry;
      }
    }
    return null;
  }

  insert(entry: KnownHostEntry): void {
    this.entries.push(entry);
  }
}

/**
 * 内存凭据库。draftRef 挂接待测草稿：set 瞬间记录草稿快照，
 * 用于断言「先写入、后清空」的顺序（写入时草稿必须仍持有明文）。
 */
class FakeSecretStore {
  readonly secrets: Map<string, string> = new Map();
  readonly setLog: string[] = [];
  readonly removeLog: string[] = [];
  readonly draftAtSet: string[] = [];
  draftRef: CredentialDraft | null = null;

  readonly get: HostEditSecretGetter = (hostId: string, kind: CredentialKind): Promise<string | null> => {
    const value: string | undefined = this.secrets.get(`${hostId}:${kind}`);
    return Promise.resolve(value === undefined ? null : value);
  };

  readonly set: HostEditSecretSetter = (hostId: string, kind: CredentialKind, value: string): Promise<void> => {
    this.setLog.push(`${kind}=${value}`);
    const draft: CredentialDraft | null = this.draftRef;
    this.draftAtSet.push(draft === null ? '' : `${draft.password}|${draft.passphrase}|${draft.privateKey}`);
    this.secrets.set(`${hostId}:${kind}`, value);
    return Promise.resolve();
  };

  readonly remove: HostEditSecretRemover = (hostId: string, kind: CredentialKind): Promise<void> => {
    this.removeLog.push(kind);
    this.secrets.delete(`${hostId}:${kind}`);
    return Promise.resolve();
  };
}

/** 测试连接执行器 fake：记录请求快照（凭据明文只在调用瞬间可见），返回可编程结果 */
class FakeRunner {
  calls: number = 0;
  readonly requestLog: string[] = [];
  result: TestConnectResult = { success: true, message: '连接测试成功', errorCode: null, hostKey: null };

  readonly run: TestConnectRunner = (request: TestConnectRequest): Promise<TestConnectResult> => {
    this.calls++;
    this.requestLog.push(`${request.host}:${request.port}:${request.username}:` +
      `${request.authType}:${request.password}:${request.privateKey}:${request.passphrase}`);
    return Promise.resolve(this.result);
  };
}

// ---------- 测试连接服务 fake ----------

class FakeTestSession implements TestConnectSessionLike {
  private readonly listener: SshEventListener;
  closedCount: number = 0;
  acceptConnect: boolean = true;
  acceptAuth: boolean = true;
  passwordArg: string = '';
  keyArg: string = '';

  constructor(listener: SshEventListener) {
    this.listener = listener;
  }

  connect(host: string, port: number, username: string): boolean {
    return this.acceptConnect;
  }

  authenticatePassword(password: string): boolean {
    this.passwordArg = password;
    return this.acceptAuth;
  }

  authenticatePublicKey(privateKey: ArrayBuffer | string, publicKey: string, passphrase: string): boolean {
    this.keyArg = typeof privateKey === 'string' ? privateKey : '<buffer>';
    return this.acceptAuth;
  }

  close(): void {
    this.closedCount++;
  }

  emit(event: SshEvent): void {
    this.listener(event);
  }
}

class ManualTimer implements TestConnectTimer {
  task: (() => void) | null = null;
  cancelled: boolean = false;

  schedule(delayMs: number, task: () => void): number {
    this.task = task;
    return 1;
  }

  cancel(timerId: number): void {
    this.cancelled = true;
  }

  fire(): void {
    const task: (() => void) | null = this.task;
    if (task !== null) {
      this.task = null;
      task();
    }
  }
}

// ---------- 测试数据辅助 ----------

function makeHost(id: string): HostProfile {
  const host: HostProfile = createDefaultHostProfile(id);
  host.name = `主机${id}`;
  host.host = '192.168.1.10';
  host.port = 2222;
  host.username = 'root';
  return host;
}

function makeRule(id: string, hostId: string): PortForwardRule {
  return {
    id: id,
    hostId: hostId,
    type: 'local',
    bindAddress: '127.0.0.1',
    localPort: 8080,
    remoteHost: 'db.internal',
    remotePort: 3306,
    enabled: true
  };
}

/** 合法表单（各用例在此基础上破坏单字段） */
function makeValidForm(): HostEditForm {
  const form: HostEditForm = createEmptyHostEditForm();
  form.name = '生产 Web';
  form.host = 'web.example.com';
  form.username = 'deploy';
  return form;
}

/** VM 测试夹具：VM + 全部内存 fake + 定序 id */
interface VmFixture {
  readonly vm: HostEditViewModel;
  readonly hostDao: FakeHostDao;
  readonly forwardDao: FakeForwardDao;
  readonly knownHostDao: FakeKnownHostDao;
  readonly store: FakeSecretStore;
  readonly runner: FakeRunner;
}

function makeVmFixture(): VmFixture {
  const hostDao: FakeHostDao = new FakeHostDao();
  const forwardDao: FakeForwardDao = new FakeForwardDao();
  const knownHostDao: FakeKnownHostDao = new FakeKnownHostDao();
  const store: FakeSecretStore = new FakeSecretStore();
  const runner: FakeRunner = new FakeRunner();
  let idSeq: number = 0;
  const deps: HostEditViewModelDeps = {
    hostDao: hostDao,
    forwardDao: forwardDao,
    knownHostDao: knownHostDao,
    getSecret: store.get,
    setSecret: store.set,
    removeSecret: store.remove,
    testRunner: runner.run,
    newId: (): string => {
      idSeq++;
      return `id-${idSeq}`;
    }
  };
  return {
    vm: new HostEditViewModel(deps),
    hostDao: hostDao,
    forwardDao: forwardDao,
    knownHostDao: knownHostDao,
    store: store,
    runner: runner
  };
}

/** 编辑态夹具：库里已有一台主机（可选预置凭据/规则） */
async function makeEditVmFixture(withPassword: string | null): Promise<VmFixture> {
  const fixture: VmFixture = makeVmFixture();
  fixture.hostDao.hosts = [makeHost('h1')];
  if (withPassword !== null) {
    fixture.store.secrets.set('h1:password', withPassword);
  }
  await fixture.vm.load('h1');
  return fixture;
}

// ---------- 测试连接服务夹具（顶层定义，describe 内禁嵌套函数） ----------

function makeTestConnectRequest(): TestConnectRequest {
  return {
    host: 'h',
    port: 22,
    username: 'u',
    authType: 'password',
    password: 'pw-secret',
    privateKey: '',
    passphrase: ''
  };
}

interface ServiceFixture {
  readonly created: FakeTestSession[];
  readonly timer: ManualTimer;
  readonly deps: TestConnectDeps;
}

/** acceptConnect/acceptAuth 预设受理开关（runTestConnect 内同步受理，须在调用前装好） */
function makeServiceFixture(acceptConnect: boolean, acceptAuth: boolean): ServiceFixture {
  const created: FakeTestSession[] = [];
  const timer: ManualTimer = new ManualTimer();
  const deps: TestConnectDeps = {
    factory: (listener: SshEventListener): TestConnectSessionLike => {
      const session: FakeTestSession = new FakeTestSession(listener);
      session.acceptConnect = acceptConnect;
      session.acceptAuth = acceptAuth;
      created.push(session);
      return session;
    },
    timer: timer
  };
  return { created: created, timer: timer, deps: deps };
}

export default function hostEditViewModelTest() {
  // ---------- 必填与数值边界校验 ----------

  describe('HostEditValidateTest', () => {

    it('合法表单无错误', 0, () => {
      const errors: HostEditErrors = validateHostEditForm(makeValidForm());
      expect(hasHostEditErrors(errors)).assertFalse();
    });

    it('名称主机用户名必填_空白视为空', 0, () => {
      const form: HostEditForm = makeValidForm();
      form.name = '  ';
      form.host = '';
      form.username = '';
      const errors: HostEditErrors = validateHostEditForm(form);
      expect(errors.name.length > 0).assertTrue();
      expect(errors.host.length > 0).assertTrue();
      expect(errors.username.length > 0).assertTrue();
      expect(hasHostEditErrors(errors)).assertTrue();
    });

    it('端口边界_1与65535合法_0与65536非法_非数字非法', 0, () => {
      expect(parsePortText('1')).assertEqual(1);
      expect(parsePortText(' 22 ')).assertEqual(22);
      expect(parsePortText('65535')).assertEqual(65535);
      expect(parsePortText('0')).assertNull();
      expect(parsePortText('65536')).assertNull();
      expect(parsePortText('')).assertNull();
      expect(parsePortText('abc')).assertNull();
      expect(parsePortText('-1')).assertNull();
      expect(parsePortText('22.5')).assertNull();
      const form: HostEditForm = makeValidForm();
      form.portText = '65536';
      expect(validateHostEditForm(form).port.length > 0).assertTrue();
    });

    it('keepalive边界_0与86400合法_86401非法', 0, () => {
      expect(parseKeepaliveText('0')).assertEqual(0);
      expect(parseKeepaliveText('86400')).assertEqual(86400);
      expect(parseKeepaliveText('86401')).assertNull();
      expect(parseKeepaliveText('')).assertNull();
      expect(parseKeepaliveText('-5')).assertNull();
      const form: HostEditForm = makeValidForm();
      form.keepaliveText = '86401';
      expect(validateHostEditForm(form).keepalive.length > 0).assertTrue();
    });

    it('termType纯空白非法', 0, () => {
      const form: HostEditForm = makeValidForm();
      form.termType = '   ';
      expect(validateHostEditForm(form).termType.length > 0).assertTrue();
      form.termType = 'vt100';
      expect(validateHostEditForm(form).termType.length).assertEqual(0);
    });
  });

  // ---------- initCommands / envVars 解析 ----------

  describe('HostEditParseTest', () => {

    it('initCommands每行一条_空行与空白行丢弃_往返一致', 0, () => {
      const commands: string[] = parseInitCommandsText('  ls -l \n\npwd\n  \nuname -a');
      expect(commands.join(',')).assertEqual('ls -l,pwd,uname -a');
      expect(serializeInitCommands(commands)).assertEqual('ls -l\npwd\nuname -a');
      expect(parseInitCommandsText('').length).assertEqual(0);
      expect(parseInitCommandsText(serializeInitCommands([])).length).assertEqual(0);
    });

    it('envVars合法多行_允许空值_往返一致', 0, () => {
      const result = parseEnvVarsText('LANG=zh_CN.UTF-8\n_EMPTY=\nEDITOR=vim');
      expect(result.error.length).assertEqual(0);
      expect(result.envVars['LANG']).assertEqual('zh_CN.UTF-8');
      expect(result.envVars['_EMPTY']).assertEqual('');
      expect(result.envVars['EDITOR']).assertEqual('vim');
      // 序列化后再解析往返一致
      const keys: string[] = Object.keys(result.envVars);
      const lines: string[] = [];
      for (let i = 0; i < keys.length; i++) {
        lines.push(`${keys[i]}=${result.envVars[keys[i]]}`);
      }
      const roundTrip = parseEnvVarsText(lines.join('\n'));
      expect(roundTrip.error.length).assertEqual(0);
      expect(roundTrip.envVars['LANG']).assertEqual('zh_CN.UTF-8');
    });

    it('envVars缺等号与非法KEY_报错带行号', 0, () => {
      expect(parseEnvVarsText('NO_EQUALS_SIGN').error.indexOf('第 1 行') >= 0).assertTrue();
      expect(parseEnvVarsText('A=1\n1BAD=x').error.indexOf('第 2 行') >= 0).assertTrue();
      expect(parseEnvVarsText('A-B=1').error.length > 0).assertTrue();
      expect(parseEnvVarsText('=v').error.length > 0).assertTrue();
      expect(isEnvKeyIdentifier('PATH')).assertTrue();
      expect(isEnvKeyIdentifier('_A1')).assertTrue();
      expect(isEnvKeyIdentifier('1A')).assertFalse();
      expect(isEnvKeyIdentifier('')).assertFalse();
      expect(isEnvKeyIdentifier('A B')).assertFalse();
      const form: HostEditForm = makeValidForm();
      form.envVarsText = 'BAD LINE';
      expect(validateHostEditForm(form).envVars.length > 0).assertTrue();
    });
  });

  // ---------- 转发规则校验（三种类型各自合法与非法样本） ----------

  describe('ForwardRuleValidateTest', () => {

    it('local合法样本_映射实体字段齐全', 0, () => {
      const form: ForwardRuleForm = createEmptyForwardRuleForm();
      form.localPortText = '8080';
      form.remoteHost = 'db.internal';
      form.remotePortText = '3306';
      expect(hasForwardRuleErrors(validateForwardRuleForm(form))).assertFalse();
      const rule: PortForwardRule | null = forwardFormToRule(form, 'h1', 'r1');
      expect(rule !== null).assertTrue();
      if (rule !== null) {
        expect(rule.hostId).assertEqual('h1');
        expect(rule.bindAddress).assertEqual('127.0.0.1');
        expect(rule.localPort).assertEqual(8080);
        expect(rule.remoteHost).assertEqual('db.internal');
        expect(rule.remotePort).assertEqual(3306);
        expect(rule.enabled).assertTrue();
      }
    });

    it('local缺目标主机或端口非法', 0, () => {
      const form: ForwardRuleForm = createEmptyForwardRuleForm();
      form.localPortText = '8080';
      const errors: ForwardRuleErrors = validateForwardRuleForm(form);
      expect(errors.remoteHost.length > 0).assertTrue();
      expect(errors.remotePort.length > 0).assertTrue();
      expect(forwardFormToRule(form, 'h1', 'r1')).assertNull();
    });

    it('remote合法样本_bindAddress不适用归空', 0, () => {
      const form: ForwardRuleForm = createEmptyForwardRuleForm();
      form.type = 'remote';
      form.bindAddress = ''; // remote 不要求监听地址
      form.localPortText = '9000';
      form.remoteHost = 'intranet.web';
      form.remotePortText = '80';
      expect(hasForwardRuleErrors(validateForwardRuleForm(form))).assertFalse();
      const rule: PortForwardRule | null = forwardFormToRule(form, 'h1', 'r2');
      expect(rule !== null).assertTrue();
      if (rule !== null) {
        expect(rule.type).assertEqual('remote');
        expect(rule.bindAddress).assertEqual('');
        expect(rule.localPort).assertEqual(9000);
      }
    });

    it('remote缺远端监听端口非法', 0, () => {
      const form: ForwardRuleForm = createEmptyForwardRuleForm();
      form.type = 'remote';
      form.localPortText = '';
      form.remoteHost = 'x';
      form.remotePortText = '80';
      expect(validateForwardRuleForm(form).localPort.length > 0).assertTrue();
    });

    it('dynamic合法样本_无固定目标字段归空', 0, () => {
      const form: ForwardRuleForm = createEmptyForwardRuleForm();
      form.type = 'dynamic';
      form.localPortText = '1080';
      expect(hasForwardRuleErrors(validateForwardRuleForm(form))).assertFalse();
      const rule: PortForwardRule | null = forwardFormToRule(form, 'h1', 'r3');
      expect(rule !== null).assertTrue();
      if (rule !== null) {
        expect(rule.type).assertEqual('dynamic');
        expect(rule.remoteHost).assertEqual('');
        expect(rule.remotePort).assertEqual(0);
      }
    });

    it('dynamic缺监听地址或端口非法', 0, () => {
      const form: ForwardRuleForm = createEmptyForwardRuleForm();
      form.type = 'dynamic';
      form.bindAddress = '  ';
      form.localPortText = '70000';
      const errors: ForwardRuleErrors = validateForwardRuleForm(form);
      expect(errors.bindAddress.length > 0).assertTrue();
      expect(errors.localPort.length > 0).assertTrue();
      expect(forwardFormToRule(form, 'h1', 'r4')).assertNull();
    });
  });

  // ---------- 表单 ↔ HostProfile 映射往返 ----------

  describe('HostEditMappingTest', () => {

    it('profile到form到profile全字段往返一致', 0, () => {
      const profile: HostProfile = createDefaultHostProfile('h1');
      profile.name = '生产 Web';
      profile.host = 'web.example.com';
      profile.port = 2222;
      profile.username = 'deploy';
      profile.authType = 'key';
      profile.hostFingerprint = 'SHA256:abc';
      profile.keepalive = 45;
      profile.groupId = 'g1';
      profile.appearanceId = 'a1';
      profile.jumpHostId = 'h0';
      profile.initCommands = ['ls -l', 'tmux attach'];
      const env: Record<string, string> = {};
      env['LANG'] = 'zh_CN.UTF-8';
      env['EDITOR'] = 'vim';
      profile.envVars = env;
      profile.termType = 'vt100';
      const form: HostEditForm = hostProfileToForm(profile);
      const back: HostProfile | null = hostEditFormToProfile(form, profile.id, profile.hostFingerprint);
      expect(back !== null).assertTrue();
      if (back !== null) {
        expect(back.id).assertEqual('h1');
        expect(back.name).assertEqual(profile.name);
        expect(back.host).assertEqual(profile.host);
        expect(back.port).assertEqual(2222);
        expect(back.username).assertEqual(profile.username);
        expect(back.authType).assertEqual('key');
        expect(back.hostFingerprint).assertEqual('SHA256:abc');
        expect(back.keepalive).assertEqual(45);
        expect(back.groupId).assertEqual('g1');
        expect(back.appearanceId).assertEqual('a1');
        expect(back.jumpHostId).assertEqual('h0');
        expect(back.initCommands.join('|')).assertEqual('ls -l|tmux attach');
        expect(back.envVars['LANG']).assertEqual('zh_CN.UTF-8');
        expect(back.envVars['EDITOR']).assertEqual('vim');
        expect(back.termType).assertEqual('vt100');
      }
    });

    it('非法表单映射返回null', 0, () => {
      const form: HostEditForm = makeValidForm();
      form.portText = 'abc';
      expect(hostEditFormToProfile(form, 'h1', '')).assertNull();
    });
  });

  // ---------- 视图模型：保存编排与凭据生命周期 ----------

  describe('HostEditVmSaveTest', () => {

    it('新建保存_生成UUID落库_凭据先写后清_VM序列化无明文', 0, async () => {
      const fixture: VmFixture = makeVmFixture();
      const form: HostEditForm | null = await fixture.vm.load('');
      expect(form !== null).assertTrue();
      if (form === null) {
        return;
      }
      form.name = 'web';
      form.host = '1.2.3.4';
      form.username = 'root';
      const creds: CredentialDraft = createEmptyCredentialDraft();
      creds.password = 's3cret';
      fixture.vm.markCredentialModified('password');
      fixture.store.draftRef = creds;
      const outcome: string = await fixture.vm.save(form, creds);
      expect(outcome).assertEqual('ok');
      // HostDao 落库（util.generateRandomUUID 由 newId fake 替代）
      expect(fixture.hostDao.insertedIds.join(',')).assertEqual('id-1');
      expect(fixture.hostDao.hosts[0].name).assertEqual('web');
      // 凭据写入值正确，且写入瞬间草稿仍持有明文（先写后清）
      expect(fixture.store.setLog.join(',')).assertEqual('password=s3cret');
      expect(fixture.store.draftAtSet[0].indexOf('s3cret') >= 0).assertTrue();
      // 保存后草稿立即清零；VM 序列化不含明文
      expect(creds.password).assertEqual('');
      expect(JSON.stringify(fixture.vm).indexOf('s3cret') < 0).assertTrue();
      // 保存成功转为编辑态
      expect(fixture.vm.isEdit).assertTrue();
    });

    it('校验不过不落库不写凭据', 0, async () => {
      const fixture: VmFixture = makeVmFixture();
      const form: HostEditForm | null = await fixture.vm.load('');
      if (form === null) {
        return;
      }
      const creds: CredentialDraft = createEmptyCredentialDraft();
      creds.password = 's3cret';
      const outcome: string = await fixture.vm.save(form, creds);
      expect(outcome).assertEqual('invalid');
      expect(fixture.hostDao.insertedIds.length).assertEqual(0);
      expect(fixture.store.setLog.length).assertEqual(0);
      expect(fixture.vm.errors.name.length > 0).assertTrue();
    });

    it('编辑加载不回填明文_只留存在性标记', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture('stored-pw');
      expect(fixture.vm.isEdit).assertTrue();
      expect(fixture.vm.hasSavedPassword).assertTrue();
      expect(fixture.vm.hasSavedPrivateKey).assertFalse();
      // 表单与 VM 序列化均不含凭据明文
      const form: HostEditForm = hostProfileToForm(fixture.hostDao.hosts[0]);
      expect(JSON.stringify(form).indexOf('stored-pw') < 0).assertTrue();
      expect(JSON.stringify(fixture.vm).indexOf('stored-pw') < 0).assertTrue();
    });

    it('编辑保存_凭据未碰不写库_清除与置空走removeSecret', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture('stored-pw');
      const form: HostEditForm = makeValidForm();
      const creds: CredentialDraft = createEmptyCredentialDraft();
      // 未触碰：不写不删，库中保留
      let outcome: string = await fixture.vm.save(form, creds);
      expect(outcome).assertEqual('ok');
      expect(fixture.hostDao.updatedIds.join(',')).assertEqual('h1');
      expect(fixture.store.setLog.length).assertEqual(0);
      expect(fixture.store.removeLog.length).assertEqual(0);
      expect(fixture.store.secrets.get('h1:password')).assertEqual('stored-pw');
      // 标记清除：removeSecret
      fixture.vm.markCredentialCleared('password');
      outcome = await fixture.vm.save(form, creds);
      expect(outcome).assertEqual('ok');
      expect(fixture.store.removeLog.join(',')).assertEqual('password');
      expect(fixture.store.secrets.get('h1:password')).assertUndefined();
      expect(fixture.vm.hasSavedPassword).assertFalse();
    });

    it('编辑保存_输入新值覆盖_改成空串等价清除', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture('stored-pw');
      const form: HostEditForm = makeValidForm();
      const creds: CredentialDraft = createEmptyCredentialDraft();
      creds.password = 'new-pw';
      fixture.vm.markCredentialModified('password');
      let outcome: string = await fixture.vm.save(form, creds);
      expect(outcome).assertEqual('ok');
      expect(fixture.store.setLog.join(',')).assertEqual('password=new-pw');
      expect(fixture.vm.hasSavedPassword).assertTrue();
      // 改成空串等价清除
      fixture.vm.markCredentialModified('password');
      outcome = await fixture.vm.save(form, createEmptyCredentialDraft());
      expect(outcome).assertEqual('ok');
      expect(fixture.store.removeLog.join(',')).assertEqual('password');
      expect(fixture.vm.hasSavedPassword).assertFalse();
    });

    it('转发规则随保存同步_新增insert修改update删除deleteById', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture(null);
      fixture.forwardDao.rules = [makeRule('r1', 'h1'), makeRule('r2', 'h1')];
      await fixture.vm.load('h1');
      expect(fixture.vm.ruleForms.length).assertEqual(2);
      // 删除 r1；修改 r2 的端口；新增一条 dynamic
      fixture.vm.removeRuleForm(0);
      fixture.vm.ruleForms[0].localPortText = '8081';
      fixture.vm.addRuleForm();
      const added: ForwardRuleForm = fixture.vm.ruleForms[1];
      added.type = 'dynamic';
      added.localPortText = '1080';
      const outcome: string = await fixture.vm.save(makeValidForm(), createEmptyCredentialDraft());
      expect(outcome).assertEqual('ok');
      expect(fixture.forwardDao.deletedIds.join(',')).assertEqual('r1');
      expect(fixture.forwardDao.updatedIds.join(',')).assertEqual('r2');
      expect(fixture.forwardDao.insertedIds.join(',')).assertEqual('id-1');
      // 新增规则 hostId 指向所属主机
      const stored: PortForwardRule[] = fixture.forwardDao.rules;
      expect(stored.length).assertEqual(2);
      expect(stored[1].hostId).assertEqual('h1');
      expect(stored[1].type).assertEqual('dynamic');
      // 保存后表单回填持久化 id（再次保存走 update 而非重复 insert）
      expect(fixture.vm.ruleForms[1].ruleId).assertEqual('id-1');
    });

    it('转发规则非法时保存被拦截_转发段不写入', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture(null);
      fixture.vm.addRuleForm(); // 空白规则：端口缺失
      const outcome: string = await fixture.vm.save(makeValidForm(), createEmptyCredentialDraft());
      expect(outcome).assertEqual('invalid');
      expect(fixture.forwardDao.insertedIds.length).assertEqual(0);
      expect(fixture.vm.forwardErrors.length).assertEqual(1);
      expect(fixture.vm.forwardErrors[0].localPort.length > 0).assertTrue();
    });
  });

  // ---------- 视图模型：测试连接 ----------

  describe('HostEditVmTestConnectTest', () => {

    it('测试连接成功_凭据优先表单输入_用完即弃_指纹入库', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture('stored-pw');
      const hostKey: HostKeyInfo = {
        keyType: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:abcd',
        randomart: '+--[ED25519]--+'
      };
      fixture.runner.result = { success: true, message: '连接测试成功', errorCode: null, hostKey: hostKey };
      const creds: CredentialDraft = createEmptyCredentialDraft();
      creds.password = 'form-pw';
      await fixture.vm.runTestConnection(makeValidForm(), creds);
      // 表单输入优先于凭据库
      expect(fixture.runner.calls).assertEqual(1);
      expect(fixture.runner.requestLog[0].indexOf('form-pw') >= 0).assertTrue();
      // 用完即弃：草稿清零，VM 序列化无明文
      expect(creds.password).assertEqual('');
      expect(JSON.stringify(fixture.vm).indexOf('form-pw') < 0).assertTrue();
      expect(fixture.vm.testSuccess).assertTrue();
      expect(fixture.vm.testMessage).assertEqual('连接测试成功');
      expect(fixture.vm.testHostKey !== null).assertTrue();
      // 指纹入库：写入 known_hosts；重复信任不重复插入
      expect(fixture.vm.trustTestedHostKey()).assertTrue();
      expect(fixture.knownHostDao.entries.length).assertEqual(1);
      expect(fixture.knownHostDao.entries[0].fingerprint).assertEqual('SHA256:abcd');
      expect(fixture.knownHostDao.entries[0].host).assertEqual('web.example.com');
      expect(fixture.knownHostDao.entries[0].port).assertEqual(22);
      expect(fixture.vm.trustTestedHostKey()).assertTrue();
      expect(fixture.knownHostDao.entries.length).assertEqual(1);
    });

    it('表单凭据为空时回退凭据库现取现用', 0, async () => {
      const fixture: VmFixture = await makeEditVmFixture('stored-pw');
      await fixture.vm.runTestConnection(makeValidForm(), createEmptyCredentialDraft());
      expect(fixture.runner.calls).assertEqual(1);
      expect(fixture.runner.requestLog[0].indexOf('stored-pw') >= 0).assertTrue();
      expect(fixture.vm.testSuccess).assertTrue();
      // 取完即弃：VM 序列化不含库中明文
      expect(JSON.stringify(fixture.vm).indexOf('stored-pw') < 0).assertTrue();
    });

    it('agent认证拦截_缺凭据拦截_均不发起连接', 0, async () => {
      const fixture: VmFixture = makeVmFixture();
      await fixture.vm.load('');
      const form: HostEditForm = makeValidForm();
      form.authType = 'agent';
      await fixture.vm.runTestConnection(form, createEmptyCredentialDraft());
      expect(fixture.vm.testMessage.indexOf('暂未开放') >= 0).assertTrue();
      form.authType = 'password';
      await fixture.vm.runTestConnection(form, createEmptyCredentialDraft());
      expect(fixture.vm.testMessage.indexOf('请填写登录密码') >= 0).assertTrue();
      expect(fixture.runner.calls).assertEqual(0);
    });

    it('表单非法时不发起连接并提示', 0, async () => {
      const fixture: VmFixture = makeVmFixture();
      await fixture.vm.load('');
      const form: HostEditForm = makeValidForm();
      form.host = '';
      await fixture.vm.runTestConnection(form, createEmptyCredentialDraft());
      expect(fixture.runner.calls).assertEqual(0);
      expect(fixture.vm.testMessage.indexOf('修正') >= 0).assertTrue();
    });
  });

  // ---------- 测试连接服务（fake native 会话 + 手动定时器） ----------

  describe('TestConnectServiceTest', () => {

    it('成功_established收口_请求凭据受理后即清零_会话关闭', 0, async () => {
      const fixture: ServiceFixture = makeServiceFixture(true, true);
      const request: TestConnectRequest = makeTestConnectRequest();
      const promise: Promise<TestConnectResult> = runTestConnect(fixture.deps, request);
      const session: FakeTestSession = fixture.created[0];
      // 受理完成即弃置明文（事件等待期间 ArkTS 侧零持有）
      expect(request.password).assertEqual('');
      expect(session.passwordArg).assertEqual('pw-secret');
      session.emit({ type: 'hostKey', keyType: 'ssh-rsa', fingerprintSha256: 'SHA256:x', randomart: 'art' });
      session.emit({ type: 'stateChange', from: 'authenticating', to: 'established' });
      const result: TestConnectResult = await promise;
      expect(result.success).assertTrue();
      expect(result.message).assertEqual('连接测试成功');
      expect(result.hostKey !== null).assertTrue();
      if (result.hostKey !== null) {
        expect(result.hostKey.keyType).assertEqual('ssh-rsa');
        expect(result.hostKey.fingerprintSha256).assertEqual('SHA256:x');
        expect(result.hostKey.randomart).assertEqual('art');
      }
      expect(session.closedCount).assertEqual(1);
      expect(fixture.timer.cancelled).assertTrue();
    });

    it('失败_stateChange错误码映射中文文案_会话关闭', 0, async () => {
      const fixture: ServiceFixture = makeServiceFixture(true, true);
      const promise: Promise<TestConnectResult> = runTestConnect(fixture.deps, makeTestConnectRequest());
      fixture.created[0].emit({
        type: 'stateChange',
        from: 'authenticating',
        to: 'error',
        errorCode: 201,
        errorCodeName: 'auth_password_failed'
      });
      const result: TestConnectResult = await promise;
      expect(result.success).assertFalse();
      expect(result.errorCode).assertEqual(SshErrorCode.AUTH_PASSWORD_FAILED);
      expect(result.message).assertEqual(SshError.toUserMessage(SshErrorCode.AUTH_PASSWORD_FAILED));
      expect(fixture.created[0].closedCount).assertEqual(1);
    });

    it('超时_手动定时器触发_SESSION_TIMEOUT', 0, async () => {
      const fixture: ServiceFixture = makeServiceFixture(true, true);
      const promise: Promise<TestConnectResult> = runTestConnect(fixture.deps, makeTestConnectRequest());
      fixture.timer.fire();
      const result: TestConnectResult = await promise;
      expect(result.success).assertFalse();
      expect(result.errorCode).assertEqual(SshErrorCode.SESSION_TIMEOUT);
      expect(result.message.indexOf('超时') >= 0).assertTrue();
      expect(fixture.created[0].closedCount).assertEqual(1);
    });

    it('连接与认证不受理_立即失败且会话关闭', 0, async () => {
      const connectRejected: ServiceFixture = makeServiceFixture(false, true);
      const result1: TestConnectResult = await runTestConnect(connectRejected.deps, makeTestConnectRequest());
      expect(result1.success).assertFalse();
      expect(result1.message.indexOf('未被受理') >= 0).assertTrue();
      expect(connectRejected.created[0].closedCount).assertEqual(1);
      const authRejected: ServiceFixture = makeServiceFixture(true, false);
      const result2: TestConnectResult = await runTestConnect(authRejected.deps, makeTestConnectRequest());
      expect(result2.success).assertFalse();
      expect(result2.message.indexOf('未被受理') >= 0).assertTrue();
      expect(authRejected.created[0].closedCount).assertEqual(1);
    });
  });
}
