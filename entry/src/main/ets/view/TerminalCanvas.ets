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
 *    放组件内可保证「拖分隔条后每个窗格各自发 request_pty_size」不漏；U4b 若需
 *    集中编排，置 autoResizeTerminal=false 并监听 onGridSizeChanged 自行调用）；
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
 * 输入通路（任务 T6 接线，详见 KeyMap/StickyModifiers/ImeInputHandler/FocusManager 头注）：
 *  - 隐藏 TextInput（ImeInputSink）承接软键盘 IME：onChange 增量 → 字节 →
 *    terminal.write()；中文候选期（previewText 非空）不发送；
 *  - 物理键盘：onKeyPreIme（IME 前拦截方向/功能/Ctrl 组合，可打印键放行给 IME）
 *    + onKeyEvent（容器自身获焦时的全量通路）→ mapKeyEvent → write()；
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
 *  - T8：长按（LongPressGesture）进入选择模式 → 拖动（PanGesture）更新活动端
 *    → 气泡菜单「复制/全选」（粘贴/分享归 U4）；选区高亮为 selectionColor
 *    半透明叠加层，随帧重绘；跨行拼接/宽字符边界等纯逻辑在
 *    terminal/SelectionModel.ets；**首版只支持主屏选择**——回滚区
 *    （scrollOffset>0）下长按不进入选择，回滚区选择登记后续；
 *    放大镜省略（T8 任务书允许）；
 *  - T9：单指竖滑——主屏 = 视图滚动回滚缓冲（scrollOffsetLines；滚动时
 *    整窗重绘「回滚+主屏」拼接窗口，**首版简化：不做增量，性能待 T0/Q2 实测**；
 *    滚动中不 endFrame、不画光标，回到底部后下帧全量自愈）；alt-screen
 *    （vim/less）= 按 altScrollMode 发方向键或 SGR 滚轮序列（每累计一行一条，
 *    纯逻辑在 terminal/TerminalGestures.ets）；双指捏合实时改字号（8–32
 *    钳制），松手经 onFontSizeCommit 回调通知外部落库（组件不写库）；
 *  - 「跳回最新」悬浮按钮不做（T9 任务书登记为可选），回滚时下滑到底即回。
 */
import { NativeTerminalFrame } from '../napi/SshNative';
import {
  DirtyRange,
  SshTerminal,
  collectDirtyRanges
} from '../napi/SshTerminal';
import { Logger } from '../common/utils/Logger';
import { FrameScheduler } from './FrameScheduler';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance
} from './terminal/TerminalAppearance';
import {
  RowDrawCommands,
  RowRenderEnv,
  generateCursorCommands,
  generateRowsCommands
} from './terminal/TerminalDrawCommands';
import {
  TextMeasureContext,
  TextMeasureResult,
  measureTerminalCells,
  verifyCjkAlignment
} from './terminal/FontMetrics';
import { TerminalLayoutMetrics, computeTerminalLayout } from './terminal/TerminalLayout';
import {
  hexColorToArgb,
  paletteToArgb,
  withOpacity
} from './terminal/TerminalPalette';
import { FocusManager } from './terminal/FocusManager';
import { isModifierKeyCode, isPrintableKeyCode, mapKeyEvent } from './terminal/KeyMap';
import { StickyModifiers } from './terminal/StickyModifiers';
import {
  CommittedDelta,
  ImeInputSink,
  committedDeltaToInputBytes
} from './terminal/ImeInputHandler';
import {
  CellPos,
  SelectionModel,
  SelectionRange,
  adjustWideCharBoundary,
  dataViewGridReader
} from './terminal/SelectionModel';
import { copyTextToPasteboard, pasteFromPasteboard } from './terminal/Pasteboard';
import {
  ShortcutAction,
  ShortcutBinding,
  matchShortcut,
  parseShortcutLayout
} from './terminal/ShortcutMap';
import {
  AltScrollMode,
  ScrollLineAccumulator,
  buildAltScrollSequences,
  clampFontSize,
  clampScrollOffset
} from './terminal/TerminalGestures';
import { vibrateLight } from '../common/utils/Haptics';
import { Tokens } from '../theme/Tokens';

