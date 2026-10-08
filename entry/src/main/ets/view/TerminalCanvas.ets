/**
 * TerminalCanvas —— 终端渲染组件（任务 T4，DESIGN §2.2 / §4.3.1 / §4.4，决策 D3/D14）。
 *
 * 帧模型：
 *  - 由全局唯一帧调度器（FrameScheduler，单条 displaySync）每帧驱动 renderFrame()；
 *  - 先比对 native revision：无变化且无需全量重绘 → 直接返回 false（零绘制，
 *    静止省电第一层；调度器层的自动休眠见 FrameSchedulerCore 头注）；
 *  - 有变化：beginFrame 拿脏行位图 → collectDirtyRanges 合并相邻脏行成区间 →
 *    每个区间 readRows 取 DataView → generateRowsCommands 出绘制指令（纯函数）
 *    → 执行 → endFrame(frame.revision) 回执（native 清脏位图）；
 *  - visible=false（不可见标签页）时调度器整帧跳过本实例，零绘制（D14）。
 *
 * 职责边界：
 *  - 尺寸协商：onAreaChange → computeTerminalLayout 得 cols/rows → 默认组件内部
 *    直接调 terminal.resize()（窗格像素尺寸 → PTY 尺寸是渲染几何的直接结果，
 *    放组件内可保证「拖分隔条后每个窗格各自发 request_pty_size」不漏；暂时置
 *    autoResizeTerminal=false 时只缓存最新网格，恢复 true 会合并提交一次 resize）；
 *  - 光标：block 反色 / bar / underline；cursorBlink 与 ATTR_BLINK 字符首版按
 *    静止绘制——闪烁需要低频定时翻转，定时器本身违背「静止 CPU≈0」，留给 A3
 *    光标设置落地时在调度层加低频 tick 一并做（真机验证后启用）；
 *  - 会话事件（terminalOpen/terminalBell/terminalTitle…）不在本组件消费，
 *    由 U4 从会话事件流分发；远端输出可能到达时 U4 调 notifyContentDirty()
 *    唤醒帧循环（自动休眠期间的唯一上屏入口）。
 *
 * 性能策略（R-2）：当前为纯脏行重绘——80×24=1920 格满脏每帧上限 1920 格指令，
 * T0 spike 负责验证该路径帧率（≥55fps 单实例 / ≥50fps 4 实例）。整屏滚动的
 * OffscreenCanvas 位块搬移做成独立方法 blitScrollUp()，默认关闭（
 * scrollBlitEnabled=false）：脏行位图无法区分「内容上移一行」与「逐行重写」，
 * 可靠检测要 native 滚动提示（T1 未暴露），T0/Q2 帧率不达标时再启用并补
 * native 侧标记（DESIGN §4.4 兜底顺序：脏行 → OffscreenCanvas 分块 → 自绘节点）。
 *
 * 本组件由 U4 TerminalPage 整合使用（单窗格：固定 paneId 绑一个会话）。
 *
 * 输入通路（详见 TerminalImeEditor/ImeInputLogic/KeyMap/StickyModifiers/FocusManager 头注）：
 *  - 主通路：inputMethod 自绘编辑器（TerminalImeEditor）——insertText/deleteLeft/
 *    sendFunctionKey/moveCursor 语义事件直接转字节；容器 Stack 自身可获焦；
 *  - 兜底：自绘编辑器 attach 失败时挂载隐藏 TextInput（ImeInputSink，零宽哨兵 +
 *    onSubmit 回车）；
 *  - 物理键盘：onKeyPreIme 只截 Ctrl/Alt 组合（兜底通路另截非可打印键），其余先给
 *    输入法，输入法不消费的键到 onKeyEvent → mapKeyEvent → write()；
 *  - DECCKM / bracketed paste / DECSCUSR 以 native 帧上报为准（frame.* 字段）；
 *  - 焦点路由：focusId 非空时按 FocusManager 判定，非聚焦窗格不投任何输入；
 *    点击窗格 = 聚焦 + 弹软键盘（焦点边框高亮归 U4b）；
 *  - 粘滞修饰：stickyModifiers 实例公开给 T7 功能键条（tap/lock），
 *    组件在每次按键/IME 提交出口消费；
 *  - T10 扩展点：2in1 物理键盘完整支持（不弹软键盘策略、keyText 非 US 布局、
 *    可自定义快捷键表、Meta 细分、小键盘映射）——handleKeyInput 是唯一出口，
 *    应用快捷键表（§4.3.2）也走这里：先 matchShortcut，命中则消费、不送给远端。
 *
 * 移动端交互（T7/T8/T9，DESIGN §4.4「移动端专属交互」表）：
 *  - T7：sendExternalInput() 是功能键条/片段等外部字节源的统一出口
 *    （按 FocusManager 焦点路由投递；粘滞修饰由 KeyBar 侧在出字节前并入）；
 *  - T8：长按进入选择模式（落在链接上则直接选中整条链接）→ 选区框 + 两端手柄
 *    → 拖手柄/在画布上拖更新端点，贴上下边缘自动滚动 → 气泡菜单
 *    「复制/粘贴/全选/打开链接」。选区用**绝对行**（回滚区 + 主屏统一编号），
 *    可以跨越回滚区，远端继续输出时选区不漂移；复制按软换行标记拼接逻辑行；
 *  - T9：单指竖滑——主屏 = 视图滚动回滚缓冲（松手惯性 FlingAnimator）；回滚中远端
 *    输出时视口锚定（不被推走）并显示「新输出」角标 +「回到底部」按钮，任何输入
 *    自动回到底部；alt-screen（vim/less）= 按 altScrollMode 发方向键或 SGR 滚轮；
 *    双指捏合 = 画面缩放预览 + 字号标签，松手只重排一次并经 onFontSizeCommit 落库；
 *  - 光标：DECSCUSR 形状/闪烁覆盖外观设置；闪烁定时器只在可见且聚焦时运行，
 *    输入后重置相位（打字时光标常亮）；非聚焦窗格画空心框；
 *  - 响铃：页面经 TerminalActionHub 投递 'bell' 动作时闪一下（视觉响铃，节流由 VM 负责；
 *    不走 @Prop 计数器——ForEach 同 key 复用节点时 item 快照不会刷新）。
 */
import { common } from '@kit.AbilityKit';
import { NativeTerminalFrame } from '../napi/SshNative';
import {
  CELL_BYTES,
  DecodedCell,
  DirtyRange,
  SshTerminal,
  addCursorRowRange,
  collectDirtyRanges,
  decodeCellAt
} from '../napi/SshTerminal';
import { Logger } from '../common/utils/Logger';
import { FrameScheduler } from './FrameScheduler';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance
} from './terminal/TerminalAppearance';
import {
  CURSOR_BLINK_PERIOD_MS,
  RowDrawCommands,
  RowRenderEnv,
  cellLeftX,
  cellTopY,
  cursorVisibleAt,
  generateCursorCommands,
  generateRowsCommands
} from './terminal/TerminalDrawCommands';
import { CursorStyle } from '../common/model/models';
import {
  TextMeasureContext,
  TextMeasureResult,
  computeBaselineOffsetFromCenter,
  measureTerminalCells,
  verifyCjkAlignment
} from './terminal/FontMetrics';
import {
  TerminalLayoutMetrics,
  areaLengthToVp,
  computeTerminalLayout,
  computeTerminalLayoutInsets
} from './terminal/TerminalLayout';
import {
  hexColorToArgb,
  paletteToArgb,
  withOpacity
} from './terminal/TerminalPalette';
import { FocusManager } from './terminal/FocusManager';
import {
  TerminalActionHub,
  TerminalActionExecutor,
  TerminalClipboardAction
} from './terminal/TerminalActionHub';
import { isModifierKeyCode, isPrintableKeyCode, mapKeyEvent } from './terminal/KeyMap';
import { StickyModifiers } from './terminal/StickyModifiers';
import { ImeInputSink } from './terminal/ImeInputHandler';
import {
  CommittedDelta,
  ImeEchoContext,
  committedDeltaToInputBytes,
  imeDeleteLeftToBytes,
  imeDeleteRightToBytes,
  imeEnterBytes,
  imeInsertToBytes,
  imeMoveCursorToBytes,
  shouldInterceptBeforeIme
} from './terminal/ImeInputLogic';
import { TerminalImeClient, TerminalImeEditor } from './terminal/TerminalImeEditor';
import {
  CellPos,
  LogicalLine,
  SelectionGridReader,
  SelectionModel,
  SelectionRange,
  adjustWideCharBoundary,
  dataViewRowWrapsNext,
  extractRangeText,
  logicalLineAt
} from './terminal/SelectionModel';
import { copyTextToPasteboard, pasteFromPasteboard } from './terminal/Pasteboard';
import { UrlMatch, openableUrl, singleUrlIn, urlAt } from './terminal/UrlDetector';
import {
  FlingAnimator,
  anchorScrollOffset,
  edgeAutoScrollLines
} from './terminal/ScrollPhysics';
import { ExternalKeyboardMonitor } from './terminal/ExternalKeyboardMonitor';
import { KeyboardChange, nextExternalKeyboardActive } from './terminal/PhysicalKeyboard';
import {
  ShortcutAction,
  ShortcutBinding,
  matchShortcut,
  parseShortcutLayout
} from './terminal/ShortcutMap';
import {
  AltScrollMode,
  ClickSelectCell,
  ClickSelectGrid,
  ClickSelectTracker,
  ClickSelectionMode,
  SELECTION_HANDLE_HIT_WIDTH_VP,
  SELECTION_HANDLE_KNOB_VP,
  SelectionHandleGeometry,
  SelectionHandleId,
  SGR_BUTTON_NONE,
  ScrollLineAccumulator,
  buildAltScrollSequences,
  clampScrollOffset,
  encodeSgrMouseEvent,
  lineSelectAt,
  pinchCommitFontSize,
  pinchPreviewScale,
  selectionHandleAnchor,
  selectionHandleAtPoint,
  selectionHandleHitRects,
  sgrButtonFromOhosButton,
  shouldForwardMouseEvent,
  wordSelectAt
} from './terminal/TerminalGestures';
import {
  isPhysicalKeyboardTypeName,
  keyboardTypeToString,
  shouldShowSoftKeyboardOnTouch,
  shouldSuppressSoftKeyboard,
  shouldSuppressSoftKeyboardOnKeyEvent
} from './terminal/PhysicalKeyboard';
import { vibrateLight } from '../common/utils/Haptics';
import { Tokens } from '../theme/Tokens';

/** 实例 id 自增序号（模块级；调度器注册用） */
let nextCanvasId = 0;

/** 字符度量失败（字体未注册）时的近似格宽系数 */
const FALLBACK_CELL_WIDTH_FRACTION = 0.6;
/** 字符网格在 Canvas 内部的最小左右留白；只改变绘制坐标，不改变 Canvas 节点尺寸。 */
const MIN_GRID_HORIZONTAL_INSET_VP = 12;
/** 字符网格在 Canvas 内部的最小顶部留白。 */
const MIN_GRID_TOP_INSET_VP = 12;
/** underline/strike 线宽 = 字号 × 该系数（下限 1vp） */
const TEXT_DECO_THICKNESS_FRACTION = 0.06;
/** 进入选择模式的长按时长（ms） */
const LONG_PRESS_DURATION_MS = 450;
/** 选区叠加层不透明度（盖在字形之上，需保持可读） */
const SELECTION_OVERLAY_OPACITY = 0.5;
/** 气泡菜单几何（vp）：≥40vp 触摸目标，单项宽 56 */
const MENU_HEIGHT_VP = 40;
const MENU_ITEM_WIDTH_VP = 56;
/** 气泡菜单左右内边距（vp） */
const MENU_SIDE_PADDING_VP = 4;
/** 气泡菜单与选区起点行的垂直间距（vp） */
const MENU_GAP_VP = 4;
/** 选区两端手柄圆钮直径（Token 表无「手柄」项；默认值与 TerminalGestures 纯函数常量对齐） */
const HANDLE_KNOB_VP = SELECTION_HANDLE_KNOB_VP;
/** 手柄竖条宽度 */
const HANDLE_BAR_WIDTH_VP = 4;
/** 手柄整体触摸宽度：圆钮 + 竖条 + 两侧热区（纯函数 SELECTION_HANDLE_HIT_WIDTH_VP） */
const HANDLE_HIT_WIDTH_VP = SELECTION_HANDLE_HIT_WIDTH_VP;
/** 选区边框线宽 */
const SELECTION_BORDER_VP = 2;
/** 回滚区一次批量读取的行数（选区/复制/链接识别的绝对行读取器） */
const SB_READ_BATCH = 256;
/** 选择拖动贴边自动滚动：边缘带宽（vp）、每拍最多行数、节拍（ms） */
const EDGE_SCROLL_BAND_VP = 36;
const EDGE_SCROLL_MAX_LINES = 3;
const EDGE_SCROLL_INTERVAL_MS = 60;
/** 「回到底部」按钮直径（≥40vp 触摸目标） */
const JUMP_BUTTON_VP = 44;
/** 视觉响铃闪烁峰值不透明度与时长 */
const BELL_FLASH_OPACITY = 0.18;
const BELL_FLASH_MS = 140;
/** 非聚焦窗格空心光标线宽 */
const HOLLOW_CURSOR_LINE_VP = 1;

/**
 * CanvasRenderingContext2D → TextMeasureContext 的名义类型适配（U4 修复）：
 * ArkTS 禁类实例→接口的结构化赋值（arkts-no-structural-typing；本组件未被任何页面
 * 引用时该校验不触发，U4 整合 TerminalPage 后才暴露为编译错误），包一层显式
 * implements 的适配类规避；仅做透传，度量行为不变。
 */
class CanvasTextMeasureContext implements TextMeasureContext {
  private readonly context: CanvasRenderingContext2D;

  constructor(context: CanvasRenderingContext2D) {
    this.context = context;
  }

  get font(): string {
    return this.context.font;
  }

  set font(value: string) {
    this.context.font = value;
  }

  measureText(text: string): TextMeasureResult {
    const metrics = this.context.measureText(text);
    return {
      width: metrics.width,
      actualBoundingBoxAscent: metrics.actualBoundingBoxAscent,
      actualBoundingBoxDescent: metrics.actualBoundingBoxDescent,
      fontBoundingBoxAscent: metrics.fontBoundingBoxAscent,
      fontBoundingBoxDescent: metrics.fontBoundingBoxDescent
    };
  }
}

/** TerminalActionHub 执行器适配（ArkTS 禁止 struct 实现接口，故包一层类转回实例方法） */
class CanvasClipboardExecutor implements TerminalActionExecutor {
  private readonly handler: (action: TerminalClipboardAction) => void;

  constructor(handler: (action: TerminalClipboardAction) => void) {
    this.handler = handler;
  }

  executeClipboardAction(action: TerminalClipboardAction): void {
    this.handler(action);
  }
}

/** ClickSelectGrid 的帧快照实现（arkts 对象字面量不承载方法，须显式类） */
class SnapshotClickGrid implements ClickSelectGrid {
  readonly rows: number;
  readonly cols: number;
  private readonly cells: ClickSelectCell[];

