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
 * 本组件尚不被任何页面使用（U4 才整合 TerminalPage），保持在 view/ 待用。
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
 *    T10 在这里扩，不要另开旁路。
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
import { measureTerminalCells, verifyCjkAlignment } from './terminal/FontMetrics';
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

/** 实例 id 自增序号（模块级；调度器注册用） */
let nextCanvasId = 0;

/** 字符度量失败（字体未注册）时的近似格宽系数 */
const FALLBACK_CELL_WIDTH_FRACTION = 0.6;
/** underline/strike 线宽 = 字号 × 该系数（下限 1vp） */
const TEXT_DECO_THICKNESS_FRACTION = 0.06;

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

  aboutToAppear(): void {
    this.applyAppearance();
    FrameScheduler.get().register(this.schedulerId, this.renderFrame);
    FrameScheduler.get().setVisible(this.schedulerId, this.visible);
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

  /** 点击窗格：聚焦本窗格（U4b 边框高亮经 FocusManager 监听器）+ 弹软键盘承接 IME */
  private onPaneClick(): void {
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
    if (preIme && !ctrl && !alt && isPrintableKeyCode(event.keyCode)) {
      return false;
    }
    if (!this.isInputTarget()) {
      return false; // 非聚焦窗格：物理输入不投递（路由验收标准）
    }
    const snap = this.stickyModifiers.snapshot();
    const mapped = mapKeyEvent(event.keyCode, this.queryModifierState(event, 'shift'),
      alt || snap.alt, ctrl || snap.ctrl, false, this.applicationCursorKeys);
    if (mapped === null) {
      return false; // 未映射键放行系统默认处理
    }
    this.sendInputBytes(mapped);
    this.stickyModifiers.consume(); // 一次性粘滞用完复位（locked 保持）
    return true;
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
    } catch (e) {
      // 外观配置非法（A 系列入库校验的兜底）：退回默认配色，渲染路径不能抛死
      Logger.warn(`TerminalCanvas 外观颜色非法，退回默认配色：${JSON.stringify(e)}`, 'Terminal');
      const fallback = createDefaultTerminalAppearance();
      this.paletteArgb = paletteToArgb(fallback.palette);
      this.defaultFgArgb = hexColorToArgb(fallback.foreground);
      this.defaultBgArgb = hexColorToArgb(fallback.background);
      this.cursorArgb = hexColorToArgb(fallback.cursorColor);
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
    const m = measureTerminalCells(this.context, a.fontFamily, a.fontSize, a.fontWeight);
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
      const r = verifyCjkAlignment(this.context, a.fontFamily, a.fontSize, a.fontWeight);
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
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      this.onPaneClick();
    })
    .onKeyEvent((event: KeyEvent): boolean => {
      // 容器自身获焦时的物理键盘通路（API 15 起返回值可拦截冒泡）；
      // 子组件（ImeInputSink）获焦时按键先经其 onKeyPreIme，此处不再重复
      return this.handleKeyInput(event, false);
    })
  }
}
