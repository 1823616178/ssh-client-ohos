/**
 * SFTP 传输队列 + ViewModel 单元测试（任务 U8，hypium）。
 * 纯逻辑全 fake，不触碰 native / 系统 API。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  TransferJob,
  TransferQueue,
  canCancelTransfer,
  canRetryTransfer,
  canStartTransfer,
  completeTransferState,
  retryTransferState,
  transferProgressPercent
} from '../main/ets/viewmodel/TransferQueue';
import {
  SftpGateway,
  SftpRow,
  SftpSessionSource,
  SftpViewModel,
  SftpViewModelDeps,
  formatByteSize,
  formatMtime,
  sftpEntryToRow,
  sftpParentDir
} from '../main/ets/viewmodel/SftpViewModel';
import { SftpNativeEntry } from '../main/ets/napi/SshNative';

class FakeGateway implements SftpGateway {
  openHandle: number = 0;
  lastListPath: string = '';
  lastDownload: string = '';
  lastUpload: string = '';
  listResult: boolean = true;
  downloadResult: boolean = true;
  uploadResult: boolean = true;
  mkdirCalls: string[] = [];

  open(_sessionNativeHandle: number): number {
    return this.openHandle;
  }

  close(_sftpHandle: number): void {
  }

  list(_sftpHandle: number, path: string): boolean {
    this.lastListPath = path;
    return this.listResult;
  }

  stat(_sftpHandle: number, _path: string): boolean {
    return true;
  }

  download(_sftpHandle: number, _transferId: number, remotePath: string,
    _localPath: string): boolean {
    this.lastDownload = remotePath;
    return this.downloadResult;
  }

  upload(_sftpHandle: number, _transferId: number, _localPath: string,
    remotePath: string): boolean {
    this.lastUpload = remotePath;
    return this.uploadResult;
  }

  mkdir(_sftpHandle: number, path: string, _mode: number): boolean {
    this.mkdirCalls.push(path);
    return true;
  }

  unlink(_sftpHandle: number, _path: string): boolean {
    return true;
  }

  rename(_sftpHandle: number, _fromPath: string, _toPath: string): boolean {
    return true;
  }
}

class FakeSessionSource implements SftpSessionSource {
  handles: Map<string, number> = new Map();
  established: Set<string> = new Set();

  nativeHandleOf(sessionId: string): number | null {
    return this.handles.get(sessionId) ?? null;
  }

  isEstablished(sessionId: string): boolean {
    return this.established.has(sessionId);
  }
}

interface SftpVmFixture {
  vm: SftpViewModel;
  gw: FakeGateway;
  src: FakeSessionSource;
}

function makeVm(): SftpVmFixture {
  const gw: FakeGateway = new FakeGateway();
  gw.openHandle = 42;
  const src: FakeSessionSource = new FakeSessionSource();
  src.handles.set('s1', 7);
  src.established.add('s1');
  const vm: SftpViewModel = new SftpViewModel({ gateway: gw, sessionSource: src } as SftpViewModelDeps);
  return { vm: vm, gw: gw, src: src };
}

export default function sftpTransferTest(): void {
  describe('TransferQueue', () => {
    it('enqueueAndList', 0, () => {
      const q: TransferQueue = new TransferQueue();
      const job: TransferJob = q.enqueue('download', '/a', '/local/a', 100);
      expect(q.list().length).assertEqual(1);
      expect(job.state).assertEqual('queued');
      expect(job.direction).assertEqual('download');
      expect(q.get(job.id)?.remotePath).assertEqual('/a');
    });

    it('stateMachinePredicates', 0, () => {
      expect(canStartTransfer('queued')).assertTrue();
      expect(canStartTransfer('running')).assertFalse();
      expect(canCancelTransfer('running')).assertTrue();
      expect(canCancelTransfer('completed')).assertFalse();
      expect(canRetryTransfer('failed')).assertTrue();
      expect(canRetryTransfer('completed')).assertFalse();
      expect(completeTransferState('running', true)).assertEqual('completed');
      expect(completeTransferState('running', false)).assertEqual('failed');
      expect(retryTransferState('failed')).assertEqual('queued');
    });

    it('singleRunningAndQueueDrain', 0, () => {
      const q: TransferQueue = new TransferQueue();
      const a: TransferJob = q.enqueue('download', '/a', '/l/a', 10);
      const b: TransferJob = q.enqueue('download', '/b', '/l/b', 20);
      expect(q.nextStartable()?.id).assertEqual(a.id);
      expect(q.markRunning(a.id)).assertTrue();
      expect(q.markRunning(b.id)).assertFalse();
      expect(q.nextStartable()).assertNull();
      q.markCompleted(a.id);
      expect(q.nextStartable()?.id).assertEqual(b.id);
    });

    it('progressClampAndComplete', 0, () => {
      const q: TransferQueue = new TransferQueue();
      const job: TransferJob = q.enqueue('upload', '/r', '/l', 50);
      q.markRunning(job.id);
      q.updateProgress(job.id, 25, 0);
      expect(job.transferredBytes).assertEqual(25);
      q.updateProgress(job.id, 999, 0);
      expect(job.transferredBytes).assertEqual(50);
      expect(transferProgressPercent(job)).assertEqual(100);
      q.markCompleted(job.id);
      expect(job.state).assertEqual('completed');
    });

    it('failRetryAndRemove', 0, () => {
      const q: TransferQueue = new TransferQueue();
      const job: TransferJob = q.enqueue('download', '/r', '/l', 5);
      q.markRunning(job.id);
      expect(q.markFailed(job.id, 'io_error', 'boom')).assertTrue();
      expect(job.errorMessage).assertEqual('boom');
      expect(q.retry(job.id)).assertTrue();
      expect(job.state).assertEqual('queued');
      expect(job.transferredBytes).assertEqual(0);
      q.markRunning(job.id);
      expect(q.remove(job.id)).assertFalse();
      q.markCompleted(job.id);
      expect(q.remove(job.id)).assertTrue();
      expect(q.list().length).assertEqual(0);
    });

    it('cancelActiveJob', 0, () => {
      const q: TransferQueue = new TransferQueue();
      const job: TransferJob = q.enqueue('download', '/r', '/l', 8);
      q.markRunning(job.id);
      expect(q.cancel(job.id)).assertTrue();
      expect(job.state).assertEqual('cancelled');
      expect(q.retry(job.id)).assertTrue();
    });
  });

  describe('SftpHelpers', () => {
    it('formatByteSize', 0, () => {
      expect(formatByteSize(0)).assertEqual('0 B');
      expect(formatByteSize(512)).assertEqual('512 B');
      expect(formatByteSize(2048)).assertEqual('2.0 KB');
    });

    it('formatMtimeZero', 0, () => {
      expect(formatMtime(0)).assertEqual('—');
    });

    it('parentDir', 0, () => {
      expect(sftpParentDir('/a/b')).assertEqual('/a');
      expect(sftpParentDir('/a')).assertEqual('/');
      expect(sftpParentDir('/')).assertEqual('/');
      expect(sftpParentDir('/a/b/')).assertEqual('/a');
    });

    it('entryToRowDir', 0, () => {
      const e: SftpNativeEntry = {
        name: 'docs',
        path: '/home/docs',
        type: 'dir',
        size: 0,
        mtime: 0,
        mode: 0o40755,
        permissions: 'rwxr-xr-x',
        linkTarget: ''
      };
      const row: SftpRow = sftpEntryToRow(e);
      expect(row.isDir).assertTrue();
      expect(row.displaySize).assertEqual('—');
    });
  });

  describe('SftpViewModel', () => {
    it('attachRequiresEstablished', 0, () => {
      const fixture0 = makeVm();
      const vm = fixture0.vm;
      expect(vm.attachSession('nope')).assertFalse();
      expect(vm.nativeUnavailable).assertTrue();
    });

    it('attachOpensAndLists', 0, () => {
      const fixture1 = makeVm();
      const vm = fixture1.vm;
      const gw = fixture1.gw;
      expect(vm.attachSession('s1')).assertTrue();
      expect(vm.sftpHandle).assertEqual(42);
      expect(gw.lastListPath).assertEqual('/');
    });

    it('handleListEventFillsRows', 0, () => {
      const fixture2 = makeVm();
      const vm = fixture2.vm;
      vm.attachSession('s1');
      const entries: string = JSON.stringify([
        { name: 'a.txt', path: '/a.txt', type: 'file', size: 3, mtime: 0, mode: 0o100644, permissions: 'rw-r--r--', linkTarget: '' },
        { name: 'dir', path: '/dir', type: 'dir', size: 0, mtime: 0, mode: 0o40755, permissions: 'rwxr-xr-x', linkTarget: '' }
      ]);
      vm.handleNativeEvent('sftpList', { success: true, path: '/', entriesJson: entries });
      expect(vm.rows.length).assertEqual(2);
      expect(vm.rows[0].name).assertEqual('a.txt');
      expect(vm.rows[1].isDir).assertTrue();
    });

    it('enqueueDownloadCallsGateway', 0, () => {
      const fixture3 = makeVm();
      const vm = fixture3.vm;
      const gw = fixture3.gw;
      vm.attachSession('s1');
      const job: TransferJob = vm.enqueueDownload('a.txt', '/tmp/a.txt', 3);
      expect(job.state).assertEqual('running');
      expect(gw.lastDownload).assertEqual('/a.txt');
    });

    it('nativeMissingMarksFailed', 0, () => {
      const gw: FakeGateway = new FakeGateway();
      gw.openHandle = 0;
      const src: FakeSessionSource = new FakeSessionSource();
      src.handles.set('s1', 1);
      src.established.add('s1');
      const vm: SftpViewModel = new SftpViewModel({ gateway: gw, sessionSource: src } as SftpViewModelDeps);
      vm.attachSession('s1');
      const job: TransferJob = vm.enqueueDownload('x', '/tmp/x', 1);
      expect(job.state).assertEqual('failed');
      expect(vm.nativeUnavailable).assertTrue();
    });

    it('transferEventsDriveQueue', 0, () => {
      const fixture4 = makeVm();
      const vm = fixture4.vm;
      vm.attachSession('s1');
      const job: TransferJob = vm.enqueueDownload('a.txt', '/tmp/a.txt', 100);
      vm.handleNativeEvent('sftpProgress', {
        transferId: job.id,
        transferred: 40,
        total: 100
      });
      expect(job.transferredBytes).assertEqual(40);
      vm.handleNativeEvent('sftpTransferDone', {
        transferId: job.id,
        success: true,
        transferred: 100,
        total: 100
      });
      expect(job.state).assertEqual('completed');
      expect(vm.progressOf(job.id)).assertEqual(100);
    });

    it('navigateUp', 0, () => {
      const fixture5 = makeVm();
      const vm = fixture5.vm;
      const gw = fixture5.gw;
      vm.attachSession('s1');
      vm.handleNativeEvent('sftpList', {
        success: true,
        path: '/home/user',
        entriesJson: '[]'
      });
      expect(vm.currentDir).assertEqual('/home/user');
      vm.navigateUp();
      expect(vm.currentDir).assertEqual('/home');
      expect(gw.lastListPath).assertEqual('/home');
    });
  });
}