  constructor(cells: ClickSelectCell[], rows: number, cols: number) {
    this.cells = cells;
    this.rows = rows;
    this.cols = cols;
  }

  cellAt(row: number, col: number): ClickSelectCell | null {
    if (row < 0 || row >= this.rows || col < 0 || col >= this.cols) {
      return null;
    }
    return this.cells[row * this.cols + col];
  }
}

/**
 * 绝对行读取器：abs ∈ [scrollbackOldest, scrollbackTotal) 读回滚区，
 * abs ∈ [scrollbackTotal, scrollbackTotal + rows) 读主屏第 abs − total 行。
 * 回滚区按 SB_READ_BATCH 行批量读取并缓存一个窗口，顺序读取（复制大选区）
 * 不会逐行跨 NAPI。帧快照只读：beginFrame 后不 endFrame。
 */
class TerminalAbsReader implements SelectionGridReader {
  readonly rows: number;
  readonly cols: number;
  readonly minRow: number;
  private readonly terminal: SshTerminal;
  private readonly frame: NativeTerminalFrame;
  private readonly total: number;
  private screen: DataView | null = null;
  private screenLoaded: boolean = false;
  private sb: DataView | null = null;
  private sbStart: number = 0;
  private sbCount: number = 0;
  private curView: DataView | null = null;
  private curRow: number = 0;

  constructor(terminal: SshTerminal, frame: NativeTerminalFrame) {
    this.terminal = terminal;
    this.frame = frame;
    this.total = frame.scrollbackTotal;
    this.minRow = Math.min(frame.scrollbackOldest, frame.scrollbackTotal);
    this.rows = frame.scrollbackTotal + frame.rows;
    this.cols = frame.cols;
  }

  private locate(abs: number): boolean {
    if (abs < this.minRow || abs >= this.rows || this.cols <= 0) {
      return false;
    }
    if (abs >= this.total) {
      if (!this.screenLoaded) {
        this.screenLoaded = true;
        this.screen = this.terminal.readRows(this.frame, 0, this.frame.rows);
      }
      if (this.screen === null) {
        return false;
      }
      this.curView = this.screen;
      this.curRow = abs - this.total;
      return true;
    }
    if (this.sb === null || abs < this.sbStart || abs >= this.sbStart + this.sbCount) {
      const start: number = Math.max(this.minRow, abs - SB_READ_BATCH / 2);
      const count: number = Math.min(SB_READ_BATCH, this.total - start);
      if (count <= 0) {
        return false;
      }
      const buf: ArrayBuffer | null = this.terminal.readScrollbackWindow(start, count);
      if (buf === null) {
        return false;
      }
      this.sb = new DataView(buf);
      this.sbStart = start;
      this.sbCount = Math.floor(buf.byteLength / (CELL_BYTES * this.cols));
      if (abs >= start + this.sbCount) {
        return false;
      }
    }
    this.curView = this.sb;
    this.curRow = abs - this.sbStart;
    return true;
  }

  rowCells(row: number): DecodedCell[] | null {
    if (!this.locate(row) || this.curView === null) {
      return null;
    }
    const view: DataView = this.curView;
    const cells: DecodedCell[] = [];
    const base: number = this.curRow * this.cols;
    for (let c = 0; c < this.cols; c++) {
      cells.push(decodeCellAt(view, base + c));
    }
    return cells;
  }

  rowWrapsNext(row: number): boolean {
    if (!this.locate(row) || this.curView === null) {
      return false;
    }
    return dataViewRowWrapsNext(this.curView, this.curRow, this.cols);
  }
}

/** 自绘编辑器事件（CanvasImeClient → 画布单一入口） */
type ImeEventKind = 'insert' | 'deleteLeft' | 'deleteRight' | 'enter' | 'move' | 'selectAll' |
  'copy' | 'paste' | 'keyboard';

/** TerminalImeClient 适配（struct 不能 implements 接口，与 CanvasClipboardExecutor 同理） */
class CanvasImeClient implements TerminalImeClient {
  private readonly dispatch: (kind: ImeEventKind, text: string, value: number) => void;
  private readonly left: (length: number) => string;

  constructor(dispatch: (kind: ImeEventKind, text: string, value: number) => void,
    left: (length: number) => string) {
    this.dispatch = dispatch;
    this.left = left;
  }

  onInsertText(text: string): void {
    this.dispatch('insert', text, 0);
  }

  onDeleteLeft(length: number): void {
    this.dispatch('deleteLeft', '', length);
  }

  onDeleteRight(length: number): void {
    this.dispatch('deleteRight', '', length);
  }

  onEnter(): void {
    this.dispatch('enter', '', 0);
  }

  onMoveCursor(direction: number): void {
    this.dispatch('move', '', direction);
  }

  onSelectAll(): void {
    this.dispatch('selectAll', '', 0);
  }

  onCopy(): void {
    this.dispatch('copy', '', 0);
  }

  onPaste(): void {
    this.dispatch('paste', '', 0);
  }

  onKeyboardShown(shown: boolean): void {
    this.dispatch('keyboard', '', shown ? 1 : 0);
  }

  leftText(length: number): string {
    return this.left(length);
  }
}

@Component
export struct TerminalCanvas {
  /**
   * 绑定的终端实例（T3 SshTerminal，薄句柄封装——@Prop 拷贝的只是句柄值，
   * native 状态不受影响）；换绑会话时父组件传入新实例触发全量重绘
   */
  @Prop @Watch('onTerminalChanged') terminal: SshTerminal | null = null;
  /** 外观参数（默认取 C3 createDefaultAppearanceProfile 的 Harmony Dark） */
  @Prop @Watch('onAppearanceChanged') appearance: TerminalAppearance =
    createDefaultTerminalAppearance();
  /** 不可见标签页置 false：帧调度器整帧跳过（零绘制，验收标准 D14） */
  @Prop @Watch('onVisibleChanged') visible: boolean = true;
  /** cols/rows 变化回调（每次变化一次；autoResizeTerminal=false 时由持有方据此调 resize） */
  onGridSizeChanged: (cols: number, rows: number) => void = () => {};
  /** true（默认）= 组件内部调 terminal.resize()；false 期间缓存最新网格，恢复时一次提交。 */
  @Prop @Watch('onAutoResizeTerminalChanged') autoResizeTerminal: boolean = true;
  /**
   * R-2 兜底开关：整屏滚动 OffscreenCanvas 位块搬移（blitScrollUp）。
   * 默认 false，T0/Q2 帧率不达标再启用（前置条件与风险见文件头注「性能策略」）
   */
  scrollBlitEnabled: boolean = false;
  /**
   * 窗格焦点 id（T6，U4b Leaf 传入）：非空时输入按 FocusManager 路由，
   * 仅聚焦窗格收发；空串 = 单窗格模式（输入直通，不做路由判定）
   */
  @Prop focusId: string = '';
  /** 页面首次进入时，聚焦窗格把系统输入焦点直接交给隐藏 IME 承接框。 */
  @Prop @Watch('onAutoFocusChanged') autoFocus: boolean = false;
  /**
   * 终端应用光标模式（DECCKM）兜底值：native 帧带 applicationCursorKeys 时以帧为准
   * （每个终端各自的模式，多窗格不串）；旧 native 无该字段时用本参数。
   */
  @Prop applicationCursorKeys: boolean = false;
  /**
   * 粘滞修饰键状态机（T6）：T7 功能键条读写（tapCtrl/tapAlt/lockCtrl/lockAlt），
   * 组件在每次物理按键与 IME 提交出口取快照并 consume
   */
  readonly stickyModifiers: StickyModifiers = new StickyModifiers();
  /**
   * alt-screen 下单指竖滑行为（T9，DESIGN §4.4「滚动」可配置项）：
   * 'keys'（默认）= 发方向键；'mouse' = 终端开鼠标上报时发 SGR 滚轮序列
   * （未开上报回退方向键）；'view' = 与主屏一致的视图滚动
   */
  @Prop altScrollMode: AltScrollMode = 'keys';
  /** 触感总开关（C3 hapticEnabled）：长按进入选择/复制成功的轻震 */
  @Prop hapticEnabled: boolean = true;
  /**
   * 捏合缩放松手回调（T9）：实时缩放已在组件内生效，松手时把最终字号
   * 通知外部落库（写库是设置仓库/A3 的职责，组件不直接持久化）
   */
  onFontSizeCommit: (fontSize: number) => void = () => {};
  /**
   * 快捷键表 JSON（C3 keyboardShortcuts；空串 = 内置默认）。
   * 命中后复制/粘贴在本组件处理，其余经 onAppShortcut 交给页面/VM。
   */
  @Prop @Watch('onShortcutJsonChanged') shortcutBindingsJson: string = '';
  /** 标签/分屏/切焦点等应用动作（复制粘贴不走这里） */
  onAppShortcut: (action: ShortcutAction) => boolean = (_action: ShortcutAction) => false;
  /** 用户产生输入（键盘/IME/键条/粘贴）回调：页面据此清除「新输出」类提示等 */
  onUserInput: () => void = () => {};

  private shortcutBindings: ShortcutBinding[] = parseShortcutLayout('');

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly schedulerId: string = `terminal-canvas-${++nextCanvasId}`;
  /** 隐藏 IME 承接框的全局唯一 id（兜底通路 focusControl.requestFocus 用） */
  private readonly imeSinkId: string = `terminal-ime-${++nextCanvasId}`;
  /** 容器 Stack 的 id（自绘编辑器通路：Stack 自身获焦承接物理键） */
  private readonly hostId: string = `terminal-host-${nextCanvasId}`;
  /** 自绘编辑器事件适配 */
  private readonly imeClient: CanvasImeClient = new CanvasImeClient(
    (kind: ImeEventKind, text: string, value: number): void => {
      this.onImeEvent(kind, text, value);
    },
    (length: number): string => this.imeEcho.leftText(length));
  /** IME 联想用本地回显上下文 */
  private readonly imeEcho: ImeEchoContext = new ImeEchoContext();
  /** true = 自绘编辑器通路；false = 隐藏 TextInput 兜底（attach 失败后切换） */
  @State private useCustomIme: boolean = TerminalImeEditor.get().isAvailable();
  private unsubscribeImeAvailability: () => void = () => {};
  private unsubscribeFocus: () => void = () => {};
  private unsubscribeKeyboardMonitor: () => void = () => {};
  /** 本窗格是否为输入目标（FocusManager 监听维护；非聚焦画空心光标、不闪烁） */
  private paneFocused: boolean = true;
  /** struct 不能 implements 接口，故用适配器把剪贴板动作转回本实例 */
  private readonly clipboardExecutor: TerminalActionExecutor =
    new CanvasClipboardExecutor((action: TerminalClipboardAction): void => {
      this.executeClipboardAction(action);
    });

  private canvasReady = false;
  /** 物理像素/vp（绘制坐标吸附用；onReady 时读取） */
  private pixelRatio: number = 0;
  private inputFocusTimer: number = -1;
  private areaWidthVp = 0;
  private areaHeightVp = 0;
  // ---- 字符度量缓存（DESIGN §4.4：字体/字号变化时才重测）----
  private measuredFontKey = '';
  private cellWidthVp = 0;
  private cellHeightVp = 0;
  /** alphabetic baseline 相对 cell 中线的偏移；由字体 ascent/descent 实测。 */
  private textBaselineOffsetVp = 0;
  private fontNormal = '';
  private fontBold = '';
  private fontItalic = '';
  private fontBoldItalic = '';
  // ---- 颜色缓存（外观变化时重解析）----
  private paletteArgb: number[] = [];
  private defaultFgArgb = 0xFFFFFFFF;
  private defaultBgArgb = 0xFF000000;
  /** 应用 backgroundOpacity 后的整底填充色 */
  private backgroundArgb = 0xFF000000;
  private cursorArgb = 0xFF4D8DFF;
  // ---- 帧状态 ----
  private layout: TerminalLayoutMetrics =
    computeTerminalLayout(0, 0, 0, 0, 0);
  private notifiedCols = 0;
  private notifiedRows = 0;
  /** autoResizeTerminal=false 期间合并的最新 PTY resize 请求。 */
  private pendingTerminalResize = false;
  private lastRenderedRevision = -1;
  private lastGridCols = 0;
  private lastGridRows = 0;
  private needsFullRedraw = true;
  /** 最近一次 1:2 对齐校验结果（T5；isCjkAligned() 供 UI/A3 读，默认 true 不告警） */
  private cjkAligned = true;
  // ---- T8 选择模式 ----
  /** 选择会话状态机（纯逻辑在 terminal/SelectionModel.ets） */
  private readonly selection: SelectionModel = new SelectionModel();
  /** 选区背景色 ARGB（外观 selectionColor 解析缓存） */
  private selectionArgb = 0xFF26314A;
  /** 气泡菜单可见性与位置（@State 驱动 build 叠加层） */
  @State private selectionMenuVisible: boolean = false;
  @State private selectionMenuX: number = 0;
  @State private selectionMenuY: number = 0;
  @State private selectionHandlesVisible: boolean = false;
  @State private startHandleX: number = 0;
  @State private startHandleY: number = 0;
  @State private endHandleX: number = 0;
  @State private endHandleY: number = 0;
  @State private handleBarHeight: number = 16;
  @State private selectionHandleColor: string = '#4D8DFF';
  /** 正在拖的手柄；空串 = 未拖。起点用选区当时另一端作锚。 */
  private draggingHandle: string = '';
  private handleDragOriginX: number = 0;
  private handleDragOriginY: number = 0;
  /** 最近一次手柄命中几何（纯函数产出，供 hit-test / 拖动 origin） */
  private lastHandleGeo: SelectionHandleGeometry | null = null;
  // ---- T9 滚动/缩放 ----
  /** 回滚视图偏移（行；0 = 紧贴最新主屏） */
  private scrollOffsetLines = 0;
  /** 拖动像素 → 整行换算器（余量跨事件累计） */
  private readonly scrollAccumulator: ScrollLineAccumulator = new ScrollLineAccumulator();
  /** 上一次 pan 事件的累计位移（算增量用） */
  private panLastOffsetY = 0;
  /** 最近一帧元信息缓存（手势决策用）：alt-screen / 鼠标上报 / 回滚行数 */
  private lastAltScreen = false;
  private lastMouseMode = 0;
  private lastScrollbackCount = 0;
  /** 捏合起点字号（scale 是相对手势起点的倍率） */
  private pinchBaseFontSize = 14;
  // ---- T10 物理键盘 / T11 鼠标·连点 ----
  /**
   * 外接键盘活跃标记：物理键事件到达后置 true，点击窗格不再拉起软键盘
   * （策略见 PhysicalKeyboard.ets；键盘类型名由设备侧 keyboard.getKeyboardType
   * 回填 externalKeyboardTypeName，缺省走宽松策略）。@State 驱动 ImeInputSink。
   */
  @State private externalKeyboardActive: boolean = false;
  /**
   * keyboard.getKeyboardType() 名称（设备侧回填；空串 = 尚未探测）。
   * @State：变化时驱动 ImeInputSink 的 enableSoftKeyboardOnFocus 跟随。
   */
  @State private externalKeyboardTypeName: string = '';
  /** 连点（双击选词/三击选行）状态机 */
  private readonly clickTracker: ClickSelectTracker = new ClickSelectTracker();
  /** 最近一次鼠标事件网格坐标（1 起，SGR 用）与按住的 SGR 按钮码 */
  private lastMouseCol1 = 1;
  private lastMouseRow1 = 1;
  private lastSgrButton = SGR_BUTTON_NONE;
  /**
   * 鼠标上报期间是否禁用触摸选择/滚动手势语义（mode≠0 时 vim/tmux 要接管鼠标）。
   * true 时 TapGesture/长按仍可退出本地选择，但 pan 不发方向键除非 altScrollMode
   * 明确要求——上报路径优先走 onMouse 的 SGR 转发。
   */
  private mouseReportingActive = false;
  // ---- A3 光标闪烁（FrameScheduler 半周期 wakeup + cursorVisibleAt 纯函数）----
  /** 上次绘制时光标的可见相位；相位翻转时即使 content revision 不变也要重画光标格 */
  private lastCursorBlinkVisible = true;
  /** execCommands 跨批次的 ctx 状态缓存（NaN/'' = 未知，任何外部改动后须 invalidateCtxStyleCache） */
  private lastCtxFont = '';
  private lastCtxFill: number = Number.NaN;
  /** 选区宽字符边界修正缓存：键 = 原始选区 + revision + 尺寸 */
  private selAdjustKey = '';
  private selAdjusted: SelectionRange | null = null;
  /** 半周期唤醒定时器（闪烁开启时防 FrameScheduler 自动休眠吞掉相位翻转） */
  private blinkWakeTimer: number = -1;
  /** 闪烁相位起点：输入后重置，打字期间光标常亮 */
  private blinkEpoch: number = 0;
  /** 最近一帧的光标可见（DECTCEM）；不可见时闪烁不触发重绘 */
  private lastFrameCursorVisible: boolean = true;
  /** native DECSCUSR 覆盖：形状 0=未覆盖 1 block 2 underline 3 bar；闪烁 -1 未覆盖 */
  private frameCursorShape: number = 0;
  private frameCursorBlink: number = -1;
  /** native 帧上报的 DECCKM / bracketed paste（undefined 字段时退回 @Prop） */
  private frameAppCursor: boolean = false;
  private frameAppCursorKnown: boolean = false;
  private frameBracketedPaste: boolean = false;
  // ---- 回滚视口锚定 / 新输出提示 / 惯性 ----
  private lastScrollbackTotal: number = -1;
  private lastScrollbackOldest: number = 0;
  private lastScrollbackEpoch: number = 0;
  @State private scrolledBack: boolean = false;
  @State private newOutputBadge: boolean = false;
  private readonly fling: FlingAnimator = new FlingAnimator();
  private readonly flingAccumulator: ScrollLineAccumulator = new ScrollLineAccumulator();
  // ---- 选择拖动贴边滚动 ----
  private edgeScrollTimer: number = -1;
  private edgeScrollLines: number = 0;
  /** 贴边滚动时要跟随的端：extend（画布拖选）/ start / end（手柄） */
  private edgeDragTarget: string = '';
  private edgeDragX: number = 0;
  private edgeDragY: number = 0;
  /** 当前选区对应的可打开链接（'' = 无） */
  @State private selectionUrl: string = '';
  // ---- 捏合预览 ----
  @State private pinchScale: number = 1;
  @State private pinchLabel: string = '';
  private pinchLastScale: number = 1;
  // ---- 视觉响铃 ----
  @State private bellFlashOpacity: number = 0;
  private bellFlashTimer: number = -1;

