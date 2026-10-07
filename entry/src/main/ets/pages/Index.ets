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
 *   - 点按主机 → selectedHostId；中栏展示主机信息 +「嵌入终端」（TerminalPaneEmbed）
 *     +「全页终端」（pushTerminalForHost，与单栏同参 hostId）。
 *   - 侧栏嵌入为单窗格终端；多标签/分屏仍走全页 TerminalPage。
 *   - 临时主机（快速连接）不进右栏，仍 sessionId 全页 push。
 */

import { router } from '@kit.ArkUI';
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
import { pushTerminalForHost } from '../common/utils/TerminalNavigation';
import { AppDatabase } from '../repository/AppDatabase';
import { Tokens } from '../theme/Tokens';
import { TerminalPaneEmbed } from '../view/TerminalPaneEmbed';
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

  /** 页面重新显示（含从编辑页/配置管理页返回）：递增 tick 通知主机列表重载 */
  onPageShow(): void {
    this.listRefreshTick = this.listRefreshTick + 1;
  }

  /** HostList 双栏回调：选中主机并展示中栏（不 push） */
  private onHostSelected(hostId: string): void {
    this.selectedHostId = hostId;
    this.embedTerminal = true;
    this.refreshSelectedHostName();
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

  private openFullTerminal(): void {
    if (this.selectedHostId.length > 0) {
      pushTerminalForHost(this.selectedHostId);
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
        router.pushUrl({
          url: tab.route,
          params: { hostId: this.selectedHostId }
        });
      } else {
        router.pushUrl({ url: tab.route });
      }
    } catch (err) {
      Logger.warn(`打开右侧面板路由失败 ${tab.route}`, LOG_TAG);
    }
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
            onOpenHost: (hostId: string): void => {
              this.onHostSelected(hostId);
            }
          })
            .width('100%')
            .height('100%')
          Column() {
            if (this.selectedHostId.length === 0 || !this.embedTerminal) {
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
            onOpenHost: (hostId: string): void => {
              this.onHostSelected(hostId);
            }
          })
            .width(280)
            .height('100%')
          Column()
            .width(1)
            .height('100%')
            .backgroundColor(Tokens.Color.border)
          Column() {
            if (this.selectedHostId.length === 0 || !this.embedTerminal) {
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
  }

  @Builder
  RightContentPane() {
    Column() {
      Row() {
        Text(this.selectedHostName.length > 0 ? this.selectedHostName : this.selectedHostId)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button('全页终端')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(28)
          .onClick(() => {
            this.openFullTerminal();
          })
        Button('清除选择')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(28)
          .margin({ left: Tokens.space.xs })
          .accessibilityText('清除当前主机选择')
          .onClick(() => {
            this.embedTerminal = false;
            this.selectedHostId = '';
            this.selectedHostName = '';
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

      TerminalPaneEmbed({
        hostId: this.selectedHostId,
        onClose: (): void => {
          this.embedTerminal = false;
          this.selectedHostId = '';
          this.selectedHostName = '';
        },
        onOpenFullPage: (hostId: string): void => {
          pushTerminalForHost(hostId);
        }
      })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
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
