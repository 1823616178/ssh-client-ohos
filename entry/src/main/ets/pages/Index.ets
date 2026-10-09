/**
 * 首页：以 HostListPage（主机列表）作为主体。
 *
 * 自适应布局：
 *   sm：单栏全屏主机列表。
 *   md：SideBarContainer 双栏（左主机树 + 右终端嵌入）。
 *   lg：三栏 —— 主机列表 | 终端嵌入 | 右侧侧面板（片段 / 转发 / 文件传输）。
 * 宽度经 onAreaChange 派生；面板宽度与可见性由 AdaptiveLayout 解析。
 *
 * 迷你终端窗口（TerminalPaneEmbed，见 viewmodel/MiniTerminalModel）：
 *   - md/lg：中栏常驻。点按左侧「活动会话」行 → 迷你窗口就地切到该会话（不跳页、不重连、
 *     回滚保留）；点按主机 → 迷你窗口新拨一路（已在显示该主机的存活会话则保持）。
 *   - sm：无中栏，点按活动会话行 → 底部半屏面板（bindSheet）承载同一迷你窗口；
 *     点按主机仍直接进全页终端（与以往一致）。
 *   - 只有显式「⤢」（迷你窗口标题栏 / 活动会话行）才 push TerminalPage；push 前迷你窗口
 *     先让出会话（寄存终端 + 解绑），全页返回后 onPageShow 递增 resumeTick 取回原会话。
 *   - 收起迷你窗口不断开会话；断开只在活动会话行「✕」里确认。
 *   - 多窗口（平板 / 2in1）：已在独立终端窗口里的会话，点按行或 ⤢ 都是切到那个窗口
 *     （HostListPage 处理，不经迷你窗口）；页面跳转一律走本页 UIContext 的 Router。
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
  useHostListSidebar
} from '../common/utils/AdaptiveLayout';
import { pushTerminalForHost, pushTerminalForSession } from '../common/utils/TerminalNavigation';
import { AppDatabase } from '../repository/AppDatabase';
import { SessionInfo, SessionManager } from '../service/SessionManager';
import { Tokens } from '../theme/Tokens';
import { MiniTerminalController, TerminalPaneEmbed } from '../view/TerminalPaneEmbed';
import {
  HostTapAction,
  MINI_TARGET_NONE,
  decideHostTap,
  encodeMiniTarget
} from '../viewmodel/MiniTerminalModel';
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
  @State private selectedHostName: string = '';
  /** U5 lg：右侧可折叠面板是否展开 */
  @State private rightPanelOpen: boolean = true;
  /** U5 lg：右侧面板当前 tab */
  @State private rightPanelTab: RightPanelTabId = 'snippets';
  /** 迷你窗口目标（encodeMiniTarget；'' = 空态） */
  @State private miniTarget: string = '';
  /** 迷你窗口当前会话（活动会话行高亮用） */
  @State private miniSessionId: string = '';
  /** 全页终端返回：递增让迷你窗口取回原会话 */
  @State private miniResumeTick: number = 0;
  /** sm：底部迷你终端面板是否展开 */
  @State private miniSheetShown: boolean = false;
  private miniSeq: number = 0;
  private miniHostId: string = '';
  private readonly miniController: MiniTerminalController = new MiniTerminalController();

  /** 页面重新显示（含从编辑页/配置管理页/全页终端返回）：主机列表重载 + 迷你窗口取回会话 */
  onPageShow(): void {
    this.listRefreshTick = this.listRefreshTick + 1;
    this.miniResumeTick = this.miniResumeTick + 1;
  }

  /** HostList 双栏回调：点按主机 → 迷你窗口（已显示该主机存活会话则保持，否则新拨一路） */
  private onHostSelected(hostId: string): void {
    const action: HostTapAction = decideHostTap(this.miniHostId, this.isLive(this.miniSessionId), hostId);
    this.selectedHostId = hostId;
    this.embedTerminal = true;
    this.refreshSelectedHostName();
    if (action === 'connect') {
      this.miniSeq++;
      this.miniTarget = encodeMiniTarget({ kind: 'host', id: hostId, seq: this.miniSeq });
    }
  }

  private isLive(sessionId: string): boolean {
    if (sessionId.length === 0) {
      return false;
    }
    const info: SessionInfo | null = SessionManager.get().getSession(sessionId);
    return info !== null && info.state !== 'closed' && info.state !== 'closing';
  }

  /** 活动会话行点按：迷你窗口就地切到该会话（sm 用底部面板承载） */
  private openSessionInMini(sessionId: string): void {
    const info: SessionInfo | null = SessionManager.get().getSession(sessionId);
    if (info !== null) {
      this.selectedHostId = info.hostId;
      this.refreshSelectedHostName();
    }
    this.miniSeq++;
    this.miniTarget = encodeMiniTarget({ kind: 'session', id: sessionId, seq: this.miniSeq });
    if (useHostListSidebar(this.breakpoint)) {
      this.embedTerminal = true;
    } else {
      this.miniSheetShown = true;
    }
  }

  /** 显式进入全页：迷你窗口先让出会话（同步 detach），再 push */
  private openSessionFullPage(sessionId: string): void {
    this.miniController.release();
    this.miniSheetShown = false;
    pushTerminalForSession(this.getUIContext(), sessionId);
  }

  /** 迷你窗口标题栏「⤢」（迷你窗口已自行让出会话） */
  private onMiniOpenFullPage(sessionId: string, hostId: string): void {
    this.miniSheetShown = false;
    if (sessionId.length > 0) {
      pushTerminalForSession(this.getUIContext(), sessionId);
    } else if (hostId.length > 0) {
      pushTerminalForHost(this.getUIContext(), hostId);
    }
  }

  private onMiniSessionChanged(sessionId: string, hostId: string): void {
    this.miniSessionId = sessionId;
    this.miniHostId = hostId;
  }

  /** 收起迷你窗口：会话保持后台（出现在活动会话里） */
  private closeMini(): void {
    this.miniTarget = encodeMiniTarget(MINI_TARGET_NONE);
    this.miniSessionId = '';
    this.miniHostId = '';
    this.miniSheetShown = false;
    this.embedTerminal = false;
  }

  /** 用户在活动会话里断开了迷你窗口正在显示的会话 → 迷你窗口回到空态 */
  private onSessionClosed(sessionId: string): void {
    if (sessionId.length > 0 && sessionId === this.miniSessionId) {
      this.closeMini();
    }
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
      this.embedTerminal,
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

  build() {
    Column() {
      if (!useHostListSidebar(this.breakpoint)) {
        // sm：单栏，行为与 U5 前一致
        HostListPage({
          refreshTick: this.listRefreshTick,
          miniSessionId: this.miniSessionId,
          onOpenSession: (sessionId: string): void => {
            this.openSessionInMini(sessionId);
          },
          onOpenSessionFullPage: (sessionId: string): void => {
            this.openSessionFullPage(sessionId);
          },
          onSessionClosed: (sessionId: string): void => {
            this.onSessionClosed(sessionId);
          }
        })
          .width('100%')
          .layoutWeight(1)
      } else if (!this.regions().rightPanel) {
        // md：双栏 SideBar（主机树 + 中栏）
        SideBarContainer(SideBarContainerType.Embed) {
          HostListPage({
            refreshTick: this.listRefreshTick,
            miniSessionId: this.miniSessionId,
            onOpenHost: (hostId: string): void => {
              this.onHostSelected(hostId);
            },
            onOpenSession: (sessionId: string): void => {
              this.openSessionInMini(sessionId);
            },
            onOpenSessionFullPage: (sessionId: string): void => {
              this.openSessionFullPage(sessionId);
            },
            onSessionClosed: (sessionId: string): void => {
              this.onSessionClosed(sessionId);
            }
          })
            .width('100%')
            .height('100%')
          Column() {
            if (!this.embedTerminal) {
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
            miniSessionId: this.miniSessionId,
            onOpenHost: (hostId: string): void => {
              this.onHostSelected(hostId);
            },
            onOpenSession: (sessionId: string): void => {
              this.openSessionInMini(sessionId);
            },
            onOpenSessionFullPage: (sessionId: string): void => {
              this.openSessionFullPage(sessionId);
            },
            onSessionClosed: (sessionId: string): void => {
              this.onSessionClosed(sessionId);
            }
          })
            .width(280)
            .height('100%')
          Column()
            .width(1)
            .height('100%')
            .backgroundColor(Tokens.Color.border)
          Column() {
            if (!this.embedTerminal) {
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
      const next: AppBreakpoint = appBreakpointOfWidth(width);
      if (next !== this.breakpoint) {
        this.onBreakpointChanged(next);
      }
      this.breakpoint = next;
    })
    // sm：迷你终端底部面板（md/lg 由中栏承载，不会展开）
    .bindSheet(this.miniSheetShown, this.MiniSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      showClose: false,
      preferType: SheetType.BOTTOM,
      backgroundColor: Tokens.Color.appBg,
      onDisappear: (): void => {
        this.onMiniSheetGone();
      }
    })
  }

  /** 断点切换：sm ↔ md/lg 之间迷你窗口换承载容器（面板 ↔ 中栏），目标保持 */
  private onBreakpointChanged(next: AppBreakpoint): void {
    const hasMini: boolean = this.miniTarget.length > 0;
    if (hasMini && (this.miniSheetShown || this.embedTerminal)) {
      // 换承载容器：旧实例先同步让出会话；目标改为「接管当前会话」，避免按主机重拨
      this.miniController.release();
      if (this.miniSessionId.length > 0) {
        this.miniSeq++;
        this.miniTarget = encodeMiniTarget({ kind: 'session', id: this.miniSessionId, seq: this.miniSeq });
      }
    }
    if (useHostListSidebar(next)) {
      if (this.miniSheetShown) {
        this.miniSheetShown = false;
        this.embedTerminal = hasMini;
      }
    } else if (this.embedTerminal && hasMini) {
      this.embedTerminal = false;
      this.miniSheetShown = true;
    }
  }

  /** 面板被下滑收起：会话保持后台；面板内组件销毁时也会 detach（双保险） */
  private onMiniSheetGone(): void {
    const dismissedByUser: boolean = this.miniSheetShown;
    // 非 $$ 绑定：下滑/点遮罩收起时状态仍为 true，这里回写
    this.miniSheetShown = false;
    if (!useHostListSidebar(this.breakpoint) && (dismissedByUser || this.miniTarget.length > 0)) {
      this.miniController.release();
      this.miniTarget = encodeMiniTarget(MINI_TARGET_NONE);
      this.miniSessionId = '';
      this.miniHostId = '';
    }
  }

  @Builder
  MiniSheet() {
    Column() {
      if (this.miniSheetShown && this.miniTarget.length > 0) {
        TerminalPaneEmbed({
          target: this.miniTarget,
          resumeTick: this.miniResumeTick,
          compact: true,
          controller: this.miniController,
          onClose: (): void => {
            this.closeMini();
          },
          onOpenFullPage: (sessionId: string, hostId: string): void => {
            this.onMiniOpenFullPage(sessionId, hostId);
          },
          onSessionChanged: (sessionId: string, hostId: string): void => {
            this.onMiniSessionChanged(sessionId, hostId);
          }
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }

  @Builder
  RightPlaceholder() {
    Column() {
      Text('迷你终端')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
      Text('点按左侧活动会话在这里就地查看；点按主机新开连接；⤢ 进入完整终端页')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.sm })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.appBg)
  }

  @Builder
  RightContentPane() {
    TerminalPaneEmbed({
      target: this.miniTarget,
      resumeTick: this.miniResumeTick,
      compact: false,
      controller: this.miniController,
      onClose: (): void => {
        this.closeMini();
      },
      onOpenFullPage: (sessionId: string, hostId: string): void => {
        this.onMiniOpenFullPage(sessionId, hostId);
      },
      onSessionChanged: (sessionId: string, hostId: string): void => {
        this.onMiniSessionChanged(sessionId, hostId);
      }
    })
      .width('100%')
      .height('100%')
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
    Column() {
      ForEach(RIGHT_PANEL_TABS, (tab: RightPanelTab) => {
        if (this.rightPanelTab === tab.id) {
          Column() {
            Text(tab.title)
              .fontSize(Tokens.fontSize.title)
              .fontColor(Tokens.Color.text)
              .fontWeight(FontWeight.Bold)
            Text(tab.subtitle)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .margin({ top: Tokens.space.xs2 })
            Text('完整能力请打开对应页面')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textFaint)
              .margin({ top: Tokens.space.sm })
            Button(tab.needsHostId && this.selectedHostId.length === 0
              ? '请先选择主机'
              : '打开完整页面')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .enabled(!(tab.needsHostId && this.selectedHostId.length === 0))
              .opacity(tab.needsHostId && this.selectedHostId.length === 0 ? 0.45 : 1)
              .margin({ top: Tokens.space.md })
              .onClick(() => {
                this.openRightPanelRoute(tab);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Tokens.space.sm)
        }
      }, (tab: RightPanelTab) => `${this.rightPanelTab}-${tab.id}`)
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}