  aboutToAppear(): void {
    this.shortcutBindings = parseShortcutLayout(this.shortcutBindingsJson);
    this.paneFocused = this.isInputTarget();
    this.applyAppearance();
    FrameScheduler.get().register(this.schedulerId, this.renderFrame);
    FrameScheduler.get().setVisible(this.schedulerId, this.visible);
    // 键条「复制/粘贴」按 paneId 路由到本实例（页面拿不到画布引用，见 Hub 头注）
    TerminalActionHub.get().register(this.focusId, this.clipboardExecutor);
    this.unsubscribeImeAvailability = TerminalImeEditor.get().addAvailabilityListener(
      (available: boolean): void => {
        if (!available && this.useCustomIme) {
          // 自绘编辑器不可用：切到隐藏 TextInput 兜底，挂载后补一次焦点
          this.useCustomIme = false;
          if (this.paneFocused) {
            this.scheduleInputFocus(true);
          }
        }
      });
    this.unsubscribeFocus = FocusManager.get().addListener((_id: string): void => {
      this.onPaneFocusChanged();
    });
    this.unsubscribeKeyboardMonitor = ExternalKeyboardMonitor.get().subscribe(
      (change: KeyboardChange): void => {
        this.externalKeyboardActive = nextExternalKeyboardActive(this.externalKeyboardActive, change);
      });
    this.syncBlinkWakeTimer();
  }

  /** TerminalActionHub 执行器：键条/页面动作复用与快捷键完全相同的实现 */
  executeClipboardAction(action: TerminalClipboardAction): void {
    if (action === 'copy') {
      this.copySelection();
      return;
    }
    if (action === 'paste') {
      this.pasteClipboard();
      return;
    }
    if (action === 'keyboard') {
      this.toggleSoftKeyboard();
      return;
    }
    if (action === 'scrollBottom') {
      this.scrollToBottom();
      return;
    }
    if (action === 'bell') {
      this.flashBell();
    }
  }

  private onShortcutJsonChanged(): void {
    this.shortcutBindings = parseShortcutLayout(this.shortcutBindingsJson);
  }

  aboutToDisappear(): void {
    if (this.inputFocusTimer >= 0) {
      clearTimeout(this.inputFocusTimer);
      this.inputFocusTimer = -1;
    }
    if (this.bellFlashTimer >= 0) {
      clearTimeout(this.bellFlashTimer);
      this.bellFlashTimer = -1;
    }
    this.stopEdgeScroll();
    this.fling.stop();
    this.clearBlinkWakeTimer();
    this.unsubscribeImeAvailability();
    this.unsubscribeFocus();
    this.unsubscribeKeyboardMonitor();
    TerminalImeEditor.get().release(this.schedulerId);
    TerminalActionHub.get().unregister(this.focusId, this.clipboardExecutor);
    FrameScheduler.get().unregister(this.schedulerId);
  }

  /** 焦点变化：空心/实心光标切换、闪烁定时器、软键盘跟随新聚焦窗格 */
  private onPaneFocusChanged(): void {
    const focused: boolean = this.isInputTarget();
    if (focused === this.paneFocused) {
      return;
    }
    this.paneFocused = focused;
    this.needsFullRedraw = true;
    this.syncBlinkWakeTimer();
    if (focused && this.useCustomIme && this.visible) {
      // 软键盘正开着时让输入跟到新聚焦窗格（不改变键盘显隐）
      const ime: TerminalImeEditor = TerminalImeEditor.get();
      if (ime.isKeyboardShown()) {
        ime.attach(this.schedulerId, this.imeClient, true);
      }
    }
    FrameScheduler.get().wakeup();
  }

  // ---------------------------------------------------------------- 对外入口

  /** U4 接线用：会话事件提示「该终端可能有新输出」时唤醒帧循环（休眠期上屏入口） */
  notifyContentDirty(): void {
    FrameScheduler.get().wakeup();
  }

  /** 强制下一帧全量重绘（外观/字体外部变更等场景） */
  forceFullRedraw(): void {
    this.needsFullRedraw = true;
    FrameScheduler.get().wakeup();
  }

  /** T5：宽字符 2 格对齐校验结果（false = 字族未 1:2 对齐，UI 可提示「字体未对齐」） */
  isCjkAligned(): boolean {
    return this.cjkAligned;
  }

  /**
   * 外部字节输入统一出口（T7 功能键条 / U10 片段 / 菜单粘贴等）：
   * 与物理键盘同口径走 FocusManager 焦点路由——非聚焦窗格不投递。
   * 粘滞修饰不进这里（调用方出字节前已并入，如 KeyBar 的 keyBarBytesForKey）。
   */
  sendExternalInput(bytes: Uint8Array): void {
    if (!this.isInputTarget()) {
      return;
    }
    this.sendInputBytes(bytes);
  }

  /**
   * R-2 兜底：整屏内容上滚 lines 行的位块搬移（OffscreenCanvas 中转）。
   * 默认关闭（scrollBlitEnabled），检测不到可靠滚动时不得调用——见文件头注。
   * 搬移后新进入的行由正常脏行路径重绘。
   */
  blitScrollUp(lines: number): boolean {
    if (!this.scrollBlitEnabled || lines <= 0 || !this.canvasReady) {
      return false;
    }
    const shift = lines * this.cellHeightVp;
    const w = this.areaWidthVp;
    const h = this.areaHeightVp;
    if (shift <= 0 || shift >= h || w <= 0) {
      return false;
    }
    // 主画布没有直接的「自我位块搬移」：getImageData 取存活区 → OffscreenCanvas
    // 中转 → transferToImageBitmap → 清底后 drawImage 回顶部
    const image = this.context.getImageData(0, shift, w, h - shift);
    const offscreen = new OffscreenCanvas(w, h - shift);
    const offCtx = offscreen.getContext('2d', this.settings);
    offCtx.putImageData(image, 0, 0);
    const bitmap = offscreen.transferToImageBitmap();
    this.invalidateCtxStyleCache();
    this.context.fillStyle = this.backgroundArgb;
    this.context.fillRect(0, 0, w, h);
    this.context.drawImage(bitmap, 0, 0);
    return true;
  }

  // ---------------------------------------------------------------- 输入通路（T6）

  /** 输入投递判定：单窗格模式（focusId 空）直通；否则仅聚焦窗格（DESIGN §4.3.1） */
  private isInputTarget(): boolean {
    return this.focusId.length === 0 || FocusManager.get().isFocused(this.focusId);
  }

  /**
   * 点击窗格（TapGesture，带手指坐标）：选择模式下点击 = 退出选择（不弹软键盘，
   * 避免打断复制后查看）；否则聚焦本窗格 + 弹软键盘。惯性滚动中的点按只停住滚动。
   *
   * T10：外接键盘活跃时只聚焦不弹软键盘（物理键仍可路由）。
   * T11：双击/三击（按手指落点）选词/选行。
   */
  private onPaneClick(event: GestureEvent): void {
    if (this.fling.running) {
      this.fling.stop();
      return;
    }
    if (this.selection.selecting) {
      this.exitSelectionMode();
      if (this.focusId.length > 0) {
        FocusManager.get().focus(this.focusId);
      }
      return;
    }
    if (this.focusId.length > 0) {
      FocusManager.get().focus(this.focusId);
    }
    if (event.fingerList.length > 0) {
      const finger = event.fingerList[0];
      const pos = this.gridPosFromPoint(finger.localX, finger.localY);
      this.lastMouseCol1 = pos.col + 1;
      this.lastMouseRow1 = pos.row + 1;
    }
    const mode = this.clickTracker.tap(this.lastMouseRow1 - 1, this.lastMouseCol1 - 1, Date.now());
    if (mode !== 'none' && this.applyClickSelect(mode)) {
      return;
    }
    if (!this.isInputTarget()) {
      return;
    }
    this.requestInput(shouldShowSoftKeyboardOnTouch(this.externalKeyboardActive));
  }

  /**
   * 把输入焦点交给本窗格。自绘编辑器通路：Stack 获焦（物理键）+ attach/show IME；
   * 兜底通路：先把焦点挪到 Stack 再交回隐藏 TextInput——同一输入框重复
   * requestFocus 不会重新弹出用户手动收起的软键盘，挪一次焦点才会。
   */
  private requestInput(showKeyboard: boolean): void {
    if (this.useCustomIme) {
      focusControl.requestFocus(this.hostId);
      const ime: TerminalImeEditor = TerminalImeEditor.get();
      const done: Promise<boolean> = showKeyboard
        ? ime.show(this.schedulerId, this.imeClient)
        : ime.attach(this.schedulerId, this.imeClient, false);
      done.then((ok: boolean) => {
        if (!ok) {
          Logger.warn('自绘编辑器不可用，已切换隐藏输入框兜底', 'Terminal');
        }
      });
      return;
    }
    if (showKeyboard) {
      focusControl.requestFocus(this.hostId);
      setTimeout((): void => {
        focusControl.requestFocus(this.imeSinkId);
      }, 0);
    } else {
      focusControl.requestFocus(this.imeSinkId);
    }
  }

  /** 切换软键盘显隐（页面/键条「键盘」按钮）：外接键盘模式下也能显式唤出 */
  private toggleSoftKeyboard(): void {
    if (this.useCustomIme && TerminalImeEditor.get().isKeyboardShown() &&
      TerminalImeEditor.get().isOwner(this.schedulerId)) {
      TerminalImeEditor.get().hide(this.schedulerId);
      return;
    }
    this.externalKeyboardActive = false;
    if (this.focusId.length > 0) {
      FocusManager.get().focus(this.focusId);
    }
    this.requestInput(true);
  }

  /**
   * 双击/三击 → 应用选区。成功返回 true（消费本次点击，不再走软键盘聚焦）。
   * 网格为当前视口（可能处于回滚中），结果换算回绝对行。
   */
  private applyClickSelect(mode: ClickSelectionMode): boolean {
    const grid = this.makeClickGrid();
    if (grid === null) {
      return false;
    }
    const row = this.lastMouseRow1 - 1;
    const col = this.lastMouseCol1 - 1;
    const range = mode === 'word' ? wordSelectAt(grid, row, col) : lineSelectAt(grid, row);
    if (range === null) {
      return false;
    }
    const top: number = this.viewTopAbs();
    this.selection.setRange({ row: top + range.startRow, col: range.startCol },
      { row: top + range.endRow, col: range.endCol });
    this.selectionUrl = '';
    this.refreshSelectionUrl();
    this.updateSelectionChrome();
    this.forceFullRedraw();
    vibrateLight(this.hapticEnabled);
    return true;
  }

  /**
   * 连点选区网格适配：从当前视口（回滚区 + 主屏拼接）构造 ClickSelectGrid。
   * 宽字符首格 wide=true；续格 codepoint=CLICK_WIDE_CONTINUATION。
   */
  private makeClickGrid(): ClickSelectGrid | null {
    const reader: TerminalAbsReader | null = this.absReader();
    if (reader === null) {
      return null;
    }
    const cols = reader.cols;
    const rows = this.lastGridRows > 0 ? this.lastGridRows : this.layout.rows;
    const top: number = this.viewTopAbs();
    const decoded: ClickSelectCell[] = new Array<ClickSelectCell>(rows * cols);
    for (let r = 0; r < rows; r++) {
      const cells: DecodedCell[] | null = reader.rowCells(top + r);
      for (let c = 0; c < cols; c++) {
        const cell: DecodedCell | null = cells !== null && c < cells.length ? cells[c] : null;
        decoded[r * cols + c] = {
          codepoint: cell === null ? 0 : cell.codepoint,
          wide: cell !== null && (cell.attrs & (1 << 7)) !== 0 // ATTR_WIDE
        };
      }
    }
    return new SnapshotClickGrid(decoded, rows, cols);
  }

