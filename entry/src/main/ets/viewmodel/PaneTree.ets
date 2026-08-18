/**
 * PaneTree —— 多标签与分屏的窗格树纯模型（任务 U4b，DESIGN §4.3.1）。
 *
 * 模型（与 tmux / iTerm2 同构）：
 *   TabSet → Tab（每个标签一棵独立的窗格树）→ PaneNode =
 *     Leaf（绑一个 SSH 会话 + 一个 TerminalCanvas）|
 *     Split { direction: 'row' | 'column', ratio, childA, childB }
 *
 * 本文件零 UI 依赖、零服务依赖：全部操作都是纯数据结构变换与纯函数，
 * 由 hypium 全量覆盖。会话开闭、终端装配、FocusManager 注册等编排副作用
 * 一律归 TerminalViewModel——本模型只回答「树怎么变 / 矩形怎么算 / 谁看得见」。
 *
 * 关键语义（§4.3.1 逐字落地）：
 *   - 分屏二叉树任意嵌套；拖分隔条 = setRatio 改 ratio（钳制 [0.1, 0.9]）；
 *   - 关闭 Leaf 时兄弟节点上提替换父 Split（保持树紧凑）；根 Leaf 关闭 = 关标签；
 *   - 两窗格在 sm 也完整显示，满足手机上的左右/上下双服务器对照；只有 3+ 窗格
 *     才在 sm 降级为聚焦 Leaf，且降级只改可见性不动树；
 *   - 布局（layoutPaneTree）：ratio 递归求矩形 + 分隔条占位；
 *     1px 舍入策略：childA 取 floor、childB 吃全部余量（总和严格等于可用
 *     尺寸，无累计缝隙，奇偶差恒落 B 侧）；零/负尺寸全部钳制收敛，不除零。
 *
 * id 生成：PaneTabSet 持有可注入的 PaneIdFactory（默认实例级自增序列，
 * 每个 PaneTabSet 独立计数，单测天然确定性）。
 */

/** 分屏方向：row = 左右并排（分隔条竖直，拖动改左右占比）；column = 上下堆叠 */
export type SplitDirection = 'row' | 'column';

/** 布局断点（DESIGN §4.3）：sm <600vp；md 600–840vp；lg >840vp */
export type PaneBreakpoint = 'sm' | 'md' | 'lg';

/** sm 上限（不含）：宽度 < 600vp 为 sm */
export const BREAKPOINT_SM_MAX_VP: number = 600;
/** md 上限（含）：600–840vp 为 md */
export const BREAKPOINT_MD_MAX_VP: number = 840;

/** ratio 钳制区间（§4.3.1：防止一侧被拖没导致另一侧重叠/不可恢复） */
export const PANE_MIN_RATIO: number = 0.1;
export const PANE_MAX_RATIO: number = 0.9;

/** 分隔条占位（vp）：对齐 space_xs；Token 是 Resource，布局纯函数必须用数值 */
export const PANE_DIVIDER_SIZE_VP: number = 8;

// ---------------------------------------------------------------- 树节点模型

/** 叶子窗格：绑一个 SSH 会话（sessionId '' = 连接受理在途）+ 一个 TerminalCanvas */
export interface PaneLeaf {
  readonly kind: 'leaf';
  readonly paneId: string;
  /** 绑定会话 id；会话切换/连接受理会改写（编排层职责），树结构不变 */
  sessionId: string;
}

/** 分屏节点：childA 占 direction 主轴的 ratio 份额，childB 吃余量 */
export interface PaneSplit {
  readonly kind: 'split';
  readonly splitId: string;
  direction: SplitDirection;
  /** childA 占比（钳制 [PANE_MIN_RATIO, PANE_MAX_RATIO]） */
  ratio: number;
  childA: PaneNode;
  childB: PaneNode;
}

export type PaneNode = PaneLeaf | PaneSplit;

/** 标签：一棵独立窗格树 + 标题（标题文案的实时投影归 VM，此字段为兜底） */
export interface PaneTab {
  readonly tabId: string;
  title: string;
  root: PaneNode;
}

