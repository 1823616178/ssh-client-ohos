/**
 * N14 生产 SFTP 网关 —— 包装 libssh_core 的 sftp* NAPI。
 * 会话句柄来自 SessionManager.getNativeHandle(sessionId)。
 */
import {
  SshNativeSftp,
  nativeCore
} from './SshNative';
import { SftpGateway } from '../viewmodel/SftpViewModel';

export class SftpNativeGateway implements SftpGateway {
  /** sftpHandle → 薄封装（由 open 装配） */
  private opened: Map<number, SshNativeSftp> = new Map();

  open(sessionNativeHandle: number): number {
    if (sessionNativeHandle <= 0) {
      return 0;
    }
    const core = nativeCore();
    const handle: number = core.sftpOpen(sessionNativeHandle);
    if (handle <= 0) {
      return 0;
    }
    const sftp: SshNativeSftp | null = SshNativeSftp.fromHandle(handle);
    if (sftp === null) {
      core.sftpClose(handle);
      return 0;
    }
    this.opened.set(handle, sftp);
    return handle;
  }

  close(sftpHandle: number): void {
    const sftp: SshNativeSftp | undefined = this.opened.get(sftpHandle);
    if (sftp !== undefined) {
      sftp.close();
      this.opened.delete(sftpHandle);
      return;
    }
    nativeCore().sftpClose(sftpHandle);
  }

  private get(sftpHandle: number): SshNativeSftp | null {
    return this.opened.get(sftpHandle) ?? null;
  }

  list(sftpHandle: number, path: string): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.list(path);
  }

  stat(sftpHandle: number, path: string): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.stat(path);
  }

  download(sftpHandle: number, transferId: number, remotePath: string,
    localPath: string): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.download(transferId, remotePath, localPath);
  }

  upload(sftpHandle: number, transferId: number, localPath: string,
    remotePath: string): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.upload(transferId, localPath, remotePath);
  }

  mkdir(sftpHandle: number, path: string, mode: number): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.mkdir(path, mode);
  }

  unlink(sftpHandle: number, path: string): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.unlink(path);
  }

  rename(sftpHandle: number, fromPath: string, toPath: string): boolean {
    const sftp: SshNativeSftp | null = this.get(sftpHandle);
    return sftp !== null && sftp.rename(fromPath, toPath);
  }
}
