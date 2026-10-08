/**
 * PortForwardPage —— U9 端口转发启停面板（DESIGN §7.3 / TASKS U9）。
 *
 * 规则增删改在 HostEditPage；本页按主机列出规则并启停，
 * 展示运行状态、连接数、流量与运行日志。
 * N15：绑定 established 会话后，SessionManager 的 forward* 事件路由进
 * PortForwardViewModel.handleNativeEvent，-R 连接/流量随事件刷新。
 * Design Tokens only。
 */

import { Tokens } from '../theme/Tokens';
import { PageHeader, PageHeaderAction } from '../view/PageHeader';
import { Logger } from '../common/utils/Logger';
import { PortForwardRule } from '../common/model/models';
import { AppDatabase } from '../repository/AppDatabase';
import { SessionInfo, SessionManager } from '../service/SessionManager';
import { SshEvent, isNativeForwardAvailable, nativeCore } from '../napi/SshNative';
import {
  ForwardRuleSource,
  ForwardNativeEvent,
  NativeForwardPortExt,
  PortForwardRow,
  PortForwardViewModel
} from '../viewmodel/PortForwardViewModel';
import { ForwardRuntimeLog } from '../service/portforward/PortForwardRuntime';
import { router } from '@kit.ArkUI';

const LOG_TAG: string = 'PortForwardPage';

/** 运行时状态 → 用户可见中文 */
function forwardStateLabel(state: string): string {
  if (state === 'listening') {
    return '监听中';
  }
  if (state === 'starting') {
    return '启动中';
  }
  if (state === 'error') {
    return '错误';
  }
  if (state === 'stopped') {
    return '已停止';
  }
  return '已停止';
}

class DaoForwardSource implements ForwardRuleSource {
  listByHostId(hostId: string): PortForwardRule[] {
    return AppDatabase.forwards().listByHostId(hostId);
  }

  listAll(): PortForwardRule[] {
    return AppDatabase.forwards().listAll();
  }

  getById(id: string): PortForwardRule | null {
    return AppDatabase.forwards().getById(id);
  }
}

/** N15：native 数据面窄口适配（openDirectTcpip / remoteForwardListen / …） */
class NativeCoreForwardPort implements NativeForwardPortExt {
  openDirectTcpip(sessionHandle: number, host: string, port: number): number {
    try {
      return nativeCore().openDirectTcpip(sessionHandle, host, port);
    } catch (_e) {
      return 0;
    }
  }

  forwardWrite(forwardHandle: number, data: ArrayBuffer | string): boolean {
    try {
      return nativeCore().forwardWrite(forwardHandle, data);
    } catch (_e) {
      return false;
    }
  }

  forwardClose(forwardHandle: number): boolean {
    try {
      return nativeCore().forwardClose(forwardHandle);
    } catch (_e) {
      return false;
    }
  }

  remoteForwardListen(sessionHandle: number, bind: string, port: number): number {
    try {
      return nativeCore().remoteForwardListen(sessionHandle, bind, port);
    } catch (_e) {
      return 0;
    }
  }
}

interface ForwardRouteParams {
  hostId?: string;
  hostName?: string;
}

@Entry
@Component
struct PortForwardPage {
  @State rows: PortForwardRow[] = [];
  @State logs: ForwardRuntimeLog[] = [];
  @State error: string = '';
  @State hostLabel: string = '';
  @State sessionId: string = '';
  @State nativeReady: boolean = false;

  private vm: PortForwardViewModel = new PortForwardViewModel({
    rules: new DaoForwardSource()
  });
  private hostId: string = '';
  private listenerBound: boolean = false;

  aboutToAppear(): void {
    const params: ForwardRouteParams = this.readRouteParams();
    this.hostId = params.hostId ?? '';
    this.hostLabel = params.hostName ?? (this.hostId.length > 0 ? this.hostId : '全部主机');
    if (this.hostId.length > 0) {
      this.vm.load(this.hostId);
    } else {
      this.vm.loadAll();
    }
    this.bindNativeSession();
    SessionManager.get().addEventListener(this.onSessionEvent);
    this.listenerBound = true;
    this.sync();
  }

  aboutToDisappear(): void {
    if (this.listenerBound) {
      SessionManager.get().removeEventListener(this.onSessionEvent);
      this.listenerBound = false;
    }
    // 停掉本页启动的转发，避免页退后本地监听残留
    for (const row of this.rows) {
      if (row.running) {
        this.vm.stop(row.rule.id);
      }
    }
  }

  /** N15：绑定本主机 established 会话 + native forward 桥 */
  private bindNativeSession(): void {
    if (this.hostId.length === 0) {
      return;
    }
    const sessions: SessionInfo[] = SessionManager.get().listSessions();
    for (const info of sessions) {
      if (info.hostId !== this.hostId || info.state !== 'established') {
        continue;
      }
      const handle: number | null = SessionManager.get().getNativeHandle(info.sessionId);
      if (handle === null || handle <= 0) {
        continue;
      }
      this.sessionId = info.sessionId;
      if (isNativeForwardAvailable()) {
        this.vm.attachSession(handle, new NativeCoreForwardPort());
        this.nativeReady = true;
        Logger.info(`端口转发绑定会话 ${info.sessionId} handle=${handle}`, LOG_TAG);
      } else {
        Logger.info('native forward 桥不可用，端口转发保持 MVP 监听骨架', LOG_TAG);
      }
      this.sync();
      return;
    }
  }

