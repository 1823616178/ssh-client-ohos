/**
 * 自适应布局纯函数 —— 任务 U5（DESIGN §4.3）。
 *
 * 与 PaneTree.breakpointOfWidth 同一套阈值，供 Index / HostList 使用：
 *   sm <600vp 单栏；md 600–840vp 双栏 SideBar；lg >840vp 三栏可选。
 *
 * lg 三栏区域：主机列表 | 终端嵌入 | 右侧可折叠面板 stub
 * （片段 / 转发 / SFTP 三个 tab，链接到 ConfigManager / PortForward / Sftp 路由）。
 */

export type AppBreakpoint = 'sm' | 'md' | 'lg';

export const APP_BREAKPOINT_SM_MAX_VP: number = 600;
export const APP_BREAKPOINT_MD_MAX_VP: number = 840;

/** lg 右侧面板展开宽度（vp） */
export const RIGHT_PANEL_OPEN_WIDTH_VP: number = 260;
/** lg 右侧面板折叠后只留开关条宽度（vp） */
export const RIGHT_PANEL_COLLAPSED_WIDTH_VP: number = 36;

/** 宽度 → 断点（非有限值按最保守 sm） */
export function appBreakpointOfWidth(widthVp: number): AppBreakpoint {
  if (!Number.isFinite(widthVp)) {
    return 'sm';
  }
  if (widthVp < APP_BREAKPOINT_SM_MAX_VP) {
    return 'sm';
  }
  return widthVp <= APP_BREAKPOINT_MD_MAX_VP ? 'md' : 'lg';
}

/** 是否使用「主机列表 + 内容」双栏（SideBarContainer） */
export function useHostListSidebar(bp: AppBreakpoint): boolean {
  return bp === 'md' || bp === 'lg';
}

/** lg 是否再挂右侧可折叠面板位 */
export function useRightPanel(bp: AppBreakpoint): boolean {
  return bp === 'lg';
}

/** U5：lg 三栏（主机树 / 终端嵌入 / 右侧面板）；md 仍双栏，sm 单栏 */
export function useThreeRegionLayout(bp: AppBreakpoint): boolean {
  return bp === 'lg';
}

/** 右侧面板宽度（vp）：展开 = 260，折叠 = 36（开关条） */
export function rightPanelWidthVp(open: boolean): number {
  return open ? RIGHT_PANEL_OPEN_WIDTH_VP : RIGHT_PANEL_COLLAPSED_WIDTH_VP;
}

/**
 * 右侧面板是否应渲染（lg + 功能开关）。
 * enabled=false 时即使 lg 也不挂第三栏（与 md 同形）。
 */
export function showRightPanel(bp: AppBreakpoint, enabled: boolean): boolean {
  return enabled && useRightPanel(bp);
}

/** 布局区域解析结果（Index 据此决定挂哪些栏） */
export interface LayoutRegions {
  /** 左侧主机列表（md/lg SideBar 或 lg Row 第一列） */
  readonly hostList: boolean;
  /** 中栏：已选中主机时展示 TerminalPaneEmbed */
  readonly terminalEmbed: boolean;
  /** lg 右侧面板位（是否渲染第三栏） */
  readonly rightPanel: boolean;
  /** 右侧面板当前是否展开（非 lg 或未启用时恒 false） */
  readonly rightPanelOpen: boolean;
  /** 右侧面板布局宽度（非 lg/未启用为 0） */
  readonly rightPanelWidthVp: number;
}

/**
 * 由断点 + 选中态 + 面板开关解析三栏布局。
 * sm：无侧栏；md：双栏（面板恒关）；lg：三栏，宽度随 rightPanelOpen 变化。
 */
export function resolveLayoutRegions(
  bp: AppBreakpoint,
  hasSelectedHost: boolean,
  rightPanelOpen: boolean,
  rightPanelEnabled: boolean = true
): LayoutRegions {
  const hostList: boolean = useHostListSidebar(bp);
  const rightPanel: boolean = showRightPanel(bp, rightPanelEnabled);
  const open: boolean = rightPanel && rightPanelOpen;
  return {
    hostList: hostList,
    terminalEmbed: hostList && hasSelectedHost,
    rightPanel: rightPanel,
    rightPanelOpen: open,
    rightPanelWidthVp: rightPanel ? rightPanelWidthVp(rightPanelOpen) : 0
  };
}

/** lg 右侧面板 stub 的 tab 标识 */
export type RightPanelTabId = 'snippets' | 'forwards' | 'sftp';

/** lg 右侧面板 stub tab：标题 + 全页路由（面板本体只做链接与说明） */
export interface RightPanelTab {
  readonly id: RightPanelTabId;
  readonly title: string;
  readonly subtitle: string;
  /**
   * 全页路由。forwards / sftp 在已选主机时由 Index 追加 params（hostId）；
   * snippets 固定进配置中心片段区。
   */
  readonly route: string;
  /** 是否需要 hostId 参数（SftpPage / PortForwardPage） */
  readonly needsHostId: boolean;
}

/** 面板 tab 清单：片段 → ConfigManager，转发 → PortForwardPage，文件传输 → SftpPage */
export const RIGHT_PANEL_TABS: RightPanelTab[] = [
  {
    id: 'snippets',
    title: '片段',
    subtitle: '配置中心 · 命令片段',
    route: 'pages/ConfigManagerPage',
    needsHostId: false
  },
  {
    id: 'forwards',
    title: '转发',
    subtitle: '端口转发规则',
    route: 'pages/PortForwardPage',
    needsHostId: true
  },
  {
    id: 'sftp',
    title: '文件传输',
    subtitle: '远端文件浏览与传输',
    route: 'pages/SftpPage',
    needsHostId: true
  }
];

/** 按 id 取 tab；未知 id 返回 null */
export function rightPanelTabById(id: RightPanelTabId): RightPanelTab | null {
  for (let i = 0; i < RIGHT_PANEL_TABS.length; i++) {
    if (RIGHT_PANEL_TABS[i].id === id) {
      return RIGHT_PANEL_TABS[i];
    }
  }
  return null;
}
