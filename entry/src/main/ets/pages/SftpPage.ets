/**
 * SftpPage —— U8 SFTP 文件浏览与传输（DESIGN §7.4 / TASKS U8）。
 *
 * MVP：
 *   - 路由参数 sessionId（优先）或 hostId；
 *   - 远端路径列表（名称/类型/大小/mtime/权限）+ 导航 + 上级；
 *   - 传输队列列表（进度字段）；
 *   - 下载/上传：文件选择器接入前本页按钮直接入队。
 * Design Tokens only。
 */

import { router } from '@kit.ArkUI';
import { SessionManager, SessionInfo } from '../service/SessionManager';
import { Tokens } from '../theme/Tokens';
import { PageHeader, PageHeaderAction } from '../view/PageHeader';
import { Logger } from '../common/utils/Logger';
import { SftpNativeGateway } from '../napi/SftpNativeGateway';
import {
  SftpRow,
  SftpSessionSource,
  SftpViewModel,
  SftpNativeEventFields
} from '../viewmodel/SftpViewModel';
import { TransferJob } from '../viewmodel/TransferQueue';
import { SshEvent } from '../napi/SshNative';

const LOG_TAG: string = 'SftpPage';

/** 传输状态 → 产品中文（UI 不暴露英文枚举） */
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

interface SftpRouteParams {
  sessionId?: string;
  hostId?: string;
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

@Entry
@Component
struct SftpPage {
  @State vmRows: SftpRow[] = [];
  @State vmDir: string = '/';
  @State vmError: string = '';
  @State vmLoading: boolean = false;
  @State nativeUnavailable: boolean = false;
  @State transfers: TransferJob[] = [];
  @State sessionLabel: string = '';

  private vm: SftpViewModel = new SftpViewModel({
    gateway: new SftpNativeGateway(),
    sessionSource: new ManagerSessionSource()
  });
  private sessionId: string = '';
  private listenerBound: boolean = false;