  /** 当前帧的绝对行读取器（只读快照；终端未就绪返回 null） */
  private absReader(): TerminalAbsReader | null {
    const terminal = this.terminal;
    if (terminal === null) {
      return null;
    }
    const frame = terminal.beginFrame();
    if (frame === null || frame.cols <= 0) {
      return null;
    }
    return new TerminalAbsReader(terminal, frame);
  }

  /** 视口第 0 行的绝对行号（= scrollbackTotal − scrollOffset） */
  private viewTopAbs(): number {
    const total: number = this.lastScrollbackTotal >= 0 ? this.lastScrollbackTotal : 0;
    return total - this.scrollOffsetLines;
  }

  /**
   * T10：物理键盘事件到达 → 外接键盘策略。
   * 纯策略已单测（PhysicalKeyboard.ets）。设备侧 API 调用点（真机/SDK 可用时）：
   *   import { keyboard } from '@kit.InputKit';
   *   const typeName = keyboardTypeToString(await keyboard.getKeyboardType());
   *   this.externalKeyboardType = typeName;
   *   if (shouldSuppressSoftKeyboard(typeName, true, isModifierKeyCode(keyCode))) {
   *     this.externalKeyboardActive = true;
   *   }
   * 当前实现：宽松策略（物理键非修饰 → externalKeyboardActive=true）；
   * 若 externalKeyboardType 已回填则用严格策略。
   */
  private notePhysicalKeyEvent(keyCode: number): void {
    const isMod = isModifierKeyCode(keyCode);
    const type = this.externalKeyboardTypeName;
    const suppress: boolean = type.length > 0
      ? shouldSuppressSoftKeyboard(type, true, isMod)
      : shouldSuppressSoftKeyboardOnKeyEvent(true, isMod);
    if (suppress && !this.externalKeyboardActive) {
      this.externalKeyboardActive = true;
    }
  }

  /** 供功能键条/设置：用户显式要软键盘时清外接键盘抑制 */
  clearExternalKeyboardActive(): void {
    this.externalKeyboardActive = false;
  }

  /**
   * 设备侧 keyboard.getKeyboardType() 回填点（T10 API）：
   *   import { keyboard } from '@kit.InputKit';
   *   canvas.setExternalKeyboardType(await keyboard.getKeyboardType());
   * 类型为物理键盘时同步置 externalKeyboardActive。
   */
  setExternalKeyboardType(ohosKeyboardType: number): void {
    this.externalKeyboardTypeName = keyboardTypeToString(ohosKeyboardType);
    if (isPhysicalKeyboardTypeName(this.externalKeyboardTypeName)) {
      this.externalKeyboardActive = true;
    }
  }

  /** 当前是否因外接键盘抑制软键盘（UI/诊断） */
  isExternalKeyboardActive(): boolean {
    return this.externalKeyboardActive;
  }

  /**
   * T11：鼠标事件 → SGR 上报（frame.mouseMode 指示时）。
   * 纯编码 encodeSgrMouseEvent / sgrButtonFromOhosButton 已单测。
   *
   * ArkUI MouseEvent 接线（本组件 build 中 .onMouse）：
   *   - action=PRESS/RELEASE/MOVE → encodeSgrMouseEvent → sendInputBytes；
   *   - 滚轮：部分 API 版本 MouseEvent 无 wheel 字段，走触控板/触摸 pan 的
   *     buildAltScrollSequences('mouse', ...) 已覆盖；若设备侧补上
   *     event.wheelDelta，可在 onWheel 上调 encodeSgrWheel（TODO 调用点）。
   *   - mouseMode=0 时完全不转发（本地选择/滚动语义不变）。
   */
  private onMouseEventReport(action: string, ohosButton: number, localX: number,
    localY: number): boolean {
    if (!this.mouseReportingActive || !this.isInputTarget()) {
      return false;
    }
    const pos = this.gridPosFromPoint(localX, localY);
    const col1 = pos.col + 1;
    const row1 = pos.row + 1;
    this.lastMouseCol1 = col1;
    this.lastMouseRow1 = row1;
    const button = sgrButtonFromOhosButton(ohosButton);
    let kind: 'press' | 'move' | 'release' = 'move';
    if (action === 'Down' || action === 'press' || action === 'PRESS') {
      kind = 'press';
      this.lastSgrButton = button;
    } else if (action === 'Up' || action === 'release' || action === 'RELEASE') {
      kind = 'release';
    } else {
      kind = 'move';
    }
    const effectiveButton = kind === 'move'
      ? (this.lastSgrButton !== SGR_BUTTON_NONE ? this.lastSgrButton : button)
      : button;
    if (!shouldForwardMouseEvent(this.lastMouseMode, kind, effectiveButton)) {
      return false;
    }
    const seq = encodeSgrMouseEvent(effectiveButton, kind, col1, row1);
    if (kind === 'release') {
      this.lastSgrButton = SGR_BUTTON_NONE;
    }
    if (seq === null) {
      return false;
    }
    this.sendInputBytes(seq);
    return true;
  }

  /** 写终端输入：Uint8Array → 零偏移全量 ArrayBuffer（writeTerminal 接受 ArrayBuffer | string） */
  private sendInputBytes(bytes: Uint8Array): void {
    const terminal = this.terminal;
    if (terminal === null || bytes.length === 0) {
      return;
    }
    this.noteUserInput();
    const accepted: boolean =
      terminal.write(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    if (!accepted) {
      Logger.warn(`终端输入未被通道受理（bytes=${bytes.length}）`, 'Terminal');
    }
  }

  /** 写终端文本（粘贴出口；已由 preparePasteText 处理换行与 2004 包裹） */
  private sendInputText(text: string): void {
    const terminal = this.terminal;
    if (terminal === null || text.length === 0) {
      return;
    }
    this.noteUserInput();
    if (!terminal.write(text)) {
      Logger.warn(`粘贴内容未被通道受理（chars=${text.length}）`, 'Terminal');
    }
  }

  /**
   * 任何用户输入的共同副作用：回到底部（看得到回显）、闪烁相位归零（打字时光标
   * 常亮）、预热 displaySync（回显到达时直接赶上下一帧，避免从休眠启动的迟滞）。
   */
  private noteUserInput(): void {
    if (this.scrollOffsetLines > 0) {
      this.scrollToBottom();
    }
    this.fling.stop();
    this.blinkEpoch = Date.now();
    FrameScheduler.get().wakeup();
    this.onUserInput();
  }

  /** 粘贴系统剪贴板：远端开了 bracketed paste 自动包裹，未开且多行时先确认 */
  private pasteClipboard(): void {
    if (this.terminal === null) {
      return;
    }
    pasteFromPasteboard((text: string): void => {
      this.sendInputText(text);
    }, this.frameBracketedPaste).catch((err: Object) => {
      Logger.warn(`粘贴失败：${JSON.stringify(err)}`, 'Terminal');
    });
  }

  /** 当前终端的 DECCKM（以 native 帧为准；旧 native 无该字段时退回 @Prop） */
  private appCursorKeys(): boolean {
    return this.frameAppCursorKnown ? this.frameAppCursor : this.applicationCursorKeys;
  }

  /**
   * 物理键盘统一出口（onKeyEvent 与 onKeyPreIme 共用；T10 扩展点，勿开旁路）。
   *
   * @param preIme true = IME 前拦截（onKeyPreIme）：按 shouldInterceptBeforeIme
   *   决定是否截获（候选中一律放行；Ctrl/Alt 组合截获；自绘编辑器通路其余键先给
   *   输入法；兜底 TextInput 通路截非可打印键）；false = 输入法不消费后的全量通路。
   * @returns true = 已消费（不再进 IME/不再冒泡）
   */
  private handleKeyInput(event: KeyEvent, preIme: boolean): boolean {
    if (event.type !== KeyType.Down) {
      return false; // 只处理按下；弹起不重复发送
    }
    if (isModifierKeyCode(event.keyCode)) {
      return false; // 修饰键自身放行（组合状态由系统跟踪，不产生字节）
    }
    // T10：物理键到达 → 外接键盘策略（抑制软键盘；见 notePhysicalKeyEvent 头注）
    this.notePhysicalKeyEvent(event.keyCode);
    const ctrl = this.queryModifierState(event, 'ctrl');
    const alt = this.queryModifierState(event, 'alt');
    const shift = this.queryModifierState(event, 'shift');
    const meta = this.queryModifierState(event, 'meta');
    if (preIme && !shouldInterceptBeforeIme(this.useCustomIme, false, ctrl, alt,
      isPrintableKeyCode(event.keyCode))) {
      return false;
    }
    if (!this.isInputTarget()) {
      return false; // 非聚焦窗格：物理输入不投递（路由验收标准）
    }
    const action: ShortcutAction | null =
      matchShortcut(this.shortcutBindings, event.keyCode, ctrl, alt, shift, meta);
    if (action !== null) {
      return this.dispatchShortcut(action);
    }
    const snap = this.stickyModifiers.snapshot();
    const mapped = mapKeyEvent(event.keyCode, shift,
      alt || snap.alt, ctrl || snap.ctrl, false, this.appCursorKeys());
    if (mapped === null) {
      return false; // 未映射键放行系统默认处理
    }
    this.sendInputBytes(mapped);
    this.stickyModifiers.consume(); // 一次性粘滞用完复位（locked 保持）
    return true;
  }

  /** 快捷键分发：复制/粘贴留在画布，其余交给页面 */
  private dispatchShortcut(action: ShortcutAction): boolean {
    if (action === 'copy') {
      this.copySelection();
      return true;
    }
    if (action === 'paste') {
      this.pasteClipboard();
      return true;
    }
    return this.onAppShortcut(action);
  }

  /**
   * 硬件修饰状态查询。KeyEvent.getModifierKeyState 在 SDK 声明中为可选方法
   * （KeyEvent 只接受大小写敏感的 'Ctrl'|'Alt'|'Shift'；Meta 不在支持列表）。
   * 参数非法会同步抛 BusinessError 401，因此必须兜底，不能让一次按键终止应用。
   */
  private queryModifierState(event: KeyEvent, name: string): boolean {
    if (event.getModifierKeyState === undefined || name === 'meta') {
      return false;
    }
    let apiName: string = '';
    switch (name) {
      case 'ctrl':
        apiName = 'Ctrl';
        break;
      case 'alt':
        apiName = 'Alt';
        break;
      case 'shift':
        apiName = 'Shift';
        break;
      default:
        return false;
    }
    try {
      return event.getModifierKeyState([apiName]);
    } catch (_err) {
      // API 12+ 声明为可选，部分输入源/系统版本仍可能拒绝查询；退化为无修饰。
      return false;
    }
  }

  /**
   * 兜底通路（隐藏 TextInput）提交出口：增量 + 粘滞快照 → 字节 → write()；每次提交
   * 都消费一次性粘滞（「下一个按键带修饰」以按键/提交计，见 StickyModifiers 头注）。
   */
  private onImeDelta = (delta: CommittedDelta): void => {
    if (!this.isInputTarget()) {
      return;
    }
    const snap = this.stickyModifiers.snapshot();
    const bytes = committedDeltaToInputBytes(delta, snap);
    this.stickyModifiers.consume();
    if (bytes !== null) {
      this.sendInputBytes(bytes);
    }
  }

  /** 兜底通路软键盘回车 */
  private onImeEnter = (): void => {
    if (!this.isInputTarget()) {
      return;
    }
    this.stickyModifiers.consume();
    this.sendInputBytes(imeEnterBytes());
  }

  private onImeInterceptKey = (event: KeyEvent): boolean => {
    return this.handleKeyInput(event, true);
  }

  /** 自绘编辑器事件入口（CanvasImeClient 统一投递） */
  private onImeEvent(kind: ImeEventKind, text: string, value: number): void {
    if (kind === 'keyboard') {
      return; // 软键盘显隐：目前无需额外处理（状态由 TerminalImeEditor 记录）
    }
    if (kind === 'selectAll') {
      this.selectAllBuffer();
      return;
    }
    if (kind === 'copy') {
      this.copySelection();
      return;
    }
    if (kind === 'paste') {
      this.pasteClipboard();
      return;
    }
    if (!this.isInputTarget()) {
      return;
    }
    const snap = this.stickyModifiers.snapshot();
    let bytes: Uint8Array | null = null;
    switch (kind) {
      case 'insert':
        bytes = imeInsertToBytes(text, snap);
        this.imeEcho.insert(text);
        break;
      case 'deleteLeft':
        bytes = imeDeleteLeftToBytes(value, snap);
        this.imeEcho.deleteLeft(value);
        break;
      case 'deleteRight':
        bytes = imeDeleteRightToBytes(value);
        break;
      case 'enter':
        bytes = imeEnterBytes();
        this.imeEcho.clear();
        break;
      case 'move':
        bytes = imeMoveCursorToBytes(value, this.appCursorKeys());
        break;
      default:
        break;
    }
    this.stickyModifiers.consume();
    if (bytes !== null) {
      this.sendInputBytes(bytes);
    }
  }

  /**
   * T9 回滚视图整窗重绘（scrollOffsetLines > 0 时）：视口 = 绝对行
   * [scrollbackTotal − scrollOffset, +rows)，回滚段经 readScrollbackWindow 取历史行
   * 拼在视口上方，主屏段取主屏 [0, rows − sbCount) 拼在下方。远端新输出时
   * renderFrame 先按 anchorScrollOffset 同步增大 offset，视口内容保持不动。
   */
  private paintScrolledWindow(frame: NativeTerminalFrame): void {
    const ctx = this.context;
    this.invalidateCtxStyleCache();
    ctx.fillStyle = this.backgroundArgb;
    ctx.fillRect(0, 0, this.areaWidthVp, this.areaHeightVp);
    const terminal = this.terminal;
    if (terminal === null) {
      return;
    }
    const env = this.renderEnv();
    const sbCount = Math.min(this.scrollOffsetLines, frame.rows);
    const mainCount = frame.rows - sbCount;
    if (sbCount > 0) {
      const topAbs = frame.scrollbackTotal - this.scrollOffsetLines;
      const buf = terminal.readScrollbackWindow(topAbs, sbCount);
      if (buf !== null) {
        this.execCommands(generateRowsCommands(new DataView(buf), 0, sbCount, frame.cols, env));
      }
    }
    if (mainCount > 0) {
      const view = terminal.readRows(frame, 0, mainCount);
      if (view !== null) {
        this.execCommands(generateRowsCommands(view, sbCount, mainCount, frame.cols, env));
      }
    }
  }

  /**
   * T8 选区高亮：selectionColor 半透明叠加层（画在行内容之后）。选区是绝对行，
   * 这里只画落在当前视口内的部分；宽字符边界修正复用 adjustWideCharBoundary
   * （只读取起止两行），选区/revision/视口不变时复用上次结果。
   */
  private paintSelectionOverlay(frame: NativeTerminalFrame): void {
    const raw = this.selection.range();
    const terminal = this.terminal;
    if (raw === null || terminal === null) {
      return;
    }
    const key = `${raw.startRow},${raw.startCol},${raw.endRow},${raw.endCol}|${frame.revision}|` +
      `${frame.rows}x${frame.cols}|${frame.scrollbackTotal}`;
    let range = this.selAdjusted;
    if (key !== this.selAdjustKey || range === null) {
      range = adjustWideCharBoundary(new TerminalAbsReader(terminal, frame), raw);
      this.selAdjustKey = key;
      this.selAdjusted = range;
    }
    const topAbs: number = frame.scrollbackTotal - this.scrollOffsetLines;
    const firstAbs: number = Math.max(range.startRow, topAbs);
    const lastAbs: number = Math.min(range.endRow, topAbs + frame.rows - 1);
    if (firstAbs > lastAbs) {
      return;
    }
    const ctx = this.context;
    const env = this.renderEnv();
    // 一次遍历：填充各行，同时收集每行 [lo, hi] 供外轮廓描边
    const los: number[] = [];
    const his: number[] = [];
    this.invalidateCtxStyleCache();
    ctx.fillStyle = withOpacity(this.selectionArgb, SELECTION_OVERLAY_OPACITY);
    for (let abs = firstAbs; abs <= lastAbs; abs++) {
      const r: number = abs - topAbs;
      const lo = abs === range.startRow ? range.startCol : 0;
      const hi = Math.min(abs === range.endRow ? range.endCol : frame.cols - 1, frame.cols - 1);
      los.push(lo);
      his.push(hi);
      if (hi >= lo) {
        const x0: number = cellLeftX(env, lo);
        const y0: number = cellTopY(env, r);
        ctx.fillRect(x0, y0, cellLeftX(env, hi + 1) - x0, cellTopY(env, r + 1) - y0);
      }
    }
    // 只描整体外轮廓：每行左右竖边 + 与上/下一行不重叠部分的横边
    ctx.strokeStyle = this.cursorArgb;
    ctx.lineWidth = SELECTION_BORDER_VP;
    ctx.beginPath();
    const n = los.length;
    const firstRow: number = firstAbs - topAbs;
    for (let i = 0; i < n; i++) {
      const lo = los[i];
      const hi = his[i];
      if (hi < lo) {
        continue;
      }
      const y0 = cellTopY(env, firstRow + i);
      const y1 = cellTopY(env, firstRow + i + 1);
      const x0 = cellLeftX(env, lo);
      const x1 = cellLeftX(env, hi + 1);
      ctx.moveTo(x0, y0);
      ctx.lineTo(x0, y1);
      ctx.moveTo(x1, y0);
      ctx.lineTo(x1, y1);
      this.strokeEdgeOutside(i > 0 ? los[i - 1] : 0, i > 0 ? his[i - 1] : -1, lo, hi, y0, env);
      this.strokeEdgeOutside(i + 1 < n ? los[i + 1] : 0, i + 1 < n ? his[i + 1] : -1, lo, hi, y1, env);
    }
    ctx.stroke();
  }

  /** 横边：本行 [lo,hi] 中不被相邻行 [nlo,nhi] 覆盖的区段（nhi<nlo 表示无相邻行） */
  private strokeEdgeOutside(nlo: number, nhi: number, lo: number, hi: number, y: number,
    env: RowRenderEnv): void {
    const ctx = this.context;
    if (nhi < nlo || nhi < lo || nlo > hi) {
      ctx.moveTo(cellLeftX(env, lo), y);
      ctx.lineTo(cellLeftX(env, hi + 1), y);
      return;
    }
    if (nlo > lo) {
      ctx.moveTo(cellLeftX(env, lo), y);
      ctx.lineTo(cellLeftX(env, nlo), y);
    }
    if (nhi < hi) {
      ctx.moveTo(cellLeftX(env, nhi + 1), y);
      ctx.lineTo(cellLeftX(env, hi + 1), y);
    }
  }

  // ---------------------------------------------------------------- T8 选择模式

  /** 像素点 → 视口网格坐标（钳到当前帧网格内；度量未完成时给 (0,0)） */
  private gridPosFromPoint(x: number, y: number): CellPos {
    const cols = this.lastGridCols > 0 ? this.lastGridCols : this.layout.cols;
    const rows = this.lastGridRows > 0 ? this.lastGridRows : this.layout.rows;
    if (this.cellWidthVp <= 0 || this.cellHeightVp <= 0) {
      return { row: 0, col: 0 };
    }
    const col = Math.floor((x - this.layout.originX) / this.cellWidthVp);
    const row = Math.floor((y - this.layout.originY) / this.cellHeightVp);
    return {
      row: Math.min(Math.max(row, 0), rows - 1),
      col: Math.min(Math.max(col, 0), cols - 1)
    };
  }

  /** 像素点 → 绝对行坐标（选区坐标系：回滚区 + 主屏统一编号） */
  private absPosFromPoint(x: number, y: number): CellPos {
    const pos: CellPos = this.gridPosFromPoint(x, y);
    return { row: this.viewTopAbs() + pos.row, col: pos.col };
  }

  /** 长按进入选择模式（回滚中同样可用）；落在链接上直接选中整条链接 */
  private onLongPressSelect(event: GestureEvent): void {
    if (this.terminal === null || event.fingerList.length === 0) {
      return;
    }
    this.fling.stop();
    const finger = event.fingerList[0];
    const pos: CellPos = this.absPosFromPoint(finger.localX, finger.localY);
    if (!this.trySelectUrlAt(pos)) {
      this.selection.begin(pos);
      this.selectionUrl = '';
    }
    this.updateSelectionChrome();
    this.forceFullRedraw();
    vibrateLight(this.hapticEnabled);
  }

  /** pos 处若是链接（含软换行折到下一行的长链接）则选中整条，返回是否命中 */
  private trySelectUrlAt(pos: CellPos): boolean {
    const reader: TerminalAbsReader | null = this.absReader();
    if (reader === null) {
      return false;
    }
    const line: LogicalLine = logicalLineAt(reader, pos.row, reader.minRow);
    let index: number = -1;
    for (let i = 0; i < line.positions.length; i++) {
      const p: CellPos = line.positions[i];
      // 宽字符续格没有对应文本单元：落在续格时匹配其首格（col − 1）
      if (p.row === pos.row && (p.col === pos.col || p.col === pos.col - 1)) {
        index = i;
        if (p.col === pos.col) {
          break;
        }
      }
    }
    if (index < 0) {
      return false;
    }
    const url: UrlMatch | null = urlAt(line.text, index);
    if (url === null || url.end - 1 >= line.positions.length) {
      return false;
    }
    this.selection.setRange(line.positions[url.start], line.positions[url.end - 1]);
    this.selectionUrl = openableUrl(url.text);
    return true;
  }

  /** 选区变化后（拖动结束/连点）判断选中内容是否恰好是一个链接（只看 ≤3 行的小选区） */
  private refreshSelectionUrl(): void {
    const range: SelectionRange | null = this.selection.range();
    if (range === null || range.endRow - range.startRow > 2) {
      this.selectionUrl = '';
      return;
    }
    const reader: TerminalAbsReader | null = this.absReader();
    if (reader === null) {
      this.selectionUrl = '';
      return;
    }
    this.selectionUrl = singleUrlIn(extractRangeText(reader, adjustWideCharBoundary(reader, range)));
  }

  /** 退出选择模式并清掉高亮/菜单（复制完成、点击他处、换绑终端时调用） */
  private exitSelectionMode(): void {
    this.stopEdgeScroll();
    if (!this.selection.selecting && !this.selectionMenuVisible) {
      return;
    }
    this.selection.cancel();
    this.selectionMenuVisible = false;
    this.selectionHandlesVisible = false;
    this.selectionUrl = '';
    this.lastHandleGeo = null;
    this.draggingHandle = '';
    this.selAdjusted = null;
    this.selAdjustKey = '';
    this.forceFullRedraw(); // 重绘覆盖掉高亮叠加层
  }

  /** 气泡菜单「复制」：取选区文本（软换行感知）→ 写系统剪贴板 → 轻震 + 提示 → 退出选择 */
  private copySelection(): void {
    const range: SelectionRange | null = this.selection.range();
    const reader: TerminalAbsReader | null = this.absReader();
    if (range === null || reader === null) {
      return;
    }
    const text = extractRangeText(reader, adjustWideCharBoundary(reader, range));
    this.exitSelectionMode();
    if (text.length === 0) {
      return;
    }
    copyTextToPasteboard(text)
      .then((ok) => {
        if (ok) {
          vibrateLight(this.hapticEnabled);
          this.showToast(text.length > 1 ? `已复制 ${text.length} 个字符` : '已复制');
        } else {
          this.showToast('复制失败');
        }
      })
      .catch((err: Object) => {
        Logger.warn(`复制到剪贴板异常：${JSON.stringify(err)}`, 'Terminal');
      });
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (err) {
      Logger.warn(`Toast 显示失败：${JSON.stringify(err)}`, 'Terminal');
    }
  }

  /** 气泡菜单「打开链接」：交给系统浏览器 */
  private openSelectionUrl(): void {
    const url: string = this.selectionUrl;
    this.exitSelectionMode();
    if (url.length === 0) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.openLink(url).catch((err: Object) => {
        Logger.warn(`打开链接失败：${JSON.stringify(err)}`, 'Terminal');
        this.showToast('无法打开链接');
      });
    } catch (err) {
      Logger.warn(`打开链接异常：${JSON.stringify(err)}`, 'Terminal');
      this.showToast('无法打开链接');
    }
  }

