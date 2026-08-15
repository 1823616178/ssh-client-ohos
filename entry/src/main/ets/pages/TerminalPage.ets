/**
 * TerminalPage —— 终端主界面（任务 U4 / U4b，DESIGN §4.3.1 / §4.4 / §7.1 / §7.2）。
 *
 * 验收（U4）：「从主机列表点击到出现 shell 提示符全程无白屏、无跳变」——
 *   页面背景 = 终端底色；画布常驻，连接中/失败/重连/已结束以蒙层叠加。
 *
 * 验收（U4b）：多标签 + 分屏二叉树 + 拖分隔条 + 焦点路由 + 断点降级树保活。
 *   - 标签栏（md/lg）：激活 / 关闭 / 新建；sm 隐藏（会话改走抽屉，树仍保活）；
 *   - 窗格区：按 VM.visiblePanes 绝对矩形铺 TerminalCanvas（focusId = paneId，
 *     输入经 FocusManager 只进聚焦叶；autoResize 各自 request_pty_size）；
 *   - 分隔条：PanGesture 把位移 / span 折算成 ratio，VM.setDividerRatio；
 *   - sm：只渲染聚焦叶铺满，分隔条不画；lg→sm→lg 往返树与会话完好。
 *
 * 版面：沉浸式顶栏 +（md/lg 标签栏）+ 窗格区 + KeyBar；侧滑抽屉会话切换。
 * 退出：返回 = VM.dispose（所有叶 unbindPane true）+ router.back；
 * 关末叶 / 末标签 → vm.shouldExit → 同样退出。
 */

import { router } from '@kit.ArkUI';
import { Logger } from '../common/utils/Logger';
import { vibrateLight } from '../common/utils/Haptics';
import { SshTerminal } from '../napi/SshTerminal';
import { SettingsRepository } from '../repository/SettingsRepository';
import { Tokens } from '../theme/Tokens';
import { KeyBar } from '../view/KeyBar';
import { TerminalCanvas } from '../view/TerminalCanvas';
import { FrameScheduler } from '../view/FrameScheduler';
import { FocusManager } from '../view/terminal/FocusManager';
import { StickyModifiers } from '../view/terminal/StickyModifiers';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance
} from '../view/terminal/TerminalAppearance';
import { sessionStateToStatus } from '../viewmodel/HostListViewModel';
import { DividerRect } from '../viewmodel/PaneTree';
import { ShortcutAction } from '../view/terminal/ShortcutMap';
import {
  OverlayModel,
  PaneRenderItem,
  TabRenderItem,
  TerminalFocusHostLike,
  TerminalRouteParams,
  TerminalSessionLike,
  TerminalViewModel,
  parseTerminalRouteParams
} from '../viewmodel/TerminalViewModel';

const LOG_TAG: string = 'TerminalPage';

/** 抽屉宽度（vp）：Token 表无「抽屉宽度」项，沿用 KeyBar/HostEditPage 局部常量惯例 */
const SIDEBAR_WIDTH_VP: number = 280;
/** 连接中 LoadingProgress 尺寸（vp）：同上局部常量惯例 */
const LOADING_SIZE_VP: number = 48;
/** 断线置灰层不透明度（画面保留但明显变暗，§7.2） */
const DIM_OVERLAY_OPACITY: number = 0.55;
/** 标签标题最大宽度（vp）：Token 表无「标签宽度」项 */
const TAB_TITLE_MAX_WIDTH_VP: number = 160;

/** 生产焦点宿主：转发给全局 FocusManager（画布点击 / 键条路由共用） */
class PageFocusHost implements TerminalFocusHostLike {
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

@Entry
@Component
struct TerminalPage {
  /** 侧滑抽屉展开态（SideBarContainer onChange 双向同步） */
  @State private showSideBar: boolean = false;
  /** 拖分隔条起点 ratio（onActionUpdate 相对此值累加，避免读到已更新的 item.ratio） */
  private dragStartRatio: number = 0.5;
  private dragSplitId: string = '';
  /** 触感总开关（C3 hapticEnabled；aboutToAppear 读取，读取失败保持默认 true） */
  private hapticEnabled: boolean = true;
  /** 功能键条布局 JSON（C3 keyBarLayout；空串/非法 = 内置默认布局） */
  private keyBarLayoutJson: string = '';
  /** 快捷键表 JSON（C3 keyboardShortcuts；空串 = 内置默认） */
  private shortcutBindingsJson: string = '';
  /** 终端外观：主机 appearanceId 绑定归 A 系列（M4），先用默认外观（Harmony Dark） */
  private readonly appearance: TerminalAppearance = createDefaultTerminalAppearance();
  /** 与所有 TerminalCanvas + KeyBar 共享的粘滞修饰（聚焦谁都吃同一份 Ctrl/Alt） */
  private readonly stickyModifiers: StickyModifiers = new StickyModifiers();
  /** 视图模型：多标签/分屏编排 / 终端装配 / 蒙层派生 / 事件分发 */
  private readonly vm: TerminalViewModel = new TerminalViewModel({
    vibrate: (): void => {
      vibrateLight(this.hapticEnabled);
    },
    onContentDirty: (): void => {
      FrameScheduler.get().wakeup();
    },
    focusHost: new PageFocusHost()
  });

