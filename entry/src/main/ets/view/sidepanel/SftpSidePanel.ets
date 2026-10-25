import { SessionManager, SessionInfo } from '../../service/SessionManager';
import { Tokens } from '../../theme/Tokens';
import { Motion } from '../../theme/Motion';
import { SmoothProgressBar } from '../SmoothProgressBar';
import { SftpNativeGateway } from '../../napi/SftpNativeGateway';
import {
  SftpRow,
  SftpSessionSource,
  SftpViewModel,
  SftpNativeEventFields
} from '../../viewmodel/SftpViewModel';
import { TransferJob } from '../../viewmodel/TransferQueue';
import { SshEvent } from '../../napi/SshNative';
import { Logger } from '../../common/utils/Logger';
import { SftpSaver } from '../../common/utils/SftpSaver';

const LOG_TAG: string = 'SftpSidePanel';

function transferStateLabel(state: string): string {
  switch (state) {
    case 'queued':
      return '排队中';
    case 'running':
      return '传输中';
    case 'paused':
      return '已暂停';
    case 'completed':
      return '已完成';
    case 'failed':
      return '失败';
    case 'cancelled':
      return '已取消';
    default:
      return '待处理';
  }
}

class ManagerSessionSource implements SftpSessionSource {
  nativeHandleOf(sessionId: string): number | null {
    return SessionManager.get().getNativeHandle(sessionId);
  }

  isEstablished(sessionId: string): boolean {
    const info: SessionInfo | null = SessionManager.get().getSession(sessionId);
    return info !== null && info.state === 'established';
  }
}

@Component
export struct SftpSidePanel {
  /** 首屏入场窗口已过：列表行改用 IDENTITY 过渡（Motion.listItemTransition 注释） */
  @State private introDone: boolean = !Motion.enabled;
  @Prop @Watch('onHostChanged') hostId: string = '';
  @Prop hostName: string = '';
  onOpenFullPage: () => void = () => {};

  @State private vmRows: SftpRow[] = [];
  @State private vmDir: string = '/';
  @State private vmError: string = '';
  @State private vmLoading: boolean = false;
  @State private transfers: TransferJob[] = [];
  @State private sessionActive: boolean = false;
  @State private sessionId: string = '';

  private vm: SftpViewModel = new SftpViewModel({
    gateway: new SftpNativeGateway(),
    sessionSource: new ManagerSessionSource()
  });
  private listenerBound: boolean = false;
  /** 下载落盘协调：系统保存框选位置 → 沙箱中转 → 完成后拷贝 */
  private readonly saver: SftpSaver = new SftpSaver();

  aboutToAppear(): void {
    this.openIntroWindow();
    this.bindSession();
    SessionManager.get().addEventListener(this.onSessionEvent);
    this.listenerBound = true;
  }

  aboutToDisappear(): void {
    if (this.listenerBound) {
      SessionManager.get().removeEventListener(this.onSessionEvent);
      this.listenerBound = false;
    }
    this.vm.detach();
  }

  private onHostChanged(): void {
    this.bindSession();
  }

  private bindSession(): void {
    this.sessionId = '';
    this.sessionActive = false;
    this.vm.detach();
    if (this.hostId.length === 0) {
      this.syncFromVm();
      return;
    }
    const sessions: SessionInfo[] = SessionManager.get().listSessions();
    for (const info of sessions) {
      if (info.hostId === this.hostId && info.state === 'established') {
        this.sessionId = info.sessionId;
        const ok: boolean = this.vm.attachSession(info.sessionId);
        this.sessionActive = ok;
        this.syncFromVm();
        return;
      }
    }
    this.syncFromVm();
  }

  private onSessionEvent = (session: SessionInfo, event: SshEvent): void => {
    if (event.type === 'stateChange' && session.hostId === this.hostId) {
      if (event.to === 'established' && !this.sessionActive) {
        this.bindSession();
        return;
      } else if (event.to === 'closed' && this.sessionActive && session.sessionId === this.sessionId) {
        this.sessionActive = false;
        this.vm.detach();
        this.syncFromVm();
        return;
      }
    }
    if (this.sessionId.length === 0 || session.sessionId !== this.sessionId) {
      return;
    }
    if (event.type === 'sftpTransferDone') {
      const doneId: number = event.transferId ?? 0;
      const saved: string = this.saver.onFinish(doneId, event.success === true);
      if (saved === 'saved') {
        this.toast('下载完成，已保存到你选择的位置');
      } else if (saved === 'failed') {
        this.toast('下载失败');
      }
    }
    if (event.type.startsWith('sftp')) {
      const fields: SftpNativeEventFields = {
        success: event.success,
        sftp: event.sftp,
        path: event.path,
        error: event.error,
        message: event.message,
        entriesJson: event.entriesJson,
        entryJson: event.entryJson,
        op: event.op,
        transferId: event.transferId,
        transferred: event.transferred,
        total: event.total
      };
      this.vm.handleNativeEvent(event.type, fields);
      this.syncFromVm();
    }
  };

  private syncFromVm(): void {
    this.vmRows = this.vm.rows.slice();
    this.vmDir = this.vm.currentDir;
    this.vmError = this.vm.error;
    this.vmLoading = this.vm.loading;
    this.transfers = this.vm.queue.list();
  }