  /** 气泡菜单「粘贴」：退出选择后粘贴 */
  private pasteFromMenu(): void {
    this.exitSelectionMode();
    this.pasteClipboard();
  }

  /** 「全选」：整个缓冲（最旧回滚行 → 主屏末行） */
  private selectAllBuffer(): void {
    const rows = this.lastGridRows > 0 ? this.lastGridRows : this.layout.rows;
    const cols = this.lastGridCols > 0 ? this.lastGridCols : this.layout.cols;
    const total: number = Math.max(0, this.lastScrollbackTotal);
    const oldest: number = Math.min(this.lastScrollbackOldest, total);
    this.selection.selectAll(total - oldest + rows, cols, oldest);
    this.selectionUrl = '';
    this.updateSelectionChrome();
    this.forceFullRedraw();
  }

  /** 气泡菜单 + 两端手柄一起刷新（视口滚动后也要调：位置是视口坐标）。 */
  private updateSelectionChrome(): void {
    this.updateSelectionMenuPosition();
    this.updateSelectionHandles();
  }

  /** 菜单项个数（宽度计算用）：复制/粘贴/全选 + 可选「打开链接」 */
  private menuItemCount(): number {
    return this.selectionUrl.length > 0 ? 4 : 3;
  }

  /**
   * 气泡菜单位置：选区起点上方；起点不在视口内或顶部放不下时放到选区下方，
   * 仍放不下则贴视口顶部（钳制在视口内）。
   */
  private updateSelectionMenuPosition(): void {
    const range: SelectionRange | null = this.selection.range();
    if (range === null) {
      this.selectionMenuVisible = false;
      return;
    }
    const top: number = this.viewTopAbs();
    const rows: number = this.lastGridRows > 0 ? this.lastGridRows : this.layout.rows;
    const menuWidth: number = this.menuItemCount() * MENU_ITEM_WIDTH_VP + MENU_SIDE_PADDING_VP * 2;
    const startView: number = range.startRow - top;
    const endView: number = range.endRow - top;
    const x = this.layout.originX + Math.max(0, startView >= 0 ? range.startCol : 0) * this.cellWidthVp;
    const maxX = Math.max(0, this.areaWidthVp - menuWidth);
    this.selectionMenuX = Math.min(Math.max(x, 0), maxX);
    let y: number = this.layout.originY + startView * this.cellHeightVp - MENU_HEIGHT_VP - MENU_GAP_VP -
      HANDLE_KNOB_VP / 2;
    if (startView < 0 || y < 0) {
      const below: number = this.layout.originY + (Math.min(endView, rows - 1) + 1) * this.cellHeightVp +
        MENU_GAP_VP + HANDLE_KNOB_VP;
      y = below + MENU_HEIGHT_VP <= this.areaHeightVp ? below : 0;
    }
    this.selectionMenuY = Math.min(Math.max(y, 0), Math.max(0, this.areaHeightVp - MENU_HEIGHT_VP));
    this.selectionMenuVisible = true;
  }

  /**
   * 起点手柄贴第一格左边、终点手柄贴末格右边，竖条与行等高；端点滚出视口时
   * 对应手柄移到视口外（不可见也不可拖）。几何由纯函数 selectionHandleHitRects 计算。
   */
  private updateSelectionHandles(): void {
    const range: SelectionRange | null = this.selection.range();
    if (range === null || this.cellWidthVp <= 0 || this.cellHeightVp <= 0) {
      this.selectionHandlesVisible = false;
      this.lastHandleGeo = null;
      return;
    }
    const top: number = this.viewTopAbs();
    const rows: number = this.lastGridRows > 0 ? this.lastGridRows : this.layout.rows;
    const barH: number = this.cellHeightVp;
    this.handleBarHeight = barH;
    const geo = selectionHandleHitRects(
      this.layout.originX, this.layout.originY,
      this.cellWidthVp, this.cellHeightVp,
      range.startRow - top, range.startCol, range.endRow - top, range.endCol,
      barH, HANDLE_HIT_WIDTH_VP, HANDLE_KNOB_VP);
    const startInView: boolean = range.startRow - top >= 0 && range.startRow - top < rows;
    const endInView: boolean = range.endRow - top >= 0 && range.endRow - top < rows;
    if (!startInView) {
      geo.start.x = -10000;
      geo.start.y = -10000;
    }
    if (!endInView) {
      geo.end.x = -10000;
      geo.end.y = -10000;
    }
    this.lastHandleGeo = geo;
    this.startHandleX = geo.start.x;
    this.startHandleY = geo.start.y;
    this.endHandleX = geo.end.x;
    this.endHandleY = geo.end.y;
    this.selectionHandlesVisible = true;
  }

  /** 画布坐标 → 命中手柄（纯函数 selectionHandleAtPoint；未在选择模式返回 none） */
  private handleIdAtPoint(x: number, y: number): SelectionHandleId {
    if (!this.selectionHandlesVisible || this.lastHandleGeo === null) {
      return 'none';
    }
    return selectionHandleAtPoint(x, y, this.lastHandleGeo);
  }

  private beginHandleDrag(which: string): void {
    const range: SelectionRange | null = this.selection.range();
    if (range === null) {
      return;
    }
    this.draggingHandle = which;
    // 拖动 origin = 端点格中心（纯函数 selectionHandleAnchor）：起拖瞬间端点不跳
    const top: number = this.viewTopAbs();
    const anchor = selectionHandleAnchor(
      which === 'start' ? 'start' : 'end',
      this.layout.originX, this.layout.originY,
      this.cellWidthVp, this.cellHeightVp,
      (which === 'start' ? range.startRow : range.endRow) - top,
      which === 'start' ? range.startCol : range.endCol,
      HANDLE_HIT_WIDTH_VP);
    this.handleDragOriginX = anchor.x;
    this.handleDragOriginY = anchor.y;
  }