  aboutToAppear(): void {
    try {
      this.hapticEnabled = SettingsRepository.isHapticEnabled();
      this.keyBarLayoutJson = SettingsRepository.getKeyBarLayout();
      this.shortcutBindingsJson = SettingsRepository.getKeyboardShortcuts();
    } catch (err) {
      Logger.warn(`设置读取失败，使用默认值：${JSON.stringify(err)}`, LOG_TAG);
    }
    const params: TerminalRouteParams = parseTerminalRouteParams(this.readRouteParams());
    this.vm.start(params).catch((err: Object) => {
      Logger.error(`终端页启动异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  aboutToDisappear(): void {
    this.vm.dispose();
  }

  /** 路由参数读取（HostListPage 传入 hostId 或 sessionId；异常收敛为空，由 VM 落错误蒙层） */
  private readRouteParams(): Object | null {
    try {
      const params: Object | undefined = router.getParams();
      return params === undefined ? null : params;
    } catch (err) {
      Logger.warn(`路由参数解析失败: ${JSON.stringify(err)}`, LOG_TAG);
      return null;
    }
  }

  private canvasTerminalOf(item: PaneRenderItem): SshTerminal | null {
    return item.terminal as SshTerminal | null;
  }

  /** 返回（关闭全部窗格会话 + 回列表） */
  private onBack(): void {
    this.vm.dispose();
    router.back();
  }

  private exitIfEmpty(): void {
    if (this.vm.shouldExit) {
      this.onBack();
    }
  }

  private onPaneClose(paneId: string): void {
    this.vm.closePane(paneId);
    this.exitIfEmpty();
  }

  private onTabClose(tabId: string): void {
    this.vm.closeTab(tabId);
    this.exitIfEmpty();
  }

  // ---------------------------------------------------------------- 顶栏派生

  private topBarTitle(): string {
    if (this.vm.terminalTitle.length > 0) {
      return this.vm.terminalTitle;
    }
    return this.vm.hostName.length > 0 ? this.vm.hostName : '终端';
  }

  private statusColorOf(state: string): Resource {
    switch (sessionStateToStatus(state)) {
      case 'connecting':
        return Tokens.Color.accent;
      case 'established':
        return Tokens.Color.success;
      case 'disconnected':
        return Tokens.Color.warn;
      case 'error':
        return Tokens.Color.danger;
      default:
        return Tokens.Color.textFaint;
    }
  }

  private statusLabel(): string {
    switch (sessionStateToStatus(this.vm.sessionState)) {
      case 'connecting':
        return '连接中';
      case 'established':
        return '已连接';
      case 'disconnected':
        return '已断开';
      case 'error':
        return '连接异常';
      default:
        return '未连接';
    }
  }

  private showTabBar(): boolean {
    return this.vm.breakpoint !== 'sm' && this.vm.tabs.length > 0;
  }

  // ---------------------------------------------------------------- 视图

  build() {
    SideBarContainer(SideBarContainerType.Overlay) {
      this.SideBar()

      Column() {
        this.TopBar()

        if (this.showTabBar()) {
          this.TabBar()
        }

        Stack() {
          ForEach(this.vm.visiblePanes, (item: PaneRenderItem) => {
            this.PaneSlot(item)
          }, (item: PaneRenderItem) => item.paneId)

          ForEach(this.vm.dividers, (item: DividerRect) => {
            this.DividerHandle(item)
          }, (item: DividerRect) => item.splitId)

          if (this.vm.visiblePanes.length === 0 && this.vm.overlay.kind !== 'none') {
            this.StatusOverlay(this.vm.overlay, '', '')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const w: number = newArea.width as number;
          const h: number = newArea.height as number;
          this.vm.setPaneAreaSize(w, h);
        })

        KeyBar({
          layoutJson: this.keyBarLayoutJson,
          hapticEnabled: this.hapticEnabled,
          stickyModifiers: this.stickyModifiers,
          onSendBytes: (bytes: Uint8Array): void => {
            this.vm.sendInput(bytes);
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.appearance.background)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.vm.setViewportWidth(newArea.width as number);
      })
    }
    .showSideBar(this.showSideBar)
    .sideBarWidth(SIDEBAR_WIDTH_VP)
    .showControlButton(false)
    .autoHide(true)
    .onChange((value: boolean) => {
      this.showSideBar = value;
    })
    .width('100%')
    .height('100%')
    .backgroundColor(this.appearance.background)
  }

  /** 沉浸式顶栏：返回 + 终端标题/主机名 + 状态点/文案 + 抽屉开关 */
  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(Tokens.fontSize.headline)
        .fontColor(Tokens.Color.text)
        .padding({
          left: Tokens.space.xs,
          right: Tokens.space.xs,
          top: Tokens.space.xs2,
          bottom: Tokens.space.xs2
        })
        .onClick(() => {
          this.onBack();
        })

      Column() {
        Text(this.topBarTitle())
          .fontSize(Tokens.fontSize.title)
          .fontColor(Tokens.Color.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.vm.terminalTitle.length > 0 && this.vm.hostName.length > 0) {
          Text(this.vm.hostName)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: Tokens.space.xs2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: Tokens.space.xs })

      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(this.statusColorOf(this.vm.sessionState))
      Text(this.statusLabel())
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ left: Tokens.space.xs2 })

      Text('☰')
        .fontSize(Tokens.fontSize.headline)
        .fontColor(Tokens.Color.text)
        .padding({ left: Tokens.space.sm, right: Tokens.space.xs })
        .onClick(() => {
          this.showSideBar = !this.showSideBar;
        })
    }
    .width('100%')
    .padding({
      top: Tokens.space.sm,
      bottom: Tokens.space.sm,
      left: Tokens.space.xs,
      right: Tokens.space.xs
    })
  }

  /** md/lg 标签栏：标签 + 关闭 + 新建 + 横/纵分屏 + 关聚焦窗格 */
  @Builder
  TabBar() {
    Row() {
      Scroll() {
        Row() {
          ForEach(this.vm.tabs, (tab: TabRenderItem) => {
            this.TabChip(tab)
          }, (tab: TabRenderItem) => tab.tabId)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)

      Text('+')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
        .onClick(() => {
          this.vm.newTab().catch((err: Object) => {
            Logger.error(`新建标签失败: ${JSON.stringify(err)}`, LOG_TAG);
          });
        })
      Text('│')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .padding({ left: Tokens.space.xs, right: Tokens.space.xs })
        .onClick(() => {
          this.vm.splitFocused('row').catch((err: Object) => {
            Logger.error(`左右分屏失败: ${JSON.stringify(err)}`, LOG_TAG);
          });
        })
      Text('─')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .padding({ left: Tokens.space.xs, right: Tokens.space.xs })
        .onClick(() => {
          this.vm.splitFocused('column').catch((err: Object) => {
            Logger.error(`上下分屏失败: ${JSON.stringify(err)}`, LOG_TAG);
          });
        })
      Text('×')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textDim)
        .padding({ left: Tokens.space.xs, right: Tokens.space.sm })
        .onClick(() => {
          this.vm.closeFocusedPane();
          this.exitIfEmpty();
        })
    }
    .width('100%')
    .padding({
      left: Tokens.space.xs,
      right: Tokens.space.xs,
      bottom: Tokens.space.xs2
    })
  }

  @Builder
  TabChip(tab: TabRenderItem) {
    Row() {
      Text(tab.title)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(tab.active ? Tokens.Color.accent : Tokens.Color.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: TAB_TITLE_MAX_WIDTH_VP })
        .onClick(() => {
          this.vm.activateTab(tab.tabId);
        })
      Text('×')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textFaint)
        .padding({ left: Tokens.space.xs2 })
        .onClick(() => {
          this.onTabClose(tab.tabId);
        })
    }
    .padding({
      left: Tokens.space.sm,
      right: Tokens.space.sm,
      top: Tokens.space.xs2,
      bottom: Tokens.space.xs2
    })
    .backgroundColor(tab.active ? Tokens.Color.surfaceHover : Tokens.Color.surface)
    .borderRadius(Tokens.radius.xs)
    .margin({ right: Tokens.space.xs2 })
  }

  /** 单个可见叶：画布 + 焦点边框 + 该叶蒙层 */
  @Builder
  PaneSlot(item: PaneRenderItem) {
    Stack() {
      TerminalCanvas({
        terminal: this.canvasTerminalOf(item),
        appearance: this.appearance,
        stickyModifiers: this.stickyModifiers,
        hapticEnabled: this.hapticEnabled,
        focusId: item.paneId,
        visible: true,
        shortcutBindingsJson: this.shortcutBindingsJson,
        onAppShortcut: (action: ShortcutAction): boolean => {
          const handled: boolean = this.vm.handleShortcut(action);
          this.exitIfEmpty();
          return handled;
        }
      })

      if (item.overlay.dimmed) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Tokens.Color.appBg)
          .opacity(DIM_OVERLAY_OPACITY)
      }

      if (item.overlay.kind !== 'none') {
        this.StatusOverlay(item.overlay, item.sessionId, item.paneId)
      }
    }
    .width(item.w)
    .height(item.h)
    .position({ x: item.x, y: item.y })
    .border({
      width: Tokens.space.xs2,
      color: item.focused ? Tokens.Color.accent : Tokens.Color.border
    })
    .onClick(() => {
      this.vm.focusPane(item.paneId);
    })
  }

  /** 分隔条：按方向限制拖动轴，位移 / span 折算 ratio */
  @Builder
  DividerHandle(item: DividerRect) {
    Column()
      .width(item.w)
      .height(item.h)
      .position({ x: item.x, y: item.y })
      .backgroundColor(Tokens.Color.border)
      .gesture(
        PanGesture({
          direction: item.direction === 'row' ? PanDirection.Horizontal : PanDirection.Vertical
        })
          .onActionStart(() => {
            this.dragSplitId = item.splitId;
            this.dragStartRatio = item.ratio;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (item.span <= 0 || this.dragSplitId !== item.splitId) {
              return;
            }
            const delta: number = item.direction === 'row' ? event.offsetX : event.offsetY;
            this.vm.setDividerRatio(item.splitId, this.dragStartRatio + delta / item.span);
          })
      )
  }

  /** 状态蒙层：连接中 / 重连倒计时 / 错误与操作按钮 / 会话已结束 */
  @Builder
  StatusOverlay(model: OverlayModel, sessionId: string, paneId: string) {
    Column() {
      if (model.kind === 'connecting' || model.kind === 'reconnecting') {
        LoadingProgress()
          .width(LOADING_SIZE_VP)
          .height(LOADING_SIZE_VP)
          .color(Tokens.Color.accent)
      }
      Text(model.title)
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .margin({ top: Tokens.space.md })
      if (model.detail.length > 0) {
        Text(model.detail)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textDim)
          .textAlign(TextAlign.Center)
          .margin({ top: Tokens.space.xs })
      }
      Row() {
        if (model.showCancelReconnect) {
          Button('取消重连')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              if (sessionId.length > 0) {
                this.vm.cancelAutoReconnectAt(sessionId);
              } else {
                this.vm.cancelAutoReconnect();
              }
            })
        }
        if (model.showReconnectNow) {
          Button('立即重连')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Color.White)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              if (sessionId.length > 0) {
                this.vm.reconnectNowAt(sessionId);
              } else {
                this.vm.reconnectNow();
              }
            })
        }
        if (model.showClose) {
          Button('关闭')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              if (paneId.length > 0) {
                this.onPaneClose(paneId);
              } else {
                this.onBack();
              }
            })
        }
      }
      .margin({ top: Tokens.space.lg })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Tokens.space.lg)
  }

  /** 侧滑抽屉：会话切换列表 + SFTP/转发/片段占位（U8/U9/U10，置灰不可点） */
  @Builder
  SideBar() {
    Column() {
      Text('会话')
        .fontSize(Tokens.fontSize.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.text)
        .margin({ top: Tokens.space.xs, bottom: Tokens.space.sm })

      if (this.vm.sessionList.length === 0) {
        Text('暂无活跃会话')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textFaint)
          .margin({ top: Tokens.space.sm })
      } else {
        Scroll() {
          Column() {
            ForEach(this.vm.sessionList, (item: TerminalSessionLike) => {
              this.SessionRow(item)
            }, (item: TerminalSessionLike) => item.sessionId)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
      }

      Divider()
        .color(Tokens.Color.border)
        .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

      this.DrawerPlaceholder('SFTP 文件传输（U8 待接入）')
      this.DrawerPlaceholder('端口转发（U9 待接入）')
      this.DrawerPlaceholder('命令片段（U10 待接入）')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.surface)
    .padding(Tokens.space.md)
  }

  /** 抽屉会话行：状态点 + 主机名 +「当前」标记；点击聚焦已有叶或替换聚焦叶 */
  @Builder
  SessionRow(item: TerminalSessionLike) {
    Row() {
      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(this.statusColorOf(item.state))
      Text(item.hostName.length > 0 ? item.hostName : '未命名会话')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: Tokens.space.sm })
      if (item.sessionId === this.vm.currentSessionId) {
        Text('当前')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .margin({ left: Tokens.space.xs })
      }
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(
      item.sessionId === this.vm.currentSessionId ? Tokens.Color.surfaceHover : Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.xs })
    .onClick(() => {
      this.vm.switchSession(item.sessionId);
      this.showSideBar = false;
    })
  }

  /** 抽屉占位项（U8/U9/U10）：置灰、不可点 */
  @Builder
  DrawerPlaceholder(label: string) {
    Text(label)
      .fontSize(Tokens.fontSize.body)
      .fontColor(Tokens.Color.textFaint)
      .width('100%')
      .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
  }
}
