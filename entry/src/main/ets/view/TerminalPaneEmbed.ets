/**
 * TerminalPaneEmbed —— 首页「迷你终端窗口」：md/lg 嵌在 Index 中栏，sm 放在底部半屏面板。
 *
 * 与 TerminalPage 同用 TerminalViewModel + TerminalCanvas + FocusManager（按所在窗口取实例），单窗格。
 * 目标由父页经 `target`（encodeMiniTarget：按主机新拨 / 接管既有会话）驱动：
 *   - 切换目标 = 旧 VM detach（终端寄存、窗格解绑、会话保持后台）→ 新 VM 接管，
 *     同一个 TerminalCanvas 实例换绑终端：不重连、回滚保留、输入法焦点不丢；
 *   - 「⤢ 全页」：先 detach 让出会话，再由父页 push TerminalPage（父页 UIContext 的 Router）；
 *   - 全页返回：父页递增 `resumeTick` → 按原会话取回（decideMiniResume；全页尚未解绑则短暂重试）；
 *   - 收起 / 组件销毁一律 detach，从不关闭会话（断开在活动会话行里显式操作）。
 * 多窗口：窗格 id 带所在窗口前缀（主窗口无前缀，与改造前一致）；目标会话正显示在别的系统窗口时
 * 不抢绑定——把那个窗口带到前台、迷你窗口回到空态并提示（VM onSessionElsewhere）。
 * 切换会话不自动弹软键盘（浏览列表时不遮挡），点按迷你终端再输入；外接键盘同理点按聚焦。
 */
import { SshTerminal } from '../napi/SshTerminal';
import { Logger } from '../common/utils/Logger';
import { SessionInfo, SessionManager } from '../service/SessionManager';
import { common } from '@kit.AbilityKit';
import { focusWindowOfSession } from '../common/utils/TerminalNavigation';
import { abilityContextOf, windowKeyOf } from '../common/utils/WindowContext';
import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';
import { TerminalCanvas } from './TerminalCanvas';
import { ServerConnect3DOverlay } from './ServerConnect3DOverlay';
import { FrameScheduler } from './FrameScheduler';
import { FocusManager } from './terminal/FocusManager';
import { paneIdPrefixOf, windowKeyOfPaneId } from '../common/constants/WindowKeys';
import { PrefixedPaneIdFactory } from '../viewmodel/PaneTree';
import {
  OverlayModel,
  OverlayPresentation,
  PasswordPromptModel,
  TerminalFocusHostLike,
  TerminalViewModel,
  deriveOverlay,
  overlayPresentation
} from '../viewmodel/TerminalViewModel';
import {
  MINI_RESUME_RETRY_LIMIT,
  MINI_RESUME_RETRY_MS,
  MINI_TERMINAL_PANE_ID,
  MiniResumeAction,
  MiniTarget,
  SessionActivityTracker,
  decideMiniResume,
  parseMiniTarget
} from '../viewmodel/MiniTerminalModel';

const LOG_TAG: string = 'TerminalPaneEmbed';
const HEADER_BUTTON_VP: number = 40;
const PASSWORD_DIALOG_MAX_WIDTH_VP: number = 420;
const SCRIM_OPACITY: number = 0.72;

/** 生产焦点宿主：与 TerminalPage.PageFocusHost 同实现（绑定所在窗口的 FocusManager） */
class EmbedFocusHost implements TerminalFocusHostLike {
  private readonly fm: FocusManager;

  constructor(fm: FocusManager) {
    this.fm = fm;
  }

  register(id: string): boolean {
    return this.fm.register(id);
  }

  unregister(id: string): boolean {
    return this.fm.unregister(id);
  }

  focus(id: string): boolean {
    return this.fm.focus(id);
  }

  addListener(cb: (id: string) => void): () => void {
    return this.fm.addListener(cb);
  }
}

/**
 * 父页持有的控制器：push 全页前让迷你窗口先让出会话（同步 detach），
 * 避免全页 bindPane 时会话仍绑在迷你窗格上。
 */
export class MiniTerminalController {
  releaseHandler: () => void = (): void => {};
  currentSessionHandler: () => string = (): string => '';

  release(): void {
    this.releaseHandler();
  }