  private onHandleDrag(event: GestureEvent): void {
    if (this.draggingHandle.length === 0) {
      return;
    }
    const x: number = this.handleDragOriginX + event.offsetX;
    const y: number = this.handleDragOriginY + event.offsetY;
    this.applyDragPoint(this.draggingHandle, x, y);
    this.updateEdgeScroll(this.draggingHandle, x, y);
  }

  private endHandleDrag(): void {
    this.draggingHandle = '';
    this.stopEdgeScroll();
    this.refreshSelectionUrl();
    this.updateSelectionChrome();
  }

  /** 拖动点 → 选区端点（target：extend 活动端 / start / end 手柄） */
  private applyDragPoint(target: string, x: number, y: number): void {
    const pos: CellPos = this.absPosFromPoint(x, y);
    if (target === 'start') {
      this.selection.moveStart(pos);
      // moveStart 会把锚点换成原终点：之后继续拖动的是新的活动端
    } else if (target === 'end') {
      this.selection.moveEnd(pos);
    } else {
      this.selection.extend(pos);
    }
    this.updateSelectionChrome();
    this.forceFullRedraw();
  }

  /** 拖动点贴近视口上/下边缘时启动自动滚动，离开边缘停止 */
  private updateEdgeScroll(target: string, x: number, y: number): void {
    this.edgeDragTarget = target;
    this.edgeDragX = x;
    this.edgeDragY = y;
    this.edgeScrollLines = edgeAutoScrollLines(y, 0, this.areaHeightVp, EDGE_SCROLL_BAND_VP,
      EDGE_SCROLL_MAX_LINES);
    if (this.edgeScrollLines === 0) {
      this.stopEdgeScroll();
      return;
    }
    if (this.edgeScrollTimer >= 0) {
      return;
    }
    this.edgeScrollTimer = setInterval((): void => {
      if (this.edgeScrollLines === 0 || !this.selection.selecting) {
        this.stopEdgeScroll();
        return;
      }
      // 负 = 手指在顶部 → 看更旧内容（offset 增大）
      this.setScrollOffset(this.scrollOffsetLines - this.edgeScrollLines);
      // 端点跟随：moveStart/moveEnd 之后锚点已固定，继续用 extend 更新活动端
      this.applyDragPoint('extend', this.edgeDragX, this.edgeDragY);
    }, EDGE_SCROLL_INTERVAL_MS);
  }

  private stopEdgeScroll(): void {
    if (this.edgeScrollTimer >= 0) {
      clearInterval(this.edgeScrollTimer);
      this.edgeScrollTimer = -1;
    }
    this.edgeScrollLines = 0;
  }

  // ---------------------------------------------------------------- T9 手势

  /**
   * 单指拖动主处理：选择模式中 = 更新活动端（贴边自动滚动）；否则竖向滚动
   * （主屏 = 视图回滚；alt-screen = 方向键/滚轮序列，见 handleVerticalPan）。
   * 两指及以上的移动属于捏合，忽略（避免先落下的手指把画面拖走）。
   */
  private onPanUpdate(event: GestureEvent): void {
    if (event.fingerList.length >= 2) {
      return;
    }
    if (this.selection.selecting) {
      if (event.fingerList.length > 0) {
        const finger = event.fingerList[0];
        // T8 打磨：落点在手柄热区时不更新活动端（手柄自身 PanGesture 接管拖动）
        if (this.handleIdAtPoint(finger.localX, finger.localY) !== 'none') {
          return;
        }
        this.applyDragPoint('extend', finger.localX, finger.localY);
        this.updateEdgeScroll('extend', finger.localX, finger.localY);
      }
      return;
    }
    const deltaY = event.offsetY - this.panLastOffsetY;
    this.panLastOffsetY = event.offsetY;
    this.handleVerticalPan(deltaY, event);
  }

  /** 拖动结束：选择模式收尾；视图滚动按松手速度起飞惯性 */
  private onPanEnd(event: GestureEvent): void {
    this.scrollAccumulator.reset();
    if (this.selection.selecting) {
      this.stopEdgeScroll();
      this.refreshSelectionUrl();
      this.updateSelectionChrome();
      return;
    }
    if (this.lastAltScreen && this.altScrollMode !== 'view') {
      return; // alt-screen 发键模式不做惯性（避免甩一下发出几十个方向键）
    }
    this.flingAccumulator.reset();
    if (this.fling.start(event.velocityY, Date.now())) {
      FrameScheduler.get().wakeup();
    }
  }

  /**
   * 竖向拖动 → 滚动语义。内容跟手方向：手指下滑（deltaY>0）看旧内容
   * （回滚偏移增大 / 发上滚序列），手指上滑看新内容。
   */
  private handleVerticalPan(deltaYPx: number, event: GestureEvent): void {
    const lines = this.scrollAccumulator.push(deltaYPx, this.cellHeightVp);
    if (lines === 0) {
      return;
    }
    if (this.lastAltScreen && this.altScrollMode !== 'view') {
      // alt-screen（vim/less 无回滚缓冲）：映射为方向键或 SGR 滚轮序列。
      // 发送按焦点路由——非聚焦窗格的滑动只滚自己的视图，不投递字节
      if (!this.isInputTarget()) {
        return;
      }
      let col1 = 1;
      let row1 = 1;
      if (event.fingerList.length > 0) {
        const finger = event.fingerList[0];
        const pos = this.gridPosFromPoint(finger.localX, finger.localY);
        col1 = pos.col + 1;
        row1 = pos.row + 1;
      }
      const seqs = buildAltScrollSequences(this.altScrollMode, this.lastMouseMode, lines,
        col1, row1, this.appCursorKeys());
      for (const seq of seqs) {
        this.sendScrollSequence(seq);
      }
      return;
    }
    // 主屏：视图滚动回滚缓冲（整窗重绘在 renderFrame 的 paintScrolledWindow）
    this.setScrollOffset(this.scrollOffsetLines + lines);
  }

