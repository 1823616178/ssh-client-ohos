/**
 * TerminalPage —— 终端主界面（任务 U4，DESIGN §4.3.1 / §4.4 / §7.1 / §7.2）。
 *
 * 验收标准「从主机列表点击到出现 shell 提示符全程无白屏、无跳变」的代码侧落地：
 *   - 页面背景 = 终端底色（appearance.background），进入第一帧即铺底，无白屏；
 *   - 终端画布常驻布局，连接中/失败/重连/已结束全部以蒙层叠加在画布之上，
 *     不做整页跳转式状态切换（蒙层形态由 TerminalViewModel.deriveOverlay 派生）；
 *   - 断线期画面保留（旧 SshTerminal 帧在 native 关闭后仍可安全读，T3 生命周期
 *     保护）+ 半透明置灰层（§7.2）；重连 established 后 VM 换绑画布 @Prop 全量重绘。
 *
 * 版面（§4.4）：
 *   - 沉浸式顶栏（作为布局一部分 + 页面背景 = 终端底色的简单沉浸方案）：返回
 *     （关闭会话并回列表）、终端标题/主机名、状态点与状态文案、抽屉开关「☰」；
 *   - 中部 TerminalCanvas（T4，尺寸协商/resize 由组件内部 autoResize 完成）；
 *   - 底部 KeyBar（T7）：与画布共享同一 StickyModifiers 实例；字节出口经
 *     vm.sendInput 直写当前终端（单窗格 focusId 为空时 TerminalCanvas.sendExternalInput
 *     的焦点路由本就直通，且 ArkUI 无子组件实例引用机制，页面拿不到 canvas 实例——
 *     多窗格焦点路由接线归 U4b）；
 *   - 侧滑抽屉（SideBarContainer Overlay，顶栏「☰」开合）：会话切换列表
 *     （主机名 + 状态点 +「当前」标记，点击换绑本页会话）+ SFTP/端口转发/命令片段
 *     三项占位（U8/U9/U10，置灰不可点）。
 *
 * 路由参数（二选一，同传 sessionId 优先，解析见 TerminalViewModel.parseTerminalRouteParams）：
 *   - hostId：按主机配置发起新连接（HostListPage 主机行的默认形态）；
 *   - sessionId：复用既有会话（该主机已有 established 会话、或快速连接先受理后跳转）。
 *
 * 外观：主机 appearanceId 绑定外观归 A 系列（M4），本页先用默认外观（Harmony Dark），
 * 捏合缩放的字号落库（onFontSizeCommit）同样归 A 系列。
 *
 * 退出语义：返回 = 关闭会话（VM dispose → unbindPane(paneId, true)）+ router.back；
 * aboutToDisappear 幂等兜底。单窗格「返回列表即断连」，会话保留/后台保活归 §7.5。
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
import { StickyModifiers } from '../view/terminal/StickyModifiers';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance
} from '../view/terminal/TerminalAppearance';
import { sessionStateToStatus } from '../viewmodel/HostListViewModel';
import {
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

@Entry
@Component
struct TerminalPage {
  /** 侧滑抽屉展开态（SideBarContainer onChange 双向同步） */
  @State private showSideBar: boolean = false;
  /** 触感总开关（C3 hapticEnabled；aboutToAppear 读取，读取失败保持默认 true） */
  private hapticEnabled: boolean = true;
  /** 功能键条布局 JSON（C3 keyBarLayout；空串/非法 = 内置默认布局） */
  private keyBarLayoutJson: string = '';
  /** 终端外观：主机 appearanceId 绑定归 A 系列（M4），U4 先用默认外观（Harmony Dark） */
  private readonly appearance: TerminalAppearance = createDefaultTerminalAppearance();
  /** 与 TerminalCanvas 共享的粘滞修饰状态机（T7：点 Ctrl/Alt 后软键盘输入也带修饰） */
  private readonly stickyModifiers: StickyModifiers = new StickyModifiers();
  /** 视图模型：进入编排 / 终端装配与换绑 / 蒙层派生 / 事件分发（生产依赖缺省惰性解析） */
  private readonly vm: TerminalViewModel = new TerminalViewModel({
    vibrate: (): void => {
      vibrateLight(this.hapticEnabled);
    },
    onContentDirty: (): void => {
      // 语义等价 TerminalCanvas.notifyContentDirty()（其内部即 wakeup，
      // TerminalCanvas.ets:253）；页面拿不到 canvas 实例，直接唤醒全局帧调度器
      FrameScheduler.get().wakeup();
    }
  });

  aboutToAppear(): void {
    try {
      this.hapticEnabled = SettingsRepository.isHapticEnabled();
      this.keyBarLayoutJson = SettingsRepository.getKeyBarLayout();
    } catch (err) {
      Logger.warn(`设置读取失败，使用默认值：${JSON.stringify(err)}`, LOG_TAG);
    }
    const params: TerminalRouteParams = parseTerminalRouteParams(this.readRouteParams());
    this.vm.start(params).catch((err: Object) => {
      // start 内部已兜底为 startError 蒙层，此处仅为双保险
      Logger.error(`终端页启动异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  aboutToDisappear(): void {
    // 返回列表即断连（单窗格语义）；onBack 已 dispose 时为幂等二次调用
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

  /** 画布绑定的终端：VM 的生产终端工厂产出的即 SshTerminal（fake 只存在于单测） */
  private canvasTerminal(): SshTerminal | null {
    return this.vm.terminal as SshTerminal | null;
  }

  /** 返回（关闭会话 + 回列表）：unbindPane(paneId, true) 在 VM dispose 内完成 */
  private onBack(): void {
    this.vm.dispose();
    router.back();
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

  // ---------------------------------------------------------------- 视图

  build() {
    SideBarContainer(SideBarContainerType.Overlay) {
      this.SideBar()

      Column() {
        this.TopBar()

        // 终端区：画布常驻，状态以蒙层叠加（无整页跳转，无白屏无跳变）
        Stack() {
          TerminalCanvas({
            terminal: this.canvasTerminal(),
            appearance: this.appearance,
            stickyModifiers: this.stickyModifiers,
            hapticEnabled: this.hapticEnabled
          })

          // 断线/结束期画面保留置灰（§7.2）：半透明灰层同时阻断终端手势
          if (this.vm.overlay.dimmed) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(Tokens.Color.appBg)
              .opacity(DIM_OVERLAY_OPACITY)
          }

          if (this.vm.overlay.kind !== 'none') {
            this.StatusOverlay()
          }
        }
        .width('100%')
        .layoutWeight(1)

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

      // 状态点：space_xs(8vp) 方块 + xs2(4vp) 圆角 = 正圆（与主机列表同风格）
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

  /** 状态蒙层（画布之上）：连接中指示 / 重连倒计时 / 错误与操作按钮 / 会话已结束 */
  @Builder
  StatusOverlay() {
    Column() {
      if (this.vm.overlay.kind === 'connecting' || this.vm.overlay.kind === 'reconnecting') {
        LoadingProgress()
          .width(LOADING_SIZE_VP)
          .height(LOADING_SIZE_VP)
          .color(Tokens.Color.accent)
      }
      Text(this.vm.overlay.title)
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .margin({ top: Tokens.space.md })
      if (this.vm.overlay.detail.length > 0) {
        Text(this.vm.overlay.detail)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textDim)
          .textAlign(TextAlign.Center)
          .margin({ top: Tokens.space.xs })
      }
      Row() {
        if (this.vm.overlay.showCancelReconnect) {
          Button('取消重连')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              this.vm.cancelAutoReconnect();
            })
        }
        if (this.vm.overlay.showReconnectNow) {
          Button('立即重连')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Color.White)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              this.vm.reconnectNow();
            })
        }
        if (this.vm.overlay.showClose) {
          Button('关闭')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              this.onBack();
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

  /** 抽屉会话行：状态点 + 主机名 +「当前」标记；点击换绑本页会话并收起抽屉 */
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
