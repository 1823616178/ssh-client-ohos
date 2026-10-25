/**
 * TerminalPaneEmbed —— Index md/lg 右栏的单窗格终端嵌入。
 *
 * 与 TerminalPage 同用 TerminalViewModel + TerminalCanvas + FocusManager，
 * 侧栏内为单窗格终端；多标签/分屏与键盘避让等完整能力走全页 TerminalPage。
 * 全页入口：父组件经 onOpenFullPage 注入（Index → pushTerminalPage）。
 *
 * 连接目标由父页用一条 `target` 串驱动（单一 @Prop，避免 hostId / sessionId
 * 两个 @Watch 在同一帧更新时互相覆盖）：
 *   - `host|<hostId>`：按主机复用既有会话或新拨；
 *   - `session|<hostId>|<sessionId>`：接管指定的活动会话（点按「活动会话」）。
 */
import { SshTerminal } from '../napi/SshTerminal';
import { Logger } from '../common/utils/Logger';
import { Tokens } from '../theme/Tokens';
import { TerminalCanvas } from './TerminalCanvas';
import { FrameScheduler } from './FrameScheduler';
import { FocusManager } from './terminal/FocusManager';
import { paneIdPrefixOf } from '../common/constants/WindowKeys';
import { windowKeyOf } from '../common/utils/WindowContext';
import { PrefixedPaneIdFactory } from '../viewmodel/PaneTree';
import { SessionInfo, SessionManager, isLiveState } from '../service/SessionManager';
import {
  OverlayModel,
  PasswordPromptModel,
  TerminalFocusHostLike,
  TerminalViewModel,
  deriveOverlay
} from '../viewmodel/TerminalViewModel';

const LOG_TAG: string = 'TerminalPaneEmbed';
const EMBED_PANE_ID: string = 'index-side-terminal';
const PASSWORD_DIALOG_MAX_WIDTH_VP: number = 420;
const SCRIM_OPACITY: number = 0.72;
/** target 串：前缀 + 分隔符（hostId / sessionId 为 UUID，不含 '|'） */
const TARGET_HOST_PREFIX: string = 'host|';
const TARGET_SESSION_PREFIX: string = 'session|';
const TARGET_SEPARATOR: string = '|';

/** 按主机连接的目标串（空 hostId → 空串 = 不渲染终端） */
export function embedHostTarget(hostId: string): string {
  return hostId.length > 0 ? `${TARGET_HOST_PREFIX}${hostId}` : '';
}

/** 接管指定会话的目标串（sessionId 为空时退化为按主机） */
export function embedSessionTarget(hostId: string, sessionId: string): string {
  return sessionId.length > 0 ? `${TARGET_SESSION_PREFIX}${hostId}${TARGET_SEPARATOR}${sessionId}`
    : embedHostTarget(hostId);
}

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

@Component
export struct TerminalPaneEmbed {
  /**
   * 连接目标（变化时拆旧建新）：`host|<hostId>` 或 `session|<hostId>|<sessionId>`。
   * 由 Index 用 embedHostTarget / embedSessionTarget 构造。
   */
  @Prop @Watch('onTargetChanged') target: string = '';
  /** 父页（Index）onPageShow 递增：从 TerminalPage 或其他页返回时触发恢复检查 */
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  /** 关闭嵌入（右栏回到提示/主机详情） */
  onClose: () => void = () => {};
  /**
   * 打开全页 TerminalPage（多标签/分屏等完整能力）。由父组件注入——跳转须走
   * 父页 UIContext 的 Router（多窗口下全局 router 绑定窗口不确定），缺省不动作。
   * 支持传递已建立的会话 id，避免全页重复拨号连接。
   */
  onOpenFullPage: (hostId: string, sessionId?: string) => void = (_id: string): void => {};

  /** V1 观察不到 @ObservedV2：@State 镜像 + onUiChange 驱动 */
  @State private uiTick: number = 0;
  /** 首叶 / 画布 focusId（主窗口即 EMBED_PANE_ID；非主窗口带窗口前缀） */
  @State private embedPaneId: string = EMBED_PANE_ID;
  @State private hostName: string = '';
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
  @State private passwordPrompt: PasswordPromptModel = {
    visible: false,
    hostName: '',
    busy: false,
    error: ''
  };
  @State private passwordDraft: string = '';

  private vm: TerminalViewModel | null = null;

  aboutToAppear(): void {
    this.startVm();
  }

  aboutToDisappear(): void {
    this.detachVm();
  }

  private onTargetChanged(): void {
    this.detachVm();
    this.canvasTerminal = null;
    this.startVm();
  }

