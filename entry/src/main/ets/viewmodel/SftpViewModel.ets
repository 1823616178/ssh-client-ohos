/**
 * SftpViewModel —— U8 SFTP 页面状态（DESIGN §7.4）。
 *
 * 依赖注入（可 hypium 全 fake）：
 *   - SftpGateway：list/stat/download/upload/mkdir/unlink/rename；
 *     生产实现包装 native SshNativeSftp，无会话时返回「native 未就绪」；
 *   - session 句柄获取：openSftp() 仅在 SessionManager 会话 established 时可用。
 *
 * 文件选择器（@ohos.file.picker）在 Page 层调用，拿到 uri 后以 stub
 * 本地路径喂 download/upload——真机联调时替换为 picker 的真实路径。
 */

import { TransferJob, TransferQueue, transferProgressPercent } from './TransferQueue';
import {
  SftpNativeEntry,
  parseSftpEntriesJson,
  parseSftpEntryJson
} from '../napi/SshNative';

/** 页面展示的远端条目（由 native entry 归一化） */
export interface SftpRow {
  name: string;
  path: string;
  isDir: boolean;
  isSymlink: boolean;
  size: number;
  mtime: number;
  permissions: string;
  displaySize: string;
  displayMtime: string;
}

/** SFTP 网关窄接口：生产 = native，单测 = fake */
export interface SftpGateway {
  /** 打开 SFTP（会话句柄 → sftp 句柄；0 = 未受理） */
  open(sessionNativeHandle: number): number;
  close(sftpHandle: number): void;
  list(sftpHandle: number, path: string): boolean;
  stat(sftpHandle: number, path: string): boolean;
  download(sftpHandle: number, transferId: number, remotePath: string, localPath: string): boolean;
  upload(sftpHandle: number, transferId: number, localPath: string, remotePath: string): boolean;
  mkdir(sftpHandle: number, path: string, mode: number): boolean;
  unlink(sftpHandle: number, path: string): boolean;
  rename(sftpHandle: number, fromPath: string, toPath: string): boolean;
}

/** 无 native 时的 stub 网关：全部返回 false / 0，UI 显示「未连接」 */
export class NullSftpGateway implements SftpGateway {
  open(_sessionNativeHandle: number): number {
    return 0;
  }

  close(_sftpHandle: number): void {
  }

  list(_sftpHandle: number, _path: string): boolean {
    return false;
  }

  stat(_sftpHandle: number, _path: string): boolean {
    return false;
  }

  download(_sftpHandle: number, _transferId: number, _remotePath: string,
    _localPath: string): boolean {
    return false;
  }

  upload(_sftpHandle: number, _transferId: number, _localPath: string,
    _remotePath: string): boolean {
    return false;
  }

  mkdir(_sftpHandle: number, _path: string, _mode: number): boolean {
    return false;
  }

  unlink(_sftpHandle: number, _path: string): boolean {
    return false;
  }

  rename(_sftpHandle: number, _fromPath: string, _toPath: string): boolean {
    return false;
  }
}

/** 会话源：提供当前 sessionId 对应的 native 句柄（null = 无会话/退避中） */
export interface SftpSessionSource {
  nativeHandleOf(sessionId: string): number | null;
  isEstablished(sessionId: string): boolean;
}

export interface SftpViewModelDeps {
  gateway?: SftpGateway;
  sessionSource?: SftpSessionSource;
}

/** 字节数 → 人类可读（纯函数） */
export function formatByteSize(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value: number = bytes;
  let idx: number = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value = value / 1024;
    idx++;
  }
  if (idx === 0) {
    return `${Math.floor(value)} ${units[idx]}`;
  }
  return `${value.toFixed(1)} ${units[idx]}`;
}

