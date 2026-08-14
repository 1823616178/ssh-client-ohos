/**
 * SshTerminal —— T3「零拷贝快照 NAPI」的 ArkTS 侧封装。
 *
 * 职责：
 *   - attach/detach 与帧读取的薄封装（native 语义与线程模型见
 *     cpp/bridge/terminal_bridge.h、cpp/term/frame_sync.h 头注）；
 *   - R-9 双路径：启动探测 external ArrayBuffer 是否真可用（selfTestGrid
 *     已知模式读回比对），不可用则永久切 copyGridRows 兜底（进程级定型）；
 *   - DataView 读网格的解码辅助（纯函数，hypium 覆盖）。
 *
 * 帧用法（T4 渲染循环的对接面）：
 *   const rev = terminal.getRevision();
 *   if (rev !== lastRendered) {                    // 无变化跳过整帧
 *     const frame = terminal.beginFrame();
 *     ... 按 frame.dirty 的脏行渲染（grid DataView 直读或兜底拷贝）...
 *     terminal.endFrame(frame.revision);           // 回执：native 清脏位图
 *     lastRendered = rev;
 *   }
 * 一致性：网格读取与远端输出并发，单格可能撕裂——endFrame 时 native 发现
 * revision 变了会保留脏位，下帧重绘自愈；撕裂内容最多在屏一帧。
 *
 * 生命周期保护：frame.grid 的旧 buffer 在 native resize/detach/会话关闭后
 * 仍可安全读取（native 侧 shared_ptr + external buffer finalize 保活，
 * 读到的是冻结的旧内容）；新尺寸以新帧的 cols/rows 为准。
 *
 * 事件：终端事件（terminalOpen/terminalClose/terminalBell/terminalTitle/
 * terminalMouseMode）随所属会话的 onEvent 上抛，本类不另开事件通道——
 * 上层（T4/U4）从会话事件流按 terminal 句柄分发。
 */
import { NativeTerminalFrame, SshNativeSession, nativeCore } from './SshNative';

// ---------------------------------------------------------------- 单元格布局常量
//（与 cpp/term/grid.h 一致，改一侧必须同步另一侧；16B/格小端）

export const CELL_BYTES = 16;
/** 宽字符续格码点标记 */
export const WIDE_CONTINUATION = 0xFFFFFFFF;

export const ATTR_BOLD = 1 << 0;
export const ATTR_ITALIC = 1 << 1;
export const ATTR_UNDERLINE = 1 << 2;
export const ATTR_BLINK = 1 << 3;
export const ATTR_REVERSE = 1 << 4;
export const ATTR_STRIKE = 1 << 5;
export const ATTR_DIM = 1 << 6;
/** 宽字符首格（续格码点为 WIDE_CONTINUATION） */
export const ATTR_WIDE = 1 << 7;

/** 解码后的单元格（DataView 直读结果） */
export interface DecodedCell {
  /** Unicode 码点；0 = 空；WIDE_CONTINUATION = 宽字符续格 */
  codepoint: number;
  /** 前景色 ARGB（已解析调色板/真彩） */
  fgArgb: number;
  /** 背景色 ARGB */
  bgArgb: number;
  /** 属性位（ATTR_* 系列） */
  attrs: number;
}

/** 连续脏行区间 [start, end)（collectDirtyRanges 输出） */
export interface DirtyRange {
  start: number;
  end: number;
}

// ---------------------------------------------------------------- 纯函数解码辅助（hypium 覆盖）

/** 从网格视图读第 cellIndex 格（cellIndex = row * cols + col；越界是调用方 bug） */
export function decodeCellAt(view: DataView, cellIndex: number): DecodedCell {
  const off = cellIndex * CELL_BYTES;
  return {
    codepoint: view.getUint32(off, true),
    fgArgb: view.getUint32(off + 4, true),
    bgArgb: view.getUint32(off + 8, true),
    attrs: view.getUint16(off + 12, true)
  };
}

/** 脏行位图查询：行 row 的脏位（u64 字数组的小端字节流；按 u32 视图读：字 [row>>5] 的位 row&31） */
export function isRowDirty(dirty: ArrayBuffer, row: number): boolean {
  const view = new DataView(dirty);
  const wordIndex = row >> 5; // u32 字下标
  if (wordIndex * 4 + 4 > dirty.byteLength) {
    return false; // 越界防御：位图比预期短视为干净（尺寸以 beginFrame 的 rows 为准）
  }
  return (view.getUint32(wordIndex * 4, true) & (1 << (row & 31))) !== 0;
}

/** 把脏行位图合并成连续区间序列 [start, end)（渲染按区间批量重绘） */
export function collectDirtyRanges(dirty: ArrayBuffer, rows: number): DirtyRange[] {
  const ranges: DirtyRange[] = [];
  let start = -1;
  for (let r = 0; r < rows; ++r) {
    const d = isRowDirty(dirty, r);
    if (d && start < 0) {
      start = r;
    } else if (!d && start >= 0) {
      ranges.push({ start, end: r });
      start = -1;
    }
  }
  if (start >= 0) {
    ranges.push({ start, end: rows });
  }
  return ranges;
}

/**
 * R-9 自检模式（32 字节，与 native terminal_bridge.cpp MakeSelfTestPattern
 * 逐字节一致，改一侧必须同步另一侧）：
 *   0-7 "SSHTGRID"；8-11 u32 LE 0x01020304；12-15 u32 LE 0xA5A55A5A；16-31 递增 0..15
 */