  private onSessionEvent = (session: SessionInfo, event: SshEvent): void => {
    if (this.sessionId.length > 0 && session.sessionId !== this.sessionId) {
      return;
    }
    if (!event.type.startsWith('forward')) {
      // 会话状态变化时尝试重新绑定（先连主机再进本页的场景）
      if (event.type === 'stateChange' && event.to === 'established' &&
        this.sessionId.length === 0 && session.hostId === this.hostId) {
        this.bindNativeSession();
      }
      return;
    }
    if (this.sessionId.length === 0 && session.hostId === this.hostId) {
      this.bindNativeSession();
    }
    const evt: ForwardNativeEvent = {
      type: event.type,
      forward: event.forward,
      listen: event.listen,
      success: event.success,
      error: event.error,
      message: event.message,
      reason: event.reason,
      data: event.data,
      boundPort: event.boundPort,
      origin: event.origin
    };
    this.vm.handleNativeEvent(evt);
    this.sync();
  };

  private readRouteParams(): ForwardRouteParams {
    const raw: object | null = router.getParams() as object | null;
    if (raw === null) {
      return {};
    }
    const rec: Record<string, Object> = raw as Record<string, Object>;
    const out: ForwardRouteParams = {};
    const hid: Object | undefined = rec['hostId'];
    if (typeof hid === 'string') {
      out.hostId = hid;
    }
    const hn: Object | undefined = rec['hostName'];
    if (typeof hn === 'string') {
      out.hostName = hn;
    }
    return out;
  }

  private sync(): void {
    this.rows = this.vm.rows.slice();
    this.logs = this.vm.logs.slice();
    this.error = this.vm.error;
  }

  private getHeaderActions(): PageHeaderAction[] {
    return [
      {
        label: '编辑规则',
        onClick: (): void => {
          this.openHostEdit();
        },
        accessibilityText: '编辑转发规则'
      }
    ];
  }

  build() {
    Column() {
      PageHeader({
        title: '端口转发',
        subtitle: this.hostLabel,
        actions: this.getHeaderActions()
      })

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
          .margin({ top: Tokens.space.xs })
      }

      if (!this.nativeReady && this.sessionId.length > 0) {
        Text('转发通道未就绪，请先建立 SSH 会话')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
      }

      if (this.rows.length === 0) {
        Text('暂无转发规则。请先在主机编辑页添加。')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textFaint)
          .margin({ top: Tokens.space.lg })
      } else {
        List() {
          ForEach(this.rows, (row: PortForwardRow) => {
            ListItem() {
              this.RuleRow(row)
            }
          }, (row: PortForwardRow) =>
          `${row.rule.id}|${row.status?.state ?? 'idle'}|${row.status?.connections ?? 0}|` +
            `${row.status?.bytesIn ?? 0}|${row.status?.bytesOut ?? 0}|${row.status?.listenLabel ?? ''}`)
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: Tokens.space.sm })
        .scrollBar(BarState.Off)
      }

      this.LogPanel()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .padding({
      top: 0,
      left: Tokens.space.md,
      right: Tokens.space.md,
      bottom: Tokens.space.sm
    })
  }

  @Builder
  RuleRow(row: PortForwardRow) {
    Column() {
      Text(row.label)
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.statusLine(row))
        .fontSize(Tokens.fontSize.caption)
        .fontColor(row.running ? Tokens.Color.success : Tokens.Color.textDim)
        .width('100%')
        .margin({ top: Tokens.space.xs2 })
      if (row.status !== null && row.status.listenLabel.length > 0 && row.running) {
        Text(row.status.listenLabel)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .width('100%')
      }
      if (row.status !== null && row.status.errorMessage.length > 0) {
        Text(this.friendlyForwardMessage(row.status.errorMessage))
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (row.status !== null && row.status.nativeChannelRequired) {
        Text('转发通道未就绪')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
      }
      Button(row.running ? '停止' : '启动')
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(row.running ? Tokens.Color.text : Tokens.Color.onAccent)
        .backgroundColor(row.running ? Tokens.Color.surfaceHover : Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(36)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .enabled(row.running || row.canStart)
        .onClick(() => {
          this.vm.toggle(row.rule.id);
          this.sync();
        })
    }
    .width('100%')
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.xs })
  }

  /** 运行时/错误文案 → 产品中文（runtime 日志仍可保留英文，UI 不暴露实现词） */
  private friendlyForwardMessage(message: string): string {
    if (message.indexOf('native channel') >= 0 || message.indexOf('NAPI') >= 0
      || message.indexOf('需已连接的 SSH 会话') >= 0) {
      return '需已连接的 SSH 会话才能打开转发通道';
    }
    return message;
  }

  /** 状态 · 连接数 · 流量（bytesIn/bytesOut，事件与本地外壳共同入账） */
  private statusLine(row: PortForwardRow): string {
    const st = row.status;
    if (st === null) {
      return '已停止';
    }
    return `${forwardStateLabel(st.state)}  ·  连接 ${st.connections}  ·  ↓${st.bytesIn}B ↑${st.bytesOut}B`;
  }

  @Builder
  LogPanel() {
    Column() {
      Text('运行日志')
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.textDim)
        .width('100%')
      if (this.logs.length === 0) {
        Text('暂无日志')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
      } else {
        ForEach(this.logs.slice(-8), (entry: ForwardRuntimeLog, index: number) => {
          Text(`${entry.ruleId.slice(0, 8)}: ${this.friendlyForwardMessage(entry.message)}`)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }, (entry: ForwardRuntimeLog, index: number) => `${index}-${entry.message}`)
      }
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ top: Tokens.space.sm })
  }

  private openHostEdit(): void {
    if (this.hostId.length === 0) {
      this.error = '未绑定主机，无法编辑规则（请从主机列表进入）';
      return;
    }
    const params: Record<string, Object> = {};
    params['hostId'] = this.hostId;
    router.pushUrl({ url: 'pages/HostEditPage', params: params });
  }
}