/** 创建叶子（paneId 由调用方经 PaneTabSet.newPaneId 分配；sessionId 待受理后回填） */
export function createPaneLeaf(paneId: string): PaneLeaf {
  const leaf: PaneLeaf = { kind: 'leaf', paneId: paneId, sessionId: '' };
  return leaf;
}

// ---------------------------------------------------------------- 节点级纯函数（单棵树内查找/遍历）

/** 先序遍历全部叶子（childA 在前：视觉顺序 = 先左后右/先上后下） */
export function leavesOf(root: PaneNode): PaneLeaf[] {
  const result: PaneLeaf[] = [];
  collectLeaves(root, result);
  return result;
}

function collectLeaves(node: PaneNode, out: PaneLeaf[]): void {
  if (node.kind === 'leaf') {
    out.push(node);
    return;
  }
  collectLeaves(node.childA, out);
  collectLeaves(node.childB, out);
}

/** 遍历序首叶（关闭根 Leaf/焦点回退等场景的确定性候选） */
export function firstLeafOf(root: PaneNode): PaneLeaf | null {
  if (root.kind === 'leaf') {
    return root;
  }
  const fromA: PaneLeaf | null = firstLeafOf(root.childA);
  return fromA === null ? firstLeafOf(root.childB) : fromA;
}

/** 树内按 paneId 找叶子 */
export function findLeafInNode(root: PaneNode, paneId: string): PaneLeaf | null {
  if (root.kind === 'leaf') {
    return root.paneId === paneId ? root : null;
  }
  const fromA: PaneLeaf | null = findLeafInNode(root.childA, paneId);
  return fromA === null ? findLeafInNode(root.childB, paneId) : fromA;
}

/** 树内按 splitId 找分屏节点 */
export function findSplitInNode(root: PaneNode, splitId: string): PaneSplit | null {
  if (root.kind === 'leaf') {
    return null;
  }
  if (root.splitId === splitId) {
    return root;
  }
  const fromA: PaneSplit | null = findSplitInNode(root.childA, splitId);
  return fromA === null ? findSplitInNode(root.childB, splitId) : fromA;
}

/** 父 Split 引用：直接持有目标叶子的 Split 及目标所在侧 */
export interface ParentSplitRef {
  readonly parent: PaneSplit;
  /** true = 目标叶子是 parent.childA */
  readonly isChildA: boolean;
}

/** 找「直接持有 paneId 叶子」的父 Split（closeLeaf 兄弟上提的依据；根 Leaf 无父返回 null） */
export function findParentSplit(root: PaneNode, paneId: string): ParentSplitRef | null {
  if (root.kind === 'leaf') {
    return null;
  }
  if (root.childA.kind === 'leaf' && root.childA.paneId === paneId) {
    const ref: ParentSplitRef = { parent: root, isChildA: true };
    return ref;
  }
  if (root.childB.kind === 'leaf' && root.childB.paneId === paneId) {
    const ref: ParentSplitRef = { parent: root, isChildA: false };
    return ref;
  }
  const fromA: ParentSplitRef | null = findParentSplit(root.childA, paneId);
  return fromA === null ? findParentSplit(root.childB, paneId) : fromA;
}

// ---------------------------------------------------------------- 布局纯函数

