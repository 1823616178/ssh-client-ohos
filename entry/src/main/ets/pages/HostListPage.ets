/**
 * HostListPage —— 主机列表页（任务 U1，DESIGN §4.3.1 页面清单 / §4.2 Token / §4.3 sm 单栏）。
 *
 * 结构（自上而下，单栏；宽度一律百分比不写真机宽度，md/lg 多栏归 U5）：
 *   - 顶栏：标题「主机」+「+」新增入口（跳 HostEditPage 是 U2 的活，当前 Toast 占位）；
 *   - 搜索框：实时过滤（名称/主机/用户名，大小写不敏感，逻辑在 HostListViewModel）；
 *   - 快速连接卡：host[:port] + 用户名 → 构造临时 HostProfile 调 SessionManager.connect，
 *     不落库（U1 只反馈状态，终端页跳转是 U4 接线点）；
 *   - 分组列表：List + LazyForEach + IDataSource 懒加载（对应验收「100 台主机滚动 ≥55fps」
 *     的代码侧要求），按 order 升序分组区 + 未分组区，组头点击折叠（持久化到 C3
 *     hostGroupCollapsed 键，重启复原）；
 *   - 主机行：状态点（按 hostId 从 C4 会话列表派生）+ 名称 + user@host:port + authType 徽标；
 *   - 滑动菜单（ListItem swipeAction）：编辑（U2 占位）、删除（AlertDialog 二次确认 →
 *     关闭该主机活跃会话 C4 → HostDao.deleteById C1 → CredentialStore.removeAllSecrets
 *     级联 C2）；
 *   - 空状态：无主机时引导「添加第一台主机」（U2 占位）；搜索无结果时给提示文案。
 *
 * 刷新模型：C1 DAO 是同步封装、数据量小，页面在 aboutToAppear 与每次操作后
 * reload 全量 + 重建行（reloadRows）；会话状态经 C4 SessionManager 事件监听器
 * （stateChange）驱动状态点刷新，aboutToDisappear 摘除监听。
 */

