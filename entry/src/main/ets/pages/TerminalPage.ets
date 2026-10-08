/**
 * TerminalPage —— 终端主界面（任务 U4 / U4b，DESIGN §4.3.1 / §4.4 / §7.1 / §7.2）。
 *
 * 验收（U4）：「从主机列表点击到出现 shell 提示符全程无白屏、无跳变」——
 *   页面背景 = 终端底色；画布常驻，连接中/失败/重连/已结束以蒙层叠加。
 *
 * 验收（U4b）：多标签 + 分屏二叉树 + 拖分隔条 + 焦点路由 + 断点降级树保活。
 *   - 标签栏：左对齐、横滑、激活 / 关闭 / 选择连接；
 *   - 窗格区：按 VM.visiblePanes 绝对矩形铺 TerminalCanvas（focusId = paneId，
 *     输入经 FocusManager 只进聚焦叶；拖动中只改本地几何，松手后各自 request_pty_size）；
 *   - 分隔条：PanGesture 把位移 / span 折算成 ratio，VM.setDividerRatio；
 *   - sm：两窗格仍完整显示；仅 3+ 窗格降级聚焦叶，树与会话始终保活。
 *
 * 版面：沉浸式顶栏 + 标签栏 + 铺到页面底部的 PTY 窗格区；侧滑抽屉会话切换。
 * 退出：返回键 / ‹ = VM.detach（会话转入后台、终端寄存，主机列表「活动会话」可恢复）
 * + router.back；关末叶 / 末标签 → vm.shouldExit → VM.dispose 后退出。
 *
 * 版面体验：
 *   - 手机（sm）紧凑外框：单标签时隐藏标签栏；单窗格不再重复画窗格标题栏；
 *   - 全屏模式：隐藏顶栏 / 标签栏 / 状态栏，只留右上角半透明「退出全屏」；
 *   - 多窗格聚焦叶画强调色外框；状态（断线 / 重连 / 已结束）在已有画面时以
 *     窗格顶部横幅呈现，画面仍可滚动、选择、复制；
 *   - 所有可点控件触控热区 ≥ 40vp，并带无障碍朗读文案。
 */

// KeyboardAvoidMode 必须显式导入：全局作用域里另有一个同名旧枚举（没有 RESIZE），
// 不导入会解析到那一个并报「Property 'RESIZE' does not exist」
import { KeyboardAvoidMode, router, window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import {
  AppearanceProfile,
  HostProfile,
  createDefaultAppearanceProfile
} from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import { vibrateLight } from '../common/utils/Haptics';
import { SshTerminal } from '../napi/SshTerminal';
import { SettingsRepository } from '../repository/SettingsRepository';
import { AppDatabase } from '../repository/AppDatabase';
import { ScreenAwake } from '../service/ScreenAwake';
import { SessionManager } from '../service/SessionManager';
import { notifyConfigSaved } from '../service/sync/SyncHooks';
import { Tokens } from '../theme/Tokens';
import { isHexColor, normalizeHexColor, uniqueHexColors } from '../common/utils/HexColor';
import { ColorPickerSheet } from '../view/ColorPickerSheet';
import { KeyBar, keyFaceOverlayForBackground } from '../view/KeyBar';
import { TerminalActionHub, TerminalClipboardAction } from '../view/terminal/TerminalActionHub';
import { TerminalCanvas } from '../view/TerminalCanvas';
import { FrameScheduler } from '../view/FrameScheduler';
import { FocusManager } from '../view/terminal/FocusManager';
import { areaLengthToVp } from '../view/terminal/TerminalLayout';
import { StickyModifiers } from '../view/terminal/StickyModifiers';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance,
  terminalAppearanceFromProfile
} from '../view/terminal/TerminalAppearance';
import { filterHosts, sessionStateToStatus } from '../viewmodel/HostListViewModel';
import { DividerRect, PaneBreakpoint } from '../viewmodel/PaneTree';
import { ShortcutAction } from '../view/terminal/ShortcutMap';
import {
  OverlayModel,
  ConnectionOpenMode,
  PaneRenderItem,
  TabRenderItem,
  TerminalFocusHostLike,
  TerminalRouteParams,
  TerminalSessionLike,
  PasswordPromptModel,
  TerminalViewModel,
  deriveOverlay,
  overlayPresentation,
  parseTerminalRouteParams
} from '../viewmodel/TerminalViewModel';

const LOG_TAG: string = 'TerminalPage';

/** 抽屉宽度（vp）：Token 表无「抽屉宽度」项，沿用 HostEditPage 局部常量惯例 */
const SIDEBAR_WIDTH_VP: number = 360;
/** 连接中 LoadingProgress 尺寸（vp）：同上局部常量惯例 */
const LOADING_SIZE_VP: number = 48;
/** 断线置灰层不透明度（画面保留但明显变暗，§7.2） */
const DIM_OVERLAY_OPACITY: number = 0.55;
/** 标签标题最大宽度（vp）：Token 表无「标签宽度」项 */
const TAB_TITLE_MAX_WIDTH_VP: number = 160;
/** 密码补录框最大宽度（vp）：平板上不铺满，同上局部常量惯例 */
const PASSWORD_DIALOG_MAX_WIDTH_VP: number = 420;
/** 补录框遮罩不透明度 */
const SCRIM_OPACITY: number = 0.72;
/** 每个终端窗格自己的服务器标签栏高度；画布只占其余区域。 */
const PANE_HEADER_HEIGHT_VP: number = 32;
/** 顶栏定高：两行标题占位，切页签时不因 OSC 标题有无而伸缩。 */
const TOP_BAR_HEIGHT_VP: number = 48;
/** 标签栏定高：芯片 40 + 上下各 2。 */
const TAB_BAR_HEIGHT_VP: number = 44;
/** 最小触控热区（vp）：小图标的视觉尺寸可以更小，热区经 responseRegion 补足 */
const TOUCH_TARGET_VP: number = 40;
/** 小号关闭按钮的视觉尺寸（vp），热区仍是 TOUCH_TARGET_VP */
const SMALL_CLOSE_VISUAL_VP: number = 24;
/** 横幅模式下的置灰更轻：画面要可读、可选择 */
const BANNER_DIM_OPACITY: number = 0.28;
/** 全屏退出按钮不透明度（不挡内容但找得到） */
const FULLSCREEN_EXIT_OPACITY: number = 0.6;
/** 标签下拖超过此距离才进入分屏落点。 */
const TAB_DRAG_SPLIT_THRESHOLD_VP: number = 36;
/** 量不到芯片宽度时的幽灵标签兜底宽。 */
const TAB_DRAG_GHOST_WIDTH_VP: number = 148;
/** 分屏相交线视觉宽度；分隔条占位仍由布局的 divider 矩形决定，用作拖动热区。 */
const PANE_JOIN_LINE_VP: number = 1;
/** 分隔条最小触摸热区；视觉仍只有 1vp，热区向两侧覆盖，手机上更容易抓住。 */
const PANE_DIVIDER_HIT_SIZE_VP: number = 24;
/** 顶部图标按钮尺寸 = 最小触控热区。 */
const TOP_ACTION_SIZE_VP: number = 40;

interface TabChipGeom {
  x: number;
  y: number;
  w: number;
}

/**
 * 拖标签幽灵层自己持有位移 @State，避免每个手指采样都重跑 TerminalPage.build。
 * 页面只在开始 / 越过阈值 / 结束时改自己的 @State。
 */
class TabDragBridge {
  begin: (title: string, x: number, y: number, width: number) => void =
    (_title: string, _x: number, _y: number, _width: number): void => {
    };
  move: (x: number, y: number, ready: boolean) => void =
    (_x: number, _y: number, _ready: boolean): void => {
    };
  end: () => void = (): void => {
  };
}

@Component
struct TabDragGhost {
  bridge: TabDragBridge = new TabDragBridge();
  @Prop titleColor: string = '#E8EEFB';
  @Prop fillColor: string = '#0E131D';
  @Prop overlayColor: string = '#33FFFFFF';
  @State private visible: boolean = false;
  @State private ready: boolean = false;
  @State private title: string = '';
  @State private x: number = 0;
  @State private y: number = 0;
  @State private widthVp: number = TAB_DRAG_GHOST_WIDTH_VP;

  aboutToAppear(): void {
    this.bridge.begin = (title: string, x: number, y: number, width: number): void => {
      this.applyPose(title, x, y, width, false, true);
    };
    this.bridge.move = (x: number, y: number, ready: boolean): void => {
      this.applyPose(this.title, x, y, this.widthVp, ready, true);
    };
    this.bridge.end = (): void => {
      this.visible = false;
      this.ready = false;
    };
  }

  aboutToDisappear(): void {
    this.bridge.begin = (_title: string, _x: number, _y: number, _width: number): void => {
    };
    this.bridge.move = (_x: number, _y: number, _ready: boolean): void => {
    };
    this.bridge.end = (): void => {
    };
  }

  private applyPose(title: string, x: number, y: number, width: number, ready: boolean,
    visible: boolean): void {
    this.title = title;
    this.x = x;
    this.y = y;
    this.widthVp = width;
    this.ready = ready;
    this.visible = visible;
  }

