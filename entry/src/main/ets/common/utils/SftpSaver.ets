/**
 * SFTP 下载落盘协调器 —— 系统保存对话框选位置，沙箱中转，完成后拷贝到用户目标。
 *
 * 背景：native 传输层只认应用沙箱内的 POSIX 路径；用户经 DocumentViewPicker
 * 选中的是 file:// URI（跨进程授权，native 无法直接写）。因此下载分两段：
 *   1. native 先下到沙箱中转文件（沿用 TransferQueue 的进度/状态）；
 *   2. sftpTransferDone 成功后由本类用 fileIo 把中转文件拷贝到用户选的 URI，
 *      随后删除中转文件。失败/取消时清理中转，不留垃圾。
 */
import { picker, fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';

const LOG_TAG: string = 'SftpSaver';

/** 沙箱中转目录（应用专属，无需权限） */
const SANDBOX_DIR: string = '/data/storage/el2/base/haps/entry/files/download';

interface PendingSave {
  name: string;
  tempPath: string;
  destUri: string;
}

/** onFinish 结果：saved = 已拷贝到用户位置；failed = 下载失败已清理；'' = 非本类跟踪的任务 */
export type SftpSaveResult = 'saved' | 'failed' | '';

export class SftpSaver {
  private readonly pending: Map<number, PendingSave> = new Map();

  /**
   * 弹系统「保存」对话框让用户选位置与文件名。
   * 返回目标 URI；用户取消返回 null（不产生下载任务）。
   */
  async pickDest(name: string): Promise<string | null> {
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const uris: string[] = await docPicker.save(options);
      return uris.length > 0 ? uris[0] : null;
    } catch (err) {
      Logger.error(`保存对话框打开失败: ${JSON.stringify(err)}`, LOG_TAG);
      return null;
    }
  }

  /** 生成沙箱中转路径（先拿路径发起任务，job id 出来后再 track 登记） */
  tempPathFor(name: string): string {
    this.ensureSandboxDir();
    return `${SANDBOX_DIR}/.tmp-${Date.now()}-${name}`;
  }

  /** 登记下载任务：完成后拷贝到 destUri */
  track(jobId: number, name: string, tempPath: string, destUri: string): void {
    this.pending.set(jobId, { name: name, tempPath: tempPath, destUri: destUri });
  }

  /**
   * sftpTransferDone 时调用：成功 → 拷贝到用户位置并清理；失败 → 仅清理。
   * 返回结果供调用方 toast。
   */
  onFinish(jobId: number, success: boolean): SftpSaveResult {
    const save: PendingSave | undefined = this.pending.get(jobId);
    if (save === undefined) {
      return '';
    }
    this.pending.delete(jobId);
    if (!success) {
      this.removeTemp(save.tempPath);
      return 'failed';
    }
    try {
      const src: fileIo.File = fileIo.openSync(save.tempPath, fileIo.OpenMode.READ_ONLY);
      const dst: fileIo.File = fileIo.openSync(save.destUri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(src.fd, dst.fd);
      fileIo.closeSync(src);
      fileIo.closeSync(dst);
      this.removeTemp(save.tempPath);
      return 'saved';
    } catch (err) {
      Logger.error(`下载文件落盘失败（${save.name}）: ${JSON.stringify(err)}`, LOG_TAG);
      this.removeTemp(save.tempPath);
      return 'failed';
    }
  }

  private ensureSandboxDir(): void {
    try {
      if (!fileIo.accessSync(SANDBOX_DIR)) {
        fileIo.mkdirSync(SANDBOX_DIR, true);
      }
    } catch (_err) {
      // 已存在 / 竞态创建均可忽略，写入失败会在 onFinish 兜底报错
    }
  }

  private removeTemp(tempPath: string): void {
    try {
      fileIo.accessSync(tempPath);
      fileIo.unlinkSync(tempPath);
    } catch (_err) {
      // 中转文件不存在（下载未受理即失败）无需清理
    }
  }
}