import { util } from '@kit.ArkTS';
import { HostProfile, createDefaultHostProfile } from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import { SshEvent } from '../napi/SshNative';
import { CredentialStore } from '../repository/CredentialStore';
import { SessionEventListener, SessionInfo, SessionManager } from '../service/SessionManager';
import { Tokens } from '../theme/Tokens';
import {
  HostConnStatus,
  HostListRow,
  HostListViewModel,
  QuickConnectTarget,
  parseQuickConnectAddress
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
  /** 视图模型：搜索串 / 折叠集合 / 派生行（生产依赖惰性解析 AppDatabase / SettingsRepository） */
  private readonly viewModel: HostListViewModel = new HostListViewModel();
  private readonly dataSource: HostRowDataSource = new HostRowDataSource();
  // 快速连接表单值（不需要响应式，普通成员即可，与 Index 冒烟表单同风格）
  private quickAddress: string = '';
  private quickUser: string = '';

  /** 会话状态变化 → 重派生状态点并重建行（U1 只反馈状态，终端页跳转归 U4） */
  private readonly sessionListener: SessionEventListener =
    (session: SessionInfo, event: SshEvent): void => {
      if (event.type === 'stateChange') {
        this.refreshConnStatus();
        this.reloadRows();
      }
    };

  aboutToAppear(): void {
    // 首载失败（数据库未就绪）时 VM 已记日志，列表保持空态，不打扰用户
    this.viewModel.reload();
    this.refreshConnStatus();
    this.reloadRows();
    SessionManager.get().addEventListener(this.sessionListener);
  }

  aboutToDisappear(): void {
    SessionManager.get().removeEventListener(this.sessionListener);
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

  /** 「+」与空状态按钮共用：跳 HostEditPage 是 U2 的活（U2 接线点） */
  private onAddHost(): void {
    this.toast('主机编辑页将在 U2 提供');
  }

  /** 点按主机行 / 快速连接共用入口：受理后状态经状态点与 Toast 反馈（U4 接线点：连接后跳 TerminalPage） */
  private connectHost(host: HostProfile): void {
    const displayName: string = host.name.length > 0 ? host.name : host.host;
    SessionManager.get().connect(host).then((info: SessionInfo) => {
      Logger.info(`已发起连接：${info.sessionId}（主机=${displayName}）`, LOG_TAG);
      this.toast(`正在连接 ${displayName}…`);
      // 受理即出现新会话（connecting 状态无 stateChange 事件），立即刷新一次状态点
      this.refreshConnStatus();
      this.reloadRows();
    }).catch((err: Object) => {
      const message: string = err instanceof Error ? err.message : '连接发起失败';
      Logger.error(`连接发起失败（${displayName}）: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast(message);
    });
  }

  /** 快速连接：host[:port] + 用户名 → 临时 HostProfile（不落库） */
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
    // 已知限制：C4 受理前置要求凭据库已有密码（authType=password），快速连接无凭据
    // 时会以「凭据缺失」失败并 Toast；交互式密码输入归 U2/U4。
    this.connectHost(host);
  }

  /** 滑动菜单「编辑」：跳 HostEditPage 是 U2 的活（U2 接线点） */
  private onEditHost(): void {
    this.toast('主机编辑页将在 U2 提供');
  }

  /** 滑动菜单「删除」→ 二次确认对话框（UIContext.showAlertDialog，AlertDialog.show 已弃用） */
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

  /** 删除主机：关闭活跃会话（C4）→ 删库（C1）→ 级联清凭据（C2 约定）→ 刷新 */
  private deleteHost(host: HostProfile): void {
    // C4：该主机仍有活跃会话时先全部关闭（配置已删，会话失去意义）
    const sessions: SessionInfo[] = SessionManager.get().listSessions();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].hostId === host.id) {
        SessionManager.get().close(sessions[i].sessionId);
      }
    }
    if (!this.viewModel.deleteHost(host.id)) {
      this.toast('删除失败，详见日志');
      return;
    }
    // C2 遗留约定：删除主机必须级联清理 ASSET 凭据（异步，不阻塞列表刷新）
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

  build() {
    Column() {
      // 顶栏：标题 + 「+」新增入口
      Row() {
        Text('主机')
          .fontSize(Tokens.fontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
        Text('+')
          .fontSize(Tokens.fontSize.headline)
          .fontColor(Tokens.Color.accent)
          .padding(Tokens.space.xs)
          .onClick(() => {
            this.onAddHost();
          })
      }
      .width('100%')

      // 搜索框：实时过滤（名称/主机/用户名，大小写不敏感）
      TextInput({ placeholder: '搜索名称 / 主机地址 / 用户名' })
        .fontSize(Tokens.fontSize.body)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .onChange((value: string) => {
          this.viewModel.setSearchText(value);
          this.reloadRows();
        })

      // 快速连接卡（页首）：host[:port] + 用户名，临时配置不落库
      Column() {
        Text('快速连接')
          .fontSize(Tokens.fontSize.title)
          .fontColor(Tokens.Color.text)
        Row() {
          TextInput({ placeholder: 'host[:port]' })
            .fontSize(Tokens.fontSize.body)
            .layoutWeight(2)
            .onChange((value: string) => {
              this.quickAddress = value;
            })
          TextInput({ placeholder: '用户名' })
            .fontSize(Tokens.fontSize.body)
            .layoutWeight(1)
            .margin({ left: Tokens.space.xs })
            .onChange((value: string) => {
              this.quickUser = value;
            })
        }
        .width('100%')
        .margin({ top: Tokens.space.xs })

        Button('连接')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Color.White)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
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

      // 列表区：空状态 / 搜索无结果 / 分组懒加载列表
      if (this.viewModel.hosts.length === 0) {
        this.EmptyState()
      } else if (this.viewModel.filteredHosts().length === 0) {
        Column() {
          Text(`没有匹配「${this.viewModel.searchText.trim()}」的主机`)
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
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .padding(Tokens.space.md)
  }

  /** 组头行：chevron + 组名 + 成员数；点击切换折叠（持久化，旋转动画可省——以字符切换代替） */
  @Builder
  GroupHeaderItem(row: HostListRow) {
    Row() {
      Text(row.collapsed ? '▸' : '▾')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.textFaint)
      Text(row.groupName)
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textDim)
        .margin({ left: Tokens.space.xs })
      Text(`${row.groupHostCount}`)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textFaint)
        .margin({ left: Tokens.space.xs })
    }
    .width('100%')
    .padding({ top: Tokens.space.sm, bottom: Tokens.space.xs })
    .onClick(() => {
      this.viewModel.toggleGroupCollapsed(row.groupId);
      this.reloadRows();
    })
  }

  /** 主机行：状态点 + 名称 + user@host:port + authType 徽标 */
  @Builder
  HostItem(row: HostListRow) {
    if (row.host !== null) {
      Row() {
        // 状态点：space_xs(8vp) 方块 + xs2(4vp) 圆角 = 正圆（仅用 Token）
        Column()
          .width(Tokens.space.xs)
          .height(Tokens.space.xs)
          .borderRadius(Tokens.space.xs2)
          .backgroundColor(this.connStatusColor(row.connStatus))
          .margin({ right: Tokens.space.sm })
        Column() {
          Text(row.host.name.length > 0 ? row.host.name : row.host.host)
            .fontSize(Tokens.fontSize.title)
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
          .fontColor(Tokens.Color.textDim)
          .backgroundColor(Tokens.Color.surfaceHover)
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
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.sm)
      .padding(Tokens.space.sm)
      .margin({ bottom: Tokens.space.xs })
      .onClick(() => {
        if (row.host !== null) {
          this.connectHost(row.host);
        }
      })
    }
  }

  /** 滑动菜单（ListItem 右滑）：编辑（U2 占位）+ 删除（二次确认） */
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
            this.onEditHost();
          })
        Button('删除')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Color.White)
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

  /** 空状态：无主机时的引导位（插画位以字符图形代替）+「添加第一台主机」 */
  @Builder
  EmptyState() {
    Column() {
      Text('>_')
        .fontSize(Tokens.fontSize.display)
        .fontColor(Tokens.Color.textFaint)
      Text('还没有主机')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.md })
      Text('添加主机后，点按即可发起 SSH 连接')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.textFaint)
        .margin({ top: Tokens.space.xs })
      Button('添加第一台主机')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Color.White)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
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
