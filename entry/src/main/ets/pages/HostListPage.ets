/**
 * HostListPage —— 主机列表页（任务 U1，DESIGN §4.3.1 页面清单 / §4.2 Token / §4.3 sm 单栏）。
 *
 * 结构（自上而下，单栏；宽度一律百分比不写真机宽度，md/lg 多栏归 U5）：
 *   - 顶栏：标题「主机」+「+」新增入口（U2 接线：router 跳 HostEditPage 新建）；
 *   - 搜索框：实时过滤 + 非空时一键清除；
 *   - 快速连接：空列表完整 CTA；有主机时默认收起，避免与列表争抢视线；
 *   - 分组列表：List + LazyForEach + IDataSource 懒加载，按 order 升序分组区 + 未分组区；
 *   - 主机行：状态点 + 名称 + user@host:port + authType 徽标；
 *   - 滑动菜单：编辑 / SFTP / 转发 / 删除（danger 底色，二次确认）；
 *   - 空状态：无主机时引导「添加第一台主机」；搜索无结果时给提示文案。
 *
 * 本组件内嵌于 Index（@Entry 在其上），从 HostEditPage 返回时经父页 onPageShow
 * 递增 refreshTick 触发重载（U2 接线，@Prop @Watch）。
 */

import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { HostProfile, createDefaultHostProfile } from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import { SshEvent } from '../napi/SshNative';
import { CredentialStore } from '../repository/CredentialStore';
import { SessionEventListener, SessionInfo, SessionManager } from '../service/SessionManager';
import { Tokens } from '../theme/Tokens';
import { SyncRuntime } from '../service/sync/SyncRuntime';
import { pushTerminalForHost, pushTerminalForSession } from '../common/utils/TerminalNavigation';
import {
  ActiveSessionItem,
  ActiveSessionLike,
  HostConnStatus,
  HostListRow,
  HostListViewModel,
  QuickConnectTarget,
  buildActiveSessionItems,
  parseQuickConnectAddress,
  recordHostLastUsed
} from '../viewmodel/HostListViewModel';

const LOG_TAG: string = 'HostListPage';

/**
 * LazyForEach 数据源：扁平行数组 + 全量重载通知。
 * 主机列表数据量小（百级）、变更低频（操作后重载），无需增量通知。
 */
