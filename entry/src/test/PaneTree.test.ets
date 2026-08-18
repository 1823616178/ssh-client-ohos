/**
 * PaneTree 单元测试（任务 U4b，DESIGN §4.3.1）。
 *
 * 纯数据结构 / 纯函数：零 UI、零服务。覆盖：
 *   遍历与查找 / 标签增删激活 / 分屏与嵌套 / 关叶兄弟上提 /
 *   ratio 钳制 / 布局舍入与零尺寸 / 断点降级可见性 /
 *   lg→sm→lg 树恒等 / 焦点候选策略 / 未知 id 收敛。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BREAKPOINT_MD_MAX_VP,
  BREAKPOINT_SM_MAX_VP,
  DividerRect,
  PANE_DIVIDER_SIZE_VP,
  PANE_MAX_RATIO,
  PANE_MIN_RATIO,
  PaneLayout,
  PaneLeaf,
  PaneSplit,
  PaneTab,
  PaneTabSet,
  ParentSplitRef,
  breakpointOfWidth,
  createPaneLeaf,
  findLeafInNode,
  findParentSplit,
  findSplitInNode,
  firstLeafOf,
  layoutPaneTree,
  layoutVisibleTree,
  leavesOf,
  neighborLeafInDirection,
  visibleLeaves
} from '../main/ets/viewmodel/PaneTree';

function makeSet(): PaneTabSet {
  return new PaneTabSet();
}

export default function paneTreeTest() {
  describe('PaneTreeTest', () => {

    it('断点宽度边界_sm小于600_md含840_lg大于840', 0, () => {
      expect(breakpointOfWidth(0)).assertEqual('sm');
      expect(breakpointOfWidth(BREAKPOINT_SM_MAX_VP - 1)).assertEqual('sm');
      expect(breakpointOfWidth(BREAKPOINT_SM_MAX_VP)).assertEqual('md');
      expect(breakpointOfWidth(BREAKPOINT_MD_MAX_VP)).assertEqual('md');
      expect(breakpointOfWidth(BREAKPOINT_MD_MAX_VP + 1)).assertEqual('lg');
    });

    it('新建标签_单叶树并激活_id按工厂序列', 0, () => {
      const set: PaneTabSet = makeSet();
      const first = set.addTab('主机A');
      expect(first.tab.tabId).assertEqual('tab-1');
      expect(first.leaf.paneId).assertEqual('pane-1');
      expect(first.leaf.sessionId).assertEqual('');
      expect(first.tab.root).assertEqual(first.leaf);
      expect(set.activeTabId).assertEqual('tab-1');
      expect(set.tabs.length).assertEqual(1);
      const second = set.addTab('主机B', 'terminal-main');
      expect(second.tab.tabId).assertEqual('tab-2');
      expect(second.leaf.paneId).assertEqual('terminal-main');
      expect(set.activeTabId).assertEqual('tab-2');
      expect(set.tabs.length).assertEqual(2);
    });

    it('激活与关闭标签_关激活取左侧邻居_关非激活不动', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b = set.addTab('B');
      const c = set.addTab('C');
      expect(set.activateTab('ghost')).assertFalse();
      expect(set.activeTabId).assertEqual(c.tab.tabId);
      expect(set.activateTab(a.tab.tabId)).assertTrue();
      expect(set.activeTabId).assertEqual(a.tab.tabId);
      // 关非激活 B：激活仍是 A
      expect(set.closeTab(b.tab.tabId) !== null).assertTrue();
      expect(set.tabs.length).assertEqual(2);
      expect(set.activeTabId).assertEqual(a.tab.tabId);
      // 关激活 A：上提左侧…A 是 index 0，取补位者（原 C，现 index 0）
      const removed: PaneTab | null = set.closeTab(a.tab.tabId);
      expect(removed !== null).assertTrue();
      expect(set.tabs.length).assertEqual(1);
      expect(set.activeTabId).assertEqual(c.tab.tabId);
      set.closeTab(c.tab.tabId);
      expect(set.tabs.length).assertEqual(0);
      expect(set.activeTabId).assertEqual('');
      expect(set.closeTab('ghost')).assertNull();
    });

    it('分屏_根叶变Split_原叶在A侧新叶在B侧', 0, () => {
      const set: PaneTabSet = makeSet();
      const added = set.addTab('A');
      const extra: PaneLeaf = createPaneLeaf(set.newPaneId());
      const split: PaneSplit | null = set.splitLeaf(added.leaf.paneId, 'row', extra);
      expect(split !== null).assertTrue();
      const node: PaneSplit = split as PaneSplit;
      expect(node.splitId).assertEqual('split-1');
      expect(node.direction).assertEqual('row');
      expect(node.ratio).assertEqual(0.5);
      expect(node.childA).assertEqual(added.leaf);
      expect(node.childB).assertEqual(extra);
      const tab: PaneTab | null = set.activeTab();
      expect(tab !== null).assertTrue();
      expect((tab as PaneTab).root).assertEqual(node);
    });

    it('dockTree_把另一棵树接到当前根的B侧', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b = set.addTab('B');
      expect(set.tabs.length).assertEqual(2);
      const incoming = b.tab.root;
      expect(set.closeTab(b.tab.tabId) !== null).assertTrue();
      const split: PaneSplit | null = set.dockTree(a.tab.tabId, incoming, 'row');
      expect(split !== null).assertTrue();
      expect(set.tabs.length).assertEqual(1);
      const node: PaneSplit = split as PaneSplit;
      expect(node.direction).assertEqual('row');
      expect(node.childA).assertEqual(a.leaf);
      expect(node.childB).assertEqual(incoming);
      expect(leavesOf((set.activeTab() as PaneTab).root).length).assertEqual(2);
    });

    it('嵌套分屏_在B侧再切_查找与遍历序先A后B', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(a.leaf.paneId, 'row', b);
      const c: PaneLeaf = createPaneLeaf(set.newPaneId());
      const inner: PaneSplit | null = set.splitLeaf(b.paneId, 'column', c);
      expect(inner !== null).assertTrue();
      const tab: PaneTab = set.activeTab() as PaneTab;
      const leaves: PaneLeaf[] = leavesOf(tab.root);
      expect(leaves.length).assertEqual(3);
      expect(leaves[0].paneId).assertEqual(a.leaf.paneId);
      expect(leaves[1].paneId).assertEqual(b.paneId);
      expect(leaves[2].paneId).assertEqual(c.paneId);
      const first: PaneLeaf | null = firstLeafOf(tab.root);
      expect(first !== null).assertTrue();
      expect((first as PaneLeaf).paneId).assertEqual(a.leaf.paneId);
      expect(findLeafInNode(tab.root, c.paneId)).assertEqual(c);
      expect(findSplitInNode(tab.root, (inner as PaneSplit).splitId)).assertEqual(inner);
      expect(findLeafInNode(tab.root, 'ghost')).assertNull();
      expect(findSplitInNode(tab.root, 'ghost')).assertNull();
    });

    it('关非根叶_兄弟上提替换父Split_嵌套祖父改指向', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(a.leaf.paneId, 'row', b);
      const c: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(b.paneId, 'column', c);
      // 关 c：B 侧内层 Split 被 b 上提，树变回 row(A, B)
      const closedC = set.closeLeaf(c.paneId);
      expect(closedC !== null).assertTrue();
      expect(closedC?.tabClosed).assertFalse();
      expect(closedC?.nextFocusPaneId).assertEqual(b.paneId);
      const tab: PaneTab = set.activeTab() as PaneTab;
      expect(tab.root.kind).assertEqual('split');
      const rootSplit: PaneSplit = tab.root as PaneSplit;
      expect(rootSplit.childA).assertEqual(a.leaf);
      expect(rootSplit.childB).assertEqual(b);
      // 关 b：A 上提为根叶
      const closedB = set.closeLeaf(b.paneId);
      expect(closedB?.tabClosed).assertFalse();
      expect(tab.root).assertEqual(a.leaf);
      // 关根叶 = 关标签
      const closedA = set.closeLeaf(a.leaf.paneId);
      expect(closedA?.tabClosed).assertTrue();
      expect(set.tabs.length).assertEqual(0);
    });

    it('关根叶且是激活标签_焦点落到邻居首叶', 0, () => {
      const set: PaneTabSet = makeSet();
      const first = set.addTab('A');
      const second = set.addTab('B');
      expect(set.activeTabId).assertEqual(second.tab.tabId);
      const result = set.closeLeaf(second.leaf.paneId);
      expect(result?.tabClosed).assertTrue();
      expect(result?.nextFocusPaneId).assertEqual(first.leaf.paneId);
      expect(set.activeTabId).assertEqual(first.tab.tabId);
    });

    it('关非激活标签根叶_焦点候选空串_激活态不动', 0, () => {
      const set: PaneTabSet = makeSet();
      const first = set.addTab('A');
      const second = set.addTab('B');
      const result = set.closeLeaf(first.leaf.paneId);
      expect(result?.tabClosed).assertTrue();
      expect(result?.nextFocusPaneId).assertEqual('');
      expect(set.activeTabId).assertEqual(second.tab.tabId);
    });

    it('未知id_split_close_find_setRatio均收敛', 0, () => {
      const set: PaneTabSet = makeSet();
      set.addTab('A');
      expect(set.splitLeaf('ghost', 'row', createPaneLeaf('x'))).assertNull();
      expect(set.closeLeaf('ghost')).assertNull();
      expect(set.findLeaf('ghost')).assertNull();
      expect(set.setRatio('ghost', 0.3)).assertNull();
      expect(set.tabOfPane('ghost')).assertNull();
      expect(set.leafBySession('s-1')).assertNull();
    });

    it('setRatio_钳制在0.1到0.9', 0, () => {
      const set: PaneTabSet = makeSet();
      const added = set.addTab('A');
      const extra: PaneLeaf = createPaneLeaf(set.newPaneId());
      const split: PaneSplit = set.splitLeaf(added.leaf.paneId, 'row', extra) as PaneSplit;
      expect(set.setRatio(split.splitId, 0.3)).assertEqual(0.3);
      expect(split.ratio).assertEqual(0.3);
      expect(set.setRatio(split.splitId, 0)).assertEqual(PANE_MIN_RATIO);
      expect(set.setRatio(split.splitId, 1)).assertEqual(PANE_MAX_RATIO);
      expect(set.setRatio(split.splitId, Number.NaN)).assertEqual(PANE_MAX_RATIO);
      expect(split.ratio).assertEqual(PANE_MAX_RATIO);
      expect(set.setRatio(split.splitId, Number.POSITIVE_INFINITY)).assertEqual(PANE_MAX_RATIO);
      expect(split.ratio).assertEqual(PANE_MAX_RATIO);
    });

    it('布局_row按ratio切分_1px舍入A取floor_B吃余量', 0, () => {
      const set: PaneTabSet = makeSet();
      const added = set.addTab('A');
      const extra: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(added.leaf.paneId, 'row', extra);
      // 可用 = 100 - 8 = 92；ratio 0.5 → A=46，分隔条=8，B=46
      const layout: PaneLayout = layoutPaneTree(set.activeTab()?.root as PaneSplit, 100, 40,
        PANE_DIVIDER_SIZE_VP);
      expect(layout.leaves.length).assertEqual(2);
      expect(layout.dividers.length).assertEqual(1);
      expect(layout.leaves[0].w).assertEqual(46);
      expect(layout.leaves[1].w).assertEqual(46);
      expect(layout.leaves[0].w + layout.dividers[0].w + layout.leaves[1].w).assertEqual(100);
      expect(layout.leaves[0].h).assertEqual(40);
      expect(layout.dividers[0].span).assertEqual(92);
      // 奇数可用：101-8=93，A=floor(46.5)=46，B=47
      const odd: PaneLayout = layoutPaneTree(set.activeTab()?.root as PaneSplit, 101, 40,
        PANE_DIVIDER_SIZE_VP);
      expect(odd.leaves[0].w).assertEqual(46);
      expect(odd.leaves[1].w).assertEqual(47);
      expect(odd.leaves[0].w + odd.dividers[0].w + odd.leaves[1].w).assertEqual(101);
    });

    it('布局_column与零负尺寸钳制不除零', 0, () => {
      const set: PaneTabSet = makeSet();
      const added = set.addTab('A');
      const extra: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(added.leaf.paneId, 'column', extra);
      const layout: PaneLayout = layoutPaneTree(set.activeTab()?.root as PaneSplit, 80, 50,
        PANE_DIVIDER_SIZE_VP);
      expect(layout.leaves[0].h + layout.dividers[0].h + layout.leaves[1].h).assertEqual(50);
      expect(layout.leaves[0].w).assertEqual(80);
      const zero: PaneLayout = layoutPaneTree(set.activeTab()?.root as PaneSplit, 0, 0, 8);
      expect(zero.leaves[0].w).assertEqual(0);
      expect(zero.leaves[0].h).assertEqual(0);
      expect(zero.dividers[0].span).assertEqual(0);
      const neg: PaneLayout = layoutPaneTree(set.activeTab()?.root as PaneSplit, -10, -4, 8);
      expect(neg.leaves[0].w).assertEqual(0);
      expect(neg.leaves[1].h).assertEqual(0);
    });

    it('可见叶_sm只返回聚焦_md与lg全量_聚焦不在本树回退首叶', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(a.leaf.paneId, 'row', b);
      const root = (set.activeTab() as PaneTab).root;
      const smFocusB: PaneLeaf[] = visibleLeaves(root, b.paneId, 'sm');
      expect(smFocusB.length).assertEqual(1);
      expect(smFocusB[0].paneId).assertEqual(b.paneId);
      const smGhost: PaneLeaf[] = visibleLeaves(root, 'ghost', 'sm');
      expect(smGhost.length).assertEqual(1);
      expect(smGhost[0].paneId).assertEqual(a.leaf.paneId);
      expect(visibleLeaves(root, a.leaf.paneId, 'md').length).assertEqual(2);
      expect(visibleLeaves(root, a.leaf.paneId, 'lg').length).assertEqual(2);
    });

    it('layoutVisibleTree_sm双窗格完整显示_三窗格以上降级聚焦叶_树不动', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(a.leaf.paneId, 'row', b);
      const root = (set.activeTab() as PaneTab).root;
      const beforeKind: string = root.kind;
      const sm: PaneLayout = layoutVisibleTree(root, b.paneId, 'sm', 400, 300,
        PANE_DIVIDER_SIZE_VP);
      expect(sm.leaves.length).assertEqual(2);
      expect(sm.leaves[0].w).assertEqual(196);
      expect(sm.leaves[0].h).assertEqual(300);
      expect(sm.dividers.length).assertEqual(1);
      const lg: PaneLayout = layoutVisibleTree(root, b.paneId, 'lg', 400, 300,
        PANE_DIVIDER_SIZE_VP);
      expect(lg.leaves.length).assertEqual(2);
      expect(lg.dividers.length).assertEqual(1);
      const c: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(b.paneId, 'column', c);
      const compact: PaneLayout = layoutVisibleTree(root, c.paneId, 'sm', 400, 300,
        PANE_DIVIDER_SIZE_VP);
      expect(compact.leaves.length).assertEqual(1);
      expect(compact.leaves[0].paneId).assertEqual(c.paneId);
      expect(compact.dividers.length).assertEqual(0);
      // lg→sm→lg 树恒等
      expect(root.kind).assertEqual(beforeKind);
      expect(leavesOf(root).length).assertEqual(3);
      expect(findParentSplit(root, a.leaf.paneId) !== null).assertTrue();
      const ref: ParentSplitRef | null = findParentSplit(root, b.paneId);
      expect(ref !== null).assertTrue();
      expect(ref?.isChildA).assertTrue();
      expect(ref?.parent.direction).assertEqual('column');
    });

    it('leafBySession与allLeaves_clear清空', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      a.leaf.sessionId = 's-1';
      const extra: PaneLeaf = createPaneLeaf(set.newPaneId());
      extra.sessionId = 's-2';
      set.splitLeaf(a.leaf.paneId, 'row', extra);
      set.addTab('B').leaf.sessionId = 's-3';
      expect(set.leafBySession('s-2')?.paneId).assertEqual(extra.paneId);
      expect(set.allLeaves().length).assertEqual(3);
      set.clear();
      expect(set.tabs.length).assertEqual(0);
      expect(set.allLeaves().length).assertEqual(0);
      expect(set.activeTabId).assertEqual('');
    });

    it('邻居焦点_row左右_column上下_无邻居空串', 0, () => {
      const set: PaneTabSet = makeSet();
      const a = set.addTab('A');
      const b: PaneLeaf = createPaneLeaf(set.newPaneId());
      set.splitLeaf(a.leaf.paneId, 'row', b);
      const layout = layoutPaneTree((set.activeTab() as PaneTab).root, 200, 80, 8);
      expect(neighborLeafInDirection(layout.leaves, a.leaf.paneId, 'right')).assertEqual(b.paneId);
      expect(neighborLeafInDirection(layout.leaves, b.paneId, 'left')).assertEqual(a.leaf.paneId);
      expect(neighborLeafInDirection(layout.leaves, a.leaf.paneId, 'left')).assertEqual('');
      expect(neighborLeafInDirection(layout.leaves, a.leaf.paneId, 'up')).assertEqual('');
      expect(neighborLeafInDirection(layout.leaves, 'ghost', 'right')).assertEqual('');
      const set2: PaneTabSet = makeSet();
      const c = set2.addTab('C');
      const d: PaneLeaf = createPaneLeaf(set2.newPaneId());
      set2.splitLeaf(c.leaf.paneId, 'column', d);
      const col = layoutPaneTree((set2.activeTab() as PaneTab).root, 200, 80, 8);
      expect(neighborLeafInDirection(col.leaves, c.leaf.paneId, 'down')).assertEqual(d.paneId);
      expect(neighborLeafInDirection(col.leaves, d.paneId, 'up')).assertEqual(c.leaf.paneId);
    });

    it('分隔条矩形_row竖直_column水平_span等于可用长', 0, () => {
      const set: PaneTabSet = makeSet();
      const added = set.addTab('A');
      set.splitLeaf(added.leaf.paneId, 'row', createPaneLeaf(set.newPaneId()));
      const row: DividerRect = layoutPaneTree((set.activeTab() as PaneTab).root, 200, 80, 8)
        .dividers[0];
      expect(row.direction).assertEqual('row');
      expect(row.w).assertEqual(8);
      expect(row.h).assertEqual(80);
      expect(row.span).assertEqual(192);
      expect(row.x).assertEqual(96);
      const set2: PaneTabSet = makeSet();
      const added2 = set2.addTab('A');
      set2.splitLeaf(added2.leaf.paneId, 'column', createPaneLeaf(set2.newPaneId()));
      const col: DividerRect = layoutPaneTree((set2.activeTab() as PaneTab).root, 200, 80, 8)
        .dividers[0];
      expect(col.direction).assertEqual('column');
      expect(col.w).assertEqual(200);
      expect(col.h).assertEqual(8);
      expect(col.y).assertEqual(36);
    });
  });
}