  aboutToAppear(): void {
    const params: SftpRouteParams = this.readRouteParams();
    let sid: string = params.sessionId ?? '';
    if (sid.length === 0 && (params.hostId ?? '').length > 0) {
      // hostId：若 SessionManager 已有该主机的 established 会话则复用，否则提示
      const info: SessionInfo | null = this.findSessionByHost(params.hostId ?? '');
      sid = info !== null ? info.sessionId : '';
    }
    if (sid.length === 0) {
      this.vmError = '请先建立 SSH 连接后再打开文件传输';
      this.nativeUnavailable = true;
      return;
    }
    this.sessionId = sid;
    const info: SessionInfo | null = SessionManager.get().getSession(sid);
    this.sessionLabel = info !== null ? info.hostName : sid;
    const ok: boolean = this.vm.attachSession(sid);
    this.nativeUnavailable = this.vm.nativeUnavailable;
    this.vmError = this.vm.error;
    this.syncFromVm();
    if (!ok) {
      Logger.info(`SFTP attach 未成功 session=${sid}`, LOG_TAG);
    }
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

  private onSessionEvent = (session: SessionInfo, event: SshEvent): void => {
    if (session.sessionId !== this.sessionId) {
      return;
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
    this.nativeUnavailable = this.vm.nativeUnavailable;
    this.transfers = this.vm.queue.list();
  }

  private readRouteParams(): SftpRouteParams {
    const raw: object | null = router.getParams() as object | null;
    if (raw === null) {
      return {};
    }
    const rec: Record<string, Object> = raw as Record<string, Object>;
    const out: SftpRouteParams = {};
    const sid: Object | undefined = rec['sessionId'];
    if (typeof sid === 'string') {
      out.sessionId = sid;
    }
    const hid: Object | undefined = rec['hostId'];
    if (typeof hid === 'string') {
      out.hostId = hid;
    }
    return out;
  }

  private findSessionByHost(hostId: string): SessionInfo | null {
    // SessionManager 无 listAll 公开口时，仅支持 sessionId 直达；
    // hostId 路径留给 HostList 先 connect 再带 sessionId 跳转
    return null;
  }

  private toast(text: string): void {
    this.vmError = text;
  }

  private getHeaderActions(): PageHeaderAction[] {
    return [
      {
        label: '上传',
        onClick: (): void => {
          this.onUploadStub();
        },
        primary: true,
        disabled: this.nativeUnavailable,
        accessibilityText: '上传文件'
      }
    ];
  }

  build() {
    Column() {
      PageHeader({
        title: '文件传输',
        subtitle: this.sessionLabel.length > 0 ? this.sessionLabel : '未连接会话',
        actions: this.getHeaderActions()
      })
      if (this.nativeUnavailable) {
        this.UnavailableBanner()
      }
      this.PathBar()
      if (this.vmLoading) {
        Text('加载中…')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm })
      }
      if (this.vmError.length > 0 && !this.nativeUnavailable) {
        Text(this.vmError)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
          .margin({ top: Tokens.space.xs })
      }
      this.FileList()
      this.TransferPanel()
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
  UnavailableBanner() {
    Column() {
      Text('文件通道未就绪')
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.warn)
      Text('请先连接主机后再浏览远端文件。传输队列仍可查看。')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.xs2 })
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  PathBar() {
    Row() {
      Text('上级')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.accent)
        .padding({
          left: Tokens.space.sm,
          right: Tokens.space.sm,
          top: Tokens.space.xs,
          bottom: Tokens.space.xs
        })
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .accessibilityText('返回上级目录')
        .onClick(() => {
          this.vm.navigateUp();
          this.syncFromVm();
        })
      Text(this.vmDir)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: Tokens.space.sm })
    }
    .width('100%')
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .padding(Tokens.space.xs)
  }

  @Builder
  FileList() {
    if (this.vmRows.length === 0) {
      Text(this.nativeUnavailable ? '暂无文件列表' : '空目录')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.textFaint)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: Tokens.space.lg })
    } else {
      List() {
        ForEach(this.vmRows, (row: SftpRow) => {
          ListItem() {
            this.FileRow(row)
          }
        }, (row: SftpRow) => row.path)
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: Tokens.space.sm })
      .scrollBar(BarState.Off)
    }
  }

  @Builder
  FileRow(row: SftpRow) {
    Row() {
      Text(row.isDir ? '目录' : row.isSymlink ? '链接' : '文件')
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
        .margin({ right: Tokens.space.sm })
      Column() {
        Text(row.name)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${row.permissions}  ${row.displaySize}  ${row.displayMtime}`)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (!row.isDir && !this.nativeUnavailable) {
        Text('↓')
          .fontSize(Tokens.fontSize.title)
          .fontColor(Tokens.Color.accent)
          .padding(Tokens.space.xs)
          .onClick(() => this.onDownloadStub(row))
      }
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.xs })
    .onClick(() => {
      if (row.isDir) {
        this.vm.navigateTo(row);
        this.syncFromVm();
      }
    })
  }

  @Builder
  TransferPanel() {
    Column() {
      Text('传输队列')
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.textDim)
        .width('100%')
      if (this.transfers.length === 0) {
        Text('暂无任务')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
          .margin({ top: Tokens.space.xs })
      } else {
        ForEach(this.transfers, (job: TransferJob) => {
          this.TransferRow(job)
        }, (job: TransferJob) => `${job.id}|${job.state}|${job.transferredBytes}`)
      }
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ top: Tokens.space.sm })
  }

  @Builder
  TransferRow(job: TransferJob) {
    Column() {
      Row() {
        Text(job.direction === 'download' ? '↓' : '↑')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.accent)
        Text(job.remotePath)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(transferStateLabel(job.state))
          .fontSize(Tokens.fontSize.caption)
          .fontColor(job.state === 'failed'
            ? Tokens.Color.danger
            : job.state === 'completed' ? Tokens.Color.success : Tokens.Color.textDim)
      }
      .width('100%')
      Text(`${job.transferredBytes} / ${job.totalBytes}  ·  ${this.vm.progressOf(job.id)}%`)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .width('100%')
      if (job.errorMessage.length > 0) {
        Text(job.errorMessage)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
      }
    }
    .width('100%')
    .margin({ top: Tokens.space.xs })
  }

  /** 文件选择器 stub：真机接入 @ohos.file.picker 后替换 localPath */
  private onDownloadStub(row: SftpRow): void {
    const localPath: string = `/data/storage/el2/base/haps/entry/files/download/${row.name}`;
    const job: TransferJob = this.vm.enqueueDownload(row.name, localPath, row.size);
    Logger.info(`SFTP download stub job=${job.id} remote=${row.path}`, LOG_TAG);
    this.syncFromVm();
  }

  private onUploadStub(): void {
    const localPath: string = '/data/storage/el2/base/haps/entry/files/upload/sample.txt';
    const job: TransferJob = this.vm.enqueueUpload(localPath, 'upload-sample.txt', 0);
    Logger.info(`SFTP upload stub job=${job.id}`, LOG_TAG);
    this.syncFromVm();
  }
}
