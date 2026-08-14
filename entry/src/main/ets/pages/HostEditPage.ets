/**
 * HostEditPage —— 主机编辑页（任务 U2，DESIGN §4.3.1 页面清单 / §5.2 / §7.1）。
 *
 * 结构（单栏长表单，自上而下四个分段卡片）：
 *   - 顶栏：返回 + 标题（新建主机 / 编辑主机）；
 *   - 连接段：名称 / 主机 / 端口 / 用户名 / 分组下拉（GroupDao.listAll）/
 *     跳板主机下拉（HostDao.listAll，编辑态排除自身）；
 *   - 认证段：authType 三选（密码 / 密钥 / Agent）——password 显示密码框；
 *     key 显示私钥粘贴 TextArea + 密码短语框（文件选择器归 U3，占位注释）；
 *     agent 置灰「应用内 agent 暂未开放」；已保存凭据只显示「已保存」占位与
 *     「清除已保存」入口，绝不回填明文；
 *   - 终端段：termType（默认 xterm-256color）/ keepalive 秒 / initCommands
 *     每行一条 / envVars 每行 KEY=VALUE / 外观下拉（AppearanceDao.listAll）；
 *   - 转发段：该主机的 PortForwardRule 列表增删改（类型三选 + 按类型显示字段 +
 *     启停开关）；新建主机未保存时整段禁用并提示先保存（规则需 hostId 外键）；
 *   - 底栏：测试连接（一次性流程，结果与主机指纹内联展示）+ 保存。
 *
 * 凭据生命周期（验收「测试连接凭据不经过 UI 层长期驻留」的 UI 侧控制点）：
 * 密码 / 密码短语 / 私钥只存在于本页 @State 编辑期；保存或测试连接时打包为
 * CredentialDraft 交给 VM（VM 用完即原地清零），本页随后同步清空 @State 三格；
 * aboutToDisappear 兜底再清一次。VM 与日志绝不接触明文（见 HostEditViewModel 头注）。
 */

import { router } from '@kit.ArkUI';
import { AuthType, PortForwardType } from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import { Tokens } from '../theme/Tokens';
import {
  CredentialDraft,
  ForwardRuleErrors,
  ForwardRuleForm,
  HostEditForm,
  HostEditSaveOutcome,
  HostEditViewModel,
  createEmptyCredentialDraft,
  createEmptyHostEditForm,
  emptyForwardRuleErrors
} from '../viewmodel/HostEditViewModel';

const LOG_TAG: string = 'HostEditPage';

/** 私钥粘贴框最小高度（vp）：Token 表无「输入区高度」项，沿用 Index 局部常量惯例 */
const PRIVATE_KEY_AREA_MIN_HEIGHT_VP: number = 96;

@Entry
@Component
struct HostEditPage {
  /** 视图模型：校验 / 加载 / 保存 / 测试连接编排（生产依赖惰性解析 AppDatabase / CredentialStore） */
  private readonly vm: HostEditViewModel = new HostEditViewModel();

  // ---- 连接段 ----
  @State name: string = '';
  @State host: string = '';
  @State portText: string = '22';
  @State username: string = '';
  /** 分组选择（'' = 未分组；下拉项 id 与 vm.groups 同序偏移 1） */
  @State groupIdSel: string = '';
  /** 跳板主机选择（'' = 无跳板） */
  @State jumpHostIdSel: string = '';

  // ---- 认证段（凭据三格：只活在 @State 编辑期，保存/测试后立即清空，见文件头纪律）----
  @State authType: AuthType = 'password';
  @State password: string = '';
  @State passphrase: string = '';
  @State privateKey: string = '';

  // ---- 终端段 ----
  @State termType: string = 'xterm-256color';
  @State keepaliveText: string = '30';
  @State initCommandsText: string = '';
  @State envVarsText: string = '';
  /** 外观选择（'' = 默认外观） */
  @State appearanceIdSel: string = '';