  private async downloadFile(row: SftpRow): Promise<void> {
    const destUri: string | null = await this.saver.pickDest(row.name);
    if (destUri === null) {
      return; // 用户在保存对话框点了取消
    }
    const tempPath: string = this.saver.tempPathFor(row.name);
    const job: TransferJob = this.vm.enqueueDownload(row.name, tempPath, row.size);
    this.saver.track(job.id, row.name, tempPath, destUri);
    this.syncFromVm();
    this.toast(`开始下载: ${row.name}`);
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
      // 头部主机信息与刷新
      Row() {
        Column() {
          Text(this.hostName.length > 0 ? this.hostName : (this.hostId.length > 0 ? this.hostId : '文件传输'))
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.sessionActive ? '会话已连接 · SFTP 就绪' : '会话未建立 · 待连接')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.sessionActive ? Tokens.Color.accent : Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.sessionActive) {
          Button('⟳')
            .fontSize(Tokens.fontSize.title)
            .fontColor(Tokens.Color.textDim)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.xs)
            .width(28)
            .height(28)
            .onClick(() => {
              this.vm.refresh(this.vmDir);
              this.syncFromVm();
            })
        }
      }
      .width('100%')
      .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs, bottom: Tokens.space.xs })

      if (!this.sessionActive) {
        Column() {
          Text('未建立 SSH 连接')
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.warn)
          Text('连接主机后，可在侧面板直接浏览、下载和管理远端文件。')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .textAlign(TextAlign.Center)
            .margin({ top: Tokens.space.xs, left: Tokens.space.md, right: Tokens.space.md })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 路径导航条
        Row() {
          Button('‹ 上级')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.vmDir === '/' ? Tokens.Color.textFaint : Tokens.Color.accent)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.xs)
            .height(26)
            .enabled(this.vmDir !== '/')
            .onClick(() => {
              this.vm.navigateUp();
              this.syncFromVm();
            })

          Text(this.vmDir)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .fontFamily('monospace')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: Tokens.space.xs })
        }
        .width('100%')
        .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs2, bottom: Tokens.space.xs2 })
        .backgroundColor(Tokens.Color.surface)

        // 状态消息
        if (this.vmLoading) {
          Text('加载目录中…')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.accent)
            .width('100%')
            .padding({ left: Tokens.space.sm, top: Tokens.space.xs2 })
          .transition(Motion.fadeTransition())
        }
        if (this.vmError.length > 0) {
          Text(this.vmError)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.danger)
            .width('100%')
            .padding({ left: Tokens.space.sm, top: Tokens.space.xs2 })
        }

        // 文件列表（List 保证从顶部向下排；Scroll 内容不足一屏时会垂直居中）
        if (this.vmRows.length === 0 && !this.vmLoading) {
          Column() {
            Text('空目录')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textFaint)
              .margin({ top: Tokens.space.lg })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Start)
          .transition(Motion.fadeTransition())
        } else {
          List() {
            ForEach(this.vmRows, (row: SftpRow, index: number) => {
              ListItem() {
                Row() {
                  Text(row.isDir ? '📁' : '📄')
                    .fontSize(Tokens.fontSize.body)
                    .margin({ right: Tokens.space.xs })

                  Column() {
                    Text(row.name)
                      .fontSize(Tokens.fontSize.caption)
                      .fontWeight(row.isDir ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(Tokens.Color.text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${row.displaySize}  ${row.displayMtime}`)
                      .fontSize(10)
                      .fontColor(Tokens.Color.textDim)
                      .maxLines(1)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (!row.isDir) {
                    Button('下载')
                      .fontSize(Tokens.fontSize.caption)
                      .fontColor(Tokens.Color.onAccent)
                      .backgroundColor(Tokens.Color.accent)
                      .borderRadius(Tokens.radius.xs)
                      .height(28)
                      .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
                      .accessibilityText(`下载 ${row.name}`)
                      .onClick(() => {
                        this.downloadFile(row);
                      })
                  }
                }
                .width('100%')
                .padding(Tokens.space.xs)
                .backgroundColor(Tokens.Color.surface)
                .borderRadius(Tokens.radius.xs)
                .margin({ bottom: Tokens.space.xs2 })
                .clickEffect(Motion.pressEffect())
                .onClick(() => {
                  if (row.isDir) {
                    this.vm.navigateTo(row);
                    this.syncFromVm();
                  }
                })
              }
              // 首屏交错入场（INTRO_WINDOW_MS 后 IDENTITY：滚动复用/数据刷新不重播）
              .transition(this.introDone ? TransitionEffect.IDENTITY : Motion.listItemTransition(index))
            }, (row: SftpRow) => row.path)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs, bottom: Tokens.space.xs })
          .scrollBar(BarState.Off)
        }

        // 传输进度
        if (this.transfers.length > 0) {
          Column() {
            Text('传输任务')
              .fontSize(Tokens.fontSize.caption)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.Color.text)
              .width('100%')

            ForEach(this.transfers, (job: TransferJob) => {
              Column() {
                Row() {
                  Text(job.direction === 'download' ? '↓' : '↑')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.accent)
                  Text(job.remotePath)
                    .fontSize(10)
                    .fontColor(Tokens.Color.text)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ left: Tokens.space.xs2, right: Tokens.space.xs2 })
                  Text(`${this.vm.progressOf(job.id)}% · ${transferStateLabel(job.state)}`)
                    .fontSize(10)
                    .fontColor(job.state === 'completed' ? Tokens.Color.success : Tokens.Color.textDim)
                }
                .width('100%')
                // 进度补间（见 SmoothProgressBar 头注）
                SmoothProgressBar({ trackKey: `sftp-side-${job.id}`, percent: this.vm.progressOf(job.id), barHeight: 2 })
                  .margin({ top: Tokens.space.xs2 })
              }
              .width('100%')
              .margin({ top: Tokens.space.xs2 })
            }, (job: TransferJob) => `${job.id}-${job.state}-${job.transferredBytes}`)
          }
          .width('100%')
          .padding(Tokens.space.xs)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)
          .margin({ left: Tokens.space.sm, right: Tokens.space.sm, bottom: Tokens.space.xs })
        }
      }

      // 底部链接
      Row() {
        Text('打开完整文件传输页 ›')
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