  private onRefreshTick(): void {
    if (this.target.length > 0 && (this.vm === null || this.vm.currentSessionId.length === 0)) {
      // 先拆旧 VM 再建新：否则旧 VM 的监听/在途拨号泄漏，两个 VM 抢同一 embedPaneId
      this.detachVm();
      this.canvasTerminal = null;
      this.startVm();
    }
  }

  /** target 串中的 hostId（session 模式也带上，供全页入口与失效回退） */
  private targetHostId(): string {
    if (this.target.startsWith(TARGET_HOST_PREFIX)) {
      return this.target.substring(TARGET_HOST_PREFIX.length);
    }
    if (this.target.startsWith(TARGET_SESSION_PREFIX)) {
      const rest: string = this.target.substring(TARGET_SESSION_PREFIX.length);
      const sep: number = rest.indexOf(TARGET_SEPARATOR);
      return sep < 0 ? rest : rest.substring(0, sep);
    }
    return '';
  }

  /** target 串中的 sessionId（host 模式为空） */
  private targetSessionId(): string {
    if (!this.target.startsWith(TARGET_SESSION_PREFIX)) {
      return '';
    }
    const rest: string = this.target.substring(TARGET_SESSION_PREFIX.length);
    const sep: number = rest.indexOf(TARGET_SEPARATOR);
    return sep < 0 ? '' : rest.substring(sep + TARGET_SEPARATOR.length);
  }

  private findLiveSessionForHost(hostId: string): string {
    const sessions: SessionInfo[] = SessionManager.get().listSessions();
    for (let i = sessions.length - 1; i >= 0; i--) {
      const s: SessionInfo = sessions[i];
      if (s.hostId === hostId && isLiveState(s.state)) {
        if (s.paneId === null || s.paneId === this.embedPaneId) {
          return s.sessionId;
        }
      }
    }
    return '';
  }

  /**
   * 会话仍可接管：closed / closing 之外都算（disconnected / error 要保留，
   * 接管后才能看到断线重连倒计时或补密码提示）。
   */
  private isResumableSession(sessionId: string): boolean {
    const info: SessionInfo | null = SessionManager.get().getSession(sessionId);
    return info !== null && info.state !== 'closed' && info.state !== 'closing';
  }

  /**
   * 解析要交给 VM 的会话 id：
   *   - session 模式且会话仍可接管 → 直接接管；
   *   - 会话已结束（全页里 shell 退出 / 被关闭）→ 回退按主机复用或新拨；
   *   - 无主机可回退时保留原 id，让 VM 给出明确的「会话已关闭」蒙层。
   */
  private resolveSessionId(hostId: string, requested: string): string {
    if (requested.length > 0) {
      if (this.isResumableSession(requested)) {
        return requested;
      }
      if (hostId.length > 0) {
        return this.findLiveSessionForHost(hostId);
      }
      return requested;
    }
    return hostId.length > 0 ? this.findLiveSessionForHost(hostId) : '';
  }

