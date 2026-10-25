/**
 * 首页：以 HostListPage（主机列表）作为主体。
 *
 * 自适应布局：
 *   sm：单栏全屏主机列表。
 *   md：SideBarContainer 双栏（左主机树 + 右终端嵌入）。
 *   lg：三栏 —— 主机列表 | 终端嵌入 | 右侧侧面板（片段 / 转发 / 文件传输）。
 * 宽度经 onAreaChange 派生；面板宽度与可见性由 AdaptiveLayout 解析。
 *
 * lg/md 右栏（中栏）：
 *   - 点按主机 → selectedHostId；中栏展示「嵌入终端」（TerminalPaneEmbed）。
 *   - 点按「活动会话」→ 中栏切换显示该会话（不 push 全页）；全页只由嵌入终端
 *     顶栏的「全页终端」按钮触发（TerminalPaneEmbed.onOpenFullPage）。
 *   - 侧栏嵌入为单窗格终端；多标签/分屏仍走全页 TerminalPage。
 *   - 快速连接的临时主机不进库，会话点按后仅按 sessionId 接管中栏。
 */

import { HostProfile } from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import {
  AppBreakpoint,
  LayoutRegions,
  RIGHT_PANEL_TABS,
  RightPanelTab,
  RightPanelTabId,
  appBreakpointOfWidth,
  resolveLayoutRegions,
  rightPanelTabById,
  useHostListSidebar
} from '../common/utils/AdaptiveLayout';
import { pushTerminalPage } from '../common/utils/TerminalNavigation';
import { AppDatabase } from '../repository/AppDatabase';
import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';
import { TerminalPaneEmbed, embedHostTarget, embedSessionTarget } from '../view/TerminalPaneEmbed';
import { SnippetSidePanel } from '../view/sidepanel/SnippetSidePanel';
import { PortForwardSidePanel } from '../view/sidepanel/PortForwardSidePanel';
import { SftpSidePanel } from '../view/sidepanel/SftpSidePanel';
import { areaLengthToVp } from '../view/terminal/TerminalLayout';
import { HostListPage } from './HostListPage';

const LOG_TAG: string = 'Index';

@Entry
@Component
struct Index {
  // 从 HostEditPage / ConfigManagerPage 等子页面返回时递增，驱动内嵌 HostListPage 重载
  @State listRefreshTick: number = 0;
  @State private breakpoint: AppBreakpoint = 'sm';
  @State private selectedHostId: string = '';
  @State private embedTerminal: boolean = false;
  /** 活动会话点按：中栏要接管的会话（'' = 按主机连接） */
  @State private embedSessionId: string = '';
  /** 被接管会话的所属主机（快速连接为临时主机，不在库中，故与 selectedHostId 分开记） */
  @State private embedSessionHostId: string = '';
  @State private selectedHostName: string = '';
  /** U5 lg：右侧可折叠面板是否展开 */
  @State private rightPanelOpen: boolean = true;
  /** U5 lg：右侧面板当前 tab */
  @State private rightPanelTab: RightPanelTabId = 'snippets';
  /** 切换服务器时中栏 / 右侧面板内容的入场态（false → true 播放淡入 + 位移） */
  @State private paneEntered: boolean = true;

  /** 页面重新显示（含从编辑页/配置管理页返回）：递增 tick 通知主机列表重载 */
  onPageShow(): void {
    this.listRefreshTick = this.listRefreshTick + 1;
  }

  /** HostList 双栏回调：选中主机并展示中栏（不 push） */
  private onHostSelected(hostId: string): void {
    const switched: boolean = this.embedTerminal && this.selectedHostId.length > 0 &&
      (this.selectedHostId !== hostId || this.embedSessionId.length > 0);
    this.selectedHostId = hostId;
    // 点主机行 = 按主机连接，丢掉上一条活动会话的接管请求
    this.embedSessionId = '';
    this.embedSessionHostId = '';
    this.embedTerminal = true;
    this.refreshSelectedHostName();
    if (switched) {
      this.playPaneEnter();
    }
  }