/** 叶子的绝对矩形（vp，相对窗格区容器左上角） */
export interface PaneRect {
  readonly paneId: string;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

/** 分隔条的绝对矩形 + 拖动换算参数（span/ratio 供 PanGesture 把位移折算回 ratio） */
export interface DividerRect {
  readonly splitId: string;
  readonly direction: SplitDirection;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  /** 可分配长度（主轴总长减去分隔条占位；拖动位移 / span = ratio 增量） */
  readonly span: number;
  /** 当前 ratio（拖动起点快照用） */
  readonly ratio: number;
}

export interface PaneLayout {
  readonly leaves: PaneRect[];
  readonly dividers: DividerRect[];
}

/** 切焦点方向（Alt+方向键；按布局矩形找最近邻居） */
export type PaneFocusDirection = 'left' | 'right' | 'up' | 'down';

/**
 * 当前聚焦叶在 direction 上的最近邻居 paneId（'' = 该方向没有）。
 * 优先要求垂直于拖动轴的投影有重叠（真正「旁边」的那一格），
 * 没有重叠时回退到该方向上最近的任意叶（L 形布局也能切过去）。
 */
export function neighborLeafInDirection(leaves: PaneRect[], focusedPaneId: string,
  direction: PaneFocusDirection): string {
  let focused: PaneRect | null = null;
  for (const leaf of leaves) {
    if (leaf.paneId === focusedPaneId) {
      focused = leaf;
      break;
    }
  }
  if (focused === null) {
    return '';
  }
  const overlapPick: string = pickNeighbor(leaves, focused, direction, true);
  if (overlapPick.length > 0) {
    return overlapPick;
  }
  return pickNeighbor(leaves, focused, direction, false);
}

function pickNeighbor(leaves: PaneRect[], focused: PaneRect, direction: PaneFocusDirection,
  requireOverlap: boolean): string {
  const horizontal: boolean = direction === 'left' || direction === 'right';
  let bestId: string = '';
  let bestGap: number = Number.POSITIVE_INFINITY;
  let bestPerp: number = Number.POSITIVE_INFINITY;
  for (const other of leaves) {
    if (other.paneId === focused.paneId) {
      continue;
    }
    const gap: number = signedGap(focused, other, direction);
    if (gap < -1) {
      continue;
    }
    if (requireOverlap && !overlapsPerpendicular(focused, other, horizontal)) {
      continue;
    }
    const perp: number = perpendicularDistance(focused, other, horizontal);
    if (gap < bestGap || (gap === bestGap && perp < bestPerp)) {
      bestGap = gap;
      bestPerp = perp;
      bestId = other.paneId;
    }
  }
  return bestId;
}

function signedGap(from: PaneRect, to: PaneRect, direction: PaneFocusDirection): number {
  switch (direction) {
    case 'left':
      return from.x - (to.x + to.w);
    case 'right':
      return to.x - (from.x + from.w);
    case 'up':
      return from.y - (to.y + to.h);
    case 'down':
      return to.y - (from.y + to.h);
    default:
      return Number.POSITIVE_INFINITY;
  }
}

function overlapsPerpendicular(a: PaneRect, b: PaneRect, horizontalMove: boolean): boolean {
  if (horizontalMove) {
    return a.y < b.y + b.h && b.y < a.y + a.h;
  }
  return a.x < b.x + b.w && b.x < a.x + a.w;
}

function perpendicularDistance(a: PaneRect, b: PaneRect, horizontalMove: boolean): number {
  const aMid: number = horizontalMove ? a.y + a.h / 2 : a.x + a.w / 2;
  const bMid: number = horizontalMove ? b.y + b.h / 2 : b.x + b.w / 2;
  return Math.abs(aMid - bMid);
}

/**
 * 窗格树 → 绝对矩形布局（vp）。递归按 ratio 切分：
 *   - row：主轴 = 宽。可用宽 = max(0, w - dividerSize)，childA 宽 =
 *     floor(可用 × ratio)，childB 吃全部余量（1px 舍入策略，见文件头注）；
 *   - column：主轴 = 高，同理；
 *   - 零/负输入一律钳到 0（防除零/负尺寸）：可用长度 ≤ 0 时两侧子节点
 *     退化为 0 面积，分隔条吃掉剩余宽度，布局仍是全铺无洞的。
 */
export function layoutPaneTree(root: PaneNode, width: number, height: number,
  dividerSize: number): PaneLayout {
  const leaves: PaneRect[] = [];
  const dividers: DividerRect[] = [];
  const safeDivider: number = Math.max(0, dividerSize);
  layoutNode(root, Math.max(0, width), Math.max(0, height), 0, 0, safeDivider, leaves, dividers);
  const layout: PaneLayout = { leaves: leaves, dividers: dividers };
  return layout;
}

function layoutNode(node: PaneNode, w: number, h: number, x: number, y: number,
  dividerSize: number, leaves: PaneRect[], dividers: DividerRect[]): void {
  if (node.kind === 'leaf') {
    const rect: PaneRect = {
      paneId: node.paneId,
      x: x,
      y: y,
      w: Math.max(0, w),
      h: Math.max(0, h)
    };
    leaves.push(rect);
    return;
  }
  const horizontal: boolean = node.direction === 'row';
  const total: number = Math.max(0, horizontal ? w : h);
  const available: number = Math.max(0, total - dividerSize);
  const aLen: number = Math.floor(available * node.ratio);
  // 分隔条实际占位收敛：剩余不足一条分隔条时吃剩余（此时 childB 长度归零）
  const dLen: number = Math.min(dividerSize, Math.max(0, total - aLen));
  const bLen: number = Math.max(0, total - aLen - dLen);
  const divider: DividerRect = {
    splitId: node.splitId,
    direction: node.direction,
    x: horizontal ? x + aLen : x,
    y: horizontal ? y : y + aLen,
    w: horizontal ? dLen : Math.max(0, w),
    h: horizontal ? Math.max(0, h) : dLen,
    span: available,
    ratio: node.ratio
  };
  dividers.push(divider);
  if (horizontal) {
    layoutNode(node.childA, aLen, h, x, y, dividerSize, leaves, dividers);
    layoutNode(node.childB, bLen, h, x + aLen + dLen, y, dividerSize, leaves, dividers);
  } else {
    layoutNode(node.childA, w, aLen, x, y, dividerSize, leaves, dividers);
    layoutNode(node.childB, w, bLen, x, y + aLen + dLen, dividerSize, leaves, dividers);
  }
}

// ---------------------------------------------------------------- 断点降级纯函数

/** 窗格区宽度 → 断点（DESIGN §4.3：<600 sm；600–840 md；>840 lg） */
export function breakpointOfWidth(widthVp: number): PaneBreakpoint {
  // NaN 防护：两个比较对 NaN 都为 false，会静默落到 'lg'（曾导致断点误判成大屏、
  // 窗格矩形算成 NaN 而渲染为 0 尺寸）。非有限值一律按最保守的单窗格 'sm' 处理。
  if (!Number.isFinite(widthVp)) {
    return 'sm';
  }
  if (widthVp < BREAKPOINT_SM_MAX_VP) {
    return 'sm';
  }
  return widthVp <= BREAKPOINT_MD_MAX_VP ? 'md' : 'lg';
}

/**
 * 断点降级可见叶子集（树本身不动）：
 *   - sm：只返回含聚焦 Leaf 的单项；聚焦 Leaf 不在本标签（如焦点仍停在别的
 *     标签）时回退遍历序首叶——「单窗格渲染」必须始终有且仅有一个可见者；
 *   - md/lg：全量（md「最多 2 窗格」首版不做硬限制，见 VM 分屏入口注释）。
 */
export function visibleLeaves(root: PaneNode, focusedPaneId: string,
  breakpoint: PaneBreakpoint): PaneLeaf[] {
  const all: PaneLeaf[] = leavesOf(root);
  if (all.length === 0 || breakpoint !== 'sm') {
    return all;
  }
  for (const leaf of all) {
    if (leaf.paneId === focusedPaneId) {
      return [leaf];
    }
  }
  return [all[0]];
}

/**
 * 当前断点下应渲染的矩形（树本身不动）：
 *   - sm 且 3+ 叶：只给聚焦叶铺满，无分隔条；
 *   - sm 的 1–2 叶及 md/lg：完整 layoutPaneTree。
 */
export function layoutVisibleTree(root: PaneNode, focusedPaneId: string,
  breakpoint: PaneBreakpoint, width: number, height: number, dividerSize: number): PaneLayout {
  if (breakpoint === 'sm' && leavesOf(root).length > 2) {
    const vis: PaneLeaf[] = visibleLeaves(root, focusedPaneId, breakpoint);
    if (vis.length === 0) {
      const empty: PaneLayout = { leaves: [], dividers: [] };
      return empty;
    }
    const rect: PaneRect = {
      paneId: vis[0].paneId,
      x: 0,
      y: 0,
      w: Math.max(0, width),
      h: Math.max(0, height)
    };
    const layout: PaneLayout = { leaves: [rect], dividers: [] };
    return layout;
  }
  return layoutPaneTree(root, width, height, dividerSize);
}

// ---------------------------------------------------------------- TabSet

/** id 生成器（默认实例级自增序列；测试可注入更语义化的序列） */
export interface PaneIdFactory {
  newTabId(): string;
  newPaneId(): string;
  newSplitId(): string;
}

class SequentialPaneIdFactory implements PaneIdFactory {
  private tabSeq: number = 0;
  private paneSeq: number = 0;
  private splitSeq: number = 0;