  build() {
    Stack() {
      if (this.visible) {
        Row() {
          Column()
            .width(Tokens.space.xs2)
            .height(Tokens.space.md)
            .borderRadius(Tokens.space.xs2)
            .backgroundColor(Tokens.Color.accent)
            .margin({ right: Tokens.space.xs2 })
          Text(this.title)
            .fontSize(Tokens.fontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width(this.widthVp)
        .height(TOP_ACTION_SIZE_VP)
        .padding({ left: Tokens.space.xs, right: Tokens.space.xs2 })
        .borderRadius(Tokens.radius.sm)
        .backgroundColor(this.fillColor)
        .border({
          width: this.ready ? 2 : 1,
          color: this.ready ? Tokens.Color.accent : this.overlayColor
        })
        .shadow({
          radius: 12,
          color: '#4D000000',
          offsetX: 0,
          offsetY: 4
        })
        .position({ x: 0, y: 0 })
        .animation({ duration: 0 })
        .translate({ x: this.x, y: this.y })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}

/** 右侧抽屉开合时长。SideBarContainer 自带位移动画，这里统一其过渡节奏。 */
const SIDE_PANEL_ANIMATION_MS: number = 220;
/** 与 EntryAbility 窗口底色一致；离页时还原，避免把终端配色带出本页。 */
const DEFAULT_WINDOW_BACKGROUND: string = '#03060A';
/** 离开终端页时系统栏前景：深色窗口底上的浅色图标。 */
const DEFAULT_WINDOW_CHROME_FOREGROUND: string = '#D6F6FF';

type TerminalSidePanelMode = 'connections' | 'appearance';

function cloneAppearance(source: TerminalAppearance): TerminalAppearance {
  return {
    fontFamily: source.fontFamily,
    fontSize: source.fontSize,
    lineHeight: source.lineHeight,
    letterSpacing: source.letterSpacing,
    fontWeight: source.fontWeight,
    boldAsBright: source.boldAsBright,
    cursorStyle: source.cursorStyle,
    cursorBlink: source.cursorBlink,
    backgroundOpacity: source.backgroundOpacity,
    padding: source.padding,
    palette: source.palette.slice(),
    foreground: source.foreground,
    background: source.background,
    cursorColor: source.cursorColor,
    selectionColor: source.selectionColor
  };
}

/**
 * 带参 @Builder 的入参包装。
 *
 * ArkUI V1 的 @Builder 传普通参数是**按值**的：首次渲染后参数再变也不会刷新 builder
 * 内部的 UI。蒙层就是栽在这上面——kind 从 connecting 变 error 时外层 if 两边都成立、
 * 分支不切换，节点不重建，文案就永远停在「正在连接…／正在准备连接」。
 * ArkUI 规定按引用传递的范式是：唯一形参命名为 $$ 且类型为对象，调用处传对象字面量。
 */
interface TabChipParams {
  tab: TabRenderItem;
}

interface PaneSlotParams {
  item: PaneRenderItem;
}

interface DividerHandleParams {
  item: DividerRect;
}

interface StatusOverlayParams {
  model: OverlayModel;
  sessionId: string;
  paneId: string;
}

interface SessionRowParams {
  item: TerminalSessionLike;
}

interface HostRowParams {
  item: HostProfile;
}

interface AppearanceColorInputParams {
  label: string;
  value: string;
  kind: string;
}

/** 生产焦点宿主：转发给全局 FocusManager（画布点击 / 键条路由共用） */
class PageFocusHost implements TerminalFocusHostLike {
  register(id: string): boolean {
    return FocusManager.get().register(id);
  }

  unregister(id: string): boolean {
    return FocusManager.get().unregister(id);
  }

  focus(id: string): boolean {
    return FocusManager.get().focus(id);
  }

  addListener(cb: (id: string) => void): () => void {
    return FocusManager.get().addListener(cb);
  }
}

@Entry
@Component
struct TerminalPage {
  /** 自管右侧抽屉展开态。 */
  @State private showSideBar: boolean = false;
  @State private sidePanelMode: TerminalSidePanelMode = 'connections';
  @State private connectionOpenMode: ConnectionOpenMode = 'tab';
  /**
   * V1 @Component 订阅不到 VM 的 @ObservedV2/@Trace，且 V1 的观察粒度是**逐元素**的：
   * 单靠一个自增计数器只会刷新读到它的那一条属性，Builder / ForEach / if 分支一概不重算，
   * 画面会永远停在构造时的「正在连接…／正在准备连接」。
   * 因此这里把 build 读到的 VM 字段整体镜像成 @State，由 onUiChange → syncFromVm() 统一同步：
   * VM 每次 refreshViews/refreshLayout 都产出新数组/新对象，赋值即触发对应元素重绘。
   * 约定：build 与各 @Builder 只读下面这组 @State，不得直接读 this.vm 的 @Trace 字段。
   */
  /** 注意：字段名不能叫 overlay —— 与 CustomComponent 内置的 .overlay() 属性方法冲突 */
  @State private overlayModel: OverlayModel = deriveOverlay({
    state: '',
    reconnectCountdownSec: 0,
    reconnectAttempt: 0,
    errorMessage: '',
    hasTerminal: false,
    terminalClosed: false,
    startError: ''
  });
  @State private panes: PaneRenderItem[] = [];
  @State private dividerRects: DividerRect[] = [];
  @State private tabItems: TabRenderItem[] = [];
  /** 正在拖的标签；空串 = 未拖。幽灵层跟手，源标签只变淡。 */
  @State private tabDragId: string = '';
  @State private tabDragReady: boolean = false;
  private tabDragOriginX: number = 0;
  private tabDragOriginY: number = 0;
  private readonly tabDragBridge: TabDragBridge = new TabDragBridge();
  private readonly tabChipGeom: Map<string, TabChipGeom> = new Map();
  @State private sessions: TerminalSessionLike[] = [];
  @State private savedHosts: HostProfile[] = [];
  /** 右侧「选择连接」抽屉的搜索草稿；只过滤本面板列表。 */
  @State private connectionSearchText: string = '';
  @State private hostName: string = '';
  @State private terminalTitle: string = '';
  @State private sessionState: string = '';
  @State private currentSessionId: string = '';
  @State private breakpoint: PaneBreakpoint = 'sm';
  /** 外观缓存本身是 Map；revision 只负责通知 V1 Builder 重新取对应主机的对象。 */
  @State private appearanceRevision: number = 0;
  @State private appearanceBackgroundDraft: string = '#0E131D';
  @State private appearanceForegroundDraft: string = '#E8EEFB';
  @State private appearanceCursorDraft: string = '#4D8DFF';
  @State private appearanceFontSizeDraft: number = 14;
  @State private appearanceLineHeightDraft: number = 1.2;
  @State private appearanceSaveMessage: string = '';
  /** 选色盘：页面/外框/终端共用背景，以及文字、光标。 */
  @State private colorPickerVisible: boolean = false;
  @State private colorPickerTitle: string = '选择颜色';
  @State private colorPickerValue: string = '#0E131D';
  @State private colorPickerKind: string = 'background';
  @State private colorPickerPresets: string[] = [];
  /** 密码补录框状态（镜像 VM.passwordPrompt） */
  @State private passwordPrompt: PasswordPromptModel = {
    visible: false,
    hostName: '',
    busy: false,
    error: ''
  };
  /** 补录框内的密码草稿。只在提交时交给 VM，不落任何持久位置、不进日志 */
  @State private passwordDraft: string = '';
  /** 拖分隔条起点 ratio（onActionUpdate 相对此值累加，避免读到已更新的 item.ratio） */
  private dragStartRatio: number = 0.5;
  private dragSplitId: string = '';
  private pendingDividerRatio: number = 0.5;
  /** 拖动期间暂停向远端提交 PTY resize；画面几何仍逐采样实时更新。 */
  @State private dividerDragging: boolean = false;
  /** 终端页独占的全屏窗口引用；离页时恢复普通布局，避免影响其他页面。 */
  private terminalWindow: window.Window | null = null;
  private terminalPageVisible: boolean = false;
  /** 已应用到窗口/系统栏的底色，避免每次 syncFromVm 都重设。 */
  private appliedChromeBackground: string = '';
  /** 全屏布局只沉浸到底部；顶部仍避开系统状态栏。 */
  @State private terminalTopInsetVp: number = 0;
  /** 页面是否在前台（onPageHide → false：画布停绘、光标不闪） */
  @State private pageVisible: boolean = true;
  /** 全屏模式：隐藏顶栏 / 标签栏 / 状态栏 */
  @State private fullscreen: boolean = false;
  /** 进入全屏前的状态栏安全区（退出时恢复） */
  private savedTopInsetVp: number = 0;
  /** 触感总开关（C3 hapticEnabled；aboutToAppear 读取，读取失败保持默认 true） */
  private hapticEnabled: boolean = true;
  /** 功能键条自定义布局 JSON（C3 keyBarLayout；空串 = 内置默认） */
  private keyBarLayoutJson: string = '';
  /** 快捷键表 JSON（C3 keyboardShortcuts；空串 = 内置默认） */
  private shortcutBindingsJson: string = '';
  /** hostId → 终端外观；临时连接 hostId 也可拥有仅本次会话生效的缓存。 */
  private readonly appearancesByHost: Map<string, TerminalAppearance> = new Map();
  private appearanceBeforeEdit: TerminalAppearance | null = null;
  private appearanceEditingHostId: string = '';
  private appearanceEditCommitted: boolean = false;
  /** 从外框打开选盘时确定即保存；从侧栏打开只写草稿。 */
  private colorPickerPersistOnConfirm: boolean = false;
  /** 打开选盘时的原色，取消时还原这一项。 */
  private colorPickerOriginal: string = '';
  /** 与所有 TerminalCanvas 共享的粘滞修饰状态。 */
  private readonly stickyModifiers: StickyModifiers = new StickyModifiers();
  /** 视图模型：多标签/分屏编排 / 终端装配 / 蒙层派生 / 事件分发 */
  private readonly vm: TerminalViewModel = new TerminalViewModel({
    vibrate: (): void => {
      vibrateLight(this.hapticEnabled);
    },
    onContentDirty: (): void => {
      FrameScheduler.get().wakeup();
    },
    onUiChange: (): void => {
      this.syncFromVm();
    },
    onBell: (paneId: string): void => {
      // 已节流的视觉响铃：投递到对应画布闪一下
      TerminalActionHub.get().execute(paneId, 'bell');
    },
    focusHost: new PageFocusHost()
  });

  aboutToAppear(): void {
    this.terminalPageVisible = true;
    try {
      this.hapticEnabled = SettingsRepository.isHapticEnabled();
      this.shortcutBindingsJson = SettingsRepository.getKeyboardShortcuts();
      this.keyBarLayoutJson = SettingsRepository.getKeyBarLayout();
    } catch (err) {
      Logger.warn(`设置读取失败，使用默认值：${JSON.stringify(err)}`, LOG_TAG);
    }
    const rawParams: Object | null = this.readRouteParams();
    const params: TerminalRouteParams = parseTerminalRouteParams(rawParams);
    Logger.info(
      `终端页路由 hostIdLen=${params.hostId.length} sessionIdLen=${params.sessionId.length}`,
      LOG_TAG);
    this.vm.start(params).catch((err: Object) => {
      Logger.error(`终端页启动异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
    this.applyKeyboardAvoidMode();
    this.applyTerminalWindowLayout();
  }

  /** 从主机编辑页返回时刷新已保存连接；终端画布与会话本身不重建。 */
  onPageShow(): void {
    this.pageVisible = true;
    this.vm.reloadConnections();
    // 从键位编辑页返回：重新读布局
    try {
      this.keyBarLayoutJson = SettingsRepository.getKeyBarLayout();
    } catch (err) {
      Logger.warn(`键条布局读取失败：${JSON.stringify(err)}`, LOG_TAG);
    }
    // 常亮只在真正看着终端时生效：跳去主机编辑页那段时间不该压着系统不息屏
    ScreenAwake.get().setTerminalVisible(true);
    FrameScheduler.get().wakeup();
  }

  onPageHide(): void {
    // 页面被盖住 / 应用退后台：画布停绘（FrameScheduler setVisible false），光标停闪
    this.pageVisible = false;
    ScreenAwake.get().setTerminalVisible(false);
  }

  /**
   * 系统返回：先收起抽屉 / 退出全屏；否则「返回不断开」——会话转后台，
   * 主机列表可恢复。返回 true 表示已自行处理（不再走默认 router.back）。
   */
  onBackPress(): boolean {
    if (this.colorPickerVisible) {
      this.onColorPickerCancel();
      return true;
    }
    if (this.showSideBar) {
      this.closeSidePanel();
      return true;
    }
    if (this.fullscreen) {
      this.setFullscreen(false);
      return true;
    }
    this.onBack();
    return true;
  }

  /** 全屏开关：隐藏顶栏 / 标签栏 / 系统状态栏（键条保留，手机上仍要靠它输入特殊键） */
  private setFullscreen(on: boolean): void {
    if (this.fullscreen === on) {
      return;
    }
    this.fullscreen = on;
    if (on) {
      this.savedTopInsetVp = this.terminalTopInsetVp;
      this.terminalTopInsetVp = 0;
    } else {
      this.terminalTopInsetVp = this.savedTopInsetVp;
    }
    const win: window.Window | null = this.terminalWindow;
    if (win !== null) {
      win.setSpecificSystemBarEnabled('status', !on).catch((err: Object) => {
        Logger.warn(`状态栏显隐切换失败：${JSON.stringify(err)}`, LOG_TAG);
      });
    }
  }

  private toggleSoftKeyboard(): void {
    const paneId: string = this.vm.focusedPaneId;
    if (paneId.length > 0) {
      TerminalActionHub.get().execute(paneId, 'keyboard');
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      Logger.warn(`toast 失败：${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /**
   * 软键盘避让改用 RESIZE（默认是 OFFSET）。
   *
   * OFFSET 是整页上推：终端页顶栏会被推出屏幕，键盘还会盖住大半个终端。
   * RESIZE 让版面高度收缩到键盘上沿，窗格区变矮后
   * onAreaChange 会重算行数并 request_pty_size，远端跟着重排，符合终端的预期。
   * 只在本页生效：离开时恢复 OFFSET，避免影响主机编辑等表单页的滚动体感。
   */
  private applyKeyboardAvoidMode(): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (err) {
      Logger.warn(`设置键盘避让模式失败：${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /**
   * 让窗口内容真正布局到系统导航区底部。expandSafeArea 只能放开 ArkUI 节点，
   * 若窗口本身仍按安全区裁剪，PTY Canvas 的 visible bounds 仍会停在导航条上沿。
   */
  private applyTerminalWindowLayout(): void {
    const uiContext: UIContext = this.getUIContext();
    const hostContext: Context | undefined = uiContext.getHostContext();
    if (hostContext === undefined) {
      return;
    }
    window.getLastWindow(hostContext).then((win: window.Window) => {
      if (!this.terminalPageVisible) {
        return;
      }
      this.terminalWindow = win;
      try {
        const systemArea: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.terminalTopInsetVp = uiContext.px2vp(systemArea.topRect.height);
      } catch (err) {
        Logger.warn(`状态栏安全区读取失败：${JSON.stringify(err)}`, LOG_TAG);
      }
      win.setWindowLayoutFullScreen(true).catch((err: Object) => {
        Logger.warn(`终端全屏布局设置失败：${JSON.stringify(err)}`, LOG_TAG);
      });
      this.syncTerminalChromeColor();
    }).catch((err: Object) => {
      Logger.warn(`终端窗口获取失败：${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  /**
   * 把窗口底与系统栏刷成当前聚焦终端的底色，避免 SSH 画布外一圈露出
   * EntryAbility 的 #03060A 或 Page 默认色。
   */
  private syncTerminalChromeColor(): void {
    const win: window.Window | null = this.terminalWindow;
    if (win === null || !this.terminalPageVisible) {
      return;
    }
    const appearance: TerminalAppearance = this.focusedAppearance();
    if (appearance.background === this.appliedChromeBackground) {
      return;
    }
    this.appliedChromeBackground = appearance.background;
    this.applyWindowChrome(win, appearance.background, appearance.foreground);
  }

  private restoreWindowChrome(win: window.Window): void {
    this.applyWindowChrome(win, DEFAULT_WINDOW_BACKGROUND, DEFAULT_WINDOW_CHROME_FOREGROUND);
  }

  private applyWindowChrome(win: window.Window, background: string, foreground: string): void {
    try {
      win.setWindowBackgroundColor(background);
    } catch (err) {
      Logger.warn(`窗口底色设置失败：${JSON.stringify(err)}`, LOG_TAG);
    }
    const props: window.SystemBarProperties = {
      statusBarColor: background,
      navigationBarColor: background,
      statusBarContentColor: foreground,
      navigationBarContentColor: foreground
    };
    win.setWindowSystemBarProperties(props).catch((err: Object) => {
      Logger.warn(`系统栏颜色设置失败：${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  aboutToDisappear(): void {
    this.terminalPageVisible = false;
    ScreenAwake.get().setTerminalVisible(false);
    this.colorPickerVisible = false;
    this.terminalTopInsetVp = 0;
    this.dragSplitId = '';
    this.dividerDragging = false;
    const win: window.Window | null = this.terminalWindow;
    this.terminalWindow = null;
    this.appliedChromeBackground = '';
    if (win !== null) {
      if (this.fullscreen) {
        win.setSpecificSystemBarEnabled('status', true).catch((err: Object) => {
          Logger.warn(`恢复状态栏失败：${JSON.stringify(err)}`, LOG_TAG);
        });
      }
      this.restoreWindowChrome(win);
      win.setWindowLayoutFullScreen(false).catch((err: Object) => {
        Logger.warn(`恢复普通窗口布局失败：${JSON.stringify(err)}`, LOG_TAG);
      });
    }
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    } catch (err) {
      Logger.warn(`恢复键盘避让模式失败：${JSON.stringify(err)}`, LOG_TAG);
    }
    this.fullscreen = false;
    // 系统手势返回等未经 onBack 的离开路径：同样只转后台不断开（detach 幂等）
    this.vm.detach();
  }

  /**
   * VM（V2）→ 页面（V1）状态镜像。VM 每次刷新都重建数组与蒙层对象，
   * 故直接赋值即可让 @State 判定变更并驱动对应元素重绘。
   */
  private syncFromVm(): void {
    this.overlayModel = this.vm.overlay;
    this.panes = this.vm.visiblePanes;
    this.dividerRects = this.vm.dividers;
    this.tabItems = this.vm.tabs;
    this.sessions = this.vm.sessionList;
    this.savedHosts = this.vm.hostList;
    this.hostName = this.vm.hostName;
    this.terminalTitle = this.vm.terminalTitle;
    this.sessionState = this.vm.sessionState;
    this.currentSessionId = this.vm.currentSessionId;
    this.breakpoint = this.vm.breakpoint;
    this.passwordPrompt = this.vm.passwordPrompt;
    this.syncTerminalChromeColor();
  }

  /** 提交补录密码：提交后立刻清掉草稿，明文不在页面状态里多留一刻 */
  private submitPassword(): void {
    const draft: string = this.passwordDraft;
    if (draft.length === 0 || this.passwordPrompt.busy) {
      return;
    }
    this.passwordDraft = '';
    this.vm.submitPassword(draft).catch((err: Object) => {
      Logger.error(`密码补录提交异常: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  /** 路由参数读取（HostListPage 传入 hostId 或 sessionId；异常收敛为空，由 VM 落错误蒙层） */
  private readRouteParams(): Object | null {
    try {
      const params: Object | undefined = router.getParams();
      return params === undefined ? null : params;
    } catch (err) {
      Logger.warn(`路由参数解析失败: ${JSON.stringify(err)}`, LOG_TAG);
      return null;
    }
  }

  /**
   * 直接画在终端背景上的文字色。
   *
   * 不能用 Tokens.Color.text 一类跟随系统色彩模式的 Token：本页背景恒为终端外观的
   * 深色（appearance.background），而浅色模式下 app_text 是近黑的 #0B1C24，
   * 画上去几乎不可见（顶栏标题、蒙层文案全糊成一片）。故一律取外观自带的前景色。
   * 画在 Tokens 表面色上的文字（标签页、抽屉、蒙层按钮）不受影响，仍用 Token。
   */
  /**
   * ForEach 的 key 策略。
   *
   * ArkUI 的 ForEach 只在 key 变化时重跑 itemGenerator——key 相同就复用旧节点，
   * **构建函数根本不会被再次调用**，@Builder 的 $$ 按引用传参也救不回来。
   * 早期只用 paneId 做 key，于是窗格永远停在首帧那次 0×0 的布局，
   * 画布缩成左上角一个点（VM 侧矩形其实是对的）。
   * 因此 key 必须编码该项所有影响渲染的状态；几何取整避免亚像素抖动导致的无谓重建。
   */
  private rectKey(x: number, y: number, w: number, h: number): string {
    return `${Math.round(x)},${Math.round(y)},${Math.round(w)},${Math.round(h)}`;
  }

  /** 画布层 key：几何 + 焦点边框 + 终端是否已装配 */
  private paneCanvasKey(item: PaneRenderItem): string {
    return `${item.paneId}|${this.rectKey(item.x, item.y, item.w, item.h)}` +
      `|${item.focused}|${item.terminal !== null}`;
  }

  private dividerKey(item: DividerRect): string {
    return `${item.splitId}|${this.rectKey(item.x, item.y, item.w, item.h)}`;
  }

  private focusedHostId(): string {
    for (const pane of this.panes) {
      if (pane.focused) {
        return pane.hostId;
      }
    }
    return this.panes.length > 0 ? this.panes[0].hostId : '';
  }

  /** 按主机读取外观；缓存加载不会触碰终端实例，只替换其 @Prop 外观对象。 */
  private appearanceForHost(hostId: string): TerminalAppearance {
    // 显式读取 revision，确保 Map 内容替换后 V1 Builder 会重新求值。
    if (this.appearanceRevision < 0) {
      return createDefaultTerminalAppearance();
    }
    const key: string = hostId.length > 0 ? hostId : '__terminal_default__';
    const cached: TerminalAppearance | undefined = this.appearancesByHost.get(key);
    if (cached !== undefined) {
      return cached;
    }
    let appearance: TerminalAppearance = createDefaultTerminalAppearance();
    if (hostId.length > 0) {
      try {
        const host: HostProfile | null = AppDatabase.hosts().getById(hostId);
        if (host !== null && host.appearanceId !== null) {
          const profile: AppearanceProfile | null = AppDatabase.appearances().getById(host.appearanceId);
          if (profile !== null) {
            appearance = terminalAppearanceFromProfile(profile);
          }
        }
      } catch (err) {
        Logger.warn(`终端外观读取失败，使用 Harmony Dark：${JSON.stringify(err)}`, LOG_TAG);
      }
    }
    this.appearancesByHost.set(key, appearance);
    return appearance;
  }

  private focusedAppearance(): TerminalAppearance {
    return this.appearanceForHost(this.focusedHostId());
  }

  private appearanceDimForHost(hostId: string): string {
    const appearance: TerminalAppearance = this.appearanceForHost(hostId);
    return appearance.palette.length > 7 ? appearance.palette[7] : appearance.foreground;
  }

  private chromeText(): string {
    return this.focusedAppearance().foreground;
  }

  /** 画在终端底色上的浅罩，给标签/图标按钮当填充。 */
  private chromeOverlay(): string {
    return keyFaceOverlayForBackground(this.focusedAppearance().background);
  }

  /** 次级文字：取 ANSI 7（浅灰），调色板异常时回落到前景色 */
  private chromeTextDim(): string {
    const appearance: TerminalAppearance = this.focusedAppearance();
    return appearance.palette.length > 7 ? appearance.palette[7] : appearance.foreground;
  }

  private openConnectionsPanel(mode: ConnectionOpenMode): void {
    if (this.panes.length === 2 && (mode === 'row' || mode === 'column')) {
      this.vm.setActiveSplitDirection(mode);
      return;
    }
    if (this.colorPickerVisible) {
      this.onColorPickerCancel();
    }
    this.cancelAppearancePreviewIfNeeded();
    this.sidePanelMode = 'connections';
    this.connectionOpenMode = mode;
    this.connectionSearchText = '';
    this.vm.reloadConnections();
    this.showSideBar = true;
  }

  /** M6：当前会话 → SftpPage（带 sessionId；established 才能开 SFTP） */
  private openSftpForCurrentSession(): void {
    const sid: string = this.currentSessionId.length > 0
      ? this.currentSessionId
      : this.vm.currentSessionId;
    if (sid.length === 0) {
      return;
    }
    const params: Record<string, Object> = {};
    params['sessionId'] = sid;
    router.pushUrl({ url: 'pages/SftpPage', params: params });
  }

  /** M6：当前会话主机 → PortForwardPage */
  private openPortForwardForCurrentSession(): void {
    const sid: string = this.currentSessionId.length > 0
      ? this.currentSessionId
      : this.vm.currentSessionId;
    const params: Record<string, Object> = {};
    if (sid.length > 0) {
      params['sessionId'] = sid;
      const host: HostProfile | null = SessionManager.get().hostOf(sid);
      if (host !== null) {
        params['hostId'] = host.id;
        params['hostName'] = host.name.length > 0 ? host.name : host.host;
      }
    }
    router.pushUrl({ url: 'pages/PortForwardPage', params: params });
  }

  /** 已保存连接：复用主机列表的名称 / 地址 / 用户名过滤。 */
  private filteredSavedHosts(): HostProfile[] {
    return filterHosts(this.savedHosts, this.connectionSearchText);
  }

  /** 活跃会话：按主机名包含匹配；空串不过滤。 */
  private filteredSessions(): TerminalSessionLike[] {
    const keyword: string = this.connectionSearchText.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.sessions;
    }
    return this.sessions.filter((item: TerminalSessionLike) =>
      item.hostName.toLowerCase().includes(keyword));
  }

  private rememberTabChipArea(tabId: string, area: Area): void {
    const gx: Length | undefined = area.globalPosition.x;
    const gy: Length | undefined = area.globalPosition.y;
    const geom: TabChipGeom = {
      x: gx === undefined ? 0 : areaLengthToVp(gx),
      y: (gy === undefined ? 0 : areaLengthToVp(gy)) - this.terminalTopInsetVp,
      w: areaLengthToVp(area.width)
    };
    this.tabChipGeom.set(tabId, geom);
  }

  private tabChipPageGeom(tabId: string, event: GestureEvent): TabChipGeom {
    const stored: TabChipGeom | undefined = this.tabChipGeom.get(tabId);
    if (stored !== undefined && stored.w > 0) {
      return stored;
    }
    if (event.fingerList.length > 0) {
      const finger = event.fingerList[0];
      const ui: UIContext = this.getUIContext();
      return {
        x: ui.px2vp(finger.displayX) - finger.localX,
        y: ui.px2vp(finger.displayY) - finger.localY - this.terminalTopInsetVp,
        w: TAB_DRAG_GHOST_WIDTH_VP
      };
    }
    return { x: 0, y: TOP_BAR_HEIGHT_VP, w: TAB_DRAG_GHOST_WIDTH_VP };
  }

  private beginTabDrag(tab: TabRenderItem, event: GestureEvent): void {
    const geom: TabChipGeom = this.tabChipPageGeom(tab.tabId, event);
    this.tabDragOriginX = geom.x - event.offsetX;
    this.tabDragOriginY = geom.y - event.offsetY;
    this.tabDragId = tab.tabId;
    this.tabDragReady = false;
    this.tabDragBridge.begin(tab.title, geom.x, geom.y, geom.w);
  }

  private updateTabDrag(event: GestureEvent): void {
    if (this.tabDragId.length === 0) {
      return;
    }
    const ready: boolean = event.offsetY > TAB_DRAG_SPLIT_THRESHOLD_VP;
    this.tabDragBridge.move(
      this.tabDragOriginX + event.offsetX,
      this.tabDragOriginY + event.offsetY,
      ready);
    if (ready !== this.tabDragReady) {
      this.tabDragReady = ready;
    }
  }

  private endTabDrag(tabId: string, event: GestureEvent): void {
    const ready: boolean = this.tabDragReady || event.offsetY > TAB_DRAG_SPLIT_THRESHOLD_VP;
    this.cancelTabDrag();
    if (ready) {
      this.vm.dockTabAsSplit(tabId, 'row');
    }
  }

  private cancelTabDrag(): void {
    this.tabDragBridge.end();
    this.tabDragId = '';
    this.tabDragReady = false;
  }

  private colorDraftOf(kind: string): string {
    if (kind === 'foreground') {
      return this.appearanceForegroundDraft;
    }
    if (kind === 'cursor') {
      return this.appearanceCursorDraft;
    }
    return this.appearanceBackgroundDraft;
  }

  private colorPickerTitleOf(kind: string): string {
    if (kind === 'foreground') {
      return '文字颜色';
    }
    if (kind === 'cursor') {
      return '光标颜色';
    }
    return '页面 / 终端颜色';
  }

  private applyDraftColor(kind: string, hex: string): void {
    const normalized: string = normalizeHexColor(hex);
    if (kind === 'foreground') {
      this.appearanceForegroundDraft = normalized;
    } else if (kind === 'cursor') {
      this.appearanceCursorDraft = normalized;
    } else {
      this.appearanceBackgroundDraft = normalized;
    }
  }

  /** 打开选盘前确保有一份可撤销的外观快照，但不强行打开侧栏。 */
  private beginAppearanceEditIfNeeded(): void {
    if (this.appearanceBeforeEdit !== null) {
      return;
    }
    const hostId: string = this.focusedHostId();
    const appearance: TerminalAppearance = cloneAppearance(this.appearanceForHost(hostId));
    this.appearanceEditingHostId = hostId;
    this.appearanceBeforeEdit = cloneAppearance(appearance);
    this.appearanceEditCommitted = false;
    this.appearanceBackgroundDraft = appearance.background;
    this.appearanceForegroundDraft = appearance.foreground;
    this.appearanceCursorDraft = appearance.cursorColor;
    this.appearanceFontSizeDraft = appearance.fontSize;
    this.appearanceLineHeightDraft = appearance.lineHeight;
    this.appearanceSaveMessage = '';
  }

  private openColorPicker(kind: string, persistOnConfirm: boolean): void {
    this.beginAppearanceEditIfNeeded();
    this.colorPickerKind = kind;
    this.colorPickerPersistOnConfirm = persistOnConfirm;
    this.colorPickerOriginal = this.colorDraftOf(kind);
    this.colorPickerValue = this.colorPickerOriginal;
    this.colorPickerTitle = this.colorPickerTitleOf(kind);
    const appearance: TerminalAppearance = this.focusedAppearance();
    this.colorPickerPresets = uniqueHexColors([
      appearance.background,
      appearance.foreground,
      appearance.cursorColor
    ].concat(appearance.palette));
    this.colorPickerVisible = true;
  }

  private onColorPickerPreview(hex: string): void {
    this.applyDraftColor(this.colorPickerKind, hex);
    this.previewAppearanceDraft();
  }

  private onColorPickerConfirm(hex: string): void {
    this.applyDraftColor(this.colorPickerKind, hex);
    this.previewAppearanceDraft();
    this.colorPickerVisible = false;
    if (this.colorPickerPersistOnConfirm) {
      this.saveAppearanceDraft();
    }
  }

  private onColorPickerCancel(): void {
    this.applyDraftColor(this.colorPickerKind, this.colorPickerOriginal);
    this.previewAppearanceDraft();
    this.colorPickerVisible = false;
    if (this.colorPickerPersistOnConfirm && this.sidePanelMode !== 'appearance') {
      this.appearanceBeforeEdit = null;
    }
  }

  private openAppearancePanel(): void {
    if (this.colorPickerVisible) {
      this.onColorPickerCancel();
    }
    const hostId: string = this.focusedHostId();
    const appearance: TerminalAppearance = cloneAppearance(this.appearanceForHost(hostId));
    this.appearanceEditingHostId = hostId;
    this.appearanceBeforeEdit = cloneAppearance(appearance);
    this.appearanceEditCommitted = false;
    this.appearanceBackgroundDraft = appearance.background;
    this.appearanceForegroundDraft = appearance.foreground;
    this.appearanceCursorDraft = appearance.cursorColor;
    this.appearanceFontSizeDraft = appearance.fontSize;
    this.appearanceLineHeightDraft = appearance.lineHeight;
    this.appearanceSaveMessage = '';
    this.sidePanelMode = 'appearance';
    this.showSideBar = true;
  }

  private cancelAppearancePreviewIfNeeded(): void {
    if (this.sidePanelMode !== 'appearance' || this.appearanceEditCommitted) {
      return;
    }
    const before: TerminalAppearance | null = this.appearanceBeforeEdit;
    if (before !== null) {
      const key: string = this.appearanceEditingHostId.length > 0
        ? this.appearanceEditingHostId : '__terminal_default__';
      this.appearancesByHost.set(key, cloneAppearance(before));
      this.appearanceRevision++;
      this.syncTerminalChromeColor();
    }
    this.appearanceBeforeEdit = null;
  }

  /** 点击 PTY 或抽屉外任意区域时收起侧栏，并撤销尚未保存的外观预览。 */
  private closeSidePanel(): void {
    if (!this.showSideBar) {
      return;
    }
    this.cancelAppearancePreviewIfNeeded();
    this.showSideBar = false;
  }

  private previewAppearanceDraft(): void {
    if (!isHexColor(this.appearanceBackgroundDraft) ||
      !isHexColor(this.appearanceForegroundDraft) || !isHexColor(this.appearanceCursorDraft)) {
      this.appearanceSaveMessage = '颜色格式应为 #RRGGBB';
      return;
    }
    const current: TerminalAppearance = this.appearanceForHost(this.appearanceEditingHostId);
    const next: TerminalAppearance = cloneAppearance(current);
    next.background = this.appearanceBackgroundDraft.toUpperCase();
    next.foreground = this.appearanceForegroundDraft.toUpperCase();
    next.cursorColor = this.appearanceCursorDraft.toUpperCase();
    next.fontSize = this.appearanceFontSizeDraft;
    next.lineHeight = this.appearanceLineHeightDraft;
    const key: string = this.appearanceEditingHostId.length > 0
      ? this.appearanceEditingHostId : '__terminal_default__';
    this.appearancesByHost.set(key, next);
    this.appearanceSaveMessage = '';
    this.appearanceRevision++;
    this.syncTerminalChromeColor();
  }

  private adjustAppearanceFontSize(delta: number): void {
    this.appearanceFontSizeDraft =
      Math.max(8, Math.min(32, this.appearanceFontSizeDraft + delta));
    this.previewAppearanceDraft();
  }

  private adjustAppearanceLineHeight(delta: number): void {
    const next: number = Math.round((this.appearanceLineHeightDraft + delta) * 10) / 10;
    this.appearanceLineHeightDraft = Math.max(1, Math.min(2, next));
    this.previewAppearanceDraft();
  }

  private resetAppearanceDraft(): void {
    const fallback: TerminalAppearance = createDefaultTerminalAppearance();
    this.appearanceBackgroundDraft = fallback.background;
    this.appearanceForegroundDraft = fallback.foreground;
    this.appearanceCursorDraft = fallback.cursorColor;
    this.appearanceFontSizeDraft = fallback.fontSize;
    this.appearanceLineHeightDraft = fallback.lineHeight;
    this.previewAppearanceDraft();
  }

  /** Copy-on-write 保存：共享主题先克隆，避免改一个服务器连带改变其他服务器。 */
  private saveAppearanceDraft(): void {
    this.previewAppearanceDraft();
    if (this.appearanceSaveMessage.length > 0) {
      return;
    }
    const hostId: string = this.appearanceEditingHostId;
    const appearance: TerminalAppearance = cloneAppearance(this.appearanceForHost(hostId));
    const result: string = this.persistAppearance(hostId, appearance);
    if (result === 'failed') {
      this.appearanceSaveMessage = '保存失败，请稍后重试';
      return;
    }
    this.appearanceEditCommitted = true;
    if (result === 'temporary') {
      this.appearanceSaveMessage = '临时连接外观已在本次会话生效';
      this.showSideBar = false;
      return;
    }
    this.appearanceBeforeEdit = cloneAppearance(appearance);
    this.appearanceSaveMessage = '已保存到当前服务器';
    this.vm.reloadConnections();
    this.showSideBar = false;
  }

  /**
   * 把外观写入主机的外观配置（Copy-on-write：共享主题先克隆）。
   * 返回 'saved' / 'temporary'（临时连接，无主机记录）/ 'failed'。
   */
  private persistAppearance(hostId: string, appearance: TerminalAppearance): string {
    if (hostId.length === 0) {
      return 'temporary';
    }
    try {
      const host: HostProfile | null = AppDatabase.hosts().getById(hostId);
      if (host === null) {
        return 'temporary';
      }
      const storedProfile: AppearanceProfile | null = host.appearanceId === null
        ? null : AppDatabase.appearances().getById(host.appearanceId);
      let shared: boolean = false;
      if (storedProfile !== null) {
        const hosts: HostProfile[] = AppDatabase.hosts().listAll();
        let referenceCount: number = 0;
        for (const item of hosts) {
          if (item.appearanceId === storedProfile.id) {
            referenceCount++;
          }
        }
        shared = referenceCount > 1;
      }
      const insert: boolean = storedProfile === null || shared;
      let profile: AppearanceProfile = createDefaultAppearanceProfile(util.generateRandomUUID());
      if (!insert && storedProfile !== null) {
        profile = storedProfile;
      }
      if (insert) {
        profile.name = `${host.name.length > 0 ? host.name : host.host} 终端`;
      }
      profile.fontFamily = appearance.fontFamily;
      profile.fontSize = appearance.fontSize;
      profile.lineHeight = appearance.lineHeight;
      profile.letterSpacing = appearance.letterSpacing;
      profile.fontWeight = appearance.fontWeight;
      profile.boldAsBright = appearance.boldAsBright;
      profile.cursorStyle = appearance.cursorStyle;
      profile.cursorBlink = appearance.cursorBlink;
      profile.backgroundOpacity = appearance.backgroundOpacity;
      profile.padding = appearance.padding;
      profile.palette = appearance.palette.slice();
      profile.foreground = appearance.foreground;
      profile.background = appearance.background;
      profile.cursorColor = appearance.cursorColor;
      profile.selectionColor = appearance.selectionColor;
      if (insert) {
        AppDatabase.appearances().insert(profile);
        host.appearanceId = profile.id;
        AppDatabase.hosts().update(host);
      } else {
        AppDatabase.appearances().update(profile);
      }
      notifyConfigSaved();
      return 'saved';
    } catch (err) {
      Logger.error(`终端外观保存失败：${JSON.stringify(err)}`, LOG_TAG);
      return 'failed';
    }
  }

  /** 双指缩放松手：只提交一次（画布内部已做预览），并持久化到该服务器的外观 */
  private onPaneFontSizeCommit(hostId: string, fontSize: number): void {
    const appearance: TerminalAppearance = cloneAppearance(this.appearanceForHost(hostId));
    const size: number = Math.max(8, Math.min(32, fontSize));
    if (size === appearance.fontSize) {
      return;
    }
    appearance.fontSize = size;
    const key: string = hostId.length > 0 ? hostId : '__terminal_default__';
    this.appearancesByHost.set(key, appearance);
    this.appearanceRevision++;
    const result: string = this.persistAppearance(hostId, appearance);
    if (result === 'saved') {
      this.showToast(`字号 ${size} 已保存到当前服务器`);
    } else if (result === 'failed') {
      this.showToast(`字号 ${size} 仅本次生效（保存失败）`);
    }
  }

  /**
   * PanGesture 的更新本身跟随系统输入帧，直接提交本地几何可去掉固定 16ms 延迟。
   * VM 的拖动专用路径只复制两侧矩形，不再逐帧查询主机、会话与蒙层。
   */
  private updateDividerRatio(splitId: string, ratio: number): void {
    this.dragSplitId = splitId;
    this.pendingDividerRatio = ratio;
    this.vm.setDividerRatio(splitId, ratio);
  }

  private finishDividerDrag(): void {
    if (this.dragSplitId.length > 0) {
      // 强制发布最终 ratio 快照；TerminalCanvas 同时恢复 autoResize，向远端只提交一次。
      this.vm.setDividerRatio(this.dragSplitId, this.pendingDividerRatio, true);
    }
    this.dragSplitId = '';
    this.dividerDragging = false;
  }

  private canvasTerminalOf(item: PaneRenderItem): SshTerminal | null {
    return item.terminal as SshTerminal | null;
  }

  /** 返回：会话不断开，转入后台（主机列表「活动会话」可恢复） */
  private onBack(): void {
    const live: number = this.vm.liveSessionCount();
    this.vm.detach();
    if (live > 0) {
      this.showToast(live > 1 ? `${live} 个会话仍在后台运行，可在主机列表恢复` :
        '会话仍在后台运行，可在主机列表恢复');
    }
    router.back();
  }

  /** 关完最后一个窗格 / 标签：会话已全部关闭，直接退出 */
  private exitIfEmpty(): void {
    if (this.vm.shouldExit) {
      this.vm.dispose();
      router.back();
    }
  }

  /** 是否紧凑外框（手机竖屏等窄断点） */
  private isCompact(): boolean {
    return this.breakpoint === 'sm';
  }

  /** 紧凑外框下单标签不显示标签栏（标题已在顶栏） */
  private showTabBar(): boolean {
    return !this.isCompact() || this.tabItems.length > 1;
  }

  private focusedPaneItem(): PaneRenderItem | null {
    for (const pane of this.panes) {
      if (pane.focused) {
        return pane;
      }
    }
    return null;
  }

  private onPaneClose(paneId: string): void {
    this.vm.closePane(paneId);
    this.exitIfEmpty();
  }

  private onTabClose(tabId: string): void {
    this.vm.closeTab(tabId);
    this.exitIfEmpty();
  }

  // ---------------------------------------------------------------- 顶栏派生

  private topBarTitle(): string {
    if (this.terminalTitle.length > 0) {
      return this.terminalTitle;
    }
    return this.hostName.length > 0 ? this.hostName : '终端';
  }

  /** 第二行永远占位：有主机名且与主标题不同才显示，避免顶栏忽高忽低。 */
  private topBarSubtitle(): string {
    if (this.hostName.length > 0 && this.hostName !== this.topBarTitle()) {
      return this.hostName;
    }
    return ' ';
  }

  private statusColorOf(state: string): Resource {
    switch (sessionStateToStatus(state)) {
      case 'connecting':
        return Tokens.Color.accent;
      case 'established':
        return Tokens.Color.success;
      case 'disconnected':
        return Tokens.Color.warn;
      case 'error':
        return Tokens.Color.danger;
      default:
        return Tokens.Color.textFaint;
    }
  }

  private statusLabel(): string {
    switch (sessionStateToStatus(this.sessionState)) {
      case 'connecting':
        return '连接中';
      case 'established':
        return '已连接';
      case 'disconnected':
        return '已断开';
      case 'error':
        return '连接异常';
      default:
        return '未连接';
    }
  }

  // ---------------------------------------------------------------- 视图

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // Stack 包一层，好把密码补录框盖在整页之上。
      Stack() {
      Column() {
        if (!this.fullscreen) {
          this.TopBar()
          if (this.showTabBar()) {
            this.TabBar()
          }
        }

        Stack() {
          // 单窗格（绝大多数场景）不走 ForEach：ForEach 的 key 一旦含几何，
          // 软键盘弹出这类布局变化就会重建画布，连带销毁持有 IME 焦点的隐藏
          // TextInput，键盘输入再也进不来。@Builder 直接调用则是原地更新
          // 子组件 @Prop，画布节点保持存活。
          if (this.panes.length === 1) {
            this.SinglePaneSlot({ item: this.panes[0] })
          } else if (this.panes.length === 2) {
            // 双窗格是主交互：不用 ForEach，窗口缩放/键盘弹出时只更新几何，
            // 两个持有 IME 的 TerminalCanvas 都不会因 key 改变而重建。
            this.PaneSlot({ item: this.panes[0] })
            this.PaneSlot({ item: this.panes[1] })

            if (this.dividerRects.length === 1) {
              // 双窗格主路径不能用含几何的 ForEach key：坐标一变会重建节点并取消手势。
              // $$ 参数会原地更新位置，DividerHandle 及其 PanGesture 全程保持同一实例。
              this.DividerHandle({ item: this.dividerRects[0] })
            }
          } else {
            // 兼容历史快捷键创建的 3+ 窗格；页面主入口限制为双窗格。
            ForEach(this.panes, (item: PaneRenderItem) => {
              this.PaneSlot({ item: item })
            }, (item: PaneRenderItem) => this.paneCanvasKey(item))

            ForEach(this.dividerRects, (item: DividerRect) => {
              this.DividerHandle({ item: item })
            }, (item: DividerRect) => this.dividerKey(item))
          }

          // 多窗格：聚焦叶画强调色外框（独立图层，不参与命中，也不触发画布重建）
          if (this.panes.length > 1 && this.focusedPaneItem() !== null) {
            Column()
              .width((this.focusedPaneItem() as PaneRenderItem).w)
              .height((this.focusedPaneItem() as PaneRenderItem).h)
              .position({
                x: (this.focusedPaneItem() as PaneRenderItem).x,
                y: (this.focusedPaneItem() as PaneRenderItem).y
              })
              .border({ width: 2, color: Tokens.Color.accent })
              .opacity(0.85)
              .hitTestBehavior(HitTestMode.None)
          }

          // 补录框弹出期间不画蒙层：否则「正在连接」的转圈会盖在输入框后面误导用户
          if (this.panes.length === 0 && this.overlayModel.kind !== 'none'
            && !this.passwordPrompt.visible) {
            this.StatusOverlay({ model: this.overlayModel, sessionId: '', paneId: '' })
          }

          if (this.fullscreen) {
            Text('⤡')
              .fontSize(Tokens.fontSize.title)
              .fontColor(this.chromeText())
              .width(TOUCH_TARGET_VP)
              .height(TOUCH_TARGET_VP)
              .textAlign(TextAlign.Center)
              .borderRadius(TOUCH_TARGET_VP / 2)
              .backgroundColor(this.chromeOverlay())
              .opacity(FULLSCREEN_EXIT_OPACITY)
              .position({ x: '100%', y: 0 })
              .translate({ x: -TOUCH_TARGET_VP - 8, y: 8 })
              .accessibilityText('退出全屏')
              .onClick(() => {
                this.setFullscreen(false);
              })
          }

          if (this.tabDragReady) {
            Column() {
              Text('松手分屏')
                .fontSize(Tokens.fontSize.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.Color.onAccent)
                .padding({
                  left: Tokens.space.sm,
                  right: Tokens.space.sm,
                  top: Tokens.space.xs2,
                  bottom: Tokens.space.xs2
                })
                .borderRadius(Tokens.radius.sm)
                .backgroundColor(Tokens.Color.accent)
                .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs })
              Column()
                .width(PANE_JOIN_LINE_VP)
                .layoutWeight(1)
                .backgroundColor(Tokens.Color.accent)
            }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(this.focusedAppearance().background)
        // 必须由 PTY 工作区自身扩进导航手势安全区；只给外层 SideBarContainer
        // 设置 expandSafeArea 只会延伸页面底色，Canvas 仍会停在安全区上沿。
        .expandSafeArea(
          [SafeAreaType.SYSTEM],
          [SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.vm.setPaneAreaSize(
            areaLengthToVp(newArea.width), areaLengthToVp(newArea.height));
        })

        // T7 功能键条：有聚焦会话时挂在终端区下方；字节经 VM.sendInput 写聚焦叶
        if (this.panes.length > 0 && this.currentSessionId.length > 0) {
          this.KeyBarSlot()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.focusedAppearance().background)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.vm.setViewportWidth(areaLengthToVp(newArea.width));
      })

        if (this.passwordPrompt.visible) {
          this.PasswordPrompt()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.focusedAppearance().background)

      // 常驻遮罩位于整个主内容之上、右侧面板之下。隐藏时完全不参与命中；展开后
      // PTY/顶栏/标签栏的首次点击只负责关面板，不会穿透给 Canvas 手势或按钮。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#01000000')
        .opacity(this.showSideBar && !this.passwordPrompt.visible ? 1 : 0)
        .hitTestBehavior(this.showSideBar && !this.passwordPrompt.visible
          ? HitTestMode.Default : HitTestMode.None)
        .zIndex(10)
        .onClick(() => {
          this.closeSidePanel();
        })
        .animation({ duration: SIDE_PANEL_ANIMATION_MS, curve: Curve.EaseOut })

      // 自管右侧抽屉，避免 SideBarContainer 在宽屏 Overlay 模式下把主内容手势
      // 留给底层，导致“点弹窗外不关闭”。translate 与 opacity 共同完成弹出动画。
      Stack() {
        this.SideBar()
      }
      .width(SIDEBAR_WIDTH_VP)
      .height('100%')
      .translate({ x: this.showSideBar ? 0 : SIDEBAR_WIDTH_VP, y: 0 })
      .opacity(this.showSideBar ? 1 : 0)
      .hitTestBehavior(this.showSideBar ? HitTestMode.Default : HitTestMode.None)
      .zIndex(11)
      .animation({ duration: SIDE_PANEL_ANIMATION_MS, curve: Curve.EaseOut })

      TabDragGhost({
        bridge: this.tabDragBridge,
        titleColor: this.chromeText(),
        fillColor: this.focusedAppearance().background,
        overlayColor: this.chromeOverlay()
      })
        .width('100%')
        .height('100%')
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.None)
        .zIndex(16)

      if (this.colorPickerVisible) {
        ColorPickerSheet({
          visible: this.colorPickerVisible,
          title: this.colorPickerTitle,
          value: this.colorPickerValue,
          presets: this.colorPickerPresets,
          onPreview: (hex: string): void => {
            this.onColorPickerPreview(hex);
          },
          onConfirm: (hex: string): void => {
            this.onColorPickerConfirm(hex);
          },
          onCancel: (): void => {
            this.onColorPickerCancel();
          }
        })
          .width('100%')
          .height('100%')
          .zIndex(20)
      }
    }
    .width('100%')
    .height('100%')
    // 只保留系统状态栏安全区，不再叠加页面外部空隙。
    .padding({ top: this.terminalTopInsetVp })
    .backgroundColor(this.focusedAppearance().background)
    // 展开 BOTTOM/START/END：左右与底部手势条不再露出窗口默认底（#03060A）。
    // 不展开 TOP 是因为顶栏只有 space.sm 的上内边距，钻到状态栏下会跟时钟打架
    .expandSafeArea(
      [SafeAreaType.SYSTEM],
      [SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }

  /** 连接列表小图标：三行「点 + 横线」，比汉堡符更像会话清单。 */
  @Builder
  ConnectionGlyphRow() {
    Row() {
      Column()
        .width(Tokens.space.xs2)
        .height(Tokens.space.xs2)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(this.chromeText())
      Column()
        .width(Tokens.space.sm)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.chromeText())
        .opacity(0.8)
        .margin({ left: 2 })
    }
    .alignItems(VerticalAlign.Center)
  }

  /**
   * T7 功能键条：挂在终端区下方。
   * stickyModifiers 与 TerminalCanvas 共用同一实例；字节经 VM.sendInput 写聚焦叶；
   * 剪贴板动作经 TerminalActionHub 按 focusedPaneId 路由到对应画布。
   */
  @Builder
  KeyBarSlot() {
    // 扩进底部安全区：PTY 区 expandSafeArea 后，键条自身也要占到手势条上方
    Column() {
      KeyBar({
        stickyModifiers: this.stickyModifiers,
        layoutJson: this.keyBarLayoutJson,
        applicationCursorKeys: this.vm.applicationCursorKeys,
        hapticEnabled: this.hapticEnabled,
        appearance: this.focusedAppearance(),
        onSendBytes: (bytes: Uint8Array): void => {
          this.vm.sendInput(bytes);
        },
        onClipboardAction: (action: TerminalClipboardAction): void => {
          const paneId: string = this.vm.focusedPaneId;
          if (paneId.length > 0) {
            TerminalActionHub.get().execute(paneId, action);
          }
        }
      })
        .width('100%')
    }
    .width('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  /** 沉浸式顶栏：返回 + 终端标题/主机名 + 状态点/文案 + 抽屉开关 */
  @Builder
  TopBar() {
    Row() {
      Text('‹')
        .fontSize(Tokens.fontSize.headline)
        .fontColor(this.chromeText())
        .width(TOP_ACTION_SIZE_VP)
        .height(TOP_ACTION_SIZE_VP)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.radius.sm)
        .backgroundColor(this.chromeOverlay())
        .accessibilityText('返回主机列表，会话保持在后台')
        .onClick(() => {
          this.onBack();
        })

      Column() {
        Text(this.topBarTitle())
          .fontSize(Tokens.fontSize.title)
          .fontColor(this.chromeText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.topBarSubtitle())
          .fontSize(Tokens.fontSize.caption)
          .fontColor(this.chromeTextDim())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: Tokens.space.xs2 })
          .opacity(this.topBarSubtitle().length > 1 ? 1 : 0)
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .height('100%')
      .margin({ left: Tokens.space.xs })

      Row() {
        Column()
          .width(Tokens.space.xs)
          .height(Tokens.space.xs)
          .borderRadius(Tokens.space.xs2)
          .backgroundColor(this.statusColorOf(this.sessionState))
        if (!this.isCompact()) {
          Text(this.statusLabel())
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.chromeTextDim())
            .margin({ left: Tokens.space.xs2 })
        }
      }
      .accessibilityGroup(true)
      .accessibilityText(`连接状态：${this.statusLabel()}`)
      .padding({
        left: Tokens.space.xs,
        right: Tokens.space.xs,
        top: Tokens.space.xs2,
        bottom: Tokens.space.xs2
      })
      .backgroundColor(this.chromeOverlay())
      .borderRadius(Tokens.radius.sm)
      .margin({ left: Tokens.space.xs })

      if (this.currentSessionId.length > 0) {
        Text('⌨')
          .fontSize(Tokens.fontSize.title)
          .fontColor(this.chromeText())
          .width(TOP_ACTION_SIZE_VP)
          .height(TOP_ACTION_SIZE_VP)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.radius.sm)
          .backgroundColor(this.chromeOverlay())
          .margin({ left: Tokens.space.xs })
          .accessibilityText('显示或隐藏软键盘')
          .onClick(() => {
            this.toggleSoftKeyboard();
          })
      }

      Text('⤢')
        .fontSize(Tokens.fontSize.title)
        .fontColor(this.chromeText())
        .width(TOP_ACTION_SIZE_VP)
        .height(TOP_ACTION_SIZE_VP)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.radius.sm)
        .backgroundColor(this.chromeOverlay())
        .margin({ left: Tokens.space.xs })
        .accessibilityText('全屏')
        .onClick(() => {
          this.setFullscreen(true);
        })

      Text('⚙')
        .fontSize(Tokens.fontSize.title)
        .fontColor(this.chromeText())
        .width(TOP_ACTION_SIZE_VP)
        .height(TOP_ACTION_SIZE_VP)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.radius.sm)
        .backgroundColor(this.chromeOverlay())
        .margin({ left: Tokens.space.xs })
        .accessibilityText('终端外观与功能键设置')
        .onClick(() => {
          this.openAppearancePanel();
        })

      Row() {
        Column({ space: 2 }) {
          this.ConnectionGlyphRow()
          this.ConnectionGlyphRow()
          this.ConnectionGlyphRow()
        }
        .justifyContent(FlexAlign.Center)
        if (!this.isCompact()) {
          Text('连接')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.chromeText())
            .margin({ left: Tokens.space.xs2 })
        }
      }
      .height(TOP_ACTION_SIZE_VP)
      .constraintSize({ minWidth: TOP_ACTION_SIZE_VP })
      .justifyContent(FlexAlign.Center)
      .accessibilityGroup(true)
      .accessibilityText('连接与会话列表')
      .padding({ left: Tokens.space.xs, right: this.isCompact() ? Tokens.space.xs : Tokens.space.sm })
      .borderRadius(Tokens.radius.sm)
      .backgroundColor(this.chromeOverlay())
      .margin({ left: Tokens.space.xs })
      .onClick(() => {
        this.openConnectionsPanel('tab');
      })
    }
    .width('100%')
    .height(TOP_BAR_HEIGHT_VP)
    .padding({
      top: Tokens.space.xs,
      bottom: Tokens.space.xs,
      left: Tokens.space.xs,
      right: Tokens.space.xs
    })
    .backgroundColor(this.focusedAppearance().background)
    .clip(true)
  }

  /** md/lg 标签栏：胶囊标签 + 关闭 + 新建 + 分屏 */
  @Builder
  TabBar() {
    Row() {
      Scroll() {
        Row() {
          ForEach(this.tabItems, (tab: TabRenderItem) => {
            this.TabChip({ tab: tab })
            // key 含 active/title：否则切标签时高亮与标题不更新（同 paneCanvasKey 的道理）
          }, (tab: TabRenderItem) =>
            `${tab.tabId}|${tab.active}|${tab.title}|${tab.subtitle}|${tab.bell}|${tab.activity}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)
      .layoutWeight(1)

      Text('+')
        .fontSize(Tokens.fontSize.body)
        .fontColor(this.chromeTextDim())
        .width(TOP_ACTION_SIZE_VP)
        .height(TOP_ACTION_SIZE_VP)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.radius.sm)
        .backgroundColor(this.chromeOverlay())
        .margin({ left: Tokens.space.xs2 })
        .accessibilityText('新建标签')
        .onClick(() => {
          this.closeSidePanel();
          this.vm.openConnectionTab();
        })
      Row() {
        Row() {
          Column()
            .width(Tokens.space.xs)
            .height(Tokens.space.md)
            .borderRadius(Tokens.space.xs2)
            .backgroundColor(this.chromeText())
            .opacity(0.88)
          Column()
            .width(Tokens.space.xs)
            .height(Tokens.space.md)
            .borderRadius(Tokens.space.xs2)
            .backgroundColor(this.chromeText())
            .opacity(0.55)
            .margin({ left: 2 })
        }
        .alignItems(VerticalAlign.Center)
        Text('分屏')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(this.chromeText())
          .margin({ left: Tokens.space.xs2 })
      }
      .height(TOP_ACTION_SIZE_VP)
      .padding({ left: Tokens.space.xs, right: Tokens.space.sm })
      .borderRadius(Tokens.radius.sm)
      .backgroundColor(this.chromeOverlay())
      .margin({ left: Tokens.space.xs2 })
      .accessibilityGroup(true)
      .accessibilityText('分屏打开连接')
      .onClick(() => {
        this.openConnectionsPanel('row');
      })
    }
    .width('100%')
    .height(TAB_BAR_HEIGHT_VP)
    .padding({
      left: Tokens.space.xs,
      right: Tokens.space.xs,
      top: Tokens.space.xs2,
      bottom: Tokens.space.xs2
    })
    .backgroundColor(this.focusedAppearance().background)
    .border({ width: { bottom: 1 }, color: this.chromeOverlay() })
    .clip(true)
  }

  @Builder
  TabChip($$: TabChipParams) {
    Row() {
      Column()
        .width(Tokens.space.xs2)
        .height(Tokens.space.md)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor($$.tab.active ? Tokens.Color.accent : Color.Transparent)
        .margin({ right: Tokens.space.xs2 })
      Column() {
        Text($$.tab.title)
          .fontSize(Tokens.fontSize.caption)
          .fontWeight($$.tab.active ? FontWeight.Medium : FontWeight.Normal)
          .fontColor($$.tab.active ? this.chromeText() : this.chromeTextDim())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: TAB_TITLE_MAX_WIDTH_VP })
        if ($$.tab.subtitle.length > 0) {
          // OSC 标题（如 vim 文件名 / 当前目录）作第二行
          Text($$.tab.subtitle)
            .fontSize(10)
            .fontColor(this.chromeTextDim())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: TAB_TITLE_MAX_WIDTH_VP })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .height('100%')
      .onClick(() => {
        this.vm.activateTab($$.tab.tabId);
      })
      if ($$.tab.bell) {
        Text('🔔')
          .fontSize(10)
          .margin({ left: Tokens.space.xs2 })
          .accessibilityText('有响铃')
      } else if ($$.tab.activity) {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(Tokens.Color.accent)
          .margin({ left: Tokens.space.xs2 })
          .accessibilityText('有新输出')
      }
      Text('×')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(this.chromeTextDim())
        .width(SMALL_CLOSE_VISUAL_VP)
        .height(SMALL_CLOSE_VISUAL_VP)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.radius.xs)
        .margin({ left: Tokens.space.xs2 })
        .responseRegion({
          x: -(TOUCH_TARGET_VP - SMALL_CLOSE_VISUAL_VP) / 2,
          y: -(TOUCH_TARGET_VP - SMALL_CLOSE_VISUAL_VP) / 2,
          width: TOUCH_TARGET_VP,
          height: TOUCH_TARGET_VP
        })
        .accessibilityText(`关闭标签 ${$$.tab.title}`)
        .onClick(() => {
          this.onTabClose($$.tab.tabId);
        })
    }
    .accessibilityText(`${$$.tab.title}${$$.tab.active ? '，当前标签' : ''}` +
      `${$$.tab.bell ? '，有响铃' : ($$.tab.activity ? '，有新输出' : '')}`)
    .height(TOP_ACTION_SIZE_VP)
    .padding({ left: Tokens.space.xs, right: Tokens.space.xs2 })
    .backgroundColor($$.tab.active ? this.chromeOverlay() : Color.Transparent)
    .borderRadius(Tokens.radius.sm)
    .margin({ right: Tokens.space.xs2 })
    .opacity(this.tabDragId === $$.tab.tabId ? 0.28 : 1)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.rememberTabChipArea($$.tab.tabId, newArea);
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Vertical })
        .onActionStart((event: GestureEvent) => {
          this.beginTabDrag($$.tab, event);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.updateTabDrag(event);
        })
        .onActionEnd((event: GestureEvent) => {
          this.endTabDrag($$.tab.tabId, event);
        })
        .onActionCancel(() => {
          this.cancelTabDrag();
        })
    )
  }

  /**
   * 单窗格铺满渲染（不绝对定位、不进 ForEach，见 build 中的说明）。
   * 画布节点在整个会话生命周期内保持存活，IME 焦点与画布内部状态都不会丢。
   */
  @Builder
  SinglePaneSlot($$: PaneSlotParams) {
    // 单窗格不画窗格标题栏：主机名 / 状态已在顶栏，省下一行给终端
    Column() {
      if ($$.item.connectionPicker) {
        this.InlineConnectionPicker({ item: $$.item })
      } else {
        this.PaneCanvasBody({ item: $$.item })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.appearanceForHost($$.item.hostId).background)
  }

  /** 单个可见叶：稳定的标题栏 + 画布/状态蒙层。分屏框线只画在相交的分隔条上。 */
  @Builder
  PaneSlot($$: PaneSlotParams) {
    Column() {
      this.PaneHeader({ item: $$.item })
      if ($$.item.connectionPicker) {
        this.InlineConnectionPicker({ item: $$.item })
      } else {
        this.PaneCanvasBody({ item: $$.item })
      }
    }
    .width($$.item.w)
    .height($$.item.h)
    .position({ x: $$.item.x, y: $$.item.y })
    .backgroundColor(this.appearanceForHost($$.item.hostId).background)
    .onClick(() => {
      this.vm.focusPane($$.item.paneId);
    })
  }

  /** “+” 创建的新标签内容：连接选择发生在该标签内，不再占用当前标签或侧栏。 */
  @Builder
  InlineConnectionPicker($$: PaneSlotParams) {
    Column() {
      Text('新建连接')
        .fontSize(Tokens.fontSize.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.chromeText())
        .width('100%')
      Text('选择一个服务器，此标签将打开独立终端会话')
        .fontSize(Tokens.fontSize.body)
        .fontColor(this.chromeTextDim())
        .width('100%')
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.md })

      Scroll() {
        Column() {
          Text('已保存连接')
            .fontSize(Tokens.fontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.chromeTextDim())
            .width('100%')
            .margin({ bottom: Tokens.space.xs })

          if (this.savedHosts.length === 0) {
            Column() {
              Text('还没有保存的服务器')
                .fontSize(Tokens.fontSize.body)
                .fontColor(this.chromeText())
              Text('添加连接后，可直接在这个标签中打开终端。')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(this.chromeTextDim())
                .margin({ top: Tokens.space.xs2 })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Tokens.space.md)
            .border({ width: 1, color: Tokens.Color.border })
            .borderRadius(Tokens.radius.sm)
          } else {
            ForEach(this.savedHosts, (item: HostProfile) => {
              this.InlineHostRow({ item: item })
            }, (item: HostProfile) => `${item.id}|${item.name}|${item.host}|${item.port}`)
          }

        }
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)

      Button('+ 添加其他连接')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(36)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          router.pushUrl({ url: 'pages/HostEditPage' });
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .layoutWeight(1)
    .padding({
      left: Tokens.space.lg,
      right: Tokens.space.lg,
      top: Tokens.space.md,
      bottom: Tokens.space.md
    })
    .backgroundColor(this.focusedAppearance().background)
    .onClick(() => {
      this.vm.focusPane($$.item.paneId);
    })
  }

  @Builder
  InlineHostRow($$: HostRowParams) {
    Row() {
      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(Tokens.Color.accent)
      Column() {
        Text($$.item.name.length > 0 ? $$.item.name : $$.item.host)
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.chromeText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${$$.item.username}@${$$.item.host}:${$$.item.port}`)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(this.chromeTextDim())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: Tokens.space.sm })
      Text('连接')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.accent)
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .border({ width: 1, color: Tokens.Color.border })
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.xs })
    .onClick(() => {
      this.vm.openHost($$.item.id, 'replace').catch((err: Object) => {
        Logger.error(`在新标签打开连接失败：${JSON.stringify(err)}`, LOG_TAG);
      });
    })
  }

  @Builder
  PaneHeader($$: PaneSlotParams) {
    Row() {
      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(this.statusColorOf($$.item.state))
      Text($$.item.hostName.length > 0 ? $$.item.hostName : '终端')
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.appearanceForHost($$.item.hostId).foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: Tokens.space.xs })
      if ($$.item.endpoint.length > 0) {
        Text($$.item.endpoint)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(this.appearanceDimForHost($$.item.hostId))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: Tokens.space.xs })
      } else {
        Blank()
      }
      if (this.panes.length > 1) {
        Text('×')
          .fontSize(Tokens.fontSize.body)
          .fontColor(this.appearanceForHost($$.item.hostId).foreground)
          .width(SMALL_CLOSE_VISUAL_VP)
          .height(SMALL_CLOSE_VISUAL_VP)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.radius.xs)
          .backgroundColor(this.chromeOverlay())
          .responseRegion({
            x: -(TOUCH_TARGET_VP - SMALL_CLOSE_VISUAL_VP) / 2,
            y: -(TOUCH_TARGET_VP - SMALL_CLOSE_VISUAL_VP) / 2,
            width: TOUCH_TARGET_VP,
            height: TOUCH_TARGET_VP
          })
          .accessibilityText(`关闭窗格 ${$$.item.hostName}`)
          .onClick(() => {
            this.onPaneClose($$.item.paneId);
          })
      }
    }
    .width('100%')
    .height(PANE_HEADER_HEIGHT_VP)
    .padding({ left: Tokens.space.sm, right: Tokens.space.xs })
    .backgroundColor(this.appearanceForHost($$.item.hostId).background)
    .border({ width: { bottom: 1 }, color: this.chromeOverlay() })
    .onClick(() => {
      this.vm.focusPane($$.item.paneId);
    })
  }

  @Builder
  PaneCanvasBody($$: PaneSlotParams) {
    Stack() {
      TerminalCanvas({
        terminal: this.canvasTerminalOf($$.item),
        appearance: this.appearanceForHost($$.item.hostId),
        stickyModifiers: this.stickyModifiers,
        hapticEnabled: this.hapticEnabled,
        focusId: $$.item.paneId,
        autoFocus: $$.item.focused,
        visible: this.pageVisible,
        autoResizeTerminal: !this.dividerDragging,
        shortcutBindingsJson: this.shortcutBindingsJson,
        // T10 DECCKM：会话级应用光标键标志（native 未暴露前恒 false）
        applicationCursorKeys: this.vm.applicationCursorKeys,
        onFontSizeCommit: (fontSize: number): void => {
          this.onPaneFontSizeCommit($$.item.hostId, fontSize);
        },
        onAppShortcut: (action: ShortcutAction): boolean => {
          const handled: boolean = this.vm.handleShortcut(action);
          this.exitIfEmpty();
          return handled;
        }
      })

      if ($$.item.overlay.dimmed) {
        // 置灰层不参与命中：横幅模式下画面仍可滚动 / 选择 / 复制
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.appearanceForHost($$.item.hostId).background)
          .opacity(overlayPresentation($$.item.overlay, $$.item.terminal !== null) === 'banner'
            ? BANNER_DIM_OPACITY : DIM_OVERLAY_OPACITY)
          .hitTestBehavior(HitTestMode.None)
      }

      if (overlayPresentation($$.item.overlay, $$.item.terminal !== null) === 'banner') {
        this.StatusBanner({
          model: $$.item.overlay,
          sessionId: $$.item.sessionId,
          paneId: $$.item.paneId
        })
      } else if ($$.item.overlay.kind !== 'none') {
        this.StatusOverlay({
          model: $$.item.overlay,
          sessionId: $$.item.sessionId,
          paneId: $$.item.paneId
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding(0)
    .backgroundColor(this.appearanceForHost($$.item.hostId).background)
  }

  /** 分隔条：只在两窗格相交处画一条线；整条热区仍可拖。 */
  @Builder
  DividerHandle($$: DividerHandleParams) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width($$.item.direction === 'row' ? PANE_JOIN_LINE_VP : '100%')
        .height($$.item.direction === 'row' ? '100%' : PANE_JOIN_LINE_VP)
        .backgroundColor(this.chromeOverlay())
    }
    .width($$.item.direction === 'row' ?
      Math.max($$.item.w, PANE_DIVIDER_HIT_SIZE_VP) : $$.item.w)
    .height($$.item.direction === 'row' ?
      $$.item.h : Math.max($$.item.h, PANE_DIVIDER_HIT_SIZE_VP))
    .position({
      x: $$.item.direction === 'row'
        ? $$.item.x - (Math.max($$.item.w, PANE_DIVIDER_HIT_SIZE_VP) - $$.item.w) / 2 : $$.item.x,
      y: $$.item.direction === 'row'
        ? $$.item.y : $$.item.y - (Math.max($$.item.h, PANE_DIVIDER_HIT_SIZE_VP) - $$.item.h) / 2
    })
    .gesture(
      PanGesture({
        direction: $$.item.direction === 'row' ? PanDirection.Horizontal : PanDirection.Vertical
      })
        .onActionStart(() => {
          this.dragSplitId = $$.item.splitId;
          this.dragStartRatio = $$.item.ratio;
          this.pendingDividerRatio = $$.item.ratio;
          this.dividerDragging = true;
        })
        .onActionUpdate((event: GestureEvent) => {
          if ($$.item.span <= 0 || this.dragSplitId !== $$.item.splitId) {
            return;
          }
          const delta: number = $$.item.direction === 'row' ? event.offsetX : event.offsetY;
          this.updateDividerRatio($$.item.splitId, this.dragStartRatio + delta / $$.item.span);
        })
        .onActionEnd(() => {
          this.finishDividerDrag();
        })
        .onActionCancel(() => {
          this.finishDividerDrag();
        })
    )
  }

  /**
   * 密码补录框：凭据库里没有该主机密码时替代「无法进入终端」死路。
   * 卡片画在 Tokens 表面色上（跟随系统色彩模式），故此处文字仍用 Token 色，
   * 不走 chromeText()——那是给画在终端深色背景上的文字用的。
   */
  @Builder
  PasswordPrompt() {
    Stack() {
      // 遮罩独立成层：opacity 会作用于整个子树，跟卡片放一起会把卡片也弄成半透明。
      // 空 onClick 用来吃掉落向下面画布/键条的点击
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Tokens.Color.appBg)
        .opacity(SCRIM_OPACITY)
        .onClick(() => {
        })

      Column() {
      Column() {
        Text('需要登录密码')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Text(`请输入 ${this.passwordPrompt.hostName} 的登录密码`)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })

        TextInput({ placeholder: '登录密码', text: this.passwordDraft })
          .type(InputType.Password)
          .enterKeyType(EnterKeyType.Go)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .width('100%')
          .enabled(!this.passwordPrompt.busy)
          .margin({ top: Tokens.space.md })
          .onChange((value: string) => {
            this.passwordDraft = value;
          })
          .onSubmit(() => {
            this.submitPassword();
          })

        if (this.passwordPrompt.error.length > 0) {
          Text(this.passwordPrompt.error)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.danger)
            .margin({ top: Tokens.space.xs })
        }

        Text('密码将保存到系统加密凭据库，供本机重连使用。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
          .margin({ top: Tokens.space.xs })

        Row() {
          Button('取消')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .layoutWeight(1)
            .enabled(!this.passwordPrompt.busy)
            .onClick(() => {
              this.passwordDraft = '';
              this.vm.cancelPasswordPrompt();
            })

          Button(this.passwordPrompt.busy ? '连接中…' : '连接')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.onAccent)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .layoutWeight(1)
            .margin({ left: Tokens.space.sm })
            .enabled(!this.passwordPrompt.busy)
            .opacity(this.passwordPrompt.busy ? 0.6 : 1.0)
            .onClick(() => {
              this.submitPassword();
            })
        }
        .width('100%')
        .margin({ top: Tokens.space.lg })
      }
      .alignItems(HorizontalAlign.Start)
      // width 与 constraintSize 必须成对：只给 maxWidth 的话，卡片内子元素的
      // width('100%') 仍按整屏宽解析，输入框和按钮会溢出卡片右边
      .width('100%')
      .constraintSize({ maxWidth: PASSWORD_DIALOG_MAX_WIDTH_VP })
      .padding(Tokens.space.lg)
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.md)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .padding(Tokens.space.lg)
    }
    .width('100%')
    .height('100%')
  }

  /** 状态蒙层：连接中 / 重连倒计时 / 错误与操作按钮 / 会话已结束 */
  /**
   * 非阻塞状态横幅：已有终端画面时用它替代整窗格蒙层。
   * 只占窗格顶部一条，画面其余部分照常可滚动 / 选择 / 复制；操作按钮与蒙层一致。
   */
  @Builder
  StatusBanner($$: StatusOverlayParams) {
    Column() {
      Row() {
        if ($$.model.kind === 'connecting' || $$.model.kind === 'reconnecting') {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(Tokens.Color.accent)
            .margin({ right: Tokens.space.xs })
        } else {
          Column()
            .width(Tokens.space.xs)
            .height(Tokens.space.xs)
            .borderRadius(Tokens.space.xs2)
            .backgroundColor($$.model.kind === 'closed' ? Tokens.Color.textFaint : Tokens.Color.warn)
            .margin({ right: Tokens.space.xs })
        }
        Column() {
          Text($$.model.title)
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.text)
            .maxLines(1)
          if ($$.model.detail.length > 0) {
            Text($$.model.detail)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if ($$.model.showCancelReconnect) {
          Button('取消')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .height(TOUCH_TARGET_VP)
            .margin({ left: Tokens.space.xs })
            .accessibilityText('取消自动重连')
            .onClick(() => {
              this.vm.cancelAutoReconnectAt($$.sessionId);
            })
        }
        if ($$.model.showReconnectNow) {
          Button($$.model.kind === 'closed' ? '重新连接' : '重连')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.onAccent)
            .backgroundColor(Tokens.Color.accent)
            .height(TOUCH_TARGET_VP)
            .margin({ left: Tokens.space.xs })
            .onClick(() => {
              this.vm.reconnectNowAt($$.sessionId);
            })
        }
        if ($$.model.showClose) {
          Button('关闭')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .height(TOUCH_TARGET_VP)
            .margin({ left: Tokens.space.xs })
            .accessibilityText('关闭此窗格')
            .onClick(() => {
              this.onPaneClose($$.paneId);
            })
        }
      }
      .width('100%')
      .padding({
        left: Tokens.space.sm,
        right: Tokens.space.xs,
        top: Tokens.space.xs,
        bottom: Tokens.space.xs
      })
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.sm)
      .shadow({ radius: 8, color: '#40000000', offsetY: 2 })
    }
    .width('100%')
    .padding(Tokens.space.xs)
    .position({ x: 0, y: 0 })
    .accessibilityGroup(true)
  }

  @Builder
  StatusOverlay($$: StatusOverlayParams) {
    Column() {
      if ($$.model.kind === 'connecting' || $$.model.kind === 'reconnecting') {
        LoadingProgress()
          .width(LOADING_SIZE_VP)
          .height(LOADING_SIZE_VP)
          .color(Tokens.Color.accent)
      }
      Text($$.model.title)
        .fontSize(Tokens.fontSize.title)
        .fontColor(this.chromeText())
        .margin({ top: Tokens.space.md })
      if ($$.model.detail.length > 0) {
        Text($$.model.detail)
          .fontSize(Tokens.fontSize.body)
          .fontColor(this.chromeTextDim())
          .textAlign(TextAlign.Center)
          .margin({ top: Tokens.space.xs })
      }
      Row() {
        if ($$.model.showCancelReconnect) {
          Button('取消重连')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              if ($$.sessionId.length > 0) {
                this.vm.cancelAutoReconnectAt($$.sessionId);
              } else {
                this.vm.cancelAutoReconnect();
              }
            })
        }
        if ($$.model.showReconnectNow) {
          Button($$.model.kind === 'closed' ? '重新连接' : '立即重连')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.onAccent)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              if ($$.sessionId.length > 0) {
                this.vm.reconnectNowAt($$.sessionId);
              } else {
                this.vm.reconnectNow();
              }
            })
        }
        if ($$.model.showClose) {
          Button('关闭')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
            .onClick(() => {
              if ($$.paneId.length > 0) {
                this.onPaneClose($$.paneId);
              } else {
                this.onBack();
              }
            })
        }
      }
      .margin({ top: Tokens.space.lg })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Tokens.space.lg)
  }

  /** 横屏右侧面板：会话/连接选择与终端外观共用容器，内容始终从顶部开始。 */
  @Builder
  SideBar() {
    if (this.sidePanelMode === 'appearance') {
      this.AppearancePanel()
    } else {
      this.ConnectionPanel()
    }
  }

  @Builder
  ConnectionPanel() {
    Column() {
      Row() {
        Column() {
          Text('选择连接')
            .fontSize(Tokens.fontSize.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
          Text('选择打开位置，再选择服务器')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('×')
          .fontSize(Tokens.fontSize.title)
          .fontColor(Tokens.Color.textDim)
          .width(TOP_ACTION_SIZE_VP)
          .height(TOP_ACTION_SIZE_VP)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.cancelAppearancePreviewIfNeeded();
            this.showSideBar = false;
          })
      }
      .width('100%')

      Row({ space: Tokens.space.xs }) {
        this.ConnectionModeButton('切换', 'replace')
        this.ConnectionModeButton('新标签', 'tab')
        this.ConnectionModeButton('右分屏', 'row')
        this.ConnectionModeButton('下分屏', 'column')
      }
      .width('100%')
      .margin({ top: Tokens.space.md, bottom: Tokens.space.sm })

      // 会话工具：从顶栏收拢的次级入口，仍一键可达
      Row({ space: Tokens.space.xs }) {
        Button('文件传输')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(32)
          .layoutWeight(1)
          .enabled(this.currentSessionId.length > 0)
          .opacity(this.currentSessionId.length > 0 ? 1 : 0.45)
          .onClick(() => {
            this.showSideBar = false;
            this.openSftpForCurrentSession();
          })
        Button('端口转发')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(32)
          .layoutWeight(1)
          .enabled(this.currentSessionId.length > 0)
          .opacity(this.currentSessionId.length > 0 ? 1 : 0.45)
          .onClick(() => {
            this.showSideBar = false;
            this.openPortForwardForCurrentSession();
          })
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      TextInput({ text: this.connectionSearchText, placeholder: '搜索名称 / IP / 用户名...' })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .placeholderColor(Tokens.Color.textFaint)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .width('100%')
        .margin({ bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.connectionSearchText = value;
        })

      Scroll() {
        Column() {
          Text('活跃会话')
            .fontSize(Tokens.fontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.textDim)
            .width('100%')
            .margin({ top: Tokens.space.xs, bottom: Tokens.space.xs })

          if (this.filteredSessions().length === 0) {
            Text(this.connectionSearchText.trim().length > 0 ? '没有匹配的活跃会话' : '暂无活跃会话')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.textFaint)
              .width('100%')
              .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
          } else {
            ForEach(this.filteredSessions(), (item: TerminalSessionLike) => {
              this.SessionRow({ item: item })
            }, (item: TerminalSessionLike) =>
            `${item.sessionId}|${item.state}|${item.hostName}|${item.sessionId === this.currentSessionId}`)
          }

          Text('已保存连接')
            .fontSize(Tokens.fontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.textDim)
            .width('100%')
            .margin({ top: Tokens.space.md, bottom: Tokens.space.xs })

          if (this.filteredSavedHosts().length === 0) {
            Text(this.connectionSearchText.trim().length > 0 ? '没有匹配的已保存连接' : '暂无已保存连接')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.textFaint)
              .width('100%')
              .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
          } else {
            ForEach(this.filteredSavedHosts(), (item: HostProfile) => {
              this.HostRow({ item: item })
            }, (item: HostProfile) => `${item.id}|${item.name}|${item.host}|${item.port}`)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)

      Button('+ 添加其他连接')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(36)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          this.showSideBar = false;
          router.pushUrl({ url: 'pages/HostEditPage' });
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.surface)
    .padding(Tokens.space.md)
  }

  @Builder
  ConnectionModeButton(label: string, mode: ConnectionOpenMode) {
    Button(label)
      .fontSize(Tokens.fontSize.caption)
      .fontColor(this.connectionOpenMode === mode ? Tokens.Color.onAccent : Tokens.Color.textDim)
      .backgroundColor(
        this.connectionOpenMode === mode ? Tokens.Color.accent : Tokens.Color.surfaceHover)
      .borderRadius(Tokens.radius.sm)
      .height(30)
      .layoutWeight(1)
      .enabled(this.panes.length < 2 || (mode !== 'row' && mode !== 'column'))
      .opacity(this.panes.length < 2 || (mode !== 'row' && mode !== 'column') ? 1 : 0.45)
      .onClick(() => {
        this.connectionOpenMode = mode;
      })
  }

  /** 抽屉会话行：状态点 + 主机名 +「当前」标记；点击聚焦已有叶或替换聚焦叶 */
  @Builder
  SessionRow($$: SessionRowParams) {
    Row() {
      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(this.statusColorOf($$.item.state))
      Text($$.item.hostName.length > 0 ? $$.item.hostName : '未命名会话')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: Tokens.space.sm })
      if ($$.item.sessionId === this.currentSessionId) {
        Text('当前')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .margin({ left: Tokens.space.xs })
      }
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(
      $$.item.sessionId === this.currentSessionId ? Tokens.Color.surfaceHover : Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.xs })
    .onClick(() => {
      this.vm.openSession($$.item.sessionId, this.connectionOpenMode);
      this.showSideBar = false;
    })
  }

  @Builder
  HostRow($$: HostRowParams) {
    Row() {
      Column()
        .width(Tokens.space.xs)
        .height(Tokens.space.xs)
        .borderRadius(Tokens.space.xs2)
        .backgroundColor(Tokens.Color.textFaint)
      Column() {
        Text($$.item.name.length > 0 ? $$.item.name : $$.item.host)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${$$.item.username}@${$$.item.host}:${$$.item.port}`)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: Tokens.space.sm })
      Text('打开')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.accent)
    }
    .width('100%')
    .padding(Tokens.space.sm)
    .backgroundColor(Tokens.Color.surfaceHover)
    .borderRadius(Tokens.radius.sm)
    .margin({ bottom: Tokens.space.xs })
    .onClick(() => {
      const hostId: string = $$.item.id;
      const mode: ConnectionOpenMode = this.connectionOpenMode;
      this.showSideBar = false;
      this.vm.openHost(hostId, mode).catch((err: Object) => {
        Logger.error(`打开保存连接失败：${JSON.stringify(err)}`, LOG_TAG);
      });
    })
  }

  @Builder
  AppearancePanel() {
    Column() {
      Row() {
        Column() {
          Text('终端外观')
            .fontSize(Tokens.fontSize.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
          Text(this.hostName.length > 0 ? `当前服务器：${this.hostName}` : '当前终端')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('×')
          .fontSize(Tokens.fontSize.title)
          .fontColor(Tokens.Color.textDim)
          .width(TOP_ACTION_SIZE_VP)
          .height(TOP_ACTION_SIZE_VP)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.cancelAppearancePreviewIfNeeded();
            this.showSideBar = false;
          })
      }
      .width('100%')

      Scroll() {
        Column() {
          Text('页面、外框与终端画布共用同一背景色。')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .width('100%')
            .margin({ bottom: Tokens.space.xs })

          this.AppearanceColorInput({
            label: '页面 / 终端颜色', value: this.appearanceBackgroundDraft, kind: 'background'
          })
          this.AppearanceColorInput({
            label: '文字颜色', value: this.appearanceForegroundDraft, kind: 'foreground'
          })
          this.AppearanceColorInput({
            label: '光标颜色', value: this.appearanceCursorDraft, kind: 'cursor'
          })

          Row() {
            Column() {
              Text('字号')
                .fontSize(Tokens.fontSize.body)
                .fontColor(Tokens.Color.text)
              Text('8–32 vp')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button('−')
              .height(30)
              .width(36)
              .backgroundColor(Tokens.Color.surfaceHover)
              .fontColor(Tokens.Color.text)
              .onClick(() => this.adjustAppearanceFontSize(-1))
            Text(`${this.appearanceFontSizeDraft}`)
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .width(44)
              .textAlign(TextAlign.Center)
            Button('+')
              .height(30)
              .width(36)
              .backgroundColor(Tokens.Color.surfaceHover)
              .fontColor(Tokens.Color.text)
              .onClick(() => this.adjustAppearanceFontSize(1))
          }
          .width('100%')
          .padding({ top: Tokens.space.md, bottom: Tokens.space.md })
          .border({ width: { bottom: 1 }, color: Tokens.Color.border })

          Row() {
            Column() {
              Text('行高')
                .fontSize(Tokens.fontSize.body)
                .fontColor(Tokens.Color.text)
              Text('1.0–2.0 倍')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button('−')
              .height(30)
              .width(36)
              .backgroundColor(Tokens.Color.surfaceHover)
              .fontColor(Tokens.Color.text)
              .onClick(() => this.adjustAppearanceLineHeight(-0.1))
            Text(`${this.appearanceLineHeightDraft.toFixed(1)}`)
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .width(44)
              .textAlign(TextAlign.Center)
            Button('+')
              .height(30)
              .width(36)
              .backgroundColor(Tokens.Color.surfaceHover)
              .fontColor(Tokens.Color.text)
              .onClick(() => this.adjustAppearanceLineHeight(0.1))
          }
          .width('100%')
          .padding({ top: Tokens.space.md, bottom: Tokens.space.md })
          .border({ width: { bottom: 1 }, color: Tokens.Color.border })

          Text('点击色块打开选色盘；颜色实时预览。字号和行高变化会重算字符网格。')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .width('100%')
            .margin({ top: Tokens.space.md })

          if (this.appearanceSaveMessage.length > 0) {
            Text(this.appearanceSaveMessage)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(isHexColor(this.appearanceBackgroundDraft) ? Tokens.Color.accent : Tokens.Color.danger)
              .width('100%')
              .margin({ top: Tokens.space.sm })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .margin({ top: Tokens.space.md })

      Button('编辑功能键条…')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .height(TOUCH_TARGET_VP)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          this.cancelAppearancePreviewIfNeeded();
          this.showSideBar = false;
          router.pushUrl({ url: 'pages/KeyBarEditorPage' });
        })

      Row({ space: Tokens.space.xs }) {
        Button('恢复默认')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .backgroundColor(Tokens.Color.surfaceHover)
          .height(TOUCH_TARGET_VP)
          .layoutWeight(1)
          .onClick(() => this.resetAppearanceDraft())
        Button('取消')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .height(TOUCH_TARGET_VP)
          .layoutWeight(1)
          .onClick(() => {
            this.cancelAppearancePreviewIfNeeded();
            this.showSideBar = false;
          })
        Button('保存')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .height(TOUCH_TARGET_VP)
          .layoutWeight(1)
          .onClick(() => this.saveAppearanceDraft())
      }
      .width('100%')
      .margin({ top: Tokens.space.sm })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.surface)
    .padding(Tokens.space.md)
  }

  @Builder
  AppearanceColorInput($$: AppearanceColorInputParams) {
    Column() {
      Text($$.label)
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .width('100%')
      Row() {
        Column() {
          Blank()
          Column()
            .width('100%')
            .height(Tokens.space.xs2)
            .linearGradient({
              angle: 90,
              colors: [['#FF0000', 0], ['#FFFF00', 0.33], ['#00FFFF', 0.66], ['#FF00FF', 1]]
            })
        }
        .width(Tokens.space.xl)
        .height(Tokens.space.xl)
        .justifyContent(FlexAlign.End)
        .borderRadius(Tokens.radius.xs)
        .clip(true)
        .backgroundColor(isHexColor($$.value) ? $$.value : Tokens.Color.surfaceHover)
        .border({ width: 1, color: Tokens.Color.border })
        .onClick(() => {
          this.openColorPicker($$.kind, false);
        })
        TextInput({ text: $$.value, placeholder: '#RRGGBB' })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(36)
          .layoutWeight(1)
          .margin({ left: Tokens.space.sm })
          .onChange((next: string) => {
            if ($$.kind === 'background') {
              this.appearanceBackgroundDraft = next;
            } else if ($$.kind === 'foreground') {
              this.appearanceForegroundDraft = next;
            } else {
              this.appearanceCursorDraft = next;
            }
            this.previewAppearanceDraft();
          })
      }
      .width('100%')
      .margin({ top: Tokens.space.xs })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: Tokens.space.md, bottom: Tokens.space.md })
    .border({ width: { bottom: 1 }, color: Tokens.Color.border })
  }
}