  /**
   * HostList 双栏回调：点按「活动会话」→ 在首页中栏切换显示该会话，
   * 不 push 全页（全页只由嵌入终端顶栏的「全页终端」按钮触发）。
   */
  private onSessionSelected(sessionId: string, hostId: string): void {
    const switched: boolean = this.embedTerminal &&
      (this.embedSessionId !== sessionId || this.embedSessionHostId !== hostId);
    if (hostId.length > 0 && this.hostExists(hostId)) {
      this.selectedHostId = hostId;
      this.refreshSelectedHostName();
    }
    this.embedSessionId = sessionId;
    this.embedSessionHostId = hostId;
    this.embedTerminal = true;
    if (switched) {
      this.playPaneEnter();
    }
  }

  /** 已保存主机才同步列表选中态；快速连接的临时主机不进库，只由会话接管 */
  private hostExists(hostId: string): boolean {
    try {
      return AppDatabase.hosts().getById(hostId) !== null;
    } catch (_err) {
      return false;
    }
  }

  /** 中栏连接目标：活动会话优先，否则按当前选中主机 */
  private embedTarget(): string {
    if (!this.embedTerminal) {
      return '';
    }
    if (this.embedSessionId.length > 0) {
      return embedSessionTarget(this.embedSessionHostId, this.embedSessionId);
    }
    return embedHostTarget(this.selectedHostId);
  }

  /** 中栏是否无内容：需同时看选中主机与活动会话（快速连接无库内主机） */
  private isEmptyEmbed(): boolean {
    return !this.embedTerminal ||
      (this.selectedHostId.length === 0 && this.embedSessionId.length === 0);
  }

  /**
   * 切换服务器的内容过渡：先（无动画）退到起始态，animateTo 前框架会先刷新这一帧，
   * 再以 FastOutSlowIn 回到终态。只动 opacity / translate，不触发终端画布重排。
   */
  private playPaneEnter(): void {
    if (!Motion.enabled) {
      return;
    }
    this.paneEntered = false;
    this.getUIContext().animateTo({
      duration: Motion.BASE_MS,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.paneEntered = true;
    });
  }