  newTabId(): string {
    this.tabSeq++;
    return `tab-${this.tabSeq}`;
  }

  newPaneId(): string {
    this.paneSeq++;
    return `pane-${this.paneSeq}`;
  }

  newSplitId(): string {
    this.splitSeq++;
    return `split-${this.splitSeq}`;
  }
}

export interface AddTabResult {
  readonly tab: PaneTab;
  readonly leaf: PaneLeaf;
}

export interface CloseLeafResult {
  /** 被关闭的叶子（其 sessionId 供编排层释放会话） */
  readonly closedLeaf: PaneLeaf;
  /** 根 Leaf 关闭 = 整标签移除（树随标签销毁，会话由编排层关） */
  readonly tabClosed: boolean;
  /** 受影响标签 id（tabClosed 时已从 TabSet 摘除） */
  readonly tabId: string;
  /** 关闭后的焦点候选（策略见 nextFocusAfterClose；'' = 无剩余窗格可聚焦） */
  readonly nextFocusPaneId: string;
}

/**
 * 标签集（多标签 + 每标签一棵窗格二叉树）。
 * 纯数据结构：所有方法同步、不抛（未知 id 返回 null/false），可全量单测。
 */
export class PaneTabSet {
  /** 全部标签（保持创建序；激活态由 activeTabId 表达） */
  readonly tabs: PaneTab[] = [];
  /** 当前激活标签（'' = 无标签） */
  activeTabId: string = '';

