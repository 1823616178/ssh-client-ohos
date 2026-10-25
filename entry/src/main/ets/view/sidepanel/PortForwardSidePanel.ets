import { util } from '@kit.ArkTS';
import { Tokens } from '../../theme/Tokens';
import { Motion } from '../../theme/Motion';
import { PortForwardRule, PortForwardType } from '../../common/model/models';
import { AppDatabase } from '../../repository/AppDatabase';
import { SessionInfo, SessionManager } from '../../service/SessionManager';
import { SshEvent, isNativeForwardAvailable, nativeCore } from '../../napi/SshNative';
import {
  ForwardRuleSource,
  ForwardNativeEvent,
  NativeForwardPortExt,
  PortForwardRow,
  PortForwardViewModel
} from '../../viewmodel/PortForwardViewModel';
import { Logger } from '../../common/utils/Logger';

const LOG_TAG: string = 'PortForwardSidePanel';

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

function stateLabel(state: string): string {
  switch (state) {
    case 'listening':
      return '监听中';
    case 'starting':
      return '启动中';
    case 'error':
      return '异常';
    case 'stopped':
    default:
      return '已停止';
  }
}

function typeLabel(type: PortForwardType): string {
  switch (type) {
    case 'local':
      return '本地 (L)';
    case 'remote':
      return '远端 (R)';
    case 'dynamic':
      return '动态 (D)';
    default:
      return type;
  }
}

@Component
export struct PortForwardSidePanel {
  /** 首屏入场窗口已过：列表行改用 IDENTITY 过渡（Motion.listItemTransition 注释） */
  @State private introDone: boolean = !Motion.enabled;
  @Prop @Watch('onHostChanged') hostId: string = '';
  @Prop hostName: string = '';
  onOpenFullPage: () => void = () => {};

  @State private rows: PortForwardRow[] = [];
  @State private sessionId: string = '';
  @State private sessionActive: boolean = false;
  @State private showAddForm: boolean = false;
  @State private newType: PortForwardType = 'local';
  @State private newLocalPort: string = '8080';
  @State private newRemoteHost: string = '127.0.0.1';
  @State private newRemotePort: string = '80';
  @State private newBindAddress: string = '127.0.0.1';

  private vm: PortForwardViewModel = new PortForwardViewModel({
    rules: new DaoForwardSource()
  });
  private listenerBound: boolean = false;

  aboutToAppear(): void {
    this.openIntroWindow();
    this.reload();
    SessionManager.get().addEventListener(this.onSessionEvent);
    this.listenerBound = true;
  }

  aboutToDisappear(): void {
    if (this.listenerBound) {
      SessionManager.get().removeEventListener(this.onSessionEvent);
      this.listenerBound = false;
    }
  }

  private onHostChanged(): void {
    this.reload();
  }

  private reload(): void {
    if (this.hostId.length > 0) {
      this.vm.load(this.hostId);
    } else {
      this.vm.loadAll();
    }
    this.bindNativeSession();
    this.sync();
  }

  private bindNativeSession(): void {
    if (this.hostId.length === 0) {
      this.sessionActive = false;
      this.sessionId = '';
      return;
    }
    const sessions: SessionInfo[] = SessionManager.get().listSessions();
    for (const info of sessions) {
      if (info.hostId === this.hostId && info.state === 'established') {
        const handle: number | null = SessionManager.get().getNativeHandle(info.sessionId);
        if (handle !== null && handle > 0) {
          this.sessionId = info.sessionId;
          this.sessionActive = true;
          if (isNativeForwardAvailable()) {
            this.vm.attachSession(handle, new NativeCoreForwardPort());
          }
          return;
        }
      }
    }
    this.sessionActive = false;
    this.sessionId = '';
  }