  /** 中栏「占位 ↔ 终端」切换与右侧面板 tab 切换共用的组件内转场 */
  private paneTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ x: Motion.enterOffset() * 1.5 }))
      .animation({ duration: Motion.duration(Motion.BASE_MS), curve: Curve.FastOutSlowIn });
  }

  private refreshSelectedHostName(): void {
    if (this.selectedHostId.length === 0) {
      this.selectedHostName = '';
      return;
    }
    try {
      const host: HostProfile | null = AppDatabase.hosts().getById(this.selectedHostId);
      this.selectedHostName = host === null
        ? this.selectedHostId
        : (host.name.length > 0 ? host.name : host.host);
    } catch (err) {
      Logger.warn(`读取主机名失败 hostId=${this.selectedHostId}`, LOG_TAG);
      this.selectedHostName = this.selectedHostId;
    }
  }

  private regions(): LayoutRegions {
    return resolveLayoutRegions(
      this.breakpoint,
      this.selectedHostId.length > 0 && this.embedTerminal,
      this.rightPanelOpen,
      true
    );
  }

  /** lg 右侧面板 tab → 全页路由（forwards/sftp 带 hostId） */
  private openRightPanelRoute(tab: RightPanelTab): void {
    if (tab.needsHostId && this.selectedHostId.length === 0) {
      Logger.info(`右侧面板 ${tab.id} 需先选择主机`, LOG_TAG);
      return;
    }
    try {
      if (tab.needsHostId) {
        this.getUIContext().getRouter().pushUrl({
          url: tab.route,
          params: { hostId: this.selectedHostId }
        });
      } else {
        this.getUIContext().getRouter().pushUrl({ url: tab.route });
      }
    } catch (err) {
      Logger.warn(`打开右侧面板路由失败 ${tab.route}`, LOG_TAG);
    }
  }

  /**
   * 页面转场（router 路由，pageTransition）：push 新页自右 PAGE_OFFSET_VP 淡入推入、旧页轻微左移；
   * pop 反向。只动 opacity/translate（合成层属性，画布不重绘）；Motion 总开关关闭时时长 0。
   */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: Motion.pageOffset() })
      .opacity(0)
    PageTransitionEnter({ type: RouteType.Pop, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: -Motion.pageOffset() / 2 })
    PageTransitionExit({ type: RouteType.Push, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: -Motion.pageOffset() / 2 })
    PageTransitionExit({ type: RouteType.Pop, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: Motion.pageOffset() })
      .opacity(0)
  }

  build() {
    Column() {
      if (!useHostListSidebar(this.breakpoint)) {
        // sm：单栏，行为与 U5 前一致
        HostListPage({ refreshTick: this.listRefreshTick })
          .width('100%')
          .layoutWeight(1)
      } else if (!this.regions().rightPanel) {
        // md：双栏 SideBar（主机树 + 中栏）
        SideBarContainer(SideBarContainerType.Embed) {
          HostListPage({
            refreshTick: this.listRefreshTick,
            selectedHostId: this.selectedHostId,
            onOpenHost: (hostId: string): void => {
              this.onHostSelected(hostId);
            },
            onResumeSession: (sessionId: string, hostId: string): void => {
              this.onSessionSelected(sessionId, hostId);
            }
          })
            .width('100%')
            .height('100%')
          Stack() {
            if (this.isEmptyEmbed()) {
              this.RightPlaceholder()
            } else {
              this.RightContentPane()
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor(Tokens.Color.appBg)
        }
        .sideBarWidth(280)
        .minSideBarWidth(240)
        .maxSideBarWidth(360)
        .divider({ strokeWidth: 1, color: Tokens.Color.border })
      } else {
        // lg：三栏 —— 主机列表 | 终端嵌入 | 右侧侧面板
        Row() {
          HostListPage({
            refreshTick: this.listRefreshTick,
            selectedHostId: this.selectedHostId,
            onOpenHost: (hostId: string): void => {
              this.onHostSelected(hostId);
            },
            onResumeSession: (sessionId: string, hostId: string): void => {
              this.onSessionSelected(sessionId, hostId);
            }
          })
            .width(280)
            .height('100%')
          Column()
            .width(1)
            .height('100%')
            .backgroundColor(Tokens.Color.border)
          Stack() {
            if (this.isEmptyEmbed()) {
              this.RightPlaceholder()
            } else {
              this.RightContentPane()
            }
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor(Tokens.Color.appBg)
          Column()
            .width(1)
            .height('100%')
            .backgroundColor(Tokens.Color.border)
          this.RightPanelStub()
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      const width: number = areaLengthToVp(area.width);
      this.breakpoint = appBreakpointOfWidth(width);
    })
  }

  @Builder
  RightPlaceholder() {
    Column() {
      Text('选择主机开始连接')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
      Text('点按左侧主机后，可在此打开终端，或跳转完整终端页')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.sm })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.appBg)
    .transition(TransitionEffect.OPACITY.animation({
      duration: Motion.duration(Motion.BASE_MS),
      curve: Curve.FastOutSlowIn
    }))
  }

  @Builder
  RightContentPane() {
    TerminalPaneEmbed({
      target: this.embedTarget(),
      refreshTick: this.listRefreshTick,
      onClose: (): void => {
        this.embedTerminal = false;
        this.selectedHostId = '';
        this.embedSessionId = '';
        this.embedSessionHostId = '';
        this.selectedHostName = '';
      },
      onOpenFullPage: (hostId: string, sessionId?: string): void => {
        pushTerminalPage(
          this.getUIContext(),
          hostId,
          (sessionId !== undefined && sessionId.length > 0) ? sessionId : ''
        );
      }
    })
      .width('100%')
      .height('100%')
      // 切换服务器：内容淡入 + 轻微右移归位
      .opacity(this.paneEntered ? 1 : 0.4)
      .translate({ x: this.paneEntered ? 0 : Motion.enterOffset() })
      // 占位 → 终端：组件内转场
      .transition(this.paneTransition())
  }

  /** lg 右侧侧面板（片段 / 转发 / 文件传输 → 全页路由） */
  @Builder
  RightPanelStub() {
    Column() {
      if (!this.rightPanelOpen) {
        // 折叠态：竖条 + 展开按钮
        Column() {
          Button() {
            Text('‹')
              .fontSize(Tokens.fontSize.title)
              .fontColor(Tokens.Color.textDim)
          }
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.sm)
          .width(28)
          .height(28)
          .accessibilityText('展开侧面板')
          .onClick(() => {
            this.rightPanelOpen = true;
          })
          Text('面板')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
            .margin({ top: Tokens.space.sm })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ top: Tokens.space.sm })
        .backgroundColor(Tokens.Color.surface)
      } else {
        Column() {
          Row() {
            Text('侧面板')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .fontWeight(FontWeight.Bold)
              .layoutWeight(1)
            Button() {
              Text('›')
                .fontSize(Tokens.fontSize.title)
                .fontColor(Tokens.Color.textDim)
            }
            .backgroundColor(Tokens.Color.surface)
            .borderRadius(Tokens.radius.sm)
            .width(28)
            .height(28)
            .accessibilityText('折叠侧面板')
            .onClick(() => {
              this.rightPanelOpen = false;
            })
          }
          .width('100%')
          .padding(Tokens.space.sm)

          Row() {
            ForEach(RIGHT_PANEL_TABS, (tab: RightPanelTab) => {
              Text(tab.title)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(this.rightPanelTab === tab.id
                  ? Tokens.Color.onAccent : Tokens.Color.textDim)
                .backgroundColor(this.rightPanelTab === tab.id
                  ? Tokens.Color.accent : Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.xs)
                .animation({ duration: Motion.duration(Motion.BASE_MS), curve: Curve.FastOutSlowIn })
                .padding({
                  left: Tokens.space.sm,
                  right: Tokens.space.sm,
                  top: Tokens.space.xs2,
                  bottom: Tokens.space.xs2
                })
                .margin({ right: Tokens.space.xs })
                .onClick(() => {
                  this.rightPanelTab = tab.id;
                })
            }, (tab: RightPanelTab) => tab.id)
          }
          .width('100%')
          .padding({ left: Tokens.space.sm, right: Tokens.space.sm, bottom: Tokens.space.xs })

          this.RightPanelTabBody()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Tokens.Color.surface)
      }
    }
    .width(this.regions().rightPanelWidthVp)
    .height('100%')
  }

  @Builder
  RightPanelTabBody() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.rightPanelTab === 'snippets') {
        SnippetSidePanel({
          onOpenFullPage: (): void => {
            const tab: RightPanelTab | null = rightPanelTabById('snippets');
            if (tab !== null) {
              this.openRightPanelRoute(tab);
            }
          }
        })
          .width('100%')
          .height('100%')
          .transition(this.paneTransition())
      } else if (this.rightPanelTab === 'forwards') {
        PortForwardSidePanel({
          hostId: this.selectedHostId,
          hostName: this.selectedHostName,
          onOpenFullPage: (): void => {
            const tab: RightPanelTab | null = rightPanelTabById('forwards');
            if (tab !== null) {
              this.openRightPanelRoute(tab);
            }
          }
        })
          .width('100%')
          .height('100%')
          .transition(this.paneTransition())
      } else if (this.rightPanelTab === 'sftp') {
        SftpSidePanel({
          hostId: this.selectedHostId,
          hostName: this.selectedHostName,
          onOpenFullPage: (): void => {
            const tab: RightPanelTab | null = rightPanelTabById('sftp');
            if (tab !== null) {
              this.openRightPanelRoute(tab);
            }
          }
        })
          .width('100%')
          .height('100%')
          .transition(this.paneTransition())
      }
    }
    .width('100%')
    .layoutWeight(1)
    // 切换服务器时右侧面板内容与中栏同步过渡
    .opacity(this.paneEntered ? 1 : 0.4)
    .translate({ x: this.paneEntered ? 0 : Motion.enterOffset() })
  }
}
