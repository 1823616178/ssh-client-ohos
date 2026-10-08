/**
 * TerminalPaneEmbed —— 首页「迷你终端窗口」：md/lg 嵌在 Index 中栏，sm 放在底部半屏面板。
 *
 * 与 TerminalPage 同用 TerminalViewModel + TerminalCanvas + FocusManager，单窗格。
 * 目标由父页经 `target`（encodeMiniTarget：按主机新拨 / 接管既有会话）驱动：
 *   - 切换目标 = 旧 VM detach（终端寄存、窗格解绑、会话保持后台）→ 新 VM 接管，
 *     同一个 TerminalCanvas 实例换绑终端：不重连、回滚保留、输入法焦点不丢；
 *   - 「⤢ 全页」：先 detach 让出会话，再由父页 push TerminalPage（全页可绑定同一会话）；
 *   - 全页返回：父页递增 `resumeTick` → 按原会话取回（decideMiniResume；全页尚未解绑则短暂重试）；
 *   - 收起 / 组件销毁一律 detach，从不关闭会话（断开在活动会话行里显式操作）。
 * 切换会话不自动弹软键盘（浏览列表时不遮挡），点按迷你终端再输入；外接键盘同理点按聚焦。
 */
import { SshTerminal } from '../napi/SshTerminal';
import { Logger } from '../common/utils/Logger';
import { SessionInfo, SessionManager } from '../service/SessionManager';
import { Tokens } from '../theme/Tokens';
import { TerminalCanvas } from './TerminalCanvas';
import { FrameScheduler } from './FrameScheduler';
import { FocusManager } from './terminal/FocusManager';
import {
  OverlayModel,
  OverlayPresentation,
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

/** 生产焦点宿主：与 TerminalPage.PageFocusHost 同实现 */
class EmbedFocusHost implements TerminalFocusHostLike {
  register(id: string): boolean {
    return FocusManager.get().register(id);
  }

  unregister(id: string): boolean {
    return FocusManager.get().unregister(id);
  }

  focus(id: string): boolean {
    return FocusManager.get().focus(id);
  }

  addListener(cb: (id: string) => void): () => void {
    return FocusManager.get().addListener(cb);
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

  @State private hostName: string = '';
  @State private terminalTitle: string = '';
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

  private vm: TerminalViewModel | null = null;
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
    const vm: TerminalViewModel = new TerminalViewModel({
      onContentDirty: (): void => {
        FrameScheduler.get().wakeup();
      },
      onUiChange: (): void => {
        if (this.vm === vm) {
          this.syncFromVm();
        }
      },
      focusHost: new EmbedFocusHost(),
      // 与画布 focusId 一致，且不与全页终端首叶 terminal-main 抢绑定
      mainPaneId: MINI_TERMINAL_PANE_ID
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
    const vm: TerminalViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    this.vm = null;
    vm.detach();
    this.canvasTerminal = null;
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
      info === null ? null : { state: info.state, paneId: info.paneId }, MINI_TERMINAL_PANE_ID);
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
          this.emptyHint = '该会话正在其他窗口中使用';
        }
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
    if (vm === null) {
      return;
    }
    this.hostName = vm.hostName;
    this.terminalTitle = vm.terminalTitle;
    this.overlayModel = vm.overlay;
    const term = vm.terminal;
    this.canvasTerminal = term as SshTerminal | null;
    const sessionId: string = vm.currentSessionId;
    if (sessionId.length > 0 && sessionId !== this.rememberedSessionId) {
      this.rememberedSessionId = sessionId;
      this.rememberedHostId = this.hostIdOf(sessionId);
      this.pendingHostId = '';
    }
    this.reportSession();
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
          TerminalCanvas({
            terminal: this.canvasTerminal,
            focusId: MINI_TERMINAL_PANE_ID,
            autoFocus: false,
            visible: true
          })
            .width('100%')
            .height('100%')
          if (this.presentation() === 'banner') {
            this.Banner()
          }
        } else {
          this.EmptyOrOverlay()
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
}