  private readonly ids: PaneIdFactory;

  constructor(ids?: PaneIdFactory) {
    this.ids = ids ?? new SequentialPaneIdFactory();
  }

  newPaneId(): string {
    return this.ids.newPaneId();
  }

  /** 新建标签（单 Leaf 树）并激活；paneId 缺省由工厂分配（首窗格可传固定 id） */
  addTab(title: string, paneId?: string): AddTabResult {
    const leaf: PaneLeaf = createPaneLeaf(paneId === undefined ? this.ids.newPaneId() : paneId);
    const tab: PaneTab = { tabId: this.ids.newTabId(), title: title, root: leaf };
    this.tabs.push(tab);
    this.activeTabId = tab.tabId;
    const result: AddTabResult = { tab: tab, leaf: leaf };
    return result;
  }

  /**
   * 关闭标签（树随标签销毁；会话释放是编排层职责，先经 leavesOf 取叶子再调本方法）。
   * 激活策略：关掉的是激活标签时，优先上提左侧邻居（原 index-1），否则取补位者
   * （关闭首标签后原第二个顶上）；关非激活标签不影响激活态。
   *
   * @returns 被移除的标签（null = 未知 tabId）
   */
  closeTab(tabId: string): PaneTab | null {
    const index: number = this.tabIndexOf(tabId);
    if (index < 0) {
      return null;
    }
    const removed: PaneTab = this.tabs[index];
    this.tabs.splice(index, 1);
    if (this.activeTabId === tabId) {
      if (this.tabs.length === 0) {
        this.activeTabId = '';
      } else {
        const next: PaneTab = this.tabs[Math.min(Math.max(index - 1, 0), this.tabs.length - 1)];
        this.activeTabId = next.tabId;
      }
    }
    return removed;
  }

  /** 激活标签（未知 id 返回 false，激活态不动） */
  activateTab(tabId: string): boolean {
    if (this.findTab(tabId) === null) {
      return false;
    }
    this.activeTabId = tabId;
    return true;
  }

  activeTab(): PaneTab | null {
    return this.findTab(this.activeTabId);
  }

  findTab(tabId: string): PaneTab | null {
    for (const tab of this.tabs) {
      if (tab.tabId === tabId) {
        return tab;
      }
    }
    return null;
  }

  /** 全标签集按 paneId 找叶子 */
  findLeaf(paneId: string): PaneLeaf | null {
    const tab: PaneTab | null = this.tabOfPane(paneId);
    return tab === null ? null : findLeafInNode(tab.root, paneId);
  }

  /** 叶子所在标签 */
  tabOfPane(paneId: string): PaneTab | null {
    for (const tab of this.tabs) {
      if (findLeafInNode(tab.root, paneId) !== null) {
        return tab;
      }
    }
    return null;
  }