  private startVm(): void {
    const hostId: string = this.targetHostId();
    const requested: string = this.targetSessionId();
    if (hostId.length === 0 && requested.length === 0) {
      return;
    }
    const prefix: string = paneIdPrefixOf(windowKeyOf(this.getUIContext()));
    this.embedPaneId = `${prefix}${EMBED_PANE_ID}`;
    const sessionId: string = this.resolveSessionId(hostId, requested);
    const vm: TerminalViewModel = new TerminalViewModel({
      onContentDirty: (): void => {
        FrameScheduler.get().wakeup();
      },
      onUiChange: (): void => {
        this.syncFromVm();
      },
      focusHost: new EmbedFocusHost(FocusManager.forWindow(windowKeyOf(this.getUIContext()))),
      // 与画布 focusId 一致，且不与全页终端首叶 terminal-main 抢绑定；非主窗口再加窗口前缀
      mainPaneId: this.embedPaneId,
      paneIdFactory: new PrefixedPaneIdFactory(prefix)
    });
    this.vm = vm;
    vm.start({ hostId: hostId, sessionId: sessionId }).catch((err: Object) => {
      Logger.error(`嵌入终端启动异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
    this.syncFromVm();
  }

  private detachVm(): void {
    this.passwordDraft = '';
    this.passwordPrompt = {
      visible: false,
      hostName: '',
      busy: false,
      error: ''
    };
    if (this.vm !== null) {
      this.vm.detach();
      this.vm = null;
    }
  }

  /** VM → @State 镜像（与 TerminalPage.syncFromVm 同约定） */
  private syncFromVm(): void {
    const vm: TerminalViewModel | null = this.vm;
    this.uiTick = this.uiTick + 1;
    if (vm === null) {
      return;
    }
    this.hostName = vm.hostName;
    this.sessionState = vm.sessionState;
    this.overlayModel = vm.overlay;
    this.passwordPrompt = vm.passwordPrompt;
    const term = vm.terminal;
    this.canvasTerminal = term as SshTerminal | null;
  }

  private submitPassword(): void {
    const vm: TerminalViewModel | null = this.vm;
    const draft: string = this.passwordDraft;
    if (vm === null || draft.length === 0 || this.passwordPrompt.busy) {
      return;
    }
    this.passwordDraft = '';
    vm.submitPassword(draft).catch((err: Object) => {
      Logger.error(`嵌入终端密码补录提交异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  build() {
    Column() {
      Row() {
        Text(this.hostName.length > 0 ? this.hostName : '侧栏终端')
          .fontSize(Tokens.fontSize.caption)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button('全页终端')
          .fontSize(Tokens.fontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(32)
          .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
          .accessibilityText('打开完整终端页')
          .onClick(() => {
            const sid: string = (this.vm !== null && this.vm.currentSessionId.length > 0)
              ? this.vm.currentSessionId
              : '';
            this.detachVm();
            this.canvasTerminal = null;
            this.onOpenFullPage(this.targetHostId(), sid);
          })
        Button('关闭')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(32)
          .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
          .margin({ left: Tokens.space.xs })
          .accessibilityText('关闭侧栏终端')
          .onClick(() => {
            this.detachVm();
            this.canvasTerminal = null;
            this.onClose();
          })
      }
      .width('100%')
      .padding({
        left: Tokens.space.sm,
        right: Tokens.space.sm,
        top: Tokens.space.xs,
        bottom: Tokens.space.xs
      })
      .backgroundColor(Tokens.Color.surface)

      Stack() {
        if (this.canvasTerminal !== null) {
          TerminalCanvas({
            terminal: this.canvasTerminal,
            focusId: this.embedPaneId,
            autoFocus: true,
            visible: true
          })
            .width('100%')
            .height('100%')
        } else {
          Column() {
            Text(this.overlayModel.kind === 'error'
              ? (this.overlayModel.detail.length > 0 ? this.overlayModel.detail : this.overlayModel.title)
              : (this.overlayModel.title.length > 0 ? this.overlayModel.title : '正在准备连接…'))
              .fontSize(Tokens.fontSize.body)
              .fontColor(this.overlayModel.kind === 'error' ? Tokens.Color.danger : Tokens.Color.text)
              .textAlign(TextAlign.Center)
            if (this.overlayModel.detail.length > 0) {
              Text(this.overlayModel.detail)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
                .textAlign(TextAlign.Center)
                .margin({ top: Tokens.space.xs })
            }
            // 失败/倒计时/结束态的操作按钮（与全页终端 StatusOverlay 同语义）：
            // 取消重连（退避倒计时）/ 重连（error 与 closed 可重连）/ 关闭（收起中栏终端）
            if (this.overlayModel.showCancelReconnect || this.overlayModel.showReconnectNow ||
              this.overlayModel.showClose) {
              Row() {
                if (this.overlayModel.showCancelReconnect) {
                  Button('取消重连')
                    .fontSize(Tokens.fontSize.body)
                    .fontColor(Tokens.Color.text)
                    .backgroundColor(Tokens.Color.surfaceHover)
                    .borderRadius(Tokens.radius.sm)
                    .height(36)
                    .onClick(() => {
                      const sid: string = this.vm !== null ? this.vm.currentSessionId : '';
                      if (sid.length > 0 && this.vm !== null) {
                        this.vm.cancelAutoReconnectAt(sid);
                      }
                    })
                }
                if (this.overlayModel.showReconnectNow) {
                  Button('重连')
                    .fontSize(Tokens.fontSize.body)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.Color.onAccent)
                    .backgroundColor(Tokens.Color.accent)
                    .borderRadius(Tokens.radius.sm)
                    .height(36)
                    .margin({ left: Tokens.space.sm })
                    .onClick(() => {
                      const sid: string = this.vm !== null ? this.vm.currentSessionId : '';
                      if (sid.length > 0 && this.vm !== null) {
                        this.vm.reconnectNowAt(sid);
                      }
                    })
                }
                if (this.overlayModel.showClose) {
                  Button('关闭')
                    .fontSize(Tokens.fontSize.body)
                    .fontColor(Tokens.Color.textDim)
                    .backgroundColor(Tokens.Color.surfaceHover)
                    .borderRadius(Tokens.radius.sm)
                    .height(36)
                    .margin({ left: Tokens.space.sm })
                    .onClick(() => {
                      this.detachVm();
                      this.canvasTerminal = null;
                      this.onClose();
                    })
                }
              }
              .margin({ top: Tokens.space.md })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ left: Tokens.space.lg, right: Tokens.space.lg })
          .backgroundColor(Tokens.Color.appBg)
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
              .enabled(!this.passwordPrompt.busy)
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
