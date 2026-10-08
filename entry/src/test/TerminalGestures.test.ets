/**
 * TerminalGestures / Pasteboard 纯逻辑测试（hypium，任务 T9 + T8 粘贴侧 + T11）。
 *
 * 覆盖：
 *  - clampScrollOffset：偏移钳制 [0, 回滚行数]（负值/超界/无回滚）；
 *  - ScrollLineAccumulator：不足一行累计、整行产出、反向（上滑）带符号行数、
 *    reset、格高 0 防御；
 *  - buildAltScrollSequences：keys/mouse/view 三模式映射、每行一条、
 *    方向语义（手指下滑=看旧内容=↑/滚轮上64）、mouseMode=None 回退方向键、
 *    SGR 序列坐标（1 起）、DECCKM 应用光标键 SS3 方向键（T10）；
 *  - clampFontSize：8–32 钳制与非法值；
 *  - wrapBracketedPaste / containsLineBreak（T8 bracketed paste）；
 *  - clickSelectionMode / ClickSelectTracker：双击/三击连点窗口与位置容差；
 *  - classifyClickCodepoint / wordSelectAt / lineSelectAt：CJK/emoji 宽字符
 *    选词边界、三击整行；
 *  - encodeSgrMouseEvent / encodeSgrWheel / sgrButtonFromOhosButton /
 *    shouldForwardMouseEvent：SGR 1006 press/move/release/滚轮编码（T11）；
 *  - selectionHandleHitRects / selectionHandleAtPoint / selectionHandleAnchor /
 *    selectionHandleHitRadius：T8 选区拖拽手柄 hit 区纯几何。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  CLICK_WIDE_CONTINUATION,
  ClickSelectCell,
  ClickSelectGrid,
  ClickSelectTracker,
  ClickSelectionRange,
  SELECTION_HANDLE_HIT_WIDTH_VP,
  SELECTION_HANDLE_KNOB_VP,
  SelectionHandleGeometry,
  SGR_BUTTON_LEFT,
  SGR_BUTTON_MIDDLE,
  SGR_BUTTON_NONE,
  SGR_BUTTON_RIGHT,
  SGR_MOD_CTRL,
  MOUSE_MODE_ANY,
  MOUSE_MODE_CLICK,
  MOUSE_MODE_DRAG,
  MOUSE_MODE_NONE,
  ScrollLineAccumulator,
  buildAltScrollSequences,
  classifyClickCodepoint,
  clickSelectionMode,
  clampFontSize,
  clampScrollOffset,
  encodeSgrMouseEvent,
  encodeSgrWheel,
  lineSelectAt,
  selectionHandleAnchor,
  selectionHandleAtPoint,
  selectionHandleHitRadius,
  selectionHandleHitRects,
  sgrButtonFromOhosButton,
  shouldForwardMouseEvent,
  wordSelectAt,
  WheelLineAccumulator,
  WHEEL_MAX_LINES_PER_EVENT,
  wheelSgrSequences
} from '../main/ets/view/terminal/TerminalGestures';
import {
  containsLineBreak,
  wrapBracketedPaste
} from '../main/ets/view/terminal/Pasteboard';

/** 字节序列 → 可读字符串（测试断言用；序列为纯 ASCII） */
function bytesToString(bytes: Uint8Array | null): string {
  if (bytes === null) {
    return 'null';
  }
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  return s;
}

/** 按字符串构造一行网格（ASCII 每字 1 格；wideRun 指定「起始列 → 码点序列」） */
class LineGrid implements ClickSelectGrid {
  readonly rows: number;
  readonly cols: number;
  private readonly cells: ClickSelectCell[][];

  constructor(rows: number, cols: number, fill: ClickSelectCell) {
    this.rows = rows;
    this.cols = cols;
    this.cells = [];
    for (let r = 0; r < rows; r++) {
      const line: ClickSelectCell[] = [];
      for (let c = 0; c < cols; c++) {
        line.push(fill);
      }
      this.cells.push(line);
    }
  }

  set(row: number, col: number, codepoint: number, wide: boolean = false): void {
    this.cells[row][col] = { codepoint: codepoint, wide: wide };
  }