  currentSessionId(): string {
    return this.currentSessionHandler();
  }
}

@Component
export struct TerminalPaneEmbed {
  /** encodeMiniTarget 编码的目标（'' = 空态） */
  @Prop @Watch('onTargetChanged') target: string = '';
  /** 父页 onPageShow 递增：从全页终端返回后取回原会话 */
  @Prop @Watch('onResumeTick') resumeTick: number = 0;
  /** 底部面板形态：标题栏更紧凑 */
  @Prop compact: boolean = false;
  /** 父页控制器（可选） */
  controller: MiniTerminalController | null = null;
  /** 收起迷你窗口（会话保持后台） */
  onClose: () => void = () => {};
  /** 打开全页 TerminalPage：sessionId 非空接管会话；否则按 hostId 新拨（连接尚未受理时） */
  onOpenFullPage: (sessionId: string, hostId: string) => void = (_s: string, _h: string): void => {};
  /** 迷你窗口当前会话变化（'' = 无） */
  onSessionChanged: (sessionId: string, hostId: string) => void = (_s: string, _h: string): void => {};

  /** V1 观察不到 @ObservedV2：@State 镜像 + onUiChange 驱动 */
  @State private uiTick: number = 0;
  /** 首叶 / 画布 focusId（主窗口即 MINI_TERMINAL_PANE_ID；非主窗口带窗口前缀） */
  @State private embedPaneId: string = MINI_TERMINAL_PANE_ID;
  @State private hostName: string = '';
  @State private terminalTitle: string = '';
  @State private sessionState: string = '';
  @State private overlayModel: OverlayModel = deriveOverlay({
    state: '',
    reconnectCountdownSec: 0,
    reconnectAttempt: 0,
    errorMessage: '',
    hasTerminal: false,
    terminalClosed: false,
    startError: ''
  });
  @State private canvasTerminal: SshTerminal | null = null;
  @State private emptyHint: string = '';
  /** 连接成功瞬间的 3D 空间穿越（Portal Dive）过渡态 */
  @State private warpingOut: boolean = false;
  @State private canvasScale: number = 1.0;
  @State private canvasRotateXDeg: number = 0;
  @State private canvasOpacity: number = 1.0;
  @State private passwordPrompt: PasswordPromptModel = {
    visible: false,
    hostName: '',
    busy: false,
    error: ''
  };
  @State private passwordDraft: string = '';

  private vm: TerminalViewModel | null = null;
  private warpTimerId: number = -1;
  /** 最近一次显示的会话（全页返回时据此取回） */
  private rememberedSessionId: string = '';
  private rememberedHostId: string = '';
  /** 按主机新拨、连接尚未受理时的主机 id（⤢ 退化为按主机全页） */
  private pendingHostId: string = '';
  private reportedSessionId: string = '';
  private resumeTimer: number = -1;
  private resumeAttempts: number = 0;

  /** 本实例注册到控制器的处理函数（断点切换时新旧实例可能短暂并存，注销前比对身份） */
  private readonly releaseFn: () => void = (): void => {
    this.release();
  };
  private readonly currentSessionFn: () => string = (): string => this.rememberedSessionId;

  aboutToAppear(): void {
    if (this.controller !== null) {
      this.controller.releaseHandler = this.releaseFn;
      this.controller.currentSessionHandler = this.currentSessionFn;
    }
    this.applyTarget(parseMiniTarget(this.target));
  }

  aboutToDisappear(): void {
    this.cancelResume();
    this.release();
    if (this.controller !== null && this.controller.releaseHandler === this.releaseFn) {
      this.controller.releaseHandler = (): void => {};
      this.controller.currentSessionHandler = (): string => '';
    }
  }

  private onTargetChanged(): void {
    this.applyTarget(parseMiniTarget(this.target));
  }

  private onResumeTick(): void {
    this.resumeAttempts = 0;
    this.tryResume();
  }

