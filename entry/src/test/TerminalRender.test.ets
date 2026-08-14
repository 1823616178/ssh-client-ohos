/**
 * T4 终端渲染纯逻辑测试（hypium）。
 *
 * 覆盖（全部不触 ArkUI/native）：
 *  - computeTerminalLayout：常规行列换算与边界（宽度不足一列、padding 大于宽度、
 *    非法格宽/负 padding 防御，cols/rows 恒 ≥1）；
 *  - hexColorToArgb / paletteToArgb / applyBoldAsBright / applyDim / withOpacity；
 *  - generateRowsCommands：颜色反转、bold-as-bright、dim、宽字符跳过续格、
 *    连续同属性合并成一次 fillRect/fillText、默认背景跳过、空字符断段、
 *    perGlyphText 退化、多行区间 y 坐标；
 *  - generateCursorCommands：block 反色（含宽字符 2 格）、bar/underline 几何、越界防御；
 *  - buildFontString / 默认外观与 AppearanceProfile 映射。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  ATTR_BOLD,
  ATTR_DIM,
  ATTR_REVERSE,
  ATTR_UNDERLINE,
  ATTR_WIDE,
  CELL_BYTES,
  WIDE_CONTINUATION
} from '../main/ets/napi/SshTerminal';
import {
  AppearanceProfile,
  HARMONY_DARK_PALETTE,
  createDefaultAppearanceProfile
} from '../main/ets/common/model/models';
import { TerminalLayoutMetrics, computeTerminalLayout } from '../main/ets/view/terminal/TerminalLayout';
import {
  applyBoldAsBright,
  applyDim,
  hexColorToArgb,
  paletteToArgb,
  withOpacity
} from '../main/ets/view/terminal/TerminalPalette';
import {
  RowDrawCommands,
  RowRenderEnv,
  buildFontString,
  generateCursorCommands,
  generateRowsCommands
} from '../main/ets/view/terminal/TerminalDrawCommands';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance,
  terminalAppearanceFromProfile
} from '../main/ets/view/terminal/TerminalAppearance';

const CELL_W = 10;
const CELL_H = 20;
const FG = 0xFFE8EEFB;
const BG = 0xFF0E131D;
const PALETTE_ARGB: number[] = paletteToArgb(HARMONY_DARK_PALETTE);

/** 造一格 16 字节单元格（布局同 cpp/term/grid.h，与 SshTerminal.test 同口径） */
function putCell(view: DataView, cellIndex: number, codepoint: number, fg: number,
  bg: number, attrs: number): void {
  const off = cellIndex * CELL_BYTES;
  view.setUint32(off, codepoint, true);
  view.setUint32(off + 4, fg, true);
  view.setUint32(off + 8, bg, true);
  view.setUint16(off + 12, attrs, true);
  view.setUint16(off + 14, 0, true);
}

/** rows×cols 空网格（默认前后景、无属性、码点 0） */
function makeGrid(rows: number, cols: number): DataView {
  const view = new DataView(new ArrayBuffer(rows * cols * CELL_BYTES));
  for (let i = 0; i < rows * cols; i++) {
    putCell(view, i, 0, FG, BG, 0);
  }
  return view;
}

function makeEnv(perGlyphText: boolean = false, boldAsBright: boolean = true): RowRenderEnv {
  return {
    originX: 8,
    originY: 8,
    cellWidth: CELL_W,
    cellHeight: CELL_H,
    defaultFgArgb: FG,
    defaultBgArgb: BG,
    paletteArgb: PALETTE_ARGB,
    boldAsBright: boldAsBright,
    perGlyphText: perGlyphText
  };
}