  private onSessionEvent = (session: SessionInfo, event: SshEvent): void => {
    if (this.sessionId.length > 0 && session.sessionId !== this.sessionId) {
      return;
    }
    if (!event.type.startsWith('forward')) {
      if (event.type === 'stateChange' && event.to === 'established' &&
        this.sessionId.length === 0 && session.hostId === this.hostId) {
        this.bindNativeSession();
      }
      return;
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

  private sync(): void {
    this.rows = this.vm.rows.slice();
  }

  private toggleRule(row: PortForwardRow): void {
    this.vm.toggle(row.rule.id);
    this.sync();
    this.toast(row.running ? '已停止转发' : '已请求启动转发');
  }

  private deleteRule(row: PortForwardRow): void {
    if (row.running) {
      this.vm.stop(row.rule.id);
    }
    try {
      AppDatabase.forwards().deleteById(row.rule.id);
      this.reload();
      this.toast('已删除规则');
    } catch (err) {
      Logger.warn(`删除规则失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast('删除失败');
    }
  }

  private saveNewRule(): void {
    const lPort: number = Number(this.newLocalPort.trim());
    const rPort: number = Number(this.newRemotePort.trim());
    if (isNaN(lPort) || lPort <= 0 || lPort > 65535) {
      this.toast('本地端口格式不正确 (1-65535)');
      return;
    }
    if (this.newType !== 'dynamic' && (isNaN(rPort) || rPort <= 0 || rPort > 65535)) {
      this.toast('目标端口格式不正确 (1-65535)');
      return;
    }
    if (this.hostId.length === 0) {
      this.toast('请先选择目标主机');
      return;
    }
    try {
      const rule: PortForwardRule = {
        id: util.generateRandomUUID(),
        hostId: this.hostId,
        type: this.newType,
        bindAddress: this.newBindAddress.trim().length > 0 ? this.newBindAddress.trim() : '127.0.0.1',
        localPort: lPort,
        remoteHost: this.newRemoteHost.trim().length > 0 ? this.newRemoteHost.trim() : '127.0.0.1',
        remotePort: this.newType === 'dynamic' ? 0 : rPort,
        enabled: true
      };
      AppDatabase.forwards().insert(rule);
      this.showAddForm = false;
      this.reload();
      this.toast('端口转发规则添加成功');
    } catch (err) {
      Logger.warn(`添加规则失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast('添加规则失败');
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 首屏入场窗口：INTRO_WINDOW_MS 内插入的列表行交错入场，之后直接终态 */
  private openIntroWindow(): void {
    if (this.introDone) {
      return;
    }
    setTimeout(() => {
      this.introDone = true;
    }, Motion.INTRO_WINDOW_MS);
  }

  build() {
    Column() {
      // 头部主机与状态提示
      Row() {
        Column() {
          Text(this.hostName.length > 0 ? this.hostName : (this.hostId.length > 0 ? this.hostId : '全部规则'))
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.sessionActive ? '会话已连接 · 随时启停' : '会话未连接 · 规则已保存')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.sessionActive ? Tokens.Color.accent : Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.showAddForm ? '取消' : '+ 规则')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(this.showAddForm ? Tokens.Color.surfaceHover : Tokens.Color.accent)
          .borderRadius(Tokens.radius.xs)
          .height(28)
          .onClick(() => {
            if (this.hostId.length === 0) {
              this.toast('请先在左侧选择主机');
              return;
            }
            this.showAddForm = !this.showAddForm;
          })
      }
      .width('100%')
      .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs, bottom: Tokens.space.xs })

      // 添加规则表单
      if (this.showAddForm) {
        Column({ space: Tokens.space.xs }) {
          Row({ space: Tokens.space.xs }) {
            Button('本地 (L)')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(this.newType === 'local' ? Tokens.Color.onAccent : Tokens.Color.textDim)
              .backgroundColor(this.newType === 'local' ? Tokens.Color.accent : Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.xs)
              .height(26)
              .layoutWeight(1)
              .onClick(() => {
                this.newType = 'local';
              })
            Button('远端 (R)')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(this.newType === 'remote' ? Tokens.Color.onAccent : Tokens.Color.textDim)
              .backgroundColor(this.newType === 'remote' ? Tokens.Color.accent : Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.xs)
              .height(26)
              .layoutWeight(1)
              .onClick(() => {
                this.newType = 'remote';
              })
            Button('动态 (D)')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(this.newType === 'dynamic' ? Tokens.Color.onAccent : Tokens.Color.textDim)
              .backgroundColor(this.newType === 'dynamic' ? Tokens.Color.accent : Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.xs)
              .height(26)
              .layoutWeight(1)
              .onClick(() => {
                this.newType = 'dynamic';
              })
          }
          .width('100%')

          Row({ space: Tokens.space.xs }) {
            TextInput({ text: this.newLocalPort, placeholder: '本地端口' })
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.xs)
              .height(30)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.newLocalPort = v;
              })
            if (this.newType !== 'dynamic') {
              TextInput({ text: this.newRemotePort, placeholder: '目标端口' })
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.text)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.xs)
                .height(30)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.newRemotePort = v;
                })
            }
          }
          .width('100%')

          if (this.newType !== 'dynamic') {
            TextInput({ text: this.newRemoteHost, placeholder: '目标地址 (如 127.0.0.1)' })
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.xs)
              .height(30)
              .width('100%')
              .onChange((v: string) => {
                this.newRemoteHost = v;
              })
          }

          Row() {
            Blank()
            Button('保存规则')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.xs)
              .height(28)
              .onClick(() => {
                this.saveNewRule();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(Tokens.space.sm)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ left: Tokens.space.sm, right: Tokens.space.sm, bottom: Tokens.space.xs })
        .transition(Motion.riseTransition())
      }

      // 规则列表
      if (this.rows.length === 0) {
        Column() {
          Text('暂无端口转发规则')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
          Text('点击上方「+ 规则」添加本地或远程转发')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
            .margin({ top: Tokens.space.xs2 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .transition(Motion.fadeTransition())
      } else {
        Scroll() {
          Column({ space: Tokens.space.xs }) {
            ForEach(this.rows, (row: PortForwardRow, index: number) => {
              Column() {
                Row() {
                  Text(typeLabel(row.rule.type))
                    .fontSize(Tokens.fontSize.caption)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Tokens.Color.accent)
                    .backgroundColor(Tokens.Color.surfaceHover)
                    .borderRadius(Tokens.radius.xs)
                    .padding({ left: Tokens.space.xs, right: Tokens.space.xs, top: 2, bottom: 2 })

                  Text(stateLabel(row.status?.state ?? 'idle'))
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(row.running ? Tokens.Color.accent : Tokens.Color.textDim)
                    .margin({ left: Tokens.space.xs })

                  Blank()

                  Text('删除')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.danger)
                    .clickEffect(Motion.pressEffect())
                    .onClick(() => {
                      this.deleteRule(row);
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                // 规则链路展示
                Text(row.rule.type === 'dynamic'
                  ? `监听 :${row.rule.localPort} (SOCKS5)`
                  : `:${row.rule.localPort} → ${row.rule.remoteHost}:${row.rule.remotePort}`)
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.text)
                  .fontFamily('monospace')
                  .margin({ top: Tokens.space.xs2, bottom: Tokens.space.xs2 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Row() {
                  Text(`连接数: ${row.status?.connections ?? 0}`)
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.textFaint)

                  Blank()

                  Button(row.running ? '停止' : '启动')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(row.running ? Tokens.Color.text : Tokens.Color.onAccent)
                    .backgroundColor(row.running ? Tokens.Color.surfaceHover : Tokens.Color.accent)
                    .borderRadius(Tokens.radius.xs)
                    .height(26)
                    .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
                    .onClick(() => {
                      this.toggleRule(row);
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .padding(Tokens.space.sm)
              .backgroundColor(Tokens.Color.surface)
              .borderRadius(Tokens.radius.sm)
              .border({ width: 1, color: Tokens.Color.border })
              // 首屏交错入场（INTRO_WINDOW_MS 后 IDENTITY：滚动复用/数据刷新不重播）
              .transition(this.introDone ? TransitionEffect.IDENTITY : Motion.listItemTransition(index))
            }, (row: PortForwardRow) => `${row.rule.id}-${row.status?.state ?? 'idle'}-${row.running}`)
          }
          .width('100%')
          .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs, bottom: Tokens.space.xs })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      // 底部链接
      Row() {
        Text('打开完整转发页面 ›')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .clickEffect(Motion.pressEffect())
          .onClick(() => {
            this.onOpenFullPage();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding(Tokens.space.xs)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }
}