  /** alt-screen 滚动序列：写终端但不算「用户输入」（不触发回到底部/回调） */
  private sendScrollSequence(bytes: Uint8Array): void {
    const terminal = this.terminal;
    if (terminal === null || bytes.length === 0) {
      return;
    }
    FrameScheduler.get().wakeup();
    terminal.write(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  }

  /**
   * 设置回滚偏移（钳制到 [0, 可回滚行数]）：变化时整窗重绘；跨越 0 时切换
   * 「回到底部」按钮；回到底部清「新输出」角标；选择模式下同步手柄/菜单位置。
   * 返回是否真的变化。
   */
  private setScrollOffset(lines: number): boolean {
    const next = clampScrollOffset(lines, this.lastScrollbackCount);
    if (next === this.scrollOffsetLines) {
      return false;
    }
    this.scrollOffsetLines = next;
    this.needsFullRedraw = true;
    const back: boolean = next > 0;
    if (back !== this.scrolledBack) {
      this.scrolledBack = back;
    }
    if (!back && this.newOutputBadge) {
      this.newOutputBadge = false;
    }
    if (this.selection.selecting) {
      this.updateSelectionChrome();
    }
    FrameScheduler.get().wakeup();
    return true;
  }

  /** 回到最新输出（「回到底部」按钮 / 任何输入） */
  private scrollToBottom(): void {
    this.fling.stop();
    this.setScrollOffset(0);
  }

  /** 惯性一帧：位移换算整行后滚动；到顶/到底即停 */
  private stepFling(now: number): void {
    const dy: number = this.fling.step(now);
    if (dy === 0) {
      return;
    }
    const lines: number = this.flingAccumulator.push(dy, this.cellHeightVp);
    if (lines === 0) {
      return;
    }
    if (!this.setScrollOffset(this.scrollOffsetLines + lines)) {
      this.fling.stop(); // 撞到边界
    }
  }

  /** 捏合开始：记录起始字号，停止惯性，进入预览 */
  private onPinchStart(): void {
    this.fling.stop();
    this.pinchBaseFontSize = this.appearance.fontSize;
    this.pinchLastScale = 1;
    this.pinchScale = 1;
    this.pinchLabel = `${Math.round(this.pinchBaseFontSize)}`;
  }

  /**
   * 捏合过程只做画面缩放预览 + 字号标签：不重测字体、不重排、不发 PTY resize
   * （旧实现每一步都 applyAppearance，远端在捏合期间收到几十次 SIGWINCH）。
   */
  private onPinchUpdate(event: GestureEvent): void {
    this.pinchLastScale = event.scale;
    this.pinchScale = pinchPreviewScale(this.pinchBaseFontSize, event.scale);
    this.pinchLabel = `${pinchCommitFontSize(this.pinchBaseFontSize, event.scale)}`;
  }

  /** 捏合松手：按最终字号重排一次，并经回调交给页面持久化 */
  private onPinchEnd(): void {
    const next: number = pinchCommitFontSize(this.pinchBaseFontSize, this.pinchLastScale);
    this.pinchScale = 1;
    this.pinchLabel = '';
    if (next !== this.appearance.fontSize) {
      this.appearance.fontSize = next;
      this.applyAppearance();
      this.onFontSizeCommit(next);
    }
  }

  private onPinchCancel(): void {
    this.pinchScale = 1;
    this.pinchLabel = '';
  }

  /** 视觉响铃：叠一层前景色薄膜闪一下 */
  private flashBell(): void {
    if (!this.visible) {
      return;
    }
    if (this.bellFlashTimer >= 0) {
      clearTimeout(this.bellFlashTimer);
    }
    this.bellFlashOpacity = BELL_FLASH_OPACITY;
    this.bellFlashTimer = setTimeout((): void => {
      this.bellFlashTimer = -1;
      this.bellFlashOpacity = 0;
    }, BELL_FLASH_MS);
  }

  // ---------------------------------------------------------------- 帧流程

  /** 有效光标闪烁：DECSCUSR 覆盖优先，其次外观设置；非聚焦/不可见窗格不闪 */
  private effectiveCursorBlink(): boolean {
    if (!this.paneFocused || !this.visible) {
      return false;
    }
    if (this.frameCursorBlink === 0) {
      return false;
    }
    if (this.frameCursorBlink === 1) {
      return true;
    }
    return this.appearance.cursorBlink;
  }

  /** 有效光标形状：DECSCUSR 覆盖优先（1 block / 2 underline / 3 bar），其次外观设置 */
  private effectiveCursorStyle(): CursorStyle {
    switch (this.frameCursorShape) {
      case 1:
        return 'block';
      case 2:
        return 'underline';
      case 3:
        return 'bar';
      default:
        return this.appearance.cursorStyle;
    }
  }

  /**
   * 帧元信息入账（每次 beginFrame 后）：alt-screen/鼠标上报/DECCKM/2004/DECSCUSR，
   * 回滚视口锚定（远端输出不推走正在看的历史）、「新输出」角标、epoch 变化时作废选区。
   */
  private ingestFrame(frame: NativeTerminalFrame): void {
    this.lastAltScreen = frame.altScreen;
    this.lastMouseMode = frame.mouseMode;
    this.mouseReportingActive = frame.mouseMode !== 0;
    this.lastFrameCursorVisible = frame.cursorVisible;
    if (frame.applicationCursorKeys !== undefined) {
      this.frameAppCursorKnown = true;
      this.frameAppCursor = frame.applicationCursorKeys;
    }
    this.frameBracketedPaste = frame.bracketedPaste === true;
    const shape: number = frame.cursorShape !== undefined ? frame.cursorShape : 0;
    const blink: number = frame.cursorBlink !== undefined ? frame.cursorBlink : -1;
    if (shape !== this.frameCursorShape || blink !== this.frameCursorBlink) {
      this.frameCursorShape = shape;
      this.frameCursorBlink = blink;
      this.needsFullRedraw = true;
      this.syncBlinkWakeTimer();
    }
    const epoch: number = frame.scrollbackEpoch !== undefined ? frame.scrollbackEpoch : 0;
    const total: number = frame.scrollbackTotal;
    const maxOffset: number = Math.max(0, total - frame.scrollbackOldest);
    if (this.lastScrollbackTotal >= 0) {
      if (epoch !== this.lastScrollbackEpoch && this.selection.selecting) {
        // 回滚缓冲被清空/重排（clear、reflow）：绝对行号失效
        this.exitSelectionMode();
      }
      if (this.scrollOffsetLines > 0) {
        const anchored: number = anchorScrollOffset({
          offset: this.scrollOffsetLines,
          prevTotal: this.lastScrollbackTotal,
          total: total,
          prevEpoch: this.lastScrollbackEpoch,
          epoch: epoch,
          maxOffset: maxOffset
        });
        if (frame.revision !== this.lastRenderedRevision && this.lastRenderedRevision >= 0 &&
          !this.newOutputBadge) {
          this.newOutputBadge = true;
        }
        this.lastScrollbackCount = maxOffset;
        if (anchored !== this.scrollOffsetLines) {
          this.setScrollOffset(anchored);
        }
      }
    }
    this.lastScrollbackTotal = total;
    this.lastScrollbackOldest = frame.scrollbackOldest;
    this.lastScrollbackEpoch = epoch;
    this.lastScrollbackCount = maxOffset;
    if (this.scrollOffsetLines > maxOffset) {
      this.setScrollOffset(maxOffset);
    }
  }

  /** 调度器每帧回调：true = 本帧发生了绘制（供自动休眠统计） */
  private renderFrame = (): boolean => {
    const terminal = this.terminal;
    if (!this.canvasReady || terminal === null ||
      this.cellWidthVp <= 0 || this.cellHeightVp <= 0) {
      return false;
    }
    const now: number = Date.now();
    if (this.fling.running) {
      this.stepFling(now);
    }
    const revision = terminal.getRevision();
    if (revision < 0) {
      return false; // 句柄失效
    }
    // A3 光标闪烁：content 静止时若相位翻转，仍需重画（显示/擦除）光标格
    let blinkOnlyRedraw = false;
    const blinking: boolean = this.effectiveCursorBlink();
    const blinkVisible: boolean = !blinking ||
      cursorVisibleAt(now - this.blinkEpoch, true, CURSOR_BLINK_PERIOD_MS);
    if (!this.needsFullRedraw && revision === this.lastRenderedRevision) {
      // 光标隐藏（DECTCEM off）或回滚视图中（不画光标）时，相位翻转无可见变化
      const blinkStable: boolean = !blinking || !this.lastFrameCursorVisible ||
        this.scrollOffsetLines > 0 || blinkVisible === this.lastCursorBlinkVisible;
      if (blinkStable) {
        return this.fling.running; // 无变化：整帧跳过；惯性中保持调度器清醒
      }
      // 相位翻转：只重绘光标所在行（block 反色需还原本体字符，脏行位图无此标记）
      blinkOnlyRedraw = true;
    }
    const frame = terminal.beginFrame();
    if (frame === null) {
      return false;
    }
    this.ingestFrame(frame);
    if (this.scrollOffsetLines > 0) {
      // T9 回滚视图：整窗重绘「回滚+主屏」拼接窗口。不 endFrame（脏位图保留，
      // 回到底部后由正常路径消费清位）；不画光标。revision/尺寸照常记账——
      // 否则 needsFullRedraw 滞留会让回滚期间每个 vsync 都整窗重绘
      this.paintScrolledWindow(frame);
      if (this.selection.selecting) {
        this.paintSelectionOverlay(frame);
      }
      this.lastRenderedRevision = frame.revision;
      this.lastGridCols = frame.cols;
      this.lastGridRows = frame.rows;
      this.needsFullRedraw = false;
      return true;
    }
    let drew = false;
    // 选择模式下叠加层为半透明：只重画脏行会让未重画行上的旧高亮叠加变深/残留，故整屏重绘
    if (this.needsFullRedraw || this.selection.selecting ||
      frame.cols !== this.lastGridCols || frame.rows !== this.lastGridRows) {
      this.paintFull(frame);
      drew = true;
    } else if (frame.dirty !== undefined) {
      const ranges = collectDirtyRanges(frame.dirty, frame.rows);
      if (blinkOnlyRedraw) {
        addCursorRowRange(ranges, frame.cursorRow, frame.rows);
      }
      if (ranges.length > 0) {
        this.paintRanges(frame, ranges);
        drew = true;
      }
    } else {
      // revision 变了却没有脏行位图（napi 组包缺省）：无法确定脏区，兜底全量重绘
      this.paintFull(frame);
      drew = true;
    }
    if (drew && frame.cursorVisible && blinkVisible) {
      this.paintCursor(frame);
    }
    if (drew && this.selection.selecting) {
      // T8：选区高亮叠加层（行内容之后、帧回执之前，随帧重绘）
      this.paintSelectionOverlay(frame);
    }
    // 受理回执：native 比对 revision 一致则清脏位图（并发撕裂下帧自愈，见 SshTerminal 头注）
    terminal.endFrame(frame.revision);
    this.lastCursorBlinkVisible = blinkVisible;
    this.lastRenderedRevision = frame.revision;
    this.lastGridCols = frame.cols;
    this.lastGridRows = frame.rows;
    this.needsFullRedraw = false;
    return drew;
  }

  /** 全量重绘：整底 + 全部行内容（首帧/尺寸变化/外观变化/onReady 清屏后） */
  private paintFull(frame: NativeTerminalFrame): void {
    const ctx = this.context;
    this.invalidateCtxStyleCache();
    ctx.fillStyle = this.backgroundArgb;
    ctx.fillRect(0, 0, this.areaWidthVp, this.areaHeightVp);
    const view = this.terminal?.readRows(frame, 0, frame.rows);
    if (view === null || view === undefined) {
      return;
    }
    this.execCommands(generateRowsCommands(view, 0, frame.rows, frame.cols, this.renderEnv()));
  }

  /** 脏行重绘：每个连续区间先整段清底（盖掉旧字符残影），再画区间内容 */
  private paintRanges(frame: NativeTerminalFrame, ranges: DirtyRange[]): void {
    const ctx = this.context;
    const env = this.renderEnv();
    for (const range of ranges) {
      const count = range.end - range.start;
      this.invalidateCtxStyleCache();
      ctx.fillStyle = this.backgroundArgb;
      // 清底与行背景用同一套像素吸附坐标：相邻区间之间不留缝、不叠色
      const y0: number = cellTopY(env, range.start);
      const y1: number = range.end >= frame.rows ? this.areaHeightVp : cellTopY(env, range.end);
      ctx.fillRect(0, y0, this.areaWidthVp, y1 - y0);
      const view = this.terminal?.readRows(frame, range.start, count);
      if (view === null || view === undefined) {
        continue;
      }
      this.execCommands(generateRowsCommands(view, range.start, count, frame.cols, env));
    }
  }

  /**
   * 光标：画在行内容之后。光标移动时 native 已把新旧光标行标脏（T1 onMoveCursor），
   * 所以旧位置的反色块会被脏行重绘自然覆盖，这里只管画当前位置。
   * 非聚焦窗格画空心框（一眼看出哪个窗格在接收输入）。
   */
  private paintCursor(frame: NativeTerminalFrame): void {
    if (frame.cursorRow < 0 || frame.cursorRow >= frame.rows ||
      frame.cursorCol < 0 || frame.cursorCol >= frame.cols) {
      return;
    }
    const env = this.renderEnv();
    if (!this.paneFocused) {
      const x0: number = cellLeftX(env, frame.cursorCol);
      const y0: number = cellTopY(env, frame.cursorRow);
      const w: number = cellLeftX(env, frame.cursorCol + 1) - x0;
      const h: number = cellTopY(env, frame.cursorRow + 1) - y0;
      const half: number = HOLLOW_CURSOR_LINE_VP / 2;
      this.invalidateCtxStyleCache();
      this.context.strokeStyle = this.cursorArgb;
      this.context.lineWidth = HOLLOW_CURSOR_LINE_VP;
      this.context.strokeRect(x0 + half, y0 + half, w - HOLLOW_CURSOR_LINE_VP, h - HOLLOW_CURSOR_LINE_VP);
      return;
    }
    const style = this.effectiveCursorStyle();
    const view = style === 'block'
      ? this.terminal?.readRows(frame, frame.cursorRow, 1) ?? null
      : null;
    this.execCommands(generateCursorCommands(style, view, frame.cursorCol, frame.cursorRow,
      frame.cols, env, this.cursorArgb));
  }

  /** 执行绘制指令：先背景后文本；underline/strike 用 fillRect 画线 */
  private execCommands(cmds: RowDrawCommands): void {
    const ctx = this.context;
    for (const bg of cmds.backgrounds) {
      if (bg.argb !== this.lastCtxFill) {
        ctx.fillStyle = bg.argb;
        this.lastCtxFill = bg.argb;
      }
      ctx.fillRect(bg.x, bg.y, bg.width, bg.height);
    }
    const thickness = Math.max(1, this.appearance.fontSize * TEXT_DECO_THICKNESS_FRACTION);
    // font 赋值触发解析，是帧热路径上最贵的状态切换：跨批次记住上次值，相同则跳过
    for (const run of cmds.texts) {
      const font = this.fontFor(run.bold, run.italic);
      if (font !== this.lastCtxFont) {
        ctx.font = font;
        this.lastCtxFont = font;
      }
      if (run.fgArgb !== this.lastCtxFill) {
        ctx.fillStyle = run.fgArgb;
        this.lastCtxFill = run.fgArgb;
      }
      // HarmonyOS Canvas 的 middle baseline 不是字形包围盒的视觉中心；统一使用
      // alphabetic baseline，并按实测 ascent/descent 把字形中心对齐到 cell 中线。
      ctx.fillText(run.text, run.x, run.y + this.textBaselineOffsetVp);
      if (run.underline) {
        ctx.fillRect(run.x, run.y + this.cellHeightVp / 2 - thickness,
          run.cellSpan * this.cellWidthVp, thickness);
      }
      if (run.strike) {
        ctx.fillRect(run.x, run.y - thickness / 2, run.cellSpan * this.cellWidthVp, thickness);
      }
    }
  }

  // ---------------------------------------------------------------- 生命周期事件

  private onCanvasReady(): void {
    // onReady 在初始化完成与尺寸变化时触发，且触发时画布已被清空（官方文档语义）
    this.canvasReady = true;
    try {
      this.pixelRatio = this.getUIContext().vp2px(1);
    } catch (_err) {
      this.pixelRatio = 0; // 读不到像素比：不吸附（旧行为）
    }
    this.invalidateCtxStyleCache();
    this.measureCells();
    this.relayout();
    this.needsFullRedraw = true;
    FrameScheduler.get().wakeup();
    if (this.autoFocus) {
      this.scheduleInputFocus(true);
    }
  }

  private onCanvasAreaChange(oldArea: Area, newArea: Area): void {
    const w = areaLengthToVp(newArea.width);
    const h = areaLengthToVp(newArea.height);
    if (w === this.areaWidthVp && h === this.areaHeightVp) {
      return;
    }
    this.areaWidthVp = w;
    this.areaHeightVp = h;
    this.relayout();
    this.needsFullRedraw = true; // 尺寸变化后 onReady 会清画布
    if (this.selection.selecting) {
      this.updateSelectionChrome();
    }
    FrameScheduler.get().wakeup();
  }

  private onTerminalChanged(): void {
    // 换绑终端：帧状态全部作废，下一帧全量重绘
    this.lastRenderedRevision = -1;
    this.lastGridCols = 0;
    this.lastGridRows = 0;
    this.needsFullRedraw = true;
    // T8/T9：旧终端的选择会话与回滚偏移一并作废（网格语义已不属于新终端）
    this.exitSelectionMode();
    this.clickTracker.reset();
    this.fling.stop();
    this.scrollOffsetLines = 0;
    this.scrolledBack = false;
    this.newOutputBadge = false;
    this.lastScrollbackTotal = -1;
    this.lastScrollbackOldest = 0;
    this.lastScrollbackEpoch = 0;
    this.frameAppCursorKnown = false;
    this.frameAppCursor = false;
    this.frameBracketedPaste = false;
    this.frameCursorShape = 0;
    this.frameCursorBlink = -1;
    this.imeEcho.clear();
    this.lastAltScreen = false;
    this.lastMouseMode = 0;
    this.mouseReportingActive = false;
    this.lastSgrButton = SGR_BUTTON_NONE;
    this.lastScrollbackCount = 0;
    // notifiedCols/Rows 记的是「已计算并通知页面的尺寸」，换终端后必须清零：
    // 否则版面在终端 attach 之前就已算出并记账，attach 后 relayout 会因
    // 「尺寸没变」提前返回，PTY 永远停在 attach 时的 80×24（表现为终端只占版面一角）。
    this.notifiedCols = 0;
    this.notifiedRows = 0;
    this.pendingTerminalResize = false;
    this.pushDefaultColorsToNative();
    this.relayout(); // autoResizeTerminal 时把当前版面同步给新终端
    FrameScheduler.get().wakeup();
  }

  private onAppearanceChanged(): void {
    this.applyAppearance();
    this.syncBlinkWakeTimer();
  }

  /**
   * A3 闪烁唤醒定时器：仅当「有效闪烁」（DECSCUSR/外观开启 + 窗格聚焦 + 可见）时
   * 每半周期 FrameScheduler.wakeup()，避免自动休眠吞掉相位翻转；其余情况一律停掉，
   * 后台标签/非聚焦窗格/隐藏页面静止 CPU≈0。
   */
  private syncBlinkWakeTimer(): void {
    if (!this.effectiveCursorBlink()) {
      this.clearBlinkWakeTimer();
      return;
    }
    if (this.blinkWakeTimer >= 0) {
      return; // 已在跑（半周期恒定，外观切换不重建）
    }
    const half: number = Math.max(50, Math.floor(CURSOR_BLINK_PERIOD_MS / 2));
    this.blinkWakeTimer = setInterval((): void => {
      FrameScheduler.get().wakeup();
    }, half);
  }

  private clearBlinkWakeTimer(): void {
    if (this.blinkWakeTimer >= 0) {
      clearInterval(this.blinkWakeTimer);
      this.blinkWakeTimer = -1;
    }
  }

  private onVisibleChanged(): void {
    FrameScheduler.get().setVisible(this.schedulerId, this.visible);
    if (!this.visible) {
      this.fling.stop();
      this.stopEdgeScroll();
    } else {
      this.needsFullRedraw = true;
      FrameScheduler.get().wakeup();
    }
    this.syncBlinkWakeTimer();
  }

  private onAutoResizeTerminalChanged(): void {
    if (this.autoResizeTerminal) {
      this.flushPendingTerminalResize();
    }
  }

  private onAutoFocusChanged(): void {
    if (this.autoFocus) {
      this.scheduleInputFocus(true);
    }
  }

  /**
   * 等输入承接方（自绘编辑器：容器 Stack；兜底：隐藏 TextInput）挂载后再请求焦点；
   * 标签/窗格切换也复用同一路径。外接键盘活跃时只聚焦不弹软键盘。
   */
  private scheduleInputFocus(showKeyboard: boolean): void {
    if (this.inputFocusTimer >= 0) {
      clearTimeout(this.inputFocusTimer);
    }
    this.inputFocusTimer = setTimeout((): void => {
      this.inputFocusTimer = -1;
      if (this.autoFocus && this.visible && this.isInputTarget()) {
        this.requestInput(showKeyboard && shouldShowSoftKeyboardOnTouch(this.externalKeyboardActive));
      }
    }, 32);
  }

  // ---------------------------------------------------------------- 内部装配

  /** 外观 → 颜色缓存 + 字符度量 + 版面 + 全量重绘标记 */
  private applyAppearance(): void {
    const a = this.appearance;
    try {
      this.paletteArgb = paletteToArgb(a.palette);
      this.defaultFgArgb = hexColorToArgb(a.foreground);
      this.defaultBgArgb = hexColorToArgb(a.background);
      this.cursorArgb = hexColorToArgb(a.cursorColor);
      this.selectionArgb = hexColorToArgb(a.selectionColor);
    } catch (e) {
      // 外观配置非法（A 系列入库校验的兜底）：退回默认配色，渲染路径不能抛死
      Logger.warn(`TerminalCanvas 外观颜色非法，退回默认配色：${JSON.stringify(e)}`, 'Terminal');
      const fallback = createDefaultTerminalAppearance();
      this.paletteArgb = paletteToArgb(fallback.palette);
      this.defaultFgArgb = hexColorToArgb(fallback.foreground);
      this.defaultBgArgb = hexColorToArgb(fallback.background);
      this.cursorArgb = hexColorToArgb(fallback.cursorColor);
      this.selectionArgb = hexColorToArgb(fallback.selectionColor);
    }
    this.backgroundArgb = withOpacity(this.defaultBgArgb, a.backgroundOpacity);
    this.selectionHandleColor = a.cursorColor;
    this.pushDefaultColorsToNative();
    this.measureCells();
    this.relayout();
    if (this.selection.selecting) {
      this.updateSelectionChrome();
    }
    this.needsFullRedraw = true;
    FrameScheduler.get().wakeup();
  }

  /** 外观默认色写进 PTY 网格，字符格底色才跟 Canvas/页面一致。 */
  private pushDefaultColorsToNative(): void {
    if (this.terminal === null) {
      return;
    }
    this.terminal.setDefaultColors(this.defaultFgArgb, this.defaultBgArgb);
  }

  /**
   * 字符度量：委托 FontMetrics（T5 单一事实源），measureText('W') 只在字体参数
   * 变化时测一次并跨实例缓存（DESIGN §4.4）。letterSpacing/lineHeight 影响 cell
   * 高宽换算，故本组件的 key 比 FontMetrics 缓存 key 多这两项。
   * 改字号「一帧内重排」：applyAppearance 同步调到本函数重测 → relayout →
   * needsFullRedraw + wakeup，下一 vsync 帧即按新版面上屏，无跨帧延迟。
   */
  private measureCells(): void {
    const a = this.appearance;
    const key = `${a.fontFamily}|${a.fontSize}|${a.fontWeight}|${a.letterSpacing}|${a.lineHeight}`;
    if (key === this.measuredFontKey) {
      return;
    }
    this.measuredFontKey = key;
    // measureText 的 bounding-box 距离以当前 baseline 为参照，必须先固定为 alphabetic。
    this.context.textBaseline = 'alphabetic';
    const m = measureTerminalCells(new CanvasTextMeasureContext(this.context), a.fontFamily,
      a.fontSize, a.fontWeight);
    this.fontNormal = m.fontNormal;
    this.fontBold = m.fontBold;
    this.fontItalic = m.fontItalic;
    this.fontBoldItalic = m.fontBoldItalic;
    this.context.font = this.fontNormal;
    this.invalidateCtxStyleCache();
    this.lastCtxFont = this.fontNormal;
    this.context.textAlign = 'left';
    this.context.textBaseline = 'alphabetic';
    let glyphWidth = m.glyphWidthVp;
    if (!m.measured) {
      // 字体未注册（启动注册失败的兜底路径）或度量失败的保底格宽。
      // 注意此时不落定 measuredFontKey：下次调用（如 onCanvasReady）会重测
      glyphWidth = a.fontSize * FALLBACK_CELL_WIDTH_FRACTION;
      this.measuredFontKey = '';
    }
    this.cellWidthVp = glyphWidth + a.letterSpacing;
    // 字形度量只用于算 baseline，不能反向覆盖用户行高；字体全局框在真机上
    // 显著大于实际字形，若参与行高会把 1.2 的配置拉大到约 1.8。
    this.cellHeightVp = a.fontSize * a.lineHeight;
    this.textBaselineOffsetVp = computeBaselineOffsetFromCenter(a.fontSize,
      m.fontAscentVp, m.fontDescentVp);
    if (m.measured) {
      this.checkCjkAlignment();
    }
  }

  /**
   * 宽字符 2 格对齐校验（每换新 fontKey 一次）：'中' 宽 ≈ 2×'W' 宽。
   * 未对齐只告警不阻断——渲染照常（混排可能错位），结果由 isCjkAligned() 供 UI/A3 读。
   */
  private checkCjkAlignment(): void {
    try {
      const a = this.appearance;
      const r = verifyCjkAlignment(new CanvasTextMeasureContext(this.context), a.fontFamily,
        a.fontSize, a.fontWeight);
      this.cjkAligned = r.aligned;
      if (!r.aligned) {
        Logger.warn(`终端字族 1:2 对齐校验未通过：'中'=${r.cjkWidthVp.toFixed(2)}vp，` +
          `2×'W'=${(2 * r.asciiWidthVp).toFixed(2)}vp（ratio=${r.ratio.toFixed(3)}，` +
          '容差 ±5%）：中英混排可能错位，请确认字体注册结果', 'Terminal');
      }
    } catch (e) {
      Logger.warn(`对齐校验异常：${JSON.stringify(e)}`, 'Terminal');
    }
  }

  /** 画布尺寸 → cols/rows；变化时回调 onGridSizeChanged 并按职责驱动 terminal.resize() */
  private relayout(): void {
    if (this.cellWidthVp <= 0 || this.cellHeightVp <= 0 ||
      this.areaWidthVp <= 0 || this.areaHeightVp <= 0) {
      return;
    }
    // 只改变 Canvas 坐标系内的网格原点和可用行列，绝不靠组件 padding 制造留白。
    // 对历史上曾保存为 0 的外观也强制保留最低内部留白。
    const horizontalInset: number =
      Math.max(MIN_GRID_HORIZONTAL_INSET_VP, this.appearance.padding);
    const topInset: number = Math.max(MIN_GRID_TOP_INSET_VP, this.appearance.padding);
    const metrics = computeTerminalLayoutInsets(this.areaWidthVp, this.areaHeightVp,
      horizontalInset, horizontalInset, topInset, 0, this.cellWidthVp, this.cellHeightVp);
    this.layout = metrics;
    if (metrics.cols === this.notifiedCols && metrics.rows === this.notifiedRows) {
      this.flushPendingTerminalResize();
      return;
    }
    this.notifiedCols = metrics.cols;
    this.notifiedRows = metrics.rows;
    // T9：网格尺寸变化（列变化会触发 native reflow）后视口/选区的行号语义失效：
    // 回到底部、退出选择（resize 自愈）
    this.fling.stop();
    this.exitSelectionMode();
    this.setScrollOffset(0);
    this.onGridSizeChanged(metrics.cols, metrics.rows);
    this.pendingTerminalResize = true;
    this.flushPendingTerminalResize();
  }

  /** 拖动期多次网格变化只保留最后一次；恢复 autoResize 后同步当前 PTY 尺寸。 */
  private flushPendingTerminalResize(): void {
    if (!this.pendingTerminalResize || !this.autoResizeTerminal || this.terminal === null ||
      this.notifiedCols <= 0 || this.notifiedRows <= 0) {
      return;
    }
    this.terminal.resize(this.notifiedCols, this.notifiedRows);
    this.pendingTerminalResize = false;
  }

  private renderEnv(): RowRenderEnv {
    return {
      originX: this.layout.originX,
      originY: this.layout.originY,
      cellWidth: this.cellWidthVp,
      cellHeight: this.cellHeightVp,
      defaultFgArgb: this.defaultFgArgb,
      defaultBgArgb: this.defaultBgArgb,
      paletteArgb: this.paletteArgb,
      boldAsBright: this.appearance.boldAsBright,
      // 字间距 ≠ 0 时合并字符串会丢间距对齐，退化为逐格一条
      perGlyphText: this.appearance.letterSpacing !== 0,
      // 矩形边吸附物理像素：分数 vp 行高下行间不再出现细缝/叠色
      pixelRatio: this.pixelRatio
    };
  }

  private invalidateCtxStyleCache(): void {
    this.lastCtxFont = '';
    this.lastCtxFill = Number.NaN;
  }

  private fontFor(bold: boolean, italic: boolean): string {
    if (bold && italic) {
      return this.fontBoldItalic;
    }
    if (bold) {
      return this.fontBold;
    }
    return italic ? this.fontItalic : this.fontNormal;
  }

  /** 起点手柄：贴在选区第一格左侧，圆钮 + 竖条。 */
  @Builder
  SelectionStartHandle() {
    Row() {
      Column()
        .width(HANDLE_KNOB_VP)
        .height(HANDLE_KNOB_VP)
        .borderRadius(HANDLE_KNOB_VP / 2)
        .backgroundColor(this.selectionHandleColor)
        .border({ width: 2, color: '#FFFFFFFF' })
      Column()
        .width(HANDLE_BAR_WIDTH_VP)
        .height(this.handleBarHeight)
        .backgroundColor(this.selectionHandleColor)
        .margin({ left: 1 })
    }
    .width(HANDLE_HIT_WIDTH_VP)
    .height(Math.max(this.handleBarHeight, HANDLE_KNOB_VP))
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
    .position({ x: this.startHandleX, y: this.startHandleY })
    .zIndex(3)
    .hitTestBehavior(HitTestMode.Default)
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.beginHandleDrag('start');
        })
        .onActionUpdate((event: GestureEvent) => {
          this.onHandleDrag(event);
        })
        .onActionEnd(() => {
          this.endHandleDrag();
        })
        .onActionCancel(() => {
          this.endHandleDrag();
        })
    )
  }

  /** 终点手柄：贴在选区末格右侧，竖条 + 圆钮。 */
  @Builder
  SelectionEndHandle() {
    Row() {
      Column()
        .width(HANDLE_BAR_WIDTH_VP)
        .height(this.handleBarHeight)
        .backgroundColor(this.selectionHandleColor)
        .margin({ right: 1 })
      Column()
        .width(HANDLE_KNOB_VP)
        .height(HANDLE_KNOB_VP)
        .borderRadius(HANDLE_KNOB_VP / 2)
        .backgroundColor(this.selectionHandleColor)
        .border({ width: 2, color: '#FFFFFFFF' })
    }
    .width(HANDLE_HIT_WIDTH_VP)
    .height(Math.max(this.handleBarHeight, HANDLE_KNOB_VP))
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
    .position({ x: this.endHandleX, y: this.endHandleY })
    .zIndex(3)
    .hitTestBehavior(HitTestMode.Default)
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.beginHandleDrag('end');
        })
        .onActionUpdate((event: GestureEvent) => {
          this.onHandleDrag(event);
        })
        .onActionEnd(() => {
          this.endHandleDrag();
        })
        .onActionCancel(() => {
          this.endHandleDrag();
        })
    )
  }

  /** 气泡菜单单项（≥40vp 高、56vp 宽的触摸目标） */
  @Builder
  MenuItem(label: string, action: () => void) {
    Text(label)
      .fontSize(Tokens.fontSize.caption)
      .fontColor(Tokens.Color.appBg)
      .textAlign(TextAlign.Center)
      .width(MENU_ITEM_WIDTH_VP)
      .height(MENU_HEIGHT_VP)
      .accessibilityText(label)
      .onClick(() => {
        action();
      })
  }

  build() {
    Stack() {
      Canvas(this.context)
        .width('100%')
        .height('100%')
        .padding(0)
        .backgroundColor(this.appearance.background)
        // 捏合预览：只缩放画面（左上角为原点，与松手后重排的网格原点一致）
        .scale({ x: this.pinchScale, y: this.pinchScale, centerX: 0, centerY: 0 })
        .onReady(() => {
          this.onCanvasReady();
        })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onCanvasAreaChange(oldArea, newArea);
        })
      if (!this.useCustomIme) {
        // 兜底通路：隐藏 IME 承接框（自绘编辑器 attach 失败时才挂载）
        ImeInputSink({
          sinkId: this.imeSinkId,
          autoFocus: this.autoFocus,
          onDelta: this.onImeDelta,
          onEnter: this.onImeEnter,
          onInterceptKey: this.onImeInterceptKey,
          // T10：外接键盘活跃时不弹软键盘（PhysicalKeyboard 策略）
          enableSoftKeyboardOnFocus: !this.externalKeyboardActive
        })
      }
      // 视觉响铃薄膜（不拦截触摸）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.appearance.foreground)
        .opacity(this.bellFlashOpacity)
        .animation({ duration: BELL_FLASH_MS, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
      // T8 气泡菜单：复制 / 粘贴 / 全选 /（选中内容是链接时）打开链接
      if (this.selectionMenuVisible) {
        Row() {
          this.MenuItem('复制', (): void => {
            this.copySelection();
          })
          this.MenuItem('粘贴', (): void => {
            this.pasteFromMenu();
          })
          this.MenuItem('全选', (): void => {
            this.selectAllBuffer();
          })
          if (this.selectionUrl.length > 0) {
            this.MenuItem('打开链接', (): void => {
              this.openSelectionUrl();
            })
          }
        }
        .height(MENU_HEIGHT_VP)
        .padding({ left: MENU_SIDE_PADDING_VP, right: MENU_SIDE_PADDING_VP })
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.md)
        .shadow({ radius: 8, color: '#40000000', offsetY: 2 })
        .position({ x: this.selectionMenuX, y: this.selectionMenuY })
        .zIndex(4)
      }
      if (this.selectionHandlesVisible) {
        this.SelectionStartHandle()
        this.SelectionEndHandle()
      }
      // 捏合字号标签
      if (this.pinchLabel.length > 0) {
        Text(`${this.pinchLabel} pt`)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.md)
          .padding({ left: Tokens.space.md, right: Tokens.space.md, top: Tokens.space.xs, bottom: Tokens.space.xs })
          .hitTestBehavior(HitTestMode.None)
          .zIndex(5)
      }
      // 回滚中：「新输出」角标 + 回到底部按钮
      if (this.scrolledBack) {
        Column({ space: Tokens.space.xs }) {
          if (this.newOutputBadge) {
            Text('有新输出')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.md)
              .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: 2, bottom: 2 })
          }
          Button() {
            Text('↓')
              .fontSize(20)
              .fontColor(Tokens.Color.onAccent)
          }
          .type(ButtonType.Circle)
          .width(JUMP_BUTTON_VP)
          .height(JUMP_BUTTON_VP)
          .backgroundColor(Tokens.Color.accent)
          .shadow({ radius: 8, color: '#40000000', offsetY: 2 })
          .accessibilityText('回到底部')
          .onClick(() => {
            this.scrollToBottom();
          })
        }
        .alignItems(HorizontalAlign.End)
        .position({ right: Tokens.space.md, bottom: Tokens.space.md })
        .zIndex(4)
      }
    }
    .id(this.hostId)
    .width('100%')
    .height('100%')
    .padding(0)
    .clip(true)
    .backgroundColor(this.appearance.background)
    // 自绘编辑器通路：容器自身获焦承接物理键（兜底通路由隐藏 TextInput 获焦）
    .focusable(true)
    .focusOnTouch(false)
    .defaultFocus(this.autoFocus && this.useCustomIme)
    .accessibilityText('终端')
    // T8/T9 触摸手势：互斥识别（先识别到的胜出，其余取消）——捏合排最前，两指
    // 落下时不会被单指拖动抢走；快速点按 = 聚焦/退出选择/停惯性；按住不动 =
    // 进入选择（链接上直接选中整条）；直接拖动 = 滚动/拖选（松手惯性）。
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            this.onPinchStart();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.onPinchUpdate(event);
          })
          .onActionEnd(() => {
            this.onPinchEnd();
          })
          .onActionCancel(() => {
            this.onPinchCancel();
          }),
        LongPressGesture({ fingers: 1, duration: LONG_PRESS_DURATION_MS })
          .onAction((event: GestureEvent) => {
            this.onLongPressSelect(event);
          }),
        PanGesture({ fingers: 1 })
          .onActionStart(() => {
            this.panLastOffsetY = 0;
            this.scrollAccumulator.reset();
            this.fling.stop();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.onPanUpdate(event);
          })
          .onActionEnd((event: GestureEvent) => {
            this.onPanEnd(event);
          })
          .onActionCancel(() => {
            this.scrollAccumulator.reset();
            this.stopEdgeScroll();
          }),
        TapGesture()
          .onAction((event: GestureEvent) => {
            this.onPaneClick(event);
          })
      )
    )
    .onMouse((event: MouseEvent): void => {
      // T11：鼠标/触控板（2in1）。frame.mouseMode≠0 时按 SGR 1006 转发；
      // mouseMode=0 时只更新最近格子（双击选词定位用），不改变触摸语义。
      const actionName: string = `${event.action}`;
      const pos: CellPos = this.gridPosFromPoint(event.x, event.y);
      this.lastMouseCol1 = pos.col + 1;
      this.lastMouseRow1 = pos.row + 1;
      if (actionName.indexOf('Hover') >= 0 || actionName.indexOf('hover') >= 0) {
        // 悬停：仅 mode≥3（任意移动）时转发
        this.onMouseEventReport('Move', -1, event.x, event.y);
        return;
      }
      this.onMouseEventReport(actionName, event.button as number, event.x, event.y);
    })
    .onKeyPreIme((event: KeyEvent): boolean => {
      // 自绘编辑器通路：只截 Ctrl/Alt 组合（规则见 shouldInterceptBeforeIme）
      return this.useCustomIme ? this.handleKeyInput(event, true) : false;
    })
    .onKeyEvent((event: KeyEvent): boolean => {
      // 输入法不消费后的物理键通路（API 15 起返回值可拦截冒泡）；兜底通路下
      // 子组件（ImeInputSink）获焦时按键先经其 onKeyPreIme
      return this.handleKeyInput(event, false);
    })
  }
}