  /** 按 sessionId 找寄宿它的叶子（会话切换「聚焦其所在 Leaf」的依据） */
  leafBySession(sessionId: string): PaneLeaf | null {
    for (const tab of this.tabs) {
      const leaves: PaneLeaf[] = leavesOf(tab.root);
      for (const leaf of leaves) {
        if (leaf.sessionId === sessionId) {
          return leaf;
        }
      }
    }
    return null;
  }

  /**
   * 分屏：目标 Leaf 原位变为 Split { direction, ratio=0.5, childA=原叶, childB=新叶 }
   * （原叶保持 childA 侧——视觉位置不动，新叶出现在 B 侧）。
   *
   * @returns 新建的 Split 节点（null = 目标不存在或不是叶子——不可能，防呆）
   */
  splitLeaf(paneId: string, direction: SplitDirection, newLeaf: PaneLeaf): PaneSplit | null {
    const tab: PaneTab | null = this.tabOfPane(paneId);
    if (tab === null) {
      return null;
    }
    const target: PaneLeaf | null = findLeafInNode(tab.root, paneId);
    if (target === null) {
      return null;
    }
    const split: PaneSplit = {
      kind: 'split',
      splitId: this.ids.newSplitId(),
      direction: direction,
      ratio: 0.5,
      childA: target,
      childB: newLeaf
    };
    if (tab.root.kind === 'leaf' && tab.root.paneId === paneId) {
      tab.root = split;
      return split;
    }
    const ref: ParentSplitRef | null = findParentSplit(tab.root, paneId);
    if (ref === null) {
      return null;
    }
    if (ref.isChildA) {
      ref.parent.childA = split;
    } else {
      ref.parent.childB = split;
    }
    return split;
  }

  /**
   * 把另一棵窗格树接到目标标签根上，成为 Split 的 B 侧（原树留在 A 侧）。
   * 用于「拖标签到当前画面分屏」：源标签先 closeTab 摘下，再把其 root 交来。
   */
  dockTree(targetTabId: string, incoming: PaneNode, direction: SplitDirection): PaneSplit | null {
    const tab: PaneTab | null = this.findTab(targetTabId);
    if (tab === null) {
      return null;
    }
    const split: PaneSplit = {
      kind: 'split',
      splitId: this.ids.newSplitId(),
      direction: direction,
      ratio: 0.5,
      childA: tab.root,
      childB: incoming
    };
    tab.root = split;
    return split;
  }

  /**
   * 关闭叶子（兄弟上提，保持树紧凑）：
   *   - 非根 Leaf：父 Split 被兄弟子树整体替换（兄弟可能是 Leaf 或 Split，
   *     嵌套场景递归成立——祖父节点直接改指向兄弟子树）；
   *   - 根 Leaf：整标签关闭（= closeTab）。
   * 焦点候选在变更前按 nextFocusAfterClose 预算（变更后兄弟已上提，依据丢失）。
   */
  closeLeaf(paneId: string): CloseLeafResult | null {
    const tab: PaneTab | null = this.tabOfPane(paneId);
    if (tab === null) {
      return null;
    }
    const leaf: PaneLeaf | null = findLeafInNode(tab.root, paneId);
    if (leaf === null) {
      return null;
    }
    const nextFocus: string = this.nextFocusAfterClose(tab.tabId, paneId);
    if (tab.root.kind === 'leaf') {
      // 根 Leaf 关闭 = 关标签
      this.closeTab(tab.tabId);
      const result: CloseLeafResult = {
        closedLeaf: leaf,
        tabClosed: true,
        tabId: tab.tabId,
        nextFocusPaneId: nextFocus
      };
      return result;
    }
    const ref: ParentSplitRef | null = findParentSplit(tab.root, paneId);
    if (ref === null) {
      return null;
    }
    const sibling: PaneNode = ref.isChildA ? ref.parent.childB : ref.parent.childA;
    // 兄弟上提：若父 Split 本身是根，则标签根换成兄弟；否则挂回祖父对应侧
    if (tab.root === ref.parent) {
      tab.root = sibling;
    } else {
      const grand: PaneSplit | null = findSplitParentOf(tab.root, ref.parent.splitId);
      if (grand === null) {
        return null;
      }
      if (grand.childA === ref.parent) {
        grand.childA = sibling;
      } else {
        grand.childB = sibling;
      }
    }
    const result: CloseLeafResult = {
      closedLeaf: leaf,
      tabClosed: false,
      tabId: tab.tabId,
      nextFocusPaneId: nextFocus
    };
    return result;
  }