/** 实例 id 自增序号（模块级；调度器注册用） */
let nextCanvasId = 0;

/** 字符度量失败（字体未注册）时的近似格宽系数 */
const FALLBACK_CELL_WIDTH_FRACTION = 0.6;
/** underline/strike 线宽 = 字号 × 该系数（下限 1vp） */
const TEXT_DECO_THICKNESS_FRACTION = 0.06;
/** 进入选择模式的长按时长（ms） */
const LONG_PRESS_DURATION_MS = 500;
/** 选区叠加层不透明度（盖在字形之上，需保持可读） */
const SELECTION_OVERLAY_OPACITY = 0.5;
/** 气泡菜单几何（vp）：高约一行菜单、宽约两枚按钮 */
const MENU_HEIGHT_VP = 36;
const MENU_WIDTH_VP = 152;
/** 气泡菜单与选区起点行的垂直间距（vp） */
const MENU_GAP_VP = 4;

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
    return { width: this.context.measureText(text).width };
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
  /** true（默认）= 组件内部直接调 terminal.resize()；职责说明见文件头注 */
  autoResizeTerminal: boolean = true;
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
  /**
   * 终端应用光标模式（DECCKM）：native 尚未暴露该模式位（T1 未加），
   * 先参数化透传给 mapKeyEvent；native 暴露后由 U4 接线（KeyMap 头注）
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

  private shortcutBindings: ShortcutBinding[] = parseShortcutLayout('');

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly schedulerId: string = `terminal-canvas-${++nextCanvasId}`;
  /** 隐藏 IME 承接框的全局唯一 id（focusControl.requestFocus 用） */
  private readonly imeSinkId: string = `terminal-ime-${++nextCanvasId}`;

  private canvasReady = false;
  private areaWidthVp = 0;
  private areaHeightVp = 0;
  // ---- 字符度量缓存（DESIGN §4.4：字体/字号变化时才重测）----
  private measuredFontKey = '';
  private cellWidthVp = 0;
  private cellHeightVp = 0;
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

  aboutToAppear(): void {
    this.shortcutBindings = parseShortcutLayout(this.shortcutBindingsJson);
    this.applyAppearance();
    FrameScheduler.get().register(this.schedulerId, this.renderFrame);
    FrameScheduler.get().setVisible(this.schedulerId, this.visible);
  }

  private onShortcutJsonChanged(): void {
    this.shortcutBindings = parseShortcutLayout(this.shortcutBindingsJson);
  }

  aboutToDisappear(): void {
    FrameScheduler.get().unregister(this.schedulerId);
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
   * 点击窗格（build 中由 TapGesture 驱动）：选择模式下点击 = 退出选择
   * （不弹软键盘，避免打断复制后查看）；否则聚焦本窗格（U4b 边框高亮经
   * FocusManager 监听器）+ 弹软键盘承接 IME。
   */
  private onPaneClick(): void {
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
    if (this.isInputTarget()) {
      focusControl.requestFocus(this.imeSinkId);
    }
  }

  /** 写终端输入：Uint8Array → 零偏移全量 ArrayBuffer（writeTerminal 接受 ArrayBuffer | string） */
  private sendInputBytes(bytes: Uint8Array): void {
    const terminal = this.terminal;
    if (terminal === null || bytes.length === 0) {
      return;
    }
    terminal.write(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  }

  /**
   * 物理键盘统一出口（onKeyEvent 与 onKeyPreIme 共用；T10 扩展点，勿开旁路）。
   *
   * @param preIme true = TextInput 的 IME 前拦截（onKeyPreIme）：无 Ctrl/Alt 的
   *   可打印键必须放行（返回 false），让 IME 走 onChange 增量路径——否则中文
   *   候选会被拦断、可打印字符与 IME 双发；false = 容器自身获焦的全量通路。
   * @returns true = 已消费（不再进 IME/不再冒泡）
   */
  private handleKeyInput(event: KeyEvent, preIme: boolean): boolean {
    if (event.type !== KeyType.Down) {
      return false; // 只处理按下；弹起不重复发送
    }
    if (isModifierKeyCode(event.keyCode)) {
      return false; // 修饰键自身放行（组合状态由系统跟踪，不产生字节）
    }
    const ctrl = this.queryModifierState(event, 'ctrl');
    const alt = this.queryModifierState(event, 'alt');
    const shift = this.queryModifierState(event, 'shift');
    const meta = this.queryModifierState(event, 'meta');
    if (preIme && !ctrl && !alt && isPrintableKeyCode(event.keyCode)) {
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
      alt || snap.alt, ctrl || snap.ctrl, false, this.applicationCursorKeys);
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
      pasteFromPasteboard(this.terminal).catch((err: Object) => {
        Logger.warn(`快捷键粘贴失败：${JSON.stringify(err)}`, 'Terminal');
      });
      return true;
    }
    return this.onAppShortcut(action);
  }

  /**
   * 硬件修饰状态查询。KeyEvent.getModifierKeyState 在 SDK 声明中为可选方法
   * （支持 'ctrl'|'alt'|'shift'；Meta 暂不支持，mapKeyEvent 内 Meta 按 Alt 处理），
   * 缺失时退化为无修饰（真机待验项，见 ImeInputHandler 头注）。
   */
  private queryModifierState(event: KeyEvent, name: string): boolean {
    return event.getModifierKeyState !== undefined ? event.getModifierKeyState([name]) : false;
  }

  /**
   * IME 提交出口：增量 + 粘滞快照 → 字节 → write()；每次提交都消费一次性粘滞
   * （「下一个按键带修饰」以按键/提交计，见 StickyModifiers 头注）。
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

  private onImeInterceptKey = (event: KeyEvent): boolean => {
    return this.handleKeyInput(event, true);
  }

  /**
   * T9 回滚视图整窗重绘（scrollOffsetLines > 0 时；首版简化方案，性能待
   * T0/Q2 实测）：视口 = 绝对行 [scrollbackTotal - scrollOffset, +rows)，
   * 回滚段经 readScrollbackWindow 取历史行拼在视口上方，主屏段取主屏
   * [0, rows-sbCount) 拼在下方。远端新输出会推动 scrollbackTotal 增长，
   * 视口内容随之移动（与桌面终端「锚定底部」惯例一致）。
   */
  private paintScrolledWindow(frame: NativeTerminalFrame): void {
    const ctx = this.context;
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
   * T8 选区高亮：selectionColor 半透明叠加层（画在行内容之后）。
   * 范围与取文本同一口径（宽字符边界修正复用 adjustWideCharBoundary，
   * 不高亮半个宽字符）；行区间越界（选择期间 resize）按帧尺寸钳制。
   */
  private paintSelectionOverlay(frame: NativeTerminalFrame): void {
    const raw = this.selection.range();
    const terminal = this.terminal;
    if (raw === null || terminal === null) {
      return;
    }
    const view = terminal.readRows(frame, 0, frame.rows);
    if (view === null) {
      return;
    }
    const range = adjustWideCharBoundary(dataViewGridReader(view, frame.rows, frame.cols), raw);
    const ctx = this.context;
    ctx.fillStyle = withOpacity(this.selectionArgb, SELECTION_OVERLAY_OPACITY);
    const lastRow = Math.min(range.endRow, frame.rows - 1);
    for (let r = range.startRow; r <= lastRow; r++) {
      if (r < 0) {
        continue;
      }
      const lo = r === range.startRow ? range.startCol : 0;
      const hi = Math.min(r === range.endRow ? range.endCol : frame.cols - 1, frame.cols - 1);
      if (hi < lo) {
        continue;
      }
      ctx.fillRect(this.layout.originX + lo * this.cellWidthVp,
        this.layout.originY + r * this.cellHeightVp,
        (hi - lo + 1) * this.cellWidthVp, this.cellHeightVp);
    }
  }

  // ---------------------------------------------------------------- T8 选择模式

  /** 像素点 → 网格坐标（钳到当前帧网格内；度量未完成时给 (0,0)） */
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

  /** 长按进入选择模式（首版仅主屏：回滚视图中忽略，见头注「T8」） */
  private onLongPressSelect(event: GestureEvent): void {
    if (this.terminal === null || this.scrollOffsetLines > 0 || event.fingerList.length === 0) {
      return;
    }
    const finger = event.fingerList[0];
    this.selection.begin(this.gridPosFromPoint(finger.localX, finger.localY));
    this.updateSelectionMenuPosition();
    this.forceFullRedraw();
    vibrateLight(this.hapticEnabled);
  }

  /** 退出选择模式并清掉高亮/菜单（复制完成、点击他处、换绑终端时调用） */
  private exitSelectionMode(): void {
    if (!this.selection.selecting && !this.selectionMenuVisible) {
      return;
    }
    this.selection.cancel();
    this.selectionMenuVisible = false;
    this.forceFullRedraw(); // 重绘覆盖掉高亮叠加层
  }

  /** 气泡菜单「复制」：取选区文本 → 写系统剪贴板 → 轻震 → 退出选择模式 */
  private copySelection(): void {
    const terminal = this.terminal;
    if (terminal === null) {
      return;
    }
    // 只读快照：beginFrame 后不 endFrame——不消费脏位图，帧流程不受影响
    const frame = terminal.beginFrame();
    if (frame === null) {
      return;
    }
    const view = terminal.readRows(frame, 0, frame.rows);
    if (view === null) {
      return;
    }
    const text = this.selection.extractText(dataViewGridReader(view, frame.rows, frame.cols));
    this.exitSelectionMode();
    if (text.length === 0) {
      return;
    }
    copyTextToPasteboard(text)
      .then((ok) => {
        if (ok) {
          vibrateLight(this.hapticEnabled);
        }
      })
      .catch((err: Object) => {
        Logger.warn(`复制到剪贴板异常：${JSON.stringify(err)}`, 'Terminal');
      });
  }

  /** 气泡菜单「全选」：选中当前主屏全部内容 */
  private selectAllOnScreen(): void {
    const rows = this.lastGridRows > 0 ? this.lastGridRows : this.layout.rows;
    const cols = this.lastGridCols > 0 ? this.lastGridCols : this.layout.cols;
    this.selection.selectAll(rows, cols);
    this.updateSelectionMenuPosition();
    this.forceFullRedraw();
  }

  /** 气泡菜单位置：选区起点上方，顶部放不下时贴顶（底部溢出由钳制兜底） */
  private updateSelectionMenuPosition(): void {
    const range: SelectionRange | null = this.selection.range();
    if (range === null) {
      this.selectionMenuVisible = false;
      return;
    }
    const x = this.layout.originX + range.startCol * this.cellWidthVp;
    const maxX = Math.max(0, this.areaWidthVp - MENU_WIDTH_VP);
    this.selectionMenuX = Math.min(Math.max(x, 0), maxX);
    const y = this.layout.originY + range.startRow * this.cellHeightVp - MENU_HEIGHT_VP - MENU_GAP_VP;
    this.selectionMenuY = Math.max(y, 0);
    this.selectionMenuVisible = true;
  }

  // ---------------------------------------------------------------- T9 手势

  /**
   * 单指拖动主处理：选择模式中 = 更新活动端；否则竖向滚动
   * （主屏 = 视图回滚；alt-screen = 方向键/滚轮序列，见 handleVerticalPan）。
   */
  private onPanUpdate(event: GestureEvent): void {
    if (this.selection.selecting) {
      if (event.fingerList.length > 0) {
        const finger = event.fingerList[0];
        this.selection.extend(this.gridPosFromPoint(finger.localX, finger.localY));
        this.updateSelectionMenuPosition();
        this.forceFullRedraw();
      }
      return;
    }
    const deltaY = event.offsetY - this.panLastOffsetY;
    this.panLastOffsetY = event.offsetY;
    this.handleVerticalPan(deltaY, event);
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
      const seqs = buildAltScrollSequences(this.altScrollMode, this.lastMouseMode, lines, col1, row1);
      for (const seq of seqs) {
        this.sendInputBytes(seq);
      }
      return;
    }
    // 主屏：视图滚动回滚缓冲（整窗重绘在 renderFrame 的 paintScrolledWindow）
    const next = clampScrollOffset(this.scrollOffsetLines + lines, this.lastScrollbackCount);
    if (next !== this.scrollOffsetLines) {
      this.scrollOffsetLines = next;
      this.needsFullRedraw = true;
      FrameScheduler.get().wakeup();
    }
  }

  /** 捏合实时改字号（8–32 钳制）：重测度量 → 重排版面 → 下帧全量上屏 */
  private onPinchUpdate(event: GestureEvent): void {
    const next = clampFontSize(this.pinchBaseFontSize * event.scale);
    if (next !== this.appearance.fontSize) {
      this.appearance.fontSize = next;
      this.applyAppearance();
    }
  }

  /** 捏合松手：最终字号经回调通知外部落库（组件不写库，职责见头注） */
  private onPinchEnd(): void {
    this.onFontSizeCommit(this.appearance.fontSize);
  }

  // ---------------------------------------------------------------- 帧流程

  /** 调度器每帧回调：true = 本帧发生了绘制（供自动休眠统计） */
  private renderFrame = (): boolean => {
    const terminal = this.terminal;
    if (!this.canvasReady || terminal === null ||
      this.cellWidthVp <= 0 || this.cellHeightVp <= 0) {
      return false;
    }
    const revision = terminal.getRevision();
    if (revision < 0) {
      return false; // 句柄失效
    }
    if (!this.needsFullRedraw && revision === this.lastRenderedRevision) {
      return false; // 无变化：整帧跳过（静止省电第一层）
    }
    const frame = terminal.beginFrame();
    if (frame === null) {
      return false;
    }
    // T9：帧元信息缓存（手势处理按最近一帧决策）；回滚量变化时同步钳制偏移
    this.lastAltScreen = frame.altScreen;
    this.lastMouseMode = frame.mouseMode;
    this.lastScrollbackCount = Math.max(0, frame.scrollbackTotal - frame.scrollbackOldest);
    if (this.scrollOffsetLines > this.lastScrollbackCount) {
      this.scrollOffsetLines = this.lastScrollbackCount;
      this.needsFullRedraw = true;
    }
    if (this.scrollOffsetLines > 0) {
      // T9 回滚视图：整窗重绘「回滚+主屏」拼接窗口（首版简化，见头注）。
      // 不 endFrame（脏位图保留，回到底部后由正常路径消费清位）；
      // 不画光标（光标在主屏，视口内无意义）。revision/尺寸照常记账——
      // 否则 needsFullRedraw 滞留会让回滚期间每个 vsync 都整窗重绘；
      // 远端新输出改变 revision 时仍会触发本分支重绘（视口锚定底部惯例）
      this.paintScrolledWindow(frame);
      this.lastRenderedRevision = frame.revision;
      this.lastGridCols = frame.cols;
      this.lastGridRows = frame.rows;
      this.needsFullRedraw = false;
      return true;
    }
    let drew = false;
    if (this.needsFullRedraw || frame.cols !== this.lastGridCols || frame.rows !== this.lastGridRows) {
      this.paintFull(frame);
      drew = true;
    } else if (frame.dirty !== undefined) {
      const ranges = collectDirtyRanges(frame.dirty, frame.rows);
      if (ranges.length > 0) {
        this.paintRanges(frame, ranges);
        drew = true;
      }
    } else {
      // revision 变了却没有脏行位图（napi 组包缺省）：无法确定脏区，兜底全量重绘
      this.paintFull(frame);
      drew = true;
    }
    if (drew && frame.cursorVisible) {
      this.paintCursor(frame);
    }
    if (drew && this.selection.selecting) {
      // T8：选区高亮叠加层（行内容之后、帧回执之前，随帧重绘）
      this.paintSelectionOverlay(frame);
    }
    // 受理回执：native 比对 revision 一致则清脏位图（并发撕裂下帧自愈，见 SshTerminal 头注）
    terminal.endFrame(frame.revision);
    this.lastRenderedRevision = frame.revision;
    this.lastGridCols = frame.cols;
    this.lastGridRows = frame.rows;
    this.needsFullRedraw = false;
    return drew;
  }

  /** 全量重绘：整底 + 全部行内容（首帧/尺寸变化/外观变化/onReady 清屏后） */
  private paintFull(frame: NativeTerminalFrame): void {
    const ctx = this.context;
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
      ctx.fillStyle = this.backgroundArgb;
      ctx.fillRect(0, env.originY + range.start * env.cellHeight, this.areaWidthVp,
        count * env.cellHeight);
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
   */
  private paintCursor(frame: NativeTerminalFrame): void {
    if (frame.cursorRow < 0 || frame.cursorRow >= frame.rows ||
      frame.cursorCol < 0 || frame.cursorCol >= frame.cols) {
      return;
    }
    const style = this.appearance.cursorStyle;
    const view = style === 'block'
      ? this.terminal?.readRows(frame, frame.cursorRow, 1) ?? null
      : null;
    this.execCommands(generateCursorCommands(style, view, frame.cursorCol, frame.cursorRow,
      frame.cols, this.renderEnv(), this.cursorArgb));
  }

  /** 执行绘制指令：先背景后文本；underline/strike 用 fillRect 画线 */
  private execCommands(cmds: RowDrawCommands): void {
    const ctx = this.context;
    for (const bg of cmds.backgrounds) {
      ctx.fillStyle = bg.argb;
      ctx.fillRect(bg.x, bg.y, bg.width, bg.height);
    }
    const thickness = Math.max(1, this.appearance.fontSize * TEXT_DECO_THICKNESS_FRACTION);
    let lastFont = ''; // font 赋值触发解析，是帧热路径上最贵的状态切换：相同则跳过
    for (const run of cmds.texts) {
      const font = this.fontFor(run.bold, run.italic);
      if (font !== lastFont) {
        ctx.font = font;
        lastFont = font;
      }
      ctx.fillStyle = run.fgArgb;
      ctx.fillText(run.text, run.x, run.y);
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
    this.measureCells();
    this.relayout();
    this.needsFullRedraw = true;
    FrameScheduler.get().wakeup();
  }

  private onCanvasAreaChange(oldArea: Area, newArea: Area): void {
    const w = newArea.width as number;
    const h = newArea.height as number;
    if (w === this.areaWidthVp && h === this.areaHeightVp) {
      return;
    }
    this.areaWidthVp = w;
    this.areaHeightVp = h;
    this.relayout();
    this.needsFullRedraw = true; // 尺寸变化后 onReady 会清画布
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
    this.scrollOffsetLines = 0;
    this.lastAltScreen = false;
    this.lastMouseMode = 0;
    this.lastScrollbackCount = 0;
    this.relayout(); // autoResizeTerminal 时把当前版面同步给新终端
    FrameScheduler.get().wakeup();
  }

  private onAppearanceChanged(): void {
    this.applyAppearance();
  }

  private onVisibleChanged(): void {
    FrameScheduler.get().setVisible(this.schedulerId, this.visible);
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
    this.measureCells();
    this.relayout();
    this.needsFullRedraw = true;
    FrameScheduler.get().wakeup();
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
    const m = measureTerminalCells(new CanvasTextMeasureContext(this.context), a.fontFamily,
      a.fontSize, a.fontWeight);
    this.fontNormal = m.fontNormal;
    this.fontBold = m.fontBold;
    this.fontItalic = m.fontItalic;
    this.fontBoldItalic = m.fontBoldItalic;
    this.context.font = this.fontNormal;
    this.context.textAlign = 'left';
    this.context.textBaseline = 'middle';
    let glyphWidth = m.glyphWidthVp;
    if (!m.measured) {
      // 字体未注册（启动注册失败的兜底路径）或度量失败的保底格宽。
      // 注意此时不落定 measuredFontKey：下次调用（如 onCanvasReady）会重测
      glyphWidth = a.fontSize * FALLBACK_CELL_WIDTH_FRACTION;
      this.measuredFontKey = '';
    }
    this.cellWidthVp = glyphWidth + a.letterSpacing;
    this.cellHeightVp = a.fontSize * a.lineHeight;
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
    const metrics = computeTerminalLayout(this.areaWidthVp, this.areaHeightVp,
      this.appearance.padding, this.cellWidthVp, this.cellHeightVp);
    this.layout = metrics;
    if (metrics.cols === this.notifiedCols && metrics.rows === this.notifiedRows) {
      return;
    }
    this.notifiedCols = metrics.cols;
    this.notifiedRows = metrics.rows;
    // T9：网格尺寸变化后回滚窗口的绝对行号语义失效，回到底部（resize 自愈）
    this.scrollOffsetLines = 0;
    this.onGridSizeChanged(metrics.cols, metrics.rows);
    if (this.autoResizeTerminal && this.terminal !== null) {
      this.terminal.resize(metrics.cols, metrics.rows); // 职责边界见文件头注
    }
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
      perGlyphText: this.appearance.letterSpacing !== 0
    };
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

  build() {
    Stack() {
      Canvas(this.context)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.onCanvasReady();
        })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.onCanvasAreaChange(oldArea, newArea);
        })
      // 隐藏 IME 承接框（T6）：1vp 近全透明、不拦截触摸，物理键 IME 前拦截
      ImeInputSink({
        sinkId: this.imeSinkId,
        onDelta: this.onImeDelta,
        onInterceptKey: this.onImeInterceptKey
      })
      // T8 气泡菜单（选择模式下；「粘贴/分享」归 U4）：复制 / 全选
      if (this.selectionMenuVisible) {
        Row({ space: MENU_GAP_VP * 2 }) {
          Text('复制')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.appBg)
            .padding({
              left: Tokens.space.md, right: Tokens.space.md,
              top: Tokens.space.xs, bottom: Tokens.space.xs
            })
            .onClick(() => {
              this.copySelection();
            })
          Text('全选')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.appBg)
            .padding({
              left: Tokens.space.md, right: Tokens.space.md,
              top: Tokens.space.xs, bottom: Tokens.space.xs
            })
            .onClick(() => {
              this.selectAllOnScreen();
            })
        }
        .height(MENU_HEIGHT_VP)
        .padding({ left: Tokens.space.xs, right: Tokens.space.xs })
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.md)
        .position({ x: this.selectionMenuX, y: this.selectionMenuY })
      }
    }
    .width('100%')
    .height('100%')
    // T8/T9 触摸手势：互斥识别（先识别到的胜出，其余取消）——
    // 快速点按 = 聚焦/退出选择（TapGesture，替代 onClick：长按后的抬指
    // 不会再误触发点击）；按住不动 = 进入选择；直接拖动 = 滚动/拖选；
    // 双指 = 捏合缩放。长按后的同指拖动被互斥取消，调整选区请抬手再拖。
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ fingers: 1, duration: LONG_PRESS_DURATION_MS })
          .onAction((event: GestureEvent) => {
            this.onLongPressSelect(event);
          }),
        PanGesture({ fingers: 1 })
          .onActionStart(() => {
            this.panLastOffsetY = 0;
            this.scrollAccumulator.reset();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.onPanUpdate(event);
          })
          .onActionEnd(() => {
            this.scrollAccumulator.reset();
          }),
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            this.pinchBaseFontSize = this.appearance.fontSize;
          })
          .onActionUpdate((event: GestureEvent) => {
            this.onPinchUpdate(event);
          })
          .onActionEnd(() => {
            this.onPinchEnd();
          }),
        TapGesture()
          .onAction(() => {
            this.onPaneClick();
          })
      )
    )
    .onKeyEvent((event: KeyEvent): boolean => {
      // 容器自身获焦时的物理键盘通路（API 15 起返回值可拦截冒泡）；
      // 子组件（ImeInputSink）获焦时按键先经其 onKeyPreIme，此处不再重复
      return this.handleKeyInput(event, false);
    })
  }
}