export function buildSelfTestPattern(): Uint8Array {
  const p = new Uint8Array(32);
  const magic = 'SSHTGRID';
  for (let i = 0; i < 8; ++i) {
    p[i] = magic.charCodeAt(i);
  }
  p[8] = 0x04;
  p[9] = 0x03;
  p[10] = 0x02;
  p[11] = 0x01;
  p[12] = 0x5A;
  p[13] = 0x5A;
  p[14] = 0xA5;
  p[15] = 0xA5;
  for (let i = 16; i < 32; ++i) {
    p[i] = i - 16;
  }
  return p;
}

/** 探测比对：selfTestGrid 读回的 buffer 与已知模式逐字节一致才算主路径可用 */
export function matchesSelfTestPattern(ab: ArrayBuffer): boolean {
  if (ab.byteLength !== 32) {
    return false;
  }
  const got = new Uint8Array(ab);
  const want = buildSelfTestPattern();
  for (let i = 0; i < 32; ++i) {
    if (got[i] !== want[i]) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------- SshTerminal

/** R-9 探测结果（进程级定型：第一次 attach 探测，全部终端复用结论） */
enum ZeroCopyProbe {
  UNPROBED = 0,
  OK = 1,
  BROKEN = 2
}

export class SshTerminal {
  private static probe: ZeroCopyProbe = ZeroCopyProbe.UNPROBED;

  private handle: number;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /**
   * 在会话上创建终端（native 侧绑定新 shell 通道，PTY 尺寸 cols×rows）。
   * 返回 null = 未受理（会话未 established 等）；打开结果经会话事件流
   * 的 terminalOpen 事件回报。首次 attach 顺带完成 R-9 探测
   */
  static attach(session: SshNativeSession, termType: string, cols: number,
    rows: number): SshTerminal | null {
    const h = nativeCore().attachTerminal(session.nativeHandle, termType, cols, rows);
    if (h <= 0) {
      return null;
    }
    if (SshTerminal.probe === ZeroCopyProbe.UNPROBED) {
      const ab = nativeCore().selfTestGrid(h);
      // external 创建失败（null）或读回字节不一致：永久切兜底
      SshTerminal.probe =
        (ab !== null && matchesSelfTestPattern(ab)) ? ZeroCopyProbe.OK : ZeroCopyProbe.BROKEN;
    }
    return new SshTerminal(h);
  }

  /** 本进程主路径是否可用（false = 永久走 copyGridRows 兜底） */
  static get zeroCopyAvailable(): boolean {
    return SshTerminal.probe === ZeroCopyProbe.OK;
  }

  /** 当前已发布 revision（-1 = 句柄无效）；帧循环先比对本地值再决定 beginFrame */
  getRevision(): number {
    return this.alive ? nativeCore().getRevision(this.handle) : -1;
  }

  /**
   * 取当前帧快照（null = 句柄无效）。返回的 frame.grid 仅在
   * zeroCopyAvailable 且 frame.gridZeroCopy 时才是可信的零拷贝视图；
   * 其余情况（探测失败/native 自动回落拷贝）请用 readRows 读取——
   * 它会按当前路径自动选择直读或 copyGridRows
   */
  beginFrame(): NativeTerminalFrame | null {
    return this.alive ? nativeCore().beginFrame(this.handle) : null;
  }

  /**
   * 读取 [startRow, startRow+count) 行区间的 DataView（渲染层统一入口）：
   *   - 主路径：直接给 frame.grid 的 DataView（零拷贝，含最新并发内容）；
   *   - 兜底路径：copyGridRows 拷贝（普通 ArrayBuffer）。
   * 返回 null = 该区间在当前帧不可得（句柄失效/越界）
   */
  readRows(frame: NativeTerminalFrame, startRow: number, count: number): DataView | null {
    if (count <= 0 || startRow < 0 || startRow + count > frame.rows) {
      return null;
    }
    if (SshTerminal.zeroCopyAvailable && frame.gridZeroCopy && frame.grid !== undefined) {
      return new DataView(frame.grid, startRow * frame.cols * CELL_BYTES,
        count * frame.cols * CELL_BYTES);
    }
    const ab = nativeCore().copyGridRows(this.handle, startRow, count);
    return ab === null ? null : new DataView(ab);
  }

  /** 帧消费回执（受理语义）：native 侧比对 revision，一致则清脏位图 */
  endFrame(seenRevision: number): boolean {
    return this.alive && nativeCore().endFrame(this.handle, seenRevision);
  }

  /**
   * 回滚窗口拷贝：absoluteIndex ∈ [frame.scrollbackOldest, frame.scrollbackTotal)，
   * 返回 count × cols × 16B（越界行填零值 Cell；列数同最新帧快照）
   */
  readScrollbackWindow(startIndex: number, count: number): ArrayBuffer | null {
    return this.alive ? nativeCore().getScrollbackWindow(this.handle, startIndex, count) : null;
  }

  /** 写终端输入（按键序列等）；false = 已关闭/背压拒收（整次拒收，稍后重试） */
  write(data: ArrayBuffer | string): boolean {
    return this.alive && nativeCore().writeTerminal(this.handle, data);
  }

  /** 调整终端尺寸（受理语义）：驱动 vterm resize + 远端 request_pty_size */
  resize(cols: number, rows: number): boolean {
    return this.alive && nativeCore().resizeTerminal(this.handle, cols, rows);
  }

  /** 关闭终端（幂等）：native 后台完成通道关闭与资源回收，旧帧 buffer 仍可读 */
  detach(): void {
    if (!this.alive) {
      return;
    }
    nativeCore().detachTerminal(this.handle);
    this.handle = 0;
  }

  private get alive(): boolean {
    return this.handle > 0;
  }
}