  /**
   * 关闭聚焦窗格后的焦点候选策略（确定性、视觉原位优先）：
   *   1. 常规：兄弟子树上提后的遍历序首叶——焦点落在视觉位置最接近被关
   *      窗格的窗格，输入不跨窗格跳变；
   *   2. 根 Leaf 关闭（整标签关闭）且关掉的是激活标签：新激活标签的首叶；
   *   3. 关非激活标签的根 Leaf：不影响焦点，返回 ''（调用方保持原焦点）；
   *   4. 最后一个标签的最后一叶：''（无剩余窗格，页面据此退出）。
   */
  nextFocusAfterClose(tabId: string, closingPaneId: string): string {
    const tab: PaneTab | null = this.findTab(tabId);
    if (tab === null || findLeafInNode(tab.root, closingPaneId) === null) {
      return '';
    }
    if (tab.root.kind === 'leaf') {
      if (this.activeTabId !== tabId) {
        return '';
      }
      const index: number = this.tabIndexOf(tabId);
      const neighbor: PaneTab | undefined =
        index > 0 ? this.tabs[index - 1] : (this.tabs.length > 1 ? this.tabs[index + 1] : undefined);
      if (neighbor === undefined) {
        return '';
      }
      const first: PaneLeaf | null = firstLeafOf(neighbor.root);
      return first === null ? '' : first.paneId;
    }
    const ref: ParentSplitRef | null = findParentSplit(tab.root, closingPaneId);
    if (ref === null) {
      return '';
    }
    const sibling: PaneNode = ref.isChildA ? ref.parent.childB : ref.parent.childA;
    const first: PaneLeaf | null = firstLeafOf(sibling);
    return first === null ? '' : first.paneId;
  }

  /** 拖分隔条：改 ratio（钳制 [0.1, 0.9]）；@returns 钳制后的实际值（null = 未知 splitId） */
  setRatio(splitId: string, ratio: number): number | null {
    for (const tab of this.tabs) {
      const split: PaneSplit | null = findSplitInNode(tab.root, splitId);
      if (split !== null) {
        // 手势事件异常值不能污染树；NaN 一旦进入 layout 会把全部矩形传播成 NaN。
        if (!Number.isFinite(ratio)) {
          return split.ratio;
        }
        const clamped: number = Math.min(PANE_MAX_RATIO, Math.max(PANE_MIN_RATIO, ratio));
        split.ratio = clamped;
        return clamped;
      }
    }
    return null;
  }

  /** 全部叶子（全标签；dispose 批量释放用） */
  allLeaves(): PaneLeaf[] {
    const result: PaneLeaf[] = [];
    for (const tab of this.tabs) {
      const leaves: PaneLeaf[] = leavesOf(tab.root);
      for (const leaf of leaves) {
        result.push(leaf);
      }
    }
    return result;
  }

  private tabIndexOf(tabId: string): number {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].tabId === tabId) {
        return i;
      }
    }
    return -1;
  }

  /** 清空（VM dispose；调用方需先释放各叶会话） */
  clear(): void {
    this.tabs.splice(0, this.tabs.length);
    this.activeTabId = '';
  }
}

/** 找「直接持有 splitId 分屏节点」的祖父 Split（兄弟上提挂回用；根 Split 无祖父返回 null） */
function findSplitParentOf(root: PaneNode, splitId: string): PaneSplit | null {
  if (root.kind === 'leaf') {
    return null;
  }
  if ((root.childA.kind === 'split' && root.childA.splitId === splitId) ||
    (root.childB.kind === 'split' && root.childB.splitId === splitId)) {
    return root;
  }
  const fromA: PaneSplit | null = findSplitParentOf(root.childA, splitId);
  return fromA === null ? findSplitParentOf(root.childB, splitId) : fromA;
}
