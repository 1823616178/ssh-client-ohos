/**
 * TerminalPaneEmbed —— Index md/lg 右栏的单窗格终端嵌入。
 *
 * 与 TerminalPage 同用 TerminalViewModel + TerminalCanvas + FocusManager，
 * 侧栏内为单窗格终端；多标签/分屏与键盘避让等完整能力走全页 TerminalPage。
 * 全页入口：父组件经 onOpenFullPage 注入（Index → pushTerminalForHost(uiContext, hostId)）。
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
import {
  OverlayModel,
  TerminalFocusHostLike,
  TerminalViewModel,
  deriveOverlay
} from '../viewmodel/TerminalViewModel';

const LOG_TAG: string = 'TerminalPaneEmbed';
const EMBED_PANE_ID: string = 'index-side-terminal';

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
  /** 连接目标主机 id（变化时拆旧建新） */
  @Prop @Watch('onHostIdChanged') hostId: string = '';
  /** 关闭嵌入（右栏回到提示/主机详情） */
  onClose: () => void = () => {};
  /**
   * 打开全页 TerminalPage（多标签/分屏等完整能力）。由父组件注入——跳转须走
   * 父页 UIContext 的 Router（多窗口下全局 router 绑定窗口不确定），缺省不动作。
   */
  onOpenFullPage: (hostId: string) => void = (_id: string): void => {};

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

  private vm: TerminalViewModel | null = null;

  aboutToAppear(): void {
    this.startVm(this.hostId);
  }

  aboutToDisappear(): void {
    this.disposeVm();
  }

  private onHostIdChanged(): void {
    this.disposeVm();
    this.canvasTerminal = null;
    this.startVm(this.hostId);
  }

  private startVm(hostId: string): void {
    if (hostId.length === 0) {
      return;
    }
    const prefix: string = paneIdPrefixOf(windowKeyOf(this.getUIContext()));
    this.embedPaneId = `${prefix}${EMBED_PANE_ID}`;
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
    vm.start({ hostId: hostId, sessionId: '' }).catch((err: Object) => {
      Logger.error(`嵌入终端启动异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
    this.syncFromVm();
  }

  private disposeVm(): void {
    if (this.vm !== null) {
      this.vm.dispose();
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
    const term = vm.terminal;
    this.canvasTerminal = term as SshTerminal | null;
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
            this.onOpenFullPage(this.hostId);
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
              .fontColor(Tokens.Color.text)
            if (this.overlayModel.detail.length > 0) {
              Text(this.overlayModel.detail)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
                .margin({ top: Tokens.space.xs })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Tokens.Color.appBg)
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
}