/** Unix 秒 → 展示串（本地时区近似：YYYY-MM-DD HH:mm；0 → "—"） */
export function formatMtime(mtime: number): string {
  if (mtime <= 0) {
    return '—';
  }
  const d: Date = new Date(mtime * 1000);
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** native entry → UI 行 */
export function sftpEntryToRow(entry: SftpNativeEntry): SftpRow {
  return {
    name: entry.name,
    path: entry.path,
    isDir: entry.type === 'dir',
    isSymlink: entry.type === 'symlink',
    size: entry.size,
    mtime: entry.mtime,
    permissions: entry.permissions,
    displaySize: entry.type === 'dir' ? '—' : formatByteSize(entry.size),
    displayMtime: formatMtime(entry.mtime)
  };
}

/** 路径导航纯函数：从 dir + 选中项得到目标路径 */
export function sftpNavigatePath(currentDir: string, entry: SftpRow): string {
  return entry.path;
}

/** 上级目录："/a/b" → "/a"；"/" → "/" */
export function sftpParentDir(currentDir: string): string {
  if (currentDir === '/' || currentDir.length === 0) {
    return '/';
  }
  const trimmed: string = currentDir.endsWith('/')
    ? currentDir.substring(0, currentDir.length - 1)
    : currentDir;
  const idx: number = trimmed.lastIndexOf('/');
  if (idx <= 0) {
    return '/';
  }
  return trimmed.substring(0, idx);
}

/**
 * SFTP 页面 ViewModel。
 * 事件入口 handleNativeEvent 由 Page 在会话 onEvent 上转发（type 以 sftp 开头）。
 */
export class SftpViewModel {
  private readonly gateway: SftpGateway;
  private readonly sessionSource: SftpSessionSource | null;
  readonly queue: TransferQueue = new TransferQueue();

  sessionId: string = '';
  sftpHandle: number = 0;
  currentDir: string = '/';
  loading: boolean = false;
  error: string = '';
  /** native 未就绪 / 会话未建立时为 true（UI 空状态文案） */
  nativeUnavailable: boolean = false;
  rows: SftpRow[] = [];

  constructor(deps?: SftpViewModelDeps) {
    this.gateway = deps?.gateway ?? new NullSftpGateway();
    this.sessionSource = deps?.sessionSource ?? null;
  }

  /** 绑定会话并尝试打开 SFTP；false = 会话未就绪或 native 未受理 */
  attachSession(sessionId: string): boolean {
    this.sessionId = sessionId;
    if (this.sessionSource === null || !this.sessionSource.isEstablished(sessionId)) {
      this.nativeUnavailable = true;
      this.error = '请先建立 SSH 连接后再打开文件传输';
      return false;
    }
    const handle: number | null = this.sessionSource.nativeHandleOf(sessionId);
    if (handle === null || handle <= 0) {
      this.nativeUnavailable = true;
      this.error = '请先建立 SSH 连接后再打开文件传输';
      return false;
    }
    const sftp: number = this.gateway.open(handle);
    if (sftp <= 0) {
      this.nativeUnavailable = true;
      this.error = '文件通道未就绪，请稍后重试';
      return false;
    }
    this.sftpHandle = sftp;
    this.nativeUnavailable = false;
    this.error = '';
    this.refresh('/');
    return true;
  }

  detach(): void {
    if (this.sftpHandle > 0) {
      this.gateway.close(this.sftpHandle);
    }
    this.sftpHandle = 0;
  }

  refresh(path: string): boolean {
    if (this.sftpHandle <= 0) {
      this.nativeUnavailable = true;
      return false;
    }
    this.loading = true;
    this.error = '';
    const ok: boolean = this.gateway.list(this.sftpHandle, path);
    if (!ok) {
      this.loading = false;
      this.error = '目录加载失败，请重试';
    }
    return ok;
  }

  navigateTo(entry: SftpRow): boolean {
    if (!entry.isDir) {
      return false;
    }
    this.currentDir = entry.path;
    return this.refresh(this.currentDir);
  }

  navigateUp(): boolean {
    const parent: string = sftpParentDir(this.currentDir);
    if (parent === this.currentDir) {
      return false;
    }
    this.currentDir = parent;
    return this.refresh(this.currentDir);
  }

  /**
   * 下载：remoteName 在 currentDir 下；localPath 由文件选择器/调用方提供。
   * native 未就绪时入队但标记 failed（TransferQueue 可测路径）。
   */
  enqueueDownload(remoteName: string, localPath: string, totalBytes: number): TransferJob {
    const remotePath: string = remoteName.startsWith('/')
      ? remoteName
      : (this.currentDir === '/' ? `/${remoteName}` : `${this.currentDir}/${remoteName}`);
    const job: TransferJob = this.queue.enqueue('download', remotePath, localPath, totalBytes);
    this.kickQueue();
    return job;
  }

  enqueueUpload(localPath: string, remoteName: string, totalBytes: number): TransferJob {
    const remotePath: string = remoteName.startsWith('/')
      ? remoteName
      : (this.currentDir === '/' ? `/${remoteName}` : `${this.currentDir}/${remoteName}`);
    const job: TransferJob = this.queue.enqueue('upload', remotePath, localPath, totalBytes);
    this.kickQueue();
    return job;
  }

  mkdir(name: string): boolean {
    if (this.sftpHandle <= 0 || name.trim().length === 0) {
      return false;
    }
    const path: string = this.currentDir === '/'
      ? `/${name.trim()}`
      : `${this.currentDir}/${name.trim()}`;
    return this.gateway.mkdir(this.sftpHandle, path, 0o755);
  }

  unlink(path: string): boolean {
    if (this.sftpHandle <= 0) {
      return false;
    }
    return this.gateway.unlink(this.sftpHandle, path);
  }

  progressOf(id: number): number {
    const job: TransferJob | null = this.queue.get(id);
    if (job === null) {
      return 0;
    }
    return transferProgressPercent(job);
  }

  /** 队列推进：无 running 时启动下一个 queued */
  private kickQueue(): void {
    const next: TransferJob | null = this.queue.nextStartable();
    if (next === null) {
      return;
    }
    if (this.sftpHandle <= 0) {
      this.queue.markFailed(next.id, 'not_established', 'SFTP 未打开');
      this.nativeUnavailable = true;
      return;
    }
    if (!this.queue.markRunning(next.id)) {
      return;
    }
    let ok: boolean = false;
    if (next.direction === 'download') {
      ok = this.gateway.download(this.sftpHandle, next.id, next.remotePath, next.localPath);
    } else {
      ok = this.gateway.upload(this.sftpHandle, next.id, next.localPath, next.remotePath);
    }
    if (!ok) {
      this.queue.markFailed(next.id, 'io_error', '传输请求未受理');
    }
  }

  /**
   * 转发 native SFTP 事件（SshEvent 上 type 以 sftp 开头）。
   * Page 层从 SessionManager 事件监听调用本方法。
   */
  handleNativeEvent(type: string, fields: SftpNativeEventFields): void {
    if (type === 'sftpOpen') {
      if (fields.success === true && (fields.sftp ?? 0) > 0) {
        this.sftpHandle = fields.sftp ?? this.sftpHandle;
        this.nativeUnavailable = false;
        this.error = '';
        this.refresh(this.currentDir);
      } else {
        this.nativeUnavailable = true;
        this.error = '文件通道打开失败，请重试';
      }
      return;
    }
    if (type === 'sftpList') {
      this.loading = false;
      if (fields.success !== true) {
        this.error = '目录加载失败，请重试';
        return;
      }
      if (typeof fields.path === 'string' && fields.path.length > 0) {
        this.currentDir = fields.path;
      }
      const entries: SftpNativeEntry[] = parseSftpEntriesJson(fields.entriesJson);
      this.rows = [];
      for (const e of entries) {
        this.rows.push(sftpEntryToRow(e));
      }
      this.error = '';
      return;
    }
    if (type === 'sftpStat') {
      if (fields.success === true) {
        const entry: SftpNativeEntry | null = parseSftpEntryJson(fields.entryJson);
        if (entry !== null) {
          // 可供详情面板使用；MVP 仅吞掉
        }
      }
      return;
    }
    if (type === 'sftpOpDone') {
      if (fields.success === true && fields.op === 'mkdir') {
        this.refresh(this.currentDir);
      }
      return;
    }
    if (type === 'sftpProgress') {
      const id: number = fields.transferId ?? 0;
      const transferred: number = fields.transferred ?? 0;
      const total: number = fields.total ?? 0;
      this.queue.updateProgress(id, transferred, total);
      return;
    }
    if (type === 'sftpTransferDone') {
      const id: number = fields.transferId ?? 0;
      if (fields.success === true) {
        this.queue.markCompleted(id);
      } else {
        this.queue.markFailed(id, fields.error ?? 'io_error', fields.message ?? '');
      }
      this.kickQueue();
      return;
    }
  }
}

/** native sftp 事件字段子集（避免 VM 依赖完整 SshEvent 结构） */
export interface SftpNativeEventFields {
  success?: boolean;
  sftp?: number;
  path?: string;
  error?: string;
  message?: string;
  entriesJson?: string;
  entryJson?: string;
  op?: string;
  transferId?: number;
  transferred?: number;
  total?: number;
}

/** 生产网关：包装 nativeCore（延迟 import，避免单测拉起 .so） */
export class NativeSftpGateway implements SftpGateway {
  open(sessionNativeHandle: number): number {
    // 动态 require 路径由 Page/Service 注入更干净；此处直接用 SshNative 薄封装
    // 避免循环依赖：NativeSftpGateway 在 SftpNativeGateway.ets 实现
    return 0;
  }

  close(_sftpHandle: number): void {
  }

  list(_sftpHandle: number, _path: string): boolean {
    return false;
  }

  stat(_sftpHandle: number, _path: string): boolean {
    return false;
  }

  download(_sftpHandle: number, _transferId: number, _remotePath: string,
    _localPath: string): boolean {
    return false;
  }

  upload(_sftpHandle: number, _transferId: number, _localPath: string,
    _remotePath: string): boolean {
    return false;
  }

  mkdir(_sftpHandle: number, _path: string, _mode: number): boolean {
    return false;
  }

  unlink(_sftpHandle: number, _path: string): boolean {
    return false;
  }

  rename(_sftpHandle: number, _fromPath: string, _toPath: string): boolean {
    return false;
  }
}