  aboutToAppear(): void {
    const hostId: string = this.readHostIdParam();
    this.vm.load(hostId).then((form: HostEditForm | null) => {
      if (form !== null) {
        this.applyForm(form);
      }
    }).catch((err: Object) => {
      Logger.error(`主机编辑加载失败: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  aboutToDisappear(): void {
    // 凭据兜底清零：用户未保存直接返回时，@State 三格同样不得滞留明文
    this.clearCredentialStates();
  }

  /** 路由参数读取（编辑模式由 HostListPage 传入 hostId；缺省/非法 = 新建） */
  private readHostIdParam(): string {
    try {
      const params: Object | undefined = router.getParams();
      if (params === undefined || params === null) {
        return '';
      }
      const record: Record<string, Object> = params as Record<string, Object>;
      const value: Object | undefined = record['hostId'];
      return typeof value === 'string' ? value : '';
    } catch (err) {
      Logger.warn(`路由参数解析失败: ${JSON.stringify(err)}`, LOG_TAG);
      return '';
    }
  }

  /** 加载结果 → @State 表单字段（null 外键映射为 '' 哨兵） */
  private applyForm(form: HostEditForm): void {
    this.name = form.name;
    this.host = form.host;
    this.portText = form.portText;
    this.username = form.username;
    this.authType = form.authType;
    this.groupIdSel = form.groupId ?? '';
    this.jumpHostIdSel = form.jumpHostId ?? '';
    this.termType = form.termType;
    this.keepaliveText = form.keepaliveText;
    this.initCommandsText = form.initCommandsText;
    this.envVarsText = form.envVarsText;
    this.appearanceIdSel = form.appearanceId ?? '';
  }

  /** @State → 表单快照（'' 哨兵映射回 null 外键）；不含凭据 */
  private buildForm(): HostEditForm {
    const form: HostEditForm = createEmptyHostEditForm();
    form.name = this.name;
    form.host = this.host;
    form.portText = this.portText;
    form.username = this.username;
    form.authType = this.authType;
    form.groupId = this.groupIdSel.length === 0 ? null : this.groupIdSel;
    form.jumpHostId = this.jumpHostIdSel.length === 0 ? null : this.jumpHostIdSel;
    form.termType = this.termType;
    form.keepaliveText = this.keepaliveText;
    form.initCommandsText = this.initCommandsText;
    form.envVarsText = this.envVarsText;
    form.appearanceId = this.appearanceIdSel.length === 0 ? null : this.appearanceIdSel;
    return form;
  }

  /** @State 三格 → 凭据草稿（交 VM 使用后由 VM 原地清零） */
  private buildCreds(): CredentialDraft {
    const draft: CredentialDraft = createEmptyCredentialDraft();
    draft.password = this.password;
    draft.passphrase = this.passphrase;
    draft.privateKey = this.privateKey;
    return draft;
  }

  /** 清空 @State 凭据三格（保存/测试连接完成后与 aboutToDisappear 兜底共用） */
  private clearCredentialStates(): void {
    this.password = '';
    this.passphrase = '';
    this.privateKey = '';
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 显示失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  // ---------------------------------------------------------------- 交互

  /** 保存：VM 编排（校验 → 落库 → 凭据 → 转发规则），成功后返回列表 */
  private onSave(): void {
    const creds: CredentialDraft = this.buildCreds();
    this.vm.save(this.buildForm(), creds).then((outcome: HostEditSaveOutcome) => {
      // VM 已清零草稿；同步清空 @State（验收：凭据不在 UI 层驻留）
      this.clearCredentialStates();
      if (outcome === 'ok') {
        this.toast('已保存');
        router.back();
      } else if (outcome === 'invalid') {
        this.toast('请修正表单中标红的错误');
      } else {
        this.toast('保存失败，详见日志');
      }
    }).catch((err: Object) => {
      Logger.error(`保存失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.clearCredentialStates();
      this.toast('保存失败，详见日志');
    });
  }

  /** 测试连接：一次性流程（不经 SessionManager）；结果与指纹由 VM @Trace 字段驱动展示 */
  private onTestConnection(): void {
    const creds: CredentialDraft = this.buildCreds();
    this.vm.runTestConnection(this.buildForm(), creds)
      .then(() => {
        this.clearCredentialStates();
      })
      .catch((err: Object) => {
        Logger.error(`测试连接异常: ${JSON.stringify(err)}`, LOG_TAG);
        this.clearCredentialStates();
      });
  }

  // ---------------------------------------------------------------- 下拉数据（小列表，每次渲染现组即可）

  private groupOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '未分组' }];
    for (let i = 0; i < this.vm.groups.length; i++) {
      options.push({ value: this.vm.groups[i].name });
    }
    return options;
  }

  private groupSelectIndex(): number {
    if (this.groupIdSel.length > 0) {
      for (let i = 0; i < this.vm.groups.length; i++) {
        if (this.vm.groups[i].id === this.groupIdSel) {
          return i + 1;
        }
      }
    }
    return 0;
  }

  private jumpOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '无跳板' }];
    for (let i = 0; i < this.vm.jumpCandidates.length; i++) {
      const candidate = this.vm.jumpCandidates[i];
      options.push({ value: candidate.name.length > 0 ? candidate.name : candidate.host });
    }
    return options;
  }

  private jumpSelectIndex(): number {
    if (this.jumpHostIdSel.length > 0) {
      for (let i = 0; i < this.vm.jumpCandidates.length; i++) {
        if (this.vm.jumpCandidates[i].id === this.jumpHostIdSel) {
          return i + 1;
        }
      }
    }
    return 0;
  }

  private appearanceOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '默认外观' }];
    for (let i = 0; i < this.vm.appearances.length; i++) {
      options.push({ value: this.vm.appearances[i].name });
    }
    return options;
  }

  private appearanceSelectIndex(): number {
    if (this.appearanceIdSel.length > 0) {
      for (let i = 0; i < this.vm.appearances.length; i++) {
        if (this.vm.appearances[i].id === this.appearanceIdSel) {
          return i + 1;
        }
      }
    }
    return 0;
  }

  private ruleErrorAt(index: number): ForwardRuleErrors {
    return index < this.vm.forwardErrors.length ? this.vm.forwardErrors[index] : emptyForwardRuleErrors();
  }

  // ---------------------------------------------------------------- 视图

  build() {
    Column() {
      // 顶栏：返回 + 标题
      Row() {
        Text('‹')
          .fontSize(Tokens.fontSize.headline)
          .fontColor(Tokens.Color.text)
          .padding(Tokens.space.xs)
          .onClick(() => {
            router.back();
          })
        Text(this.vm.isEdit ? '编辑主机' : '新建主机')
          .fontSize(Tokens.fontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
          .margin({ left: Tokens.space.xs })
      }
      .width('100%')

      if (this.vm.loading) {
        Text('加载中…')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.lg })
      } else if (this.vm.loadError.length > 0) {
        Text(this.vm.loadError)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.danger)
          .margin({ top: Tokens.space.lg })
      } else {
        // 四段式表单（长表单滚动）
        Scroll() {
          Column() {
            this.ConnectionSection()
            this.AuthSection()
            this.TerminalSection()
            this.ForwardSection()
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
        .margin({ top: Tokens.space.sm })

        this.BottomBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .padding(Tokens.space.md)
  }

  // ---------------------------------------------------------------- 分段卡片

  /** 连接段：名称 / 主机 / 端口 / 用户名 / 分组 / 跳板主机 */
  @Builder
  ConnectionSection() {
    Column() {
      this.SectionTitle('连接')
      this.FieldLabel('名称')
      TextInput({ placeholder: '如：生产 Web', text: this.name })
        .fontSize(Tokens.fontSize.body)
        .onChange((value: string) => {
          this.name = value;
        })
      this.FieldError(this.vm.errors.name)

      this.FieldLabel('主机地址')
      TextInput({ placeholder: 'IP 或域名', text: this.host })
        .fontSize(Tokens.fontSize.body)
        .margin({ top: Tokens.space.xs })
        .onChange((value: string) => {
          this.host = value;
        })
      this.FieldError(this.vm.errors.host)

      Row() {
        Column() {
          this.FieldLabel('端口')
          TextInput({ placeholder: '22', text: this.portText })
            .fontSize(Tokens.fontSize.body)
            .onChange((value: string) => {
              this.portText = value;
            })
          this.FieldError(this.vm.errors.port)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          this.FieldLabel('用户名')
          TextInput({ placeholder: '如：root', text: this.username })
            .fontSize(Tokens.fontSize.body)
            .onChange((value: string) => {
              this.username = value;
            })
          this.FieldError(this.vm.errors.username)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(2)
        .margin({ left: Tokens.space.sm })
      }
      .width('100%')
      .margin({ top: Tokens.space.xs })

      this.FieldLabel('分组')
      Select(this.groupOptions())
        .selected(this.groupSelectIndex())
        .value(this.groupIdSel.length === 0 ? '未分组' : this.groupOptions()[this.groupSelectIndex()].value)
        .font({ size: Tokens.fontSize.body })
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .margin({ top: Tokens.space.xs2 })
        .onSelect((index: number) => {
          this.groupIdSel = index <= 0 ? '' : this.vm.groups[index - 1].id;
        })

      this.FieldLabel('跳板主机（ProxyJump）')
      Select(this.jumpOptions())
        .selected(this.jumpSelectIndex())
        .value(this.jumpHostIdSel.length === 0 ? '无跳板' : this.jumpOptions()[this.jumpSelectIndex()].value)
        .font({ size: Tokens.fontSize.body })
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .margin({ top: Tokens.space.xs2 })
        .onSelect((index: number) => {
          this.jumpHostIdSel = index <= 0 ? '' : this.vm.jumpCandidates[index - 1].id;
        })
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
  }

  /** 认证段：authType 三选 + 各方式凭据区（已保存只显示占位，不回填明文） */
  @Builder
  AuthSection() {
    Column() {
      this.SectionTitle('认证')
      this.Segmented(['密码', '密钥', 'Agent'], this.authType === 'password' ? 0 : this.authType === 'key' ? 1 : 2,
        (index: number) => {
          this.authType = index === 0 ? 'password' : index === 1 ? 'key' : 'agent';
        })

      if (this.authType === 'password') {
        this.FieldLabel('密码')
        TextInput({
          placeholder: this.vm.hasSavedPassword ? '已保存（输入以更换）' : '登录密码',
          text: this.password
        })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .onChange((value: string) => {
            this.password = value;
            this.vm.markCredentialModified('password');
          })
        this.SavedCredentialHint('password')
      } else if (this.authType === 'key') {
        this.FieldLabel('私钥（PEM / OpenSSH 文本）')
        // U3 接线点：私钥文件选择器（@kit.CoreFileKit picker）在此追加「从文件导入」按钮
        TextArea({
          placeholder: this.vm.hasSavedPrivateKey ? '已保存（粘贴以更换）' : '粘贴私钥内容',
          text: this.privateKey
        })
          .fontSize(Tokens.fontSize.caption)
          .constraintSize({ minHeight: PRIVATE_KEY_AREA_MIN_HEIGHT_VP })
          .onChange((value: string) => {
            this.privateKey = value;
            this.vm.markCredentialModified('private_key');
          })
        this.SavedCredentialHint('private_key')

        this.FieldLabel('密码短语（可选）')
        TextInput({
          placeholder: this.vm.hasSavedPassphrase ? '已保存（输入以更换）' : '私钥有口令时填写',
          text: this.passphrase
        })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .onChange((value: string) => {
            this.passphrase = value;
            this.vm.markCredentialModified('passphrase');
          })
        this.SavedCredentialHint('passphrase')
      } else {
        Text('应用内 agent 暂未开放')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textFaint)
          .margin({ top: Tokens.space.sm })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
    .margin({ top: Tokens.space.sm })
  }

  /** 终端段：termType / keepalive / initCommands / envVars / 外观 */
  @Builder
  TerminalSection() {
    Column() {
      this.SectionTitle('终端')
      Row() {
        Column() {
          this.FieldLabel('终端类型')
          TextInput({ placeholder: 'xterm-256color', text: this.termType })
            .fontSize(Tokens.fontSize.body)
            .onChange((value: string) => {
              this.termType = value;
            })
          this.FieldError(this.vm.errors.termType)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(2)

        Column() {
          this.FieldLabel('keepalive（秒）')
          TextInput({ placeholder: '30', text: this.keepaliveText })
            .fontSize(Tokens.fontSize.body)
            .onChange((value: string) => {
              this.keepaliveText = value;
            })
          this.FieldError(this.vm.errors.keepalive)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: Tokens.space.sm })
      }
      .width('100%')

      this.FieldLabel('登录后自动执行（每行一条）')
      TextArea({ placeholder: '如：tmux attach', text: this.initCommandsText })
        .fontSize(Tokens.fontSize.body)
        .margin({ top: Tokens.space.xs2 })
        .onChange((value: string) => {
          this.initCommandsText = value;
        })

      this.FieldLabel('环境变量（每行 KEY=VALUE）')
      TextArea({ placeholder: '如：LANG=zh_CN.UTF-8', text: this.envVarsText })
        .fontSize(Tokens.fontSize.body)
        .margin({ top: Tokens.space.xs2 })
        .onChange((value: string) => {
          this.envVarsText = value;
        })
      this.FieldError(this.vm.errors.envVars)

      this.FieldLabel('外观')
      Select(this.appearanceOptions())
        .selected(this.appearanceSelectIndex())
        .value(this.appearanceIdSel.length === 0 ? '默认外观' : this.appearanceOptions()[this.appearanceSelectIndex()].value)
        .font({ size: Tokens.fontSize.body })
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .margin({ top: Tokens.space.xs2 })
        .onSelect((index: number) => {
          this.appearanceIdSel = index <= 0 ? '' : this.vm.appearances[index - 1].id;
        })
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
    .margin({ top: Tokens.space.sm })
  }

  /** 转发段：规则增删改；新建主机未保存时禁用（规则需 hostId 外键，先保存主机） */
  @Builder
  ForwardSection() {
    Column() {
      this.SectionTitle('端口转发')
      if (!this.vm.isEdit) {
        Text('转发规则需在主机保存后配置，请先保存主机')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textFaint)
          .margin({ top: Tokens.space.xs })
      } else {
        ForEach(this.vm.ruleForms, (rule: ForwardRuleForm, index: number) => {
          this.RuleEditor(rule, index)
        }, (rule: ForwardRuleForm, index: number) => `${rule.ruleId}:${index}`)
        Text('+ 添加转发规则')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.accent)
          .margin({ top: Tokens.space.xs })
          .onClick(() => {
            this.vm.addRuleForm();
          })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
    .margin({ top: Tokens.space.sm })
  }

  /** 单条转发规则编辑卡：类型三选 + 按类型字段 + 启停 + 删除 */
  @Builder
  RuleEditor(rule: ForwardRuleForm, index: number) {
    Column() {
      Row() {
        this.Segmented(['本地 -L', '远程 -R', '动态 -D'],
          rule.type === 'local' ? 0 : rule.type === 'remote' ? 1 : 2,
          (selected: number) => {
            const type: PortForwardType = selected === 0 ? 'local' : selected === 1 ? 'remote' : 'dynamic';
            this.vm.setRuleFormType(index, type);
          })
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
          .onChange((isOn: boolean) => {
            this.vm.setRuleFormEnabled(index, isOn);
          })
        Text('删除')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.danger)
          .margin({ left: Tokens.space.sm })
          .onClick(() => {
            this.vm.removeRuleForm(index);
          })
      }
      .width('100%')

      if (rule.type !== 'remote') {
        this.FieldLabel(rule.type === 'dynamic' ? 'SOCKS5 监听地址' : '本地监听地址')
        TextInput({ placeholder: '127.0.0.1', text: rule.bindAddress })
          .fontSize(Tokens.fontSize.body)
          .onChange((value: string) => {
            rule.bindAddress = value;
          })
        this.FieldError(this.ruleErrorAt(index).bindAddress)
      }

      Row() {
        Column() {
          this.FieldLabel(rule.type === 'remote' ? '远端监听端口' : '本地监听端口')
          TextInput({ placeholder: '如：8080', text: rule.localPortText })
            .fontSize(Tokens.fontSize.body)
            .onChange((value: string) => {
              rule.localPortText = value;
            })
          this.FieldError(this.ruleErrorAt(index).localPort)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (rule.type !== 'dynamic') {
          Column() {
            this.FieldLabel('目标端口')
            TextInput({ placeholder: '如：3306', text: rule.remotePortText })
              .fontSize(Tokens.fontSize.body)
              .onChange((value: string) => {
                rule.remotePortText = value;
              })
            this.FieldError(this.ruleErrorAt(index).remotePort)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: Tokens.space.sm })
        }
      }
      .width('100%')
      .margin({ top: Tokens.space.xs })

      if (rule.type !== 'dynamic') {
        this.FieldLabel('目标主机')
        TextInput({ placeholder: '如：db.internal', text: rule.remoteHost })
          .fontSize(Tokens.fontSize.body)
          .onChange((value: string) => {
            rule.remoteHost = value;
          })
        this.FieldError(this.ruleErrorAt(index).remoteHost)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surfaceHover)
    .borderRadius(Tokens.radius.sm)
    .padding(Tokens.space.sm)
    .width('100%')
    .margin({ top: Tokens.space.xs })
  }

  // ---------------------------------------------------------------- 底栏（测试连接 + 保存）

  @Builder
  BottomBar() {
    Column() {
      // 测试连接结果：中文文案（成功绿 / 失败红）
      if (this.vm.testMessage.length > 0) {
        Text(this.vm.testMessage)
          .fontSize(Tokens.fontSize.body)
          .fontColor(this.vm.testSuccess ? Tokens.Color.success : Tokens.Color.danger)
          .margin({ bottom: Tokens.space.xs })
      }
      // 主机指纹展示（TOFU 素材；真实连接中的确认/拒绝完整交互归 U4）
      if (this.vm.testHostKey !== null) {
        Column() {
          Text('主机指纹（首次连接请核对）')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
          Text(`类型：${this.vm.testHostKey?.keyType ?? ''}`)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.text)
            .margin({ top: Tokens.space.xs2 })
          Text(`SHA256：${this.vm.testHostKey?.fingerprintSha256 ?? ''}`)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.text)
            .margin({ top: Tokens.space.xs2 })
          if ((this.vm.testHostKey?.randomart ?? '').length > 0) {
            Text(this.vm.testHostKey?.randomart ?? '')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .margin({ top: Tokens.space.xs2 })
          }
          Text('确认入库的最小闭环在此提供；真实连接中的 TOFU 确认与不匹配拒绝归 U4')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
            .margin({ top: Tokens.space.xs2 })
          if (!this.vm.hostKeyTrusted) {
            Text('信任该指纹并入库')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.accent)
              .margin({ top: Tokens.space.xs })
              .onClick(() => {
                if (this.vm.trustTestedHostKey()) {
                  this.toast('指纹已入库');
                } else {
                  this.toast('指纹入库失败或与既有记录不一致');
                }
              })
          } else {
            Text('已入库')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.success)
              .margin({ top: Tokens.space.xs })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.sm)
        .padding(Tokens.space.sm)
        .width('100%')
        .margin({ bottom: Tokens.space.xs })
      }

      Row() {
        Button(this.vm.testing ? '测试中…' : '测试连接')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .layoutWeight(1)
          .enabled(!this.vm.testing && !this.vm.saving)
          .onClick(() => {
            this.onTestConnection();
          })
        Button(this.vm.saving ? '保存中…' : '保存')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Color.White)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .layoutWeight(1)
          .margin({ left: Tokens.space.sm })
          .enabled(!this.vm.testing && !this.vm.saving)
          .onClick(() => {
            this.onSave();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: Tokens.space.sm })
  }

  // ---------------------------------------------------------------- 通用小件

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(Tokens.fontSize.title)
      .fontColor(Tokens.Color.text)
      .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  FieldLabel(label: string) {
    Text(label)
      .fontSize(Tokens.fontSize.caption)
      .fontColor(Tokens.Color.textDim)
      .margin({ top: Tokens.space.xs, bottom: Tokens.space.xs2 })
  }

  @Builder
  FieldError(error: string) {
    if (error.length > 0) {
      Text(error)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.danger)
        .margin({ top: Tokens.space.xs2 })
    }
  }

  /** 三选一分段小控件（认证方式 / 转发类型共用） */
  @Builder
  Segmented(labels: string[], selectedIndex: number, onSelect: (index: number) => void) {
    Row() {
      ForEach(labels, (label: string, index: number) => {
        Text(label)
          .fontSize(Tokens.fontSize.body)
          .fontColor(index === selectedIndex ? Color.White : Tokens.Color.textDim)
          .backgroundColor(index === selectedIndex ? Tokens.Color.accent : Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)
          .padding({
            left: Tokens.space.sm,
            right: Tokens.space.sm,
            top: Tokens.space.xs2,
            bottom: Tokens.space.xs2
          })
          .margin({ right: Tokens.space.xs })
          .onClick(() => {
            onSelect(index);
          })
      }, (label: string) => label)
    }
  }

  /** 已保存凭据的占位提示与「清除已保存」入口（绝不回填明文） */
  @Builder
  SavedCredentialHint(kind: 'password' | 'passphrase' | 'private_key') {
    if (this.hasSaved(kind)) {
      if (this.vm.credentialStateOf(kind) === 'cleared') {
        Text('已标记清除，保存后生效')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.warn)
          .margin({ top: Tokens.space.xs2 })
      } else {
        Text('清除已保存')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .margin({ top: Tokens.space.xs2 })
          .onClick(() => {
            this.vm.markCredentialCleared(kind);
            if (kind === 'password') {
              this.password = '';
            } else if (kind === 'passphrase') {
              this.passphrase = '';
            } else {
              this.privateKey = '';
            }
          })
      }
    }
  }

  private hasSaved(kind: 'password' | 'passphrase' | 'private_key'): boolean {
    if (kind === 'password') {
      return this.vm.hasSavedPassword;
    }
    if (kind === 'passphrase') {
      return this.vm.hasSavedPassphrase;
    }
    return this.vm.hasSavedPrivateKey;
  }
}