  cellAt(row: number, col: number): ClickSelectCell | null {
    if (row < 0 || row >= this.rows || col < 0 || col >= this.cols) {
      return null;
    }
    return this.cells[row][col];
  }
}

function spaceCell(): ClickSelectCell {
  return { codepoint: 0x20, wide: false };
}

function cp(ch: string): number {
  return ch.codePointAt(0) ?? 0;
}

/** 断言选区非空并取出（null 时用哨兵坐标触发 assert 失败） */
function requireRange(r: ClickSelectionRange | null): ClickSelectionRange {
  if (r === null) {
    return { startRow: -9, startCol: -9, endRow: -9, endCol: -9 };
  }
  return r;
}

/** 便捷：用 ASCII 串填充一行（遇宽字符占 2 格：首格 wide + 续格） */
function fillAsciiLine(grid: LineGrid, row: number, text: string, startCol: number = 0): void {
  let col = startCol;
  for (const ch of text) {
    const code = cp(ch);
    const wide = code > 0x7F && classifyClickCodepoint(code, false) === 'wide';
    grid.set(row, col, code, wide);
    col++;
    if (wide) {
      grid.set(row, col, CLICK_WIDE_CONTINUATION, false);
      col++;
    }
  }
}

function bytesToAscii(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

export default function terminalGesturesTest() {
  describe('TerminalGesturesTest', () => {

    it('scrollOffset钳制', 0, () => {
      expect(clampScrollOffset(5, 10)).assertEqual(5);
      expect(clampScrollOffset(-1, 10)).assertEqual(0);
      expect(clampScrollOffset(15, 10)).assertEqual(10);
      expect(clampScrollOffset(3, -2)).assertEqual(0); // 无回滚（负上限按 0）
      expect(clampScrollOffset(0, 0)).assertEqual(0);
    });

    it('滚动行换算不足一行累计跨事件', 0, () => {
      const acc = new ScrollLineAccumulator();
      // 格高 10vp：4+4 不足一行不出行，再 +4 累计 12 → 1 行，余 2
      expect(acc.push(4, 10)).assertEqual(0);
      expect(acc.push(4, 10)).assertEqual(0);
      expect(acc.push(4, 10)).assertEqual(1);
      // 余量 2 再 +9 = 11 → 1 行
      expect(acc.push(9, 10)).assertEqual(1);
    });

    it('滚动行换算反向带符号', 0, () => {
      const acc = new ScrollLineAccumulator();
      // 手指上滑 25vp（格高 10）→ -2 行（向 0 取整），余 -5
      expect(acc.push(-25, 10)).assertEqual(-2);
      expect(acc.push(-6, 10)).assertEqual(-1); // -5 + -6 = -11 → -1 行
    });

    it('滚动行换算reset与零格高防御', 0, () => {
      const acc = new ScrollLineAccumulator();
      expect(acc.push(12, 10)).assertEqual(1); // 余 2
      acc.reset();
      expect(acc.push(3, 10)).assertEqual(0); // 余量已清
      expect(acc.push(100, 0)).assertEqual(0); // 格高 0（度量未完成）：不滚动
    });

    it('altScroll keys模式映射方向键', 0, () => {
      // 手指下滑 2 行 = 看旧内容 = 两次 ↑
      const down = buildAltScrollSequences('keys', 0, 2, 5, 3);
      expect(down.length).assertEqual(2);
      expect(bytesToString(down[0])).assertEqual('\x1b[A');
      // 手指上滑 3 行 = 看新内容 = 三次 ↓
      const up = buildAltScrollSequences('keys', 0, -3, 5, 3);
      expect(up.length).assertEqual(3);
      expect(bytesToString(up[0])).assertEqual('\x1b[B');
    });

    it('altScroll keys模式DECCKM切SS3方向键_T10', 0, () => {
      const down = buildAltScrollSequences('keys', 0, 1, 5, 3, true);
      expect(bytesToString(down[0])).assertEqual('\x1bOA');
      const up = buildAltScrollSequences('keys', 0, 1, 5, 3, true);
      // lines>0 = 手指下移 = 上滚 = OA（应用光标模式 SS3 A）
      expect(bytesToString(up[0])).assertEqual('\x1bOA');
      const scrollDownContent = buildAltScrollSequences('keys', 0, -1, 5, 3, true);
      expect(bytesToString(scrollDownContent[0])).assertEqual('\x1bOB');
      // mouse 模式不受 DECCKM 影响
      const wheel = buildAltScrollSequences('mouse', 2, 1, 5, 3, true);
      expect(bytesToString(wheel[0])).assertEqual('\x1b[<64;5;3M');
    });

    it('altScroll mouse模式发SGR滚轮序列', 0, () => {
      // mouseMode=2（拖动上报）：下滑 1 行 = 滚轮上 64，坐标 1 起
      const seqs = buildAltScrollSequences('mouse', 2, 1, 5, 3);
      expect(seqs.length).assertEqual(1);
      expect(bytesToString(seqs[0])).assertEqual('\x1b[<64;5;3M');
      const upSeqs = buildAltScrollSequences('mouse', 2, -1, 5, 3);
      expect(bytesToString(upSeqs[0])).assertEqual('\x1b[<65;5;3M');
    });

    it('altScroll mouse模式未开上报回退方向键', 0, () => {
      const seqs = buildAltScrollSequences('mouse', 0, 1, 5, 3);
      expect(seqs.length).assertEqual(1);
      expect(bytesToString(seqs[0])).assertEqual('\x1b[A');
    });

    it('altScroll view模式不发字节', 0, () => {
      expect(buildAltScrollSequences('view', 0, 3, 5, 3).length).assertEqual(0);
      expect(buildAltScrollSequences('keys', 0, 0, 5, 3).length).assertEqual(0);
    });

    it('捏合字号钳制8到32', 0, () => {
      expect(clampFontSize(7.9)).assertEqual(8);
      expect(clampFontSize(8)).assertEqual(8);
      expect(clampFontSize(20)).assertEqual(20);
      expect(clampFontSize(33)).assertEqual(32);
      expect(clampFontSize(Number.NaN)).assertEqual(8);
    });

    it('bracketedPaste包裹与原样', 0, () => {
      expect(wrapBracketedPaste('abc', true)).assertEqual('\x1b[200~abc\x1b[201~');
      expect(wrapBracketedPaste('abc', false)).assertEqual('abc');
      expect(wrapBracketedPaste('a\nb', true)).assertEqual('\x1b[200~a\nb\x1b[201~');
    });

    it('多行检测', 0, () => {
      expect(containsLineBreak('a\nb')).assertTrue();
      expect(containsLineBreak('a\rb')).assertTrue();
      expect(containsLineBreak('abc')).assertFalse();
      expect(containsLineBreak('')).assertFalse();
    });

    // ---------------------------------------------------------------- T11 连点

    it('clickCount映射选区模式', 0, () => {
      expect(clickSelectionMode(1)).assertEqual('none');
      expect(clickSelectionMode(2)).assertEqual('word');
      expect(clickSelectionMode(3)).assertEqual('line');
      expect(clickSelectionMode(4)).assertEqual('line');
    });

    it('连点跟踪_窗口内邻近递增_超窗或超距重计', 0, () => {
      const t = new ClickSelectTracker();
      expect(t.tap(2, 5, 1000)).assertEqual('none');
      expect(t.tap(2, 5, 1200)).assertEqual('word'); // 200ms 内同格
      expect(t.tap(2, 6, 1350)).assertEqual('line'); // 邻近（slop=2）继续
      expect(t.tap(2, 5, 3000)).assertEqual('none'); // 超窗重计
      expect(t.tap(2, 5, 3100)).assertEqual('word');
      expect(t.tap(20, 20, 3200)).assertEqual('none'); // 超距重计
      t.reset();
      expect(t.tap(2, 5, 3300)).assertEqual('none');
    });

    it('classify_空白词字符宽字符与标点', 0, () => {
      expect(classifyClickCodepoint(0, false)).assertEqual('space');
      expect(classifyClickCodepoint(0x20, false)).assertEqual('space');
      expect(classifyClickCodepoint(cp('a'), false)).assertEqual('word');
      expect(classifyClickCodepoint(cp('Z'), false)).assertEqual('word');
      expect(classifyClickCodepoint(cp('9'), false)).assertEqual('word');
      expect(classifyClickCodepoint(cp('_'), false)).assertEqual('word');
      expect(classifyClickCodepoint(cp('中'), false)).assertEqual('wide'); // CJK 码点兜底
      expect(classifyClickCodepoint(cp('中'), true)).assertEqual('wide');
      expect(classifyClickCodepoint(CLICK_WIDE_CONTINUATION, false)).assertEqual('wide');
      expect(classifyClickCodepoint(cp(','), false)).assertEqual('other');
      expect(classifyClickCodepoint(cp('.'), false)).assertEqual('other');
    });

    it('双击选词_ASCII词边界', 0, () => {
      const g = new LineGrid(3, 20, spaceCell());
      fillAsciiLine(g, 0, 'foo bar');
      const range = requireRange(wordSelectAt(g, 0, 4));
      expect(range.startCol).assertEqual(4);
      expect(range.endCol).assertEqual(6);
      const range2 = requireRange(wordSelectAt(g, 0, 1));
      expect(range2.startCol).assertEqual(0);
      expect(range2.endCol).assertEqual(2);
    });

    it('双击选词_CJK连续合并与混排切分', 0, () => {
      const g = new LineGrid(2, 20, spaceCell());
      fillAsciiLine(g, 0, '你好世界');
      const cjk = requireRange(wordSelectAt(g, 0, 2));
      expect(cjk.startCol).assertEqual(0);
      expect(cjk.endCol).assertEqual(7);
      const g2 = new LineGrid(1, 10, spaceCell());
      fillAsciiLine(g2, 0, 'a中b');
      const mid = requireRange(wordSelectAt(g2, 0, 1));
      expect(mid.startCol).assertEqual(1);
      expect(mid.endCol).assertEqual(2);
      const left = requireRange(wordSelectAt(g2, 0, 0));
      expect(left.startCol).assertEqual(0);
      expect(left.endCol).assertEqual(0);
    });

    it('双击选词_emoji宽字符不切半个字', 0, () => {
      const g = new LineGrid(1, 10, spaceCell());
      g.set(0, 0, cp('a'), false);
      g.set(0, 1, 0x1F44D, true);
      g.set(0, 2, CLICK_WIDE_CONTINUATION, false);
      g.set(0, 3, cp('b'), false);
      const onCont = requireRange(wordSelectAt(g, 0, 2));
      expect(onCont.startCol).assertEqual(1);
      expect(onCont.endCol).assertEqual(2);
      const onHead = requireRange(wordSelectAt(g, 0, 1));
      expect(onHead.startCol).assertEqual(1);
      expect(onHead.endCol).assertEqual(2);
      const onA = requireRange(wordSelectAt(g, 0, 0));
      expect(onA.startCol).assertEqual(0);
      expect(onA.endCol).assertEqual(0);
    });

    it('双击选词_空格与标点同类合并', 0, () => {
      const g = new LineGrid(1, 12, spaceCell());
      fillAsciiLine(g, 0, 'a,,b');
      const punct = requireRange(wordSelectAt(g, 0, 1));
      expect(punct.startCol).assertEqual(1);
      expect(punct.endCol).assertEqual(2);
      const sp = requireRange(wordSelectAt(g, 0, 5));
      expect(sp.startCol <= 5 && sp.endCol >= 5).assertTrue();
    });

    it('三击选行_整行含宽字符并去行尾空格', 0, () => {
      const g = new LineGrid(3, 12, spaceCell());
      fillAsciiLine(g, 1, 'hi中');
      const r = requireRange(lineSelectAt(g, 1));
      expect(r.startCol).assertEqual(0);
      expect(r.startRow).assertEqual(1);
      expect(r.endRow).assertEqual(1);
      expect(r.endCol).assertEqual(3);
      const empty = requireRange(lineSelectAt(g, 0));
      expect(empty.startCol).assertEqual(0);
      expect(empty.endCol).assertEqual(0);
      expect(lineSelectAt(g, 99)).assertNull();
    });

    // ---------------------------------------------------------------- T11 SGR

    it('encodeSgr_press_release_move_wheel', 0, () => {
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_LEFT, 'press', 5, 3)))
        .assertEqual('\x1b[<0;5;3M');
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_LEFT, 'release', 5, 3)))
        .assertEqual('\x1b[<0;5;3m');
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_MIDDLE, 'press', 1, 1)))
        .assertEqual('\x1b[<1;1;1M');
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_RIGHT, 'press', 2, 4)))
        .assertEqual('\x1b[<2;2;4M');
      // 拖动：button|32
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_LEFT, 'move', 6, 3)))
        .assertEqual('\x1b[<32;6;3M');
      // 无键悬停 move：3+32=35
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_NONE, 'move', 6, 3)))
        .assertEqual('\x1b[<35;6;3M');
      expect(bytesToString(encodeSgrWheel(true, 5, 3))).assertEqual('\x1b[<64;5;3M');
      expect(bytesToString(encodeSgrWheel(false, 5, 3))).assertEqual('\x1b[<65;5;3M');
      // Ctrl+press left → button|16
      expect(bytesToString(encodeSgrMouseEvent(SGR_BUTTON_LEFT, 'press', 5, 3, SGR_MOD_CTRL)))
        .assertEqual('\x1b[<16;5;3M');
      // 非法坐标
      expect(encodeSgrMouseEvent(SGR_BUTTON_LEFT, 'press', 0, 3)).assertNull();
      expect(encodeSgrMouseEvent(SGR_BUTTON_LEFT, 'press', 5, 0)).assertNull();
    });

    it('ohos鼠标按钮重映射SGR', 0, () => {
      // OHOS: 0=Left 1=Right 2=Middle → SGR: 0=left 1=middle 2=right
      expect(sgrButtonFromOhosButton(0)).assertEqual(SGR_BUTTON_LEFT);
      expect(sgrButtonFromOhosButton(1)).assertEqual(SGR_BUTTON_RIGHT);
      expect(sgrButtonFromOhosButton(2)).assertEqual(SGR_BUTTON_MIDDLE);
      expect(sgrButtonFromOhosButton(-1)).assertEqual(SGR_BUTTON_NONE);
    });

    it('shouldForward按mouseMode过滤', 0, () => {
      expect(shouldForwardMouseEvent(MOUSE_MODE_NONE, 'press', SGR_BUTTON_LEFT)).assertFalse();
      expect(shouldForwardMouseEvent(MOUSE_MODE_CLICK, 'press', SGR_BUTTON_LEFT)).assertTrue();
      expect(shouldForwardMouseEvent(MOUSE_MODE_CLICK, 'move', SGR_BUTTON_LEFT)).assertFalse();
      expect(shouldForwardMouseEvent(MOUSE_MODE_DRAG, 'move', SGR_BUTTON_LEFT)).assertTrue();
      expect(shouldForwardMouseEvent(MOUSE_MODE_DRAG, 'move', SGR_BUTTON_NONE)).assertFalse();
      expect(shouldForwardMouseEvent(MOUSE_MODE_ANY, 'move', SGR_BUTTON_NONE)).assertTrue();
      expect(shouldForwardMouseEvent(MOUSE_MODE_ANY, 'release', SGR_BUTTON_LEFT)).assertTrue();
    });

    // ---------------------------------------------------------------- T8 手柄 hit 区纯函数

    it('selectionHandleHitRects_贴选区两端', 0, () => {
      // origin(12,8) cell 10×20；选区 (0,2)→(1,5)
      const geo = selectionHandleHitRects(12, 8, 10, 20, 0, 2, 1, 5);
      // start 贴第一格左侧：x = 12+2*10 - 36 = -4
      expect(geo.start.x).assertEqual(-4);
      expect(geo.start.y).assertEqual(8);
      expect(geo.start.width).assertEqual(SELECTION_HANDLE_HIT_WIDTH_VP);
      expect(geo.start.height).assertEqual(Math.max(20, SELECTION_HANDLE_KNOB_VP));
      // end 贴末格右侧：x = 12+(5+1)*10 = 72
      expect(geo.end.x).assertEqual(72);
      expect(geo.end.y).assertEqual(8 + 20);
      expect(geo.end.width).assertEqual(SELECTION_HANDLE_HIT_WIDTH_VP);
    });

    it('selectionHandleHitRadius_默认热区半宽', 0, () => {
      expect(selectionHandleHitRadius()).assertEqual(SELECTION_HANDLE_HIT_WIDTH_VP / 2);
      // knob 大于 hitWidth 时取 knob/2
      expect(selectionHandleHitRadius(30, 40)).assertEqual(20);
    });

    it('selectionHandleAtPoint_命中与end优先', 0, () => {
      const geo = selectionHandleHitRects(0, 0, 10, 20, 0, 0, 0, 3);
      // start 热区 [-36, 0) × [0, max(20,22))
      expect(selectionHandleAtPoint(-20, 10, geo)).assertEqual('start');
      expect(selectionHandleAtPoint(-36, 0, geo)).assertEqual('start'); // 左闭
      expect(selectionHandleAtPoint(0, 10, geo)).assertEqual('none'); // 右开：0 不在 start
      // end 热区从 (3+1)*10=40 起
      expect(selectionHandleAtPoint(40, 10, geo)).assertEqual('end');
      expect(selectionHandleAtPoint(50, 10, geo)).assertEqual('end');
      expect(selectionHandleAtPoint(20, 10, geo)).assertEqual('none');
      expect(selectionHandleAtPoint(-20, 100, geo)).assertEqual('none'); // 垂直越界
    });

    it('selectionHandleAnchor_端点格中心_起拖不跳', 0, () => {
      const start = selectionHandleAnchor('start', 12, 8, 10, 20, 0, 2);
      expect(start.x).assertEqual(12 + 2 * 10 + 5);
      expect(start.y).assertEqual(8 + 10); // 行高中心
      // 起拖 offset=0：锚点换算回网格仍是原端点格
      expect(Math.floor((start.x - 12) / 10)).assertEqual(2);
      const end = selectionHandleAnchor('end', 12, 8, 10, 20, 1, 5);
      expect(end.x).assertEqual(12 + 5 * 10 + 5);
      expect(end.y).assertEqual(8 + 20 + 10);
      expect(Math.floor((end.x - 12) / 10)).assertEqual(5);
    });

    it('手柄几何与SelectionModel范围联动口径', 0, () => {
      // 调用方已把 range 规范化后再算 hit 区（函数本身不做文档序交换）
      const geo: SelectionHandleGeometry = selectionHandleHitRects(
        0, 0, 8, 16, 1, 1, 0, 1);
      // start 贴起点左侧（col=1）：x = 1*8 - 36 = -28
      expect(geo.start.x).assertEqual(-28);
      expect(geo.start.y).assertEqual(16);
      expect(geo.end.x).assertEqual((1 + 1) * 8);
      expect(geo.end.y).assertEqual(0);
    });
    it('滚轮轴事件_鼠标按格换算_触控板按行高累计_单次上限_SGR序列', 0, () => {
      const acc: WheelLineAccumulator = new WheelLineAccumulator();
      // 鼠标一格 15°，scrollStep=3 → 3 行；向上为负
      expect(acc.push(15, 3, true, 20)).assertEqual(3);
      expect(acc.push(-15, 0, true, 20)).assertEqual(-3);
      // 高精度滚轮：半格累计
      expect(acc.push(7.5, 2, true, 20)).assertEqual(1);
      expect(acc.push(7.5, 2, true, 20)).assertEqual(1);
      acc.reset();
      // 触控板：按行高累计余量
      expect(acc.push(10, 0, false, 20)).assertEqual(0);
      expect(acc.push(10, 0, false, 20)).assertEqual(1);
      expect(acc.push(-1000, 0, false, 20)).assertEqual(-WHEEL_MAX_LINES_PER_EVENT);
      expect(acc.push(0, 0, false, 20)).assertEqual(0);
      const up: Uint8Array[] = wheelSgrSequences(-2, 5, 7);
      expect(up.length).assertEqual(2);
      expect(bytesToAscii(up[0])).assertEqual('\x1b[<64;5;7M');
      const down: Uint8Array[] = wheelSgrSequences(1, 1, 1);
      expect(bytesToAscii(down[0])).assertEqual('\x1b[<65;1;1M');
      expect(wheelSgrSequences(100, 1, 1).length).assertEqual(WHEEL_MAX_LINES_PER_EVENT);
    });
  });
}