export default function terminalRenderTest() {
  describe('TerminalRenderTest', () => {

    // ---------------------------------------------------------------- 版面计算

    it('layout_常规行列换算', 0, () => {
      const m: TerminalLayoutMetrics = computeTerminalLayout(816, 416, 8, CELL_W, 16);
      expect(m.cols).assertEqual(80);   // floor((816-16)/10)
      expect(m.rows).assertEqual(25);   // floor((416-16)/16)
      expect(m.originX).assertEqual(8);
      expect(m.originY).assertEqual(8);
      expect(m.contentWidth).assertEqual(800);
      expect(m.contentHeight).assertEqual(400);
    });

    it('layout_宽度不足一列钳到1', 0, () => {
      const m = computeTerminalLayout(12, 100, 8, CELL_W, 16);
      expect(m.cols).assertEqual(1);    // 可用宽 0 → 1 列（PTY 最小 1×1）
      expect(m.rows).assertEqual(5);    // floor((100-16)/16)
    });

    it('layout_padding大于宽度钳到1', 0, () => {
      const m = computeTerminalLayout(10, 100, 20, CELL_W, 16);
      expect(m.cols).assertEqual(1);    // 可用宽 max(0, 10-40) = 0 → 1 列
      expect(m.rows).assertEqual(3);    // 可用高 max(0, 100-40) = 60 → floor(60/16)
    });

    it('layout_非法输入防御', 0, () => {
      const zeroCell = computeTerminalLayout(800, 600, 8, 0, 0);
      expect(zeroCell.cols).assertEqual(1);
      expect(zeroCell.rows).assertEqual(1);
      expect(zeroCell.contentWidth).assertEqual(0);
      // 负 padding 按 0 处理
      const negPad = computeTerminalLayout(800, 600, -5, CELL_W, 16);
      expect(negPad.cols).assertEqual(80);
      expect(negPad.originX).assertEqual(0);
    });

    // ---------------------------------------------------------------- 颜色

    it('hexColorToArgb_解析', 0, () => {
      expect(hexColorToArgb('#E8EEFB')).assertEqual(0xFFE8EEFB);
      expect(hexColorToArgb('#000000')).assertEqual(0xFF000000);
      expect(hexColorToArgb('#80FF0000')).assertEqual(0x80FF0000);
      expect(hexColorToArgb('#aabbcc')).assertEqual(0xFFAABBCC);
    });

    it('hexColorToArgb_非法输入抛错', 0, () => {
      const bad: string[] = ['FF0000', '#12345', '#1234567', 'red', '', '#GGGGGG'];
      for (const hex of bad) {
        let threw = false;
        try {
          hexColorToArgb(hex);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      }
    });

    it('paletteToArgb_必须16色', 0, () => {
      const argb = paletteToArgb(HARMONY_DARK_PALETTE);
      expect(argb.length).assertEqual(16);
      expect(argb[0]).assertEqual(0xFF1B2536);
      let threw = false;
      try {
        paletteToArgb(HARMONY_DARK_PALETTE.slice(0, 15));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('applyBoldAsBright_映射0至7到8至15', 0, () => {
      // 开 + bold + 命中 ANSI 1（红）→ ANSI 9（亮红）
      expect(applyBoldAsBright(PALETTE_ARGB[1], true, PALETTE_ARGB, true))
        .assertEqual(PALETTE_ARGB[9]);
      // 非 bold / 关闭开关 / 非调色板色：原样返回
      expect(applyBoldAsBright(PALETTE_ARGB[1], false, PALETTE_ARGB, true))
        .assertEqual(PALETTE_ARGB[1]);
      expect(applyBoldAsBright(PALETTE_ARGB[1], true, PALETTE_ARGB, false))
        .assertEqual(PALETTE_ARGB[1]);
      expect(applyBoldAsBright(0xFF123456, true, PALETTE_ARGB, true)).assertEqual(0xFF123456);
      // 亮色 8–15 不再映射
      expect(applyBoldAsBright(PALETTE_ARGB[9], true, PALETTE_ARGB, true))
        .assertEqual(PALETTE_ARGB[9]);
    });

    it('applyDim_前景向背景混一半', 0, () => {
      expect(applyDim(0xFFFFFFFF, 0xFF000000)).assertEqual(0xFF7F7F7F);
      // (0xE8+0x0E)>>1=0x7B，(0xEE+0x13)>>1=0x80，(0xFB+0x1D)>>1=0x8C
      expect(applyDim(0xFFE8EEFB, 0xFF0E131D)).assertEqual(0xFF7B808C);
    });

    it('withOpacity_缩放alpha并钳位', 0, () => {
      expect(withOpacity(0xFFE8EEFB, 0.5)).assertEqual(0x80E8EEFB); // round(255*0.5)=128
      expect(withOpacity(0xFFE8EEFB, 1)).assertEqual(0xFFE8EEFB);
      expect(withOpacity(0xFFE8EEFB, 2)).assertEqual(0xFFE8EEFB);  // 钳到 1
      expect(withOpacity(0xFFE8EEFB, 0)).assertEqual(0x00E8EEFB);
      expect(withOpacity(0xFFE8EEFB, -1)).assertEqual(0x00E8EEFB); // 钳到 0
    });

    // ---------------------------------------------------------------- 行指令生成

    it('指令_连续同属性合并成一次填充与一次文本', 0, () => {
      const grid = makeGrid(1, 4);
      for (let i = 0; i < 4; i++) {
        putCell(grid, i, 0x41 + i, FG, 0xFF112233, 0); // 'ABCD' 同背景同前景
      }
      const cmds = generateRowsCommands(grid, 0, 1, 4, makeEnv());
      expect(cmds.backgrounds.length).assertEqual(1);
      expect(cmds.backgrounds[0].x).assertEqual(8);
      expect(cmds.backgrounds[0].y).assertEqual(8);
      expect(cmds.backgrounds[0].width).assertEqual(40);
      expect(cmds.backgrounds[0].height).assertEqual(CELL_H);
      expect(cmds.backgrounds[0].argb).assertEqual(0xFF112233);
      expect(cmds.texts.length).assertEqual(1);
      expect(cmds.texts[0].text).assertEqual('ABCD');
      expect(cmds.texts[0].x).assertEqual(8);
      expect(cmds.texts[0].y).assertEqual(8 + CELL_H / 2);
      expect(cmds.texts[0].cellSpan).assertEqual(4);
      expect(cmds.texts[0].fgArgb).assertEqual(FG);
    });

    it('指令_默认背景段不产出背景指令', 0, () => {
      const grid = makeGrid(1, 3);
      putCell(grid, 1, 0x41, FG, 0xFF112233, 0); // 只有中间一格非默认背景
      const cmds = generateRowsCommands(grid, 0, 1, 3, makeEnv());
      expect(cmds.backgrounds.length).assertEqual(1);
      expect(cmds.backgrounds[0].x).assertEqual(8 + CELL_W);
      expect(cmds.backgrounds[0].width).assertEqual(CELL_W);
      expect(cmds.texts.length).assertEqual(1); // 两侧空格断段，只有 'A'
      expect(cmds.texts[0].text).assertEqual('A');
    });

    it('指令_相邻背景色变化分段', 0, () => {
      const grid = makeGrid(1, 4);
      putCell(grid, 0, 0x41, FG, 0xFF111111, 0);
      putCell(grid, 1, 0x42, FG, 0xFF111111, 0);
      putCell(grid, 2, 0x43, FG, 0xFF222222, 0);
      putCell(grid, 3, 0x44, FG, 0xFF222222, 0);
      const cmds = generateRowsCommands(grid, 0, 1, 4, makeEnv());
      expect(cmds.backgrounds.length).assertEqual(2);
      expect(cmds.backgrounds[0].argb).assertEqual(0xFF111111);
      expect(cmds.backgrounds[0].width).assertEqual(20);
      expect(cmds.backgrounds[1].argb).assertEqual(0xFF222222);
      expect(cmds.backgrounds[1].x).assertEqual(8 + 20);
    });

    it('指令_reverse交换前后景', 0, () => {
      const grid = makeGrid(1, 1);
      putCell(grid, 0, 0x61, 0xFFFF0000, 0xFF0000FF, ATTR_REVERSE);
      const cmds = generateRowsCommands(grid, 0, 1, 1, makeEnv());
      expect(cmds.backgrounds.length).assertEqual(1);
      expect(cmds.backgrounds[0].argb).assertEqual(0xFFFF0000); // 原前景变背景
      expect(cmds.texts[0].fgArgb).assertEqual(0xFF0000FF);     // 原背景变前景
    });

    it('指令_boldAsBright命中调色板', 0, () => {
      const grid = makeGrid(1, 2);
      putCell(grid, 0, 0x61, PALETTE_ARGB[1], BG, ATTR_BOLD); // bold + ANSI 红
      putCell(grid, 1, 0x62, PALETTE_ARGB[1], BG, 0);         // 非 bold 对照
      const cmds = generateRowsCommands(grid, 0, 1, 2, makeEnv());
      expect(cmds.texts.length).assertEqual(2); // 样式不同不合并
      expect(cmds.texts[0].fgArgb).assertEqual(PALETTE_ARGB[9]); // 亮红
      expect(cmds.texts[0].bold).assertTrue();
      expect(cmds.texts[1].fgArgb).assertEqual(PALETTE_ARGB[1]);

      const off = generateRowsCommands(grid, 0, 1, 2, makeEnv(false, false));
      expect(off.texts[0].fgArgb).assertEqual(PALETTE_ARGB[1]); // 开关关闭不映射
    });

    it('指令_dim变暗', 0, () => {
      const grid = makeGrid(1, 1);
      putCell(grid, 0, 0x61, 0xFFFFFFFF, BG, ATTR_DIM);
      const cmds = generateRowsCommands(grid, 0, 1, 1, makeEnv());
      expect(cmds.texts[0].fgArgb).assertEqual(applyDim(0xFFFFFFFF, BG));
    });

    it('指令_宽字符占2格且续格跳过', 0, () => {
      const grid = makeGrid(1, 4);
      putCell(grid, 0, 0x4E2D, FG, BG, ATTR_WIDE);        // 「中」首格
      putCell(grid, 1, WIDE_CONTINUATION, FG, BG, 0);     // 续格
      putCell(grid, 2, 0x42, FG, BG, 0);                  // 'B'
      const cmds = generateRowsCommands(grid, 0, 1, 4, makeEnv());
      expect(cmds.texts.length).assertEqual(2);
      expect(cmds.texts[0].text).assertEqual('中');
      expect(cmds.texts[0].x).assertEqual(8);
      expect(cmds.texts[0].cellSpan).assertEqual(2);
      expect(cmds.texts[1].text).assertEqual('B');
      expect(cmds.texts[1].x).assertEqual(8 + 2 * CELL_W); // 中(0) + 续格(1)，B 在第 2 列
      expect(cmds.backgrounds.length).assertEqual(0);      // 全默认背景
    });

    it('指令_perGlyphText逐格出段', 0, () => {
      const grid = makeGrid(1, 3);
      for (let i = 0; i < 3; i++) {
        putCell(grid, i, 0x41 + i, FG, BG, 0);
      }
      const cmds = generateRowsCommands(grid, 0, 1, 3, makeEnv(true));
      expect(cmds.texts.length).assertEqual(3);
      expect(cmds.texts[1].x).assertEqual(8 + CELL_W);
      expect(cmds.texts[2].x).assertEqual(8 + 2 * CELL_W);
    });

    it('指令_多行区间y坐标与起始行', 0, () => {
      const grid = makeGrid(3, 1);
      putCell(grid, 1 * 1, 0x61, FG, BG, 0); // 第 2 行（区间首行）
      putCell(grid, 2 * 1, 0x62, FG, BG, 0); // 第 3 行
      // readRows(1, 2) 切片：视图第 0 格 = 网格 (1, 0)
      const slice = new DataView(grid.buffer, 1 * CELL_BYTES, 2 * CELL_BYTES);
      const cmds = generateRowsCommands(slice, 1, 2, 1, makeEnv());
      expect(cmds.texts.length).assertEqual(2);
      expect(cmds.texts[0].y).assertEqual(8 + 1 * CELL_H + CELL_H / 2);
      expect(cmds.texts[1].y).assertEqual(8 + 2 * CELL_H + CELL_H / 2);
    });

    it('指令_underline与strike透传', 0, () => {
      const grid = makeGrid(1, 1);
      putCell(grid, 0, 0x61, FG, BG, ATTR_UNDERLINE);
      const cmds = generateRowsCommands(grid, 0, 1, 1, makeEnv());
      expect(cmds.texts[0].underline).assertTrue();
      expect(cmds.texts[0].strike).assertFalse();
    });

    it('指令_非法输入空指令', 0, () => {
      const grid = makeGrid(1, 1);
      expect(generateRowsCommands(grid, 0, 1, 0, makeEnv()).texts.length).assertEqual(0);
      const env = makeEnv();
      env.cellWidth = 0;
      expect(generateRowsCommands(grid, 0, 1, 1, env).texts.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 光标

    it('光标_block反色语义', 0, () => {
      const row = makeGrid(1, 2);
      putCell(row, 1, 0x61, FG, BG, ATTR_BOLD);
      const cmds = generateCursorCommands('block', row, 1, 3, 2, makeEnv(), 0xFF4D8DFF);
      expect(cmds.backgrounds.length).assertEqual(1);
      expect(cmds.backgrounds[0].argb).assertEqual(FG);          // 原前景当块色
      expect(cmds.backgrounds[0].x).assertEqual(8 + CELL_W);
      expect(cmds.backgrounds[0].y).assertEqual(8 + 3 * CELL_H);
      expect(cmds.backgrounds[0].width).assertEqual(CELL_W);
      expect(cmds.texts.length).assertEqual(1);
      expect(cmds.texts[0].fgArgb).assertEqual(BG);              // 原背景当字形色
      expect(cmds.texts[0].bold).assertTrue();                   // 原属性保留
      expect(cmds.texts[0].text).assertEqual('a');
    });

    it('光标_block宽字符覆盖2格', 0, () => {
      const row = makeGrid(1, 3);
      putCell(row, 0, 0x4E2D, FG, BG, ATTR_WIDE);
      putCell(row, 1, WIDE_CONTINUATION, FG, BG, 0);
      const cmds = generateCursorCommands('block', row, 0, 0, 3, makeEnv(), 0xFF4D8DFF);
      expect(cmds.backgrounds[0].width).assertEqual(2 * CELL_W);
      expect(cmds.texts[0].cellSpan).assertEqual(2);
    });

    it('光标_block空格调色块与null视图兜底', 0, () => {
      const row = makeGrid(1, 1); // 空格
      const empty = generateCursorCommands('block', row, 0, 0, 1, makeEnv(), 0xFF4D8DFF);
      expect(empty.backgrounds[0].argb).assertEqual(FG);
      expect(empty.texts.length).assertEqual(0);
      const noView = generateCursorCommands('block', null, 0, 0, 1, makeEnv(), 0xFF4D8DFF);
      expect(noView.backgrounds[0].argb).assertEqual(FG);
      expect(noView.texts.length).assertEqual(0);
    });

    it('光标_bar与underline几何', 0, () => {
      const cursorArgb = 0xFF4D8DFF;
      const bar = generateCursorCommands('bar', null, 2, 1, 5, makeEnv(), cursorArgb);
      expect(bar.backgrounds.length).assertEqual(1);
      expect(bar.backgrounds[0].argb).assertEqual(cursorArgb);
      expect(bar.backgrounds[0].x).assertEqual(8 + 2 * CELL_W);
      expect(bar.backgrounds[0].y).assertEqual(8 + CELL_H);
      expect(bar.backgrounds[0].width).assertEqual(Math.max(1.5, CELL_W * 0.15));
      expect(bar.backgrounds[0].height).assertEqual(CELL_H);
      expect(bar.texts.length).assertEqual(0);

      const under = generateCursorCommands('underline', null, 2, 1, 5, makeEnv(), cursorArgb);
      const h = Math.max(1.5, CELL_H * 0.12);
      expect(under.backgrounds[0].y).assertEqual(8 + CELL_H + CELL_H - h);
      expect(under.backgrounds[0].height).assertEqual(h);
      expect(under.backgrounds[0].width).assertEqual(CELL_W);
    });

    it('光标_越界返回空指令', 0, () => {
      expect(generateCursorCommands('bar', null, -1, 0, 5, makeEnv(), 0xFF4D8DFF)
        .backgrounds.length).assertEqual(0);
      expect(generateCursorCommands('bar', null, 5, 0, 5, makeEnv(), 0xFF4D8DFF)
        .backgrounds.length).assertEqual(0);
      expect(generateCursorCommands('bar', null, 0, -1, 5, makeEnv(), 0xFF4D8DFF)
        .backgrounds.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 字体串与外观

    it('buildFontString_组合', 0, () => {
      expect(buildFontString(false, false, 400, 14, 'JetBrains Mono'))
        .assertEqual('normal normal 14vp "JetBrains Mono"');
      expect(buildFontString(true, true, 400, 14, 'JetBrains Mono'))
        .assertEqual('italic bold 14vp "JetBrains Mono"');
      expect(buildFontString(false, false, 500, 12, 'monospace'))
        .assertEqual('normal 500 12vp "monospace"');
    });

    it('外观_默认值与C3一致', 0, () => {
      const a: TerminalAppearance = createDefaultTerminalAppearance();
      const profile = createDefaultAppearanceProfile('x');
      expect(a.fontFamily).assertEqual(profile.fontFamily);
      expect(a.fontSize).assertEqual(14);
      expect(a.lineHeight).assertEqual(1.2);
      expect(a.padding).assertEqual(8);
      expect(a.cursorStyle).assertEqual('block');
      expect(a.cursorBlink).assertTrue();
      expect(a.boldAsBright).assertTrue();
      expect(a.backgroundOpacity).assertEqual(1);
      expect(a.palette.length).assertEqual(16);
      expect(a.foreground).assertEqual('#E8EEFB');
      expect(a.background).assertEqual('#0E131D');
    });

    it('外观_fromProfile映射且调色板是副本', 0, () => {
      const profile: AppearanceProfile = createDefaultAppearanceProfile('p1');
      const a = terminalAppearanceFromProfile(profile);
      a.palette[0] = '#000000';
      expect(profile.palette[0]).assertEqual(HARMONY_DARK_PALETTE[0]); // 不回写 profile
      expect(a.fontWeight).assertEqual(profile.fontWeight);
      expect(a.letterSpacing).assertEqual(profile.letterSpacing);
    });

  });
}