class HostRowDataSource implements IDataSource {
  private rows: HostListRow[] = [];
  private readonly listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): HostListRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 整体替换行数据并通知 LazyForEach 全量重载 */
  setRows(rows: HostListRow[]): void {
    this.rows = rows;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

@Component
export struct HostListPage {
  /**
   * 父页（Index）onPageShow 递增：从 HostEditPage 保存/返回后触发重载（U2 接线）。
   * 首次 aboutToAppear 已 reload，此处仅响应后续变化（@Watch 只在值变化时触发）。
   */
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  /**
   * U5 双栏：Index md/lg 提供时，点按主机不 router.push，改为通知父栏选中
   * （右栏嵌入 TerminalPaneEmbed 或展示详情）。未提供时保持单栏 push TerminalPage。
   */
  onOpenHost: ((hostId: string) => void) | null = null;
  @State private syncChipSub: string = '云同步';
  @State private syncLinked: boolean = false;
  /** 搜索草稿：驱动输入框与清除按钮（vm.searchText 在 V1 中不可观察） */
  @State private searchText: string = '';
  /** 快速直连展开态：主机列表非空时默认收起，空态保留完整 CTA */
  @State private quickConnectExpanded: boolean = false;
  /** 后台运行中的会话（终端页返回不断开；点按恢复） */
  @State private activeSessions: ActiveSessionItem[] = [];
  /** 视图模型：搜索串 / 折叠集合 / 派生行（生产依赖惰性解析 AppDatabase / SettingsRepository） */
  private readonly viewModel: HostListViewModel = new HostListViewModel();
  private readonly dataSource: HostRowDataSource = new HostRowDataSource();
  // 快速连接表单值（不需要响应式，普通成员即可）
  private quickAddress: string = '';
  private quickUser: string = '';

  /** 会话状态变化 → 重派生状态点并重建行 */
  private readonly sessionListener: SessionEventListener =
    (session: SessionInfo, event: SshEvent): void => {
      if (event.type === 'stateChange') {
        this.refreshConnStatus();
        this.reloadRows();
        this.refreshActiveSessions();
      }
    };

  /** 会话增删（连接受理 / 关闭）→ 刷新活动会话 */
  private readonly sessionCountListener = (): void => {
    this.refreshActiveSessions();
  };

  aboutToAppear(): void {
    // 首载失败（数据库未就绪）时 VM 已记日志，列表保持空态，不打扰用户
    this.viewModel.reload();
    this.refreshConnStatus();
    this.reloadRows();
    this.refreshSyncChip();
    // 无主机时默认展开快速直连；有主机时默认收起（降权）
    this.quickConnectExpanded = this.viewModel.hosts.length === 0;
    this.searchText = this.viewModel.searchText;
    // SyncRuntime.start() 是 fire-and-forget；冷启动补一次 hydrate，避免芯片瞬间误报
    void this.refreshSyncChipAfterHydrate();
    SessionManager.get().addEventListener(this.sessionListener);
    SessionManager.get().addSessionCountListener(this.sessionCountListener);
    this.refreshActiveSessions();
  }

  private async refreshSyncChipAfterHydrate(): Promise<void> {
    await SyncRuntime.get().ensureHydrated();
    this.refreshSyncChip();
  }

  aboutToDisappear(): void {
    SessionManager.get().removeEventListener(this.sessionListener);
    SessionManager.get().removeSessionCountListener(this.sessionCountListener);
  }

  /** 活动会话：未绑定窗格（终端页已返回）且非终态的会话 */
  private refreshActiveSessions(): void {
    const names: Map<string, string> = new Map();
    for (const host of this.viewModel.hosts) {
      names.set(host.id, host.name.length > 0 ? host.name : host.host);
    }
    const sessions: ActiveSessionLike[] = SessionManager.get().listSessions();
    this.activeSessions = buildActiveSessionItems(sessions, names);
  }

  private resumeSession(sessionId: string): void {
    pushTerminalForSession(sessionId);
  }

  private confirmCloseSession(item: ActiveSessionItem): void {
    AlertDialog.show({
      title: '断开会话？',
      message: `将断开「${item.title}」，未保存的远端工作（非 tmux/screen）会丢失。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '断开',
        fontColor: Tokens.Color.danger,
        action: () => {
          SessionManager.get().close(item.sessionId);
          this.refreshConnStatus();
          this.reloadRows();
          this.refreshActiveSessions();
        }
      }
    });
  }

  /** 从 C4 会话列表重派生状态点（SessionInfo[] 结构性满足 HostSessionStateLike） */
  private refreshConnStatus(): void {
    this.viewModel.refreshConnStatus(SessionManager.get().listSessions());
  }

  /** 重建扁平行并刷新 LazyForEach */
  private reloadRows(): void {
    this.dataSource.setRows(this.viewModel.buildRows());
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 显示失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  // ---------------------------------------------------------------- 交互

  /** 父页 onPageShow 驱动：从 HostEditPage 返回后全量重载（含状态点与行重建） */
  private onRefreshTick(): void {
    this.viewModel.reload();
    this.refreshConnStatus();
    this.reloadRows();
    this.refreshSyncChip();
  }

  /** 顶栏芯片：登录/锁定/已连接，从同步运行时快照（页面重建时刷新） */
  private refreshSyncChip(): void {
    try {
      const runtime: SyncRuntime = SyncRuntime.get();
      if (!runtime.auth.isSignedIn()) {
        this.syncChipSub = '未登录';
        this.syncLinked = false;
        return;
      }
      if (!runtime.vault.isReady()) {
        this.syncChipSub = '已锁定';
        this.syncLinked = false;
        return;
      }
      this.syncChipSub = '已连接';
      this.syncLinked = true;
    } catch (_err) {
      this.syncChipSub = '云同步';
      this.syncLinked = false;
    }
  }

  /** 「+」与空状态按钮共用：跳 HostEditPage 新建（U2 接线） */
  private onAddHost(): void {
    router.pushUrl({ url: 'pages/HostEditPage' });
  }

  /**
   * 点按主机行：优先走父页回调（Index 双栏）；否则按 hostId push TerminalPage，
   * 再拨一路独立会话。同一主机允许同时开多个连接。
   */
  private openTerminal(host: HostProfile): void {
    recordHostLastUsed(host.id);
    if (this.onOpenHost !== null) {
      this.onOpenHost(host.id);
      return;
    }
    pushTerminalForHost(host.id);
  }

  /** 快速连接：host[:port] + 用户名 → 临时 HostProfile（不落库）→ 先受理连接再持 sessionId 跳 TerminalPage */
  private quickConnect(): void {
    const target: QuickConnectTarget | null = parseQuickConnectAddress(this.quickAddress);
    const username: string = this.quickUser.trim();
    if (target === null || username.length === 0) {
      this.toast('请填写主机地址（host[:port]）与用户名');
      return;
    }
    const host: HostProfile = createDefaultHostProfile(util.generateRandomUUID());
    host.name = `${username}@${target.host}`;
    host.host = target.host;
    host.port = target.port;
    host.username = username;
    const displayName: string = host.name;
    // 临时主机不落库，TerminalPage 无法按 hostId 取回，故先受理连接、持 sessionId 跳转
    SessionManager.get().connect(host).then((info: SessionInfo) => {
      Logger.info(`快速连接已受理：${info.sessionId}（${displayName}）`, LOG_TAG);
      pushTerminalForSession(info.sessionId);
    }).catch((err: Object) => {
      const message: string = err instanceof Error ? err.message : '连接发起失败';
      Logger.error(`快速连接发起失败（${displayName}）: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast(message);
    });
  }

  /** 滑动菜单「编辑」：跳 HostEditPage 并传 hostId（U2 接线） */
  private onEditHost(hostId: string): void {
    const params: Record<string, Object> = {};
    params['hostId'] = hostId;
    router.pushUrl({ url: 'pages/HostEditPage', params: params });
  }

  /** 滑动菜单「SFTP」：带 hostId（SftpPage 无会话时会提示先建立 SSH 会话） */
  private onOpenSftp(host: HostProfile): void {
    const params: Record<string, Object> = {};
    params['hostId'] = host.id;
    router.pushUrl({ url: 'pages/SftpPage', params: params });
  }

  /** 滑动菜单「转发」：PortForwardPage（规则编辑仍在 HostEdit） */
  private onOpenPortForward(host: HostProfile): void {
    const params: Record<string, Object> = {};
    params['hostId'] = host.id;
    params['hostName'] = host.name.length > 0 ? host.name : host.host;
    router.pushUrl({ url: 'pages/PortForwardPage', params: params });
  }

  /** 滑动菜单「删除」→ 二次确认对话框 */
  private confirmDeleteHost(host: HostProfile): void {
    const displayName: string = host.name.length > 0 ? host.name : host.host;
    try {
      this.getUIContext().showAlertDialog({
        title: '删除主机',
        message: `将删除「${displayName}」及其已保存的凭据，该操作不可恢复。`,
        autoCancel: true,
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '删除',
          fontColor: Tokens.Color.danger,
          action: () => {
            this.deleteHost(host);
          }
        }
      });
    } catch (err) {
      Logger.error(`删除确认对话框显示失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 删除主机：关闭活跃会话 → 删库 → 级联清凭据 → 刷新 */
  private deleteHost(host: HostProfile): void {
    const sessions: SessionInfo[] = SessionManager.get().listSessions();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].hostId === host.id) {
        SessionManager.get().close(sessions[i].sessionId);
      }
    }
    if (!this.viewModel.deleteHost(host.id)) {
      this.toast('操作失败，请重试');
      return;
    }
    CredentialStore.removeAllSecrets(host.id).catch((err: Object) => {
      Logger.error(`级联清理凭据失败（hostId=${host.id}）: ${JSON.stringify(err)}`, LOG_TAG);
    });
    this.refreshConnStatus();
    this.reloadRows();
    this.toast('已删除主机');
  }

  private connStatusColor(status: HostConnStatus): Resource {
    switch (status) {
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

  private authTypeLabel(host: HostProfile): string {
    switch (host.authType) {
      case 'password':
        return '密码';
      case 'key':
        return '密钥';
      default:
        return 'Agent';
    }
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  ActiveSessionsSection() {
    Column() {
      Text(`活动会话（${this.activeSessions.length}）`)
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.text)
        .margin({ bottom: Tokens.space.xs2 })
      ForEach(this.activeSessions, (item: ActiveSessionItem) => {
        Row() {
          Column()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.connStatusColor(item.status))
          Column() {
            Text(item.title)
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${item.statusLabel} · 点按恢复`)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: Tokens.space.sm })
          Text('断开')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.danger)
            .height(40)
            .constraintSize({ minWidth: 48 })
            .textAlign(TextAlign.Center)
            .accessibilityText(`断开会话 ${item.title}`)
            .onClick(() => {
              this.confirmCloseSession(item);
            })
        }
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .alignItems(VerticalAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText(`恢复会话 ${item.title}，${item.statusLabel}`)
        .onClick(() => {
          this.resumeSession(item.sessionId);
        })
      }, (item: ActiveSessionItem) => `${item.sessionId}|${item.status}|${item.title}`)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: Tokens.space.md, right: Tokens.space.xs, top: Tokens.space.sm, bottom: Tokens.space.xs })
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.sm })
  }

  build() {
    const emptyList: boolean = this.viewModel.hosts.length === 0;
    Column() {
      // 顶栏：中文标题 + 云同步胶囊 + 「+」新增入口
      Row() {
        Text('主机')
          .fontSize(Tokens.fontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
          .accessibilityText('主机列表')

        Blank()

        this.SyncChip()
        this.SettingsButton()
        this.ConfigManagerButton()
        this.AddHostButton()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 搜索框：实时过滤 + 非空时一键清除
      Row() {
        TextInput({ placeholder: '搜索名称 / IP / 用户名...', text: this.searchText })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.sm)
          .height(42)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchText = value;
            this.viewModel.setSearchText(value);
            this.reloadRows();
          })
        if (this.searchText.trim().length > 0) {
          Button('×')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.textDim)
            .backgroundColor(Tokens.Color.surface)
            .borderRadius(Tokens.radius.sm)
            .width(42)
            .height(42)
            .margin({ left: Tokens.space.xs })
            .accessibilityText('清除搜索')
            .onClick(() => {
              this.searchText = '';
              this.viewModel.setSearchText('');
              this.reloadRows();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: Tokens.space.sm })

      // 活动会话：终端页返回后仍在后台运行的连接，点按恢复（画面 / 回滚保留）
      if (this.activeSessions.length > 0) {
        this.ActiveSessionsSection()
      }

      // 快速直连：空列表完整展示；有主机时默认收起为轻量入口
      this.QuickConnectSection()

      // 列表区：空状态 / 搜索无结果 / 分组懒加载列表
      if (emptyList) {
        this.EmptyState()
      } else if (this.dataSource.totalCount() === 0) {
        Column() {
          Text(this.searchText.trim().length > 0
            ? `没有匹配「${this.searchText.trim()}」的主机`
            : '暂无主机，点右上角「+」添加')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.textDim)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          LazyForEach(this.dataSource, (row: HostListRow) => {
            if (row.kind === 'groupHeader') {
              ListItem() {
                this.GroupHeaderItem(row)
              }
            } else {
              ListItem() {
                this.HostItem(row)
              }
              .swipeAction({
                end: () => {
                  this.SwipeActions(row);
                }
              })
            }
          }, (row: HostListRow) => row.rowId)
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: Tokens.space.xs })
        .scrollBar(BarState.Off)
        .contentEndOffset(Tokens.space.md)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .padding({
      top: Tokens.space.md,
      left: Tokens.space.md,
      right: Tokens.space.md,
      bottom: 0
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  SyncChip() {
    Row() {
      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(this.syncLinked ? Tokens.Color.success : Tokens.Color.textFaint)
        .margin({ right: Tokens.space.xs })

      Text(this.syncChipSub)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(this.syncLinked ? Tokens.Color.success : Tokens.Color.textDim)
        .fontWeight(FontWeight.Medium)
    }
    .padding({
      left: Tokens.space.sm,
      right: Tokens.space.sm,
      top: Tokens.space.xs,
      bottom: Tokens.space.xs
    })
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ right: Tokens.space.xs })
    .accessibilityText(`云同步：${this.syncChipSub}`)
    .onClick(() => {
      router.pushUrl({ url: 'pages/AccountSyncPage' });
    })
  }

  @Builder
  SettingsButton() {
    Row() {
      Text('☰')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textDim)
    }
    .width(36)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ right: Tokens.space.xs })
    .accessibilityText('设置')
    .accessibilityDescription('打开通用设置')
    .onClick(() => {
      router.pushUrl({ url: 'pages/SettingsPage' });
    })
  }

  @Builder
  ConfigManagerButton() {
    Row() {
      Text('⚙')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textDim)
    }
    .width(36)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ right: Tokens.space.xs })
    .accessibilityText('配置中心')
    .accessibilityDescription('主机、分组、片段与转发的集中管理')
    .onClick(() => {
      router.pushUrl({ url: 'pages/ConfigManagerPage' });
    })
  }

  @Builder
  AddHostButton() {
    Row() {
      Text('+')
        .fontSize(Tokens.fontSize.headline)
        .fontColor(Tokens.Color.onAccent)
        .fontWeight(FontWeight.Regular)
        .textAlign(TextAlign.Center)
    }
    .width(36)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Tokens.Color.accent)
    .borderRadius(Tokens.radius.sm)
    .accessibilityText('添加主机')
    .onClick(() => {
      this.onAddHost();
    })
  }

  /** 快速直连：空态完整展示；有主机时收起为弱入口 */
  @Builder
  QuickConnectSection() {
    if (this.viewModel.hosts.length === 0 || this.quickConnectExpanded) {
      Column() {
        Row() {
          Text('快速直连')
            .fontSize(this.viewModel.hosts.length === 0
              ? Tokens.fontSize.title : Tokens.fontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
            .layoutWeight(1)
          if (this.viewModel.hosts.length > 0) {
            Text('收起')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.accent)
              .padding({
                left: Tokens.space.sm,
                right: Tokens.space.sm,
                top: Tokens.space.xs2,
                bottom: Tokens.space.xs2
              })
              .accessibilityText('收起快速直连')
              .onClick(() => {
                this.quickConnectExpanded = false;
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          TextInput({ placeholder: 'IP 或域名:端口 (如 192.168.1.1:22)', text: this.quickAddress })
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .height(42)
            .layoutWeight(2)
            .onChange((value: string) => {
              this.quickAddress = value;
            })
          TextInput({ placeholder: '用户名 (如 root)', text: this.quickUser })
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .height(42)
            .layoutWeight(1)
            .margin({ left: Tokens.space.xs })
            .onChange((value: string) => {
              this.quickUser = value;
            })
        }
        .width('100%')
        .margin({ top: Tokens.space.sm })

        Button(this.viewModel.hosts.length === 0 ? '立即连接终端' : '连接')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.viewModel.hosts.length === 0 ? Tokens.Color.onAccent : Tokens.Color.text)
          .backgroundColor(this.viewModel.hosts.length === 0
            ? Tokens.Color.accent : Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(this.viewModel.hosts.length === 0 ? 42 : 36)
          .width('100%')
          .margin({ top: Tokens.space.sm })
          .onClick(() => {
            this.quickConnect();
          })
      }
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.md)
      .padding(Tokens.space.md)
      .width('100%')
      .margin({ top: Tokens.space.sm })
    } else {
      Row() {
        Text('快速直连')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .layoutWeight(1)
        Text('展开')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .padding({
            left: Tokens.space.sm,
            right: Tokens.space.sm,
            top: Tokens.space.xs2,
            bottom: Tokens.space.xs2
          })
          .accessibilityText('展开快速连接')
          .onClick(() => {
            this.quickConnectExpanded = true;
          })
      }
      .width('100%')
      .padding({ top: Tokens.space.xs, bottom: Tokens.space.xs })
      .accessibilityText('快速直连（已折叠）')
    }
  }

  @Builder
  GroupHeaderItem(row: HostListRow) {
    Row() {
      Text(row.collapsed ? '▸' : '▾')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textDim)
      Text(row.groupName)
        .fontSize(Tokens.fontSize.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.text)
        .margin({ left: Tokens.space.xs })
      Text(`${row.groupHostCount} 台`)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textFaint)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.xs)
        .padding({
          left: Tokens.space.xs,
          right: Tokens.space.xs,
          top: Tokens.space.xs2,
          bottom: Tokens.space.xs2
        })
        .margin({ left: Tokens.space.xs })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: Tokens.space.md, bottom: Tokens.space.xs })
    .onClick(() => {
      this.viewModel.toggleGroupCollapsed(row.groupId);
      this.reloadRows();
    })
  }

  @Builder
  HostItem(row: HostListRow) {
    if (row.host !== null) {
      Row() {
        Row() {
          Column()
            .width(Tokens.space.xs)
            .height(Tokens.space.xs)
            .borderRadius(Tokens.space.xs2)
            .backgroundColor(this.connStatusColor(row.connStatus))
        }
        .width(24)
        .height(24)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(12)
        .margin({ right: Tokens.space.sm })

        Column() {
          Text(row.host.name.length > 0 ? row.host.name : row.host.host)
            .fontSize(Tokens.fontSize.title)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${row.host.username}@${row.host.host}:${row.host.port}`)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: Tokens.space.xs2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.authTypeLabel(row.host))
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .backgroundColor(Tokens.Color.accentMuted)
          .borderRadius(Tokens.radius.xs)
          .padding({
            left: Tokens.space.xs,
            right: Tokens.space.xs,
            top: Tokens.space.xs2,
            bottom: Tokens.space.xs2
          })
          .margin({ left: Tokens.space.sm })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.sm)
      .padding(Tokens.space.md)
      .margin({ bottom: Tokens.space.xs })
      .onClick(() => {
        if (row.host !== null) {
          this.openTerminal(row.host);
        }
      })
    }
  }

  /** 滑动菜单：编辑 + SFTP + 转发 + 删除（danger 底色，与次操作视觉隔离） */
  @Builder
  SwipeActions(row: HostListRow) {
    if (row.host !== null) {
      Row() {
        Button('编辑')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height('100%')
          .margin({ right: Tokens.space.xs })
          .onClick(() => {
            if (row.host !== null) {
              this.onEditHost(row.host.id);
            }
          })
        Button('SFTP')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height('100%')
          .margin({ right: Tokens.space.xs })
          .onClick(() => {
            if (row.host !== null) {
              this.onOpenSftp(row.host);
            }
          })
        Button('转发')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accentMuted)
          .borderRadius(Tokens.radius.sm)
          .height('100%')
          .margin({ right: Tokens.space.xs })
          .onClick(() => {
            if (row.host !== null) {
              this.onOpenPortForward(row.host);
            }
          })
        Button('删除')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.danger)
          .borderRadius(Tokens.radius.sm)
          .height('100%')
          .onClick(() => {
            if (row.host !== null) {
              this.confirmDeleteHost(row.host);
            }
          })
      }
      .padding({ left: Tokens.space.xs })
    }
  }

  /** 空状态：无主机时的引导位 +「添加第一台主机」 */
  @Builder
  EmptyState() {
    Column() {
      Row() {
        Text('>_')
          .fontSize(Tokens.fontSize.display)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.accent)
          .fontFamily('monospace')
      }
      .width(72)
      .height(72)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.lg)

      Text('暂无主机配置')
        .fontSize(Tokens.fontSize.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.text)
        .margin({ top: Tokens.space.md })

      Text('添加主机后，点按即可一键发起 SSH 终端连接')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.xs })

      Button('添加第一台主机')
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .padding({ left: Tokens.space.lg, right: Tokens.space.lg })
        .margin({ top: Tokens.space.lg })
        .onClick(() => {
          this.onAddHost();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}