  private applyTarget(target: MiniTarget): void {
    this.cancelResume();
    if (target.kind === 'none') {
      this.release();
      this.rememberedSessionId = '';
      this.rememberedHostId = '';
      this.reportSession();
      return;
    }
    if (target.kind === 'session' && target.id === this.reportedSessionId && this.vm !== null) {
      return; // 已在显示
    }
    this.release();
    if (target.kind === 'session') {
      this.rememberedSessionId = target.id;
      this.rememberedHostId = this.hostIdOf(target.id);
      this.pendingHostId = '';
      SessionActivityTracker.global().markSeen(target.id);
      this.startVm('', target.id);
    } else {
      this.rememberedSessionId = '';
      this.rememberedHostId = target.id;
      this.pendingHostId = target.id;
      this.startVm(target.id, '');
    }
  }

  private startVm(hostId: string, sessionId: string): void {
    const windowKey: string = windowKeyOf(this.getUIContext());
    const prefix: string = paneIdPrefixOf(windowKey);
    this.embedPaneId = `${prefix}${MINI_TERMINAL_PANE_ID}`;
    const vm: TerminalViewModel = new TerminalViewModel({
      onContentDirty: (): void => {
        FrameScheduler.get().wakeup();
      },
      onUiChange: (): void => {
        if (this.vm === vm) {
          this.syncFromVm();
        }
      },
      focusHost: new EmbedFocusHost(FocusManager.forWindow(windowKey)),
      // 与画布 focusId 一致，且不与全页终端首叶 terminal-main 抢绑定；非主窗口再加窗口前缀
      mainPaneId: this.embedPaneId,
      paneIdFactory: new PrefixedPaneIdFactory(prefix),
      onSessionElsewhere: (elsewhereSessionId: string, paneId: string): void => {
        if (this.vm === vm) {
          this.onSessionElsewhere(elsewhereSessionId, paneId);
        }
      }
    });
    this.vm = vm;
    this.emptyHint = '';
    // sessionId 路径在 start 内同步完成 adoptSession（取回寄存终端），画布当帧即可换绑
    vm.start({ hostId: hostId, sessionId: sessionId }).catch((err: Object) => {
      Logger.error(`迷你终端启动异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
    this.syncFromVm();
  }

  /** 让出会话：终端寄存、窗格解绑、会话保持后台（幂等） */
  private release(): void {
    if (this.warpTimerId !== -1) {
      clearTimeout(this.warpTimerId);
      this.warpTimerId = -1;
    }
    this.warpingOut = false;
    this.canvasScale = 1.0;
    this.canvasRotateXDeg = 0;
    this.canvasOpacity = 1.0;
    this.passwordDraft = '';
    this.passwordPrompt = {
      visible: false,
      hostName: '',
      busy: false,
      error: ''
    };
    this.canvasTerminal = null;
    const vm: TerminalViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    this.vm = null;
    vm.detach();
  }

  private cancelResume(): void {
    if (this.resumeTimer >= 0) {
      clearTimeout(this.resumeTimer);
      this.resumeTimer = -1;
    }
  }

  /** 全页返回：按原会话取回；全页尚未解绑则短暂重试；会话已结束则回到空态 */
  private tryResume(): void {
    this.cancelResume();
    if (this.vm !== null || this.rememberedSessionId.length === 0) {
      return;
    }
    const sessionId: string = this.rememberedSessionId;
    const info: SessionInfo | null = SessionManager.get().getSession(sessionId);
    const action: MiniResumeAction = decideMiniResume(
      info === null ? null : { state: info.state, paneId: info.paneId }, this.embedPaneId);
    switch (action) {
      case 'adopt':
        this.startVm('', sessionId);
        break;
      case 'wait':
        if (this.resumeAttempts < MINI_RESUME_RETRY_LIMIT) {
          this.resumeAttempts++;
          this.resumeTimer = setTimeout((): void => {
            this.resumeTimer = -1;
            this.tryResume();
          }, MINI_RESUME_RETRY_MS);
        } else {
          Logger.warn('迷你终端取回会话超时：会话仍被其他窗格持有', LOG_TAG);
          this.emptyHint = '该会话正在全页终端中使用';
        }
        break;
      case 'elsewhere':
        // 会话已迁去独立窗口（全页「在新窗口打开」）：不等、不抢，回到空态
        this.rememberedSessionId = '';
        this.emptyHint = '该会话已在独立窗口中打开，点按左侧对应行可切换过去';
        this.reportSession();
        break;
      case 'gone':
        this.rememberedSessionId = '';
        this.emptyHint = '会话已结束，可在左侧选择其他活动会话';
        this.reportSession();
        break;
      default:
        break;
    }
  }

  /**
   * VM 发现目标会话正绑在不属于迷你窗口的窗格上（start 已以「已在其他窗口打开」失败返回）：
   * 放弃本次接管、迷你窗口回到空态；会话在别的系统窗口则把那个窗口带到前台。
   */
  private onSessionElsewhere(sessionId: string, paneId: string): void {
    const owner: string = windowKeyOfPaneId(paneId);
    const here: string = windowKeyOfPaneId(this.embedPaneId);
    this.release();
    this.rememberedSessionId = '';
    this.pendingHostId = '';
    this.reportSession();
    if (owner === here) {
      this.emptyHint = '该会话正在全页终端中使用';
      return;
    }
    this.emptyHint = '该会话已在独立窗口中打开，已切换到该窗口';
    const context: common.UIAbilityContext | null = abilityContextOf(this.getUIContext());
    if (context !== null) {
      focusWindowOfSession(context, owner, sessionId).catch((err: Object) => {
        Logger.warn(`切换到会话所在窗口失败: ${JSON.stringify(err)}`, LOG_TAG);
      });
    }
  }

  private hostIdOf(sessionId: string): string {
    const info: SessionInfo | null = SessionManager.get().getSession(sessionId);
    return info === null ? '' : info.hostId;
  }

  private reportSession(): void {
    const current: string = this.rememberedSessionId;
    if (current === this.reportedSessionId) {
      return;
    }
    this.reportedSessionId = current;
    this.onSessionChanged(current, current.length > 0 ? this.rememberedHostId : '');
  }

  /** VM → @State 镜像（与 TerminalPage.syncFromVm 同约定） */
  private syncFromVm(): void {
    const vm: TerminalViewModel | null = this.vm;
    this.uiTick = this.uiTick + 1;
    if (vm === null) {
      return;
    }
    const prevTerminal: SshTerminal | null = this.canvasTerminal;
    this.hostName = vm.hostName;
    this.terminalTitle = vm.terminalTitle;
    this.sessionState = vm.sessionState;
    this.overlayModel = vm.overlay;
    this.passwordPrompt = vm.passwordPrompt;
    const term = vm.terminal;
    const nextTerminal: SshTerminal | null = term as SshTerminal | null;
    this.canvasTerminal = nextTerminal;
    const sessionId: string = vm.currentSessionId;
    if (sessionId.length > 0 && sessionId !== this.rememberedSessionId) {
      this.rememberedSessionId = sessionId;
      this.rememberedHostId = this.hostIdOf(sessionId);
      this.pendingHostId = '';
    }
    this.reportSession();
    if (prevTerminal === null && nextTerminal !== null && Motion.enabled) {
      this.triggerPortalDive();
    }
  }

  /** 连接建立瞬间：触发 3D 空间穿越（Astro 星环前冲消散 + 画布自 3D 远端拉近展开） */
  private triggerPortalDive(): void {
    if (this.warpTimerId !== -1) {
      clearTimeout(this.warpTimerId);
    }
    this.warpingOut = true;
    this.canvasScale = 0.92;
    this.canvasRotateXDeg = 8;
    this.canvasOpacity = 0.25;
    this.getUIContext().animateTo({
      duration: Motion.warpDuration(),
      curve: Curve.FastOutSlowIn
    }, () => {
      this.canvasScale = 1.0;
      this.canvasRotateXDeg = 0;
      this.canvasOpacity = 1.0;
    });
    this.warpTimerId = setTimeout(() => {
      this.warpingOut = false;
      this.warpTimerId = -1;
    }, Motion.warpDuration());
  }

  private submitPassword(): void {
    const vm: TerminalViewModel | null = this.vm;
    const draft: string = this.passwordDraft;
    if (vm === null || draft.length === 0 || this.passwordPrompt.busy) {
      return;
    }
    this.passwordDraft = '';
    vm.submitPassword(draft).catch((err: Object) => {
      Logger.error(`迷你终端密码补录提交异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  private openFullPage(): void {
    const sessionId: string = this.vm !== null ? this.vm.currentSessionId : this.rememberedSessionId;
    const hostId: string = this.pendingHostId;
    if (sessionId.length === 0 && hostId.length === 0) {
      return;
    }
    // 先让出会话（寄存终端 + 解绑），全页才能绑定同一会话并取回画面
    this.release();
    if (sessionId.length > 0) {
      SessionActivityTracker.global().markSeen(sessionId);
    }
    this.onOpenFullPage(sessionId, sessionId.length > 0 ? '' : hostId);
  }

  private presentation(): OverlayPresentation {
    return overlayPresentation(this.overlayModel, this.canvasTerminal !== null);
  }

  private headerTitle(): string {
    const name: string = this.hostName.length > 0 ? this.hostName : '迷你终端';
    return this.terminalTitle.length > 0 ? `${name} · ${this.terminalTitle}` : name;
  }

  build() {
    Column() {
      this.Header()
      Stack({ alignContent: Alignment.Top }) {
        if (this.canvasTerminal !== null) {
          Column() {
            TerminalCanvas({
              terminal: this.canvasTerminal,
              focusId: this.embedPaneId,
              autoFocus: false,
              visible: true
            })
              .width('100%')
              .height('100%')
          }
          .width('100%')
          .height('100%')
          .scale({ x: this.canvasScale, y: this.canvasScale })
          .rotate({
            x: 1,
            y: 0,
            z: 0,
            angle: this.canvasRotateXDeg,
            perspective: Motion.PERSPECTIVE_VP
          })
          .opacity(this.canvasOpacity)
          if (this.presentation() === 'banner') {
            this.Banner()
          }
        } else if (this.vm === null) {
          this.EmptyOrOverlay()
        }
        if ((this.canvasTerminal === null && this.vm !== null) || this.warpingOut) {
          ServerConnect3DOverlay({
            overlayKind: this.overlayModel.kind,
            sessionState: this.sessionState,
            titleText: this.overlayModel.title.length > 0 ? this.overlayModel.title : '正在准备连接…',
            detailText: this.overlayModel.detail,
            warping: this.warpingOut,
            compact: true,
            showCancelReconnect: this.overlayModel.showCancelReconnect,
            showReconnectNow: this.overlayModel.showReconnectNow,
            showClose: this.overlayModel.showClose,
            onCancelReconnect: (): void => {
              const sid: string = this.vm !== null ? this.vm.currentSessionId : '';
              if (sid.length > 0 && this.vm !== null) {
                this.vm.cancelAutoReconnectAt(sid);
              }
            },
            onReconnectNow: (): void => {
              if (this.vm !== null) {
                const sid: string = this.vm.currentSessionId;
                if (sid.length > 0) {
                  this.vm.reconnectNowAt(sid);
                } else {
                  this.vm.reconnectNow();
                }
              }
            },
            onClose: (): void => {
              this.release();
              this.onClose();
            }
          })
            .width('100%')
            .height('100%')
            .backgroundColor(Tokens.Color.appBg)
            .hitTestBehavior(this.warpingOut ? HitTestMode.None : HitTestMode.Default)
        }
        if (this.passwordPrompt.visible) {
          this.PasswordPrompt()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(Tokens.Color.appBg)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }

  @Builder
  Header() {
    Row() {
      Text(this.headerTitle())
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .accessibilityText(`迷你终端：${this.headerTitle()}`)
      Button() {
        Text(this.compact ? '⤢' : '⤢ 全页')
          .fontSize(Tokens.fontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
      }
      .backgroundColor(Tokens.Color.accent)
      .borderRadius(Tokens.radius.sm)
      .height(HEADER_BUTTON_VP)
      .constraintSize({ minWidth: HEADER_BUTTON_VP })
      .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
      .accessibilityText('在完整终端页打开当前会话')
      .onClick(() => {
        this.openFullPage();
      })
      Button() {
        Text('✕')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textDim)
      }
      .backgroundColor(Tokens.Color.surfaceHover)
      .borderRadius(Tokens.radius.sm)
      .width(HEADER_BUTTON_VP)
      .height(HEADER_BUTTON_VP)
      .margin({ left: Tokens.space.xs })
      .accessibilityText('收起迷你终端，会话保持后台运行')
      .onClick(() => {
        this.release();
        this.onClose();
      })
    }
    .width('100%')
    .padding({
      left: Tokens.space.sm,
      right: Tokens.space.xs,
      top: Tokens.space.xs2,
      bottom: Tokens.space.xs2
    })
    .backgroundColor(Tokens.Color.surface)
  }

  /** 有画面时的非阻塞状态条（断线 / 重连倒计时 / 已结束），画面可继续滚动查看 */
  @Builder
  Banner() {
    Row() {
      Text(this.overlayModel.detail.length > 0
        ? `${this.overlayModel.title} · ${this.overlayModel.detail}` : this.overlayModel.title)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.overlayModel.showReconnectNow) {
        Button('重连')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(HEADER_BUTTON_VP)
          .accessibilityText('立即重新连接')
          .onClick(() => {
            if (this.vm !== null) {
              this.vm.reconnectNow();
            }
          })
      }
    }
    .width('100%')
    .padding({ left: Tokens.space.sm, right: Tokens.space.xs })
    .backgroundColor(Tokens.Color.surfaceHover)
    .opacity(0.94)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  EmptyOrOverlay() {
    Column() {
      if (this.vm === null) {
        Text(this.emptyHint.length > 0 ? this.emptyHint : '点按左侧活动会话或主机，在这里查看终端')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textDim)
          .textAlign(TextAlign.Center)
      } else {
        Text(this.overlayModel.kind === 'error'
          ? (this.overlayModel.detail.length > 0 ? this.overlayModel.detail : this.overlayModel.title)
          : (this.overlayModel.title.length > 0 ? this.overlayModel.title : '正在准备连接…'))
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .textAlign(TextAlign.Center)
        if (this.overlayModel.kind !== 'error' && this.overlayModel.detail.length > 0) {
          Text(this.overlayModel.detail)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs })
        }
        if (this.overlayModel.showReconnectNow) {
          Button('立即重连')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.onAccent)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .height(HEADER_BUTTON_VP)
            .margin({ top: Tokens.space.sm })
            .onClick(() => {
              if (this.vm !== null) {
                this.vm.reconnectNow();
              }
            })
        }
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.appBg)
  }

  @Builder
  PasswordPrompt() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Tokens.Color.appBg)
        .opacity(SCRIM_OPACITY)
        .onClick(() => {
        })

      Column() {
        Column() {
          Text('需要登录密码')
            .fontSize(Tokens.fontSize.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
          Text(`请输入 ${this.passwordPrompt.hostName} 的登录密码`)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs2 })

          TextInput({ placeholder: '登录密码', text: this.passwordDraft })
            .type(InputType.Password)
            .enterKeyType(EnterKeyType.Go)
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .width('100%')
            .enabled(!this.passwordPrompt.busy)
            .margin({ top: Tokens.space.md })
            .onChange((value: string) => {
              this.passwordDraft = value;
            })
            .onSubmit(() => {
              this.submitPassword();
            })

          if (this.passwordPrompt.error.length > 0) {
            Text(this.passwordPrompt.error)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.danger)
              .margin({ top: Tokens.space.xs })
          }

          Text('密码将保存到系统加密凭据库，供本机重连使用。')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
            .margin({ top: Tokens.space.xs })

          Row() {
            Button('取消')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .layoutWeight(1)
              .onClick(() => {
                this.passwordDraft = '';
                this.vm?.cancelPasswordPrompt();
              })

            Button(this.passwordPrompt.busy ? '连接中…' : '连接')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .layoutWeight(1)
              .margin({ left: Tokens.space.sm })
              .enabled(!this.passwordPrompt.busy)
              .opacity(this.passwordPrompt.busy ? 0.6 : 1.0)
              .onClick(() => {
                this.submitPassword();
              })
          }
          .width('100%')
          .margin({ top: Tokens.space.lg })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .constraintSize({ maxWidth: PASSWORD_DIALOG_MAX_WIDTH_VP })
        .padding(Tokens.space.lg)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding(Tokens.space.lg)
    }
    .width('100%')
    .height('100%')
  }
}
