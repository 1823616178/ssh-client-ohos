/**
 * HostListViewModel —— 主机列表页视图模型（任务 U1，DESIGN §4.3.1 页面清单）。
 *
 * 逻辑与 UI 分离：过滤 / 分组排序 / 折叠切换 / 折叠持久化编解码 / 状态点派生 /
 * 快速连接地址解析全部是不依赖 context 的纯函数（hypium 直接覆盖）；
 * @ObservedV2 的 HostListViewModel 只做状态持有与编排，生产依赖经窄接口注入
 * （对齐 C1/C4 注入惯例）：HostDaoLike / GroupDaoLike 缺省走 AppDatabase，
 * CollapsedStoreLike 缺省走 SettingsRepository（C3 的 hostGroupCollapsed 键）。
 * DAO 引用在调用时惰性解析，避免「页面构造早于数据库就绪」时构造即崩。
 *
 * 关键规则（均有单测）：
 *   - 搜索：名称 / 主机地址 / 用户名三字段大小写不敏感包含匹配，空串复原全量；
 *   - 分组：按 HostGroup.order 升序，未分组区置最后；组内主机按最后使用时间
 *     降序（近者优先），未用过的靠后，时间相同再按 name 字典序；
 *   - 折叠持久化：JSON 串 Record<groupId, true>（未分组区用空串作键），
 *     脏数据（非法 JSON / 非对象 / 非布尔值）一律收敛空集或剔除；
 *   - 状态点：按 hostId 从会话列表派生，多会话同主机取最严重状态，
 *     优先级 error > connecting > disconnected > established > none（理由见
 *     statusSeverity 注释）。
 */

import { HostGroup, HostProfile } from '../common/model/models';
import { AppDatabase } from '../repository/AppDatabase';
import { SettingsRepository } from '../repository/SettingsRepository';
import { Logger } from '../common/utils/Logger';
import { notifyConfigSaved } from '../service/sync/SyncHooks';

const LOG_TAG: string = 'HostList';

/** 未分组区的分组键（HostProfile.groupId = null 的主机；折叠持久化与行 id 共用该哨兵） */
export const GROUP_ID_UNGROUPED: string = '';

// ---------------------------------------------------------------- 状态点派生

/**
 * 主机连接状态（状态点语义，对应 Tokens 颜色）：
 *   none=灰（textFaint，无会话）/ connecting=蓝（accent）/ established=绿（success）/
 *   disconnected=橙（warn，含断线退避中）/ error=红（danger）。
 */
export type HostConnStatus = 'none' | 'connecting' | 'established' | 'disconnected' | 'error';

/**
 * 会话状态窄接口：生产传入 SessionInfo[]（C4 SessionManager.listSessions()，
 * SessionInfo 结构性满足本接口），单测传字面量；本文件因此不依赖 napi 层。
 */
export interface HostSessionStateLike {
  readonly hostId: string;
  /** SshSessionStateName（C4）；按 string 接收以容忍未知值（归 none） */
  readonly state: string;
}

/**
 * 会话状态 → 状态点映射：
 *   connecting / handshaking / authenticating → connecting（蓝，进行中，动画可省）；
 *   established → established（绿）；disconnected → disconnected（橙）；error → error（红）；
 *   idle / closing / closed / 未知值 → none（瞬态或已摘除，不显示为活跃连接；
 *   注：close() 会把会话摘出列表，closed 正常不会出现在快照中）。
 */
export function sessionStateToStatus(state: string): HostConnStatus {
  switch (state) {
    case 'connecting':
    case 'handshaking':
    case 'authenticating':
      return 'connecting';
    case 'established':
      return 'established';
    case 'disconnected':
      return 'disconnected';
    case 'error':
      return 'error';
    default:
      return 'none';
  }
}

/**
 * 状态严重度：多会话同主机取最高者（最需要用户注意的优先）。
 * error(40) 需立即处理 > connecting(30) 正在进行 > disconnected(20) 断线待重连
 * > established(10) 一切正常 > none(0) 无会话。
 */
function statusSeverity(status: HostConnStatus): number {
  switch (status) {
    case 'error':
      return 40;
    case 'connecting':
      return 30;
    case 'disconnected':
      return 20;
    case 'established':
      return 10;
    default:
      return 0;
  }
}

/** 活动会话窄接口（生产 = SessionInfo；paneId 非空 = 已在终端页窗格里打开） */
export interface ActiveSessionLike {
  readonly sessionId: string;
  readonly hostId: string;
  readonly hostName: string;
  readonly state: string;
  readonly paneId: string | null;
}

/** 主机列表「活动会话」一行 */
export interface ActiveSessionItem {
  readonly sessionId: string;
  readonly title: string;
  readonly status: HostConnStatus;
  readonly statusLabel: string;
}

export function hostConnStatusLabel(status: HostConnStatus): string {
  switch (status) {
    case 'connecting':
      return '连接中';
    case 'established':
      return '运行中';
    case 'disconnected':
      return '已断开，等待重连';
    case 'error':
      return '连接异常';
    default:
      return '';
  }
}

/**
 * 活动会话列表：终端页返回后仍在后台运行（未绑窗格）且非终态的会话，
 * 点按即可恢复（画面与回滚由终端寄存处保留）。标题优先用已保存主机名。
 */
export function buildActiveSessionItems(sessions: ActiveSessionLike[],
  hostNames: Map<string, string>): ActiveSessionItem[] {
  const items: ActiveSessionItem[] = [];
  for (const session of sessions) {
    if (session.paneId !== null) {
      continue;
    }
    const status: HostConnStatus = sessionStateToStatus(session.state);
    if (status === 'none') {
      continue;
    }
    const saved: string | undefined = hostNames.get(session.hostId);
    const title: string = saved !== undefined && saved.length > 0 ? saved :
      (session.hostName.length > 0 ? session.hostName : '终端');
    items.push({
      sessionId: session.sessionId,
      title: title,
      status: status,
      statusLabel: hostConnStatusLabel(status)
    });
  }
  return items;
}

/** 单主机状态点派生：其全部会话中取最严重状态；无会话 → none */
export function deriveHostConnStatus(sessions: HostSessionStateLike[], hostId: string): HostConnStatus {
  let best: HostConnStatus = 'none';
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i].hostId !== hostId) {
      continue;
    }
    const status: HostConnStatus = sessionStateToStatus(sessions[i].state);
    if (statusSeverity(status) > statusSeverity(best)) {
      best = status;
    }
  }
  return best;
}

/** 全量派生：一遍扫描出 hostId → 最严重状态（列表渲染按 hostId 查表） */
export function buildConnStatusMap(sessions: HostSessionStateLike[]): Map<string, HostConnStatus> {
  const map: Map<string, HostConnStatus> = new Map();
  for (let i = 0; i < sessions.length; i++) {
    const status: HostConnStatus = sessionStateToStatus(sessions[i].state);
    const prev: HostConnStatus | undefined = map.get(sessions[i].hostId);
    if (prev === undefined || statusSeverity(status) > statusSeverity(prev)) {
      map.set(sessions[i].hostId, status);
    }
  }
  return map;
}

// ---------------------------------------------------------------- 搜索过滤与分组排序

/** 搜索过滤：名称 / 主机地址 / 用户名三字段大小写不敏感包含匹配；空串（含纯空白）复原全量 */
export function filterHosts(hosts: HostProfile[], query: string): HostProfile[] {
  const keyword: string = query.trim().toLowerCase();
  if (keyword.length === 0) {
    return hosts.slice();
  }
  return hosts.filter((host: HostProfile) =>
    host.name.toLowerCase().includes(keyword) ||
    host.host.toLowerCase().includes(keyword) ||
    host.username.toLowerCase().includes(keyword));
}

/** 分组排序：order 升序；order 相同按 name 字典序稳定次序 */
export function sortGroupsByOrder(groups: HostGroup[]): HostGroup[] {
  return groups.slice().sort((a: HostGroup, b: HostGroup) => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    return compareByName(a.name, b.name);
  });
}

function compareByName(a: string, b: string): number {
  if (a === b) {
    return 0;
  }
  return a < b ? -1 : 1;
}

/** 组内主机排序：按 name 字典序（HostProfile 无 createdAt 字段，见文件头说明） */
export function sortHostsByName(hosts: HostProfile[]): HostProfile[] {
  return hosts.slice().sort((a: HostProfile, b: HostProfile) => compareByName(a.name, b.name));
}

/** 组内主机排序：最后使用近者在前；从未使用（缺省 0）靠后；并列再按 name */
export function sortHostsByLastUsed(hosts: HostProfile[], lastUsed: Map<string, number>): HostProfile[] {
  return hosts.slice().sort((a: HostProfile, b: HostProfile) => {
    const aUsed: number = lastUsed.get(a.id) ?? 0;
    const bUsed: number = lastUsed.get(b.id) ?? 0;
    if (aUsed !== bUsed) {
      return bUsed - aUsed;
    }
    return compareByName(a.name, b.name);
  });
}

/** JSON 串 → hostId→epochMs；脏数据收敛为空表 */
export function decodeHostLastUsed(json: string): Map<string, number> {
  const result: Map<string, number> = new Map();
  const trimmed: string = json.trim();
  if (trimmed.length === 0) {
    return result;
  }
  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(trimmed);
  } catch (err) {
    Logger.warn(`主机最后使用时间 JSON 非法，收敛为空表：${JSON.stringify(err)}`, LOG_TAG);
    return result;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return result;
  }
  const record: Record<string, Object> = parsed as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const value: Object = record[key];
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
      result.set(key, value);
    }
  }
  return result;
}

/** hostId→epochMs → JSON 串 */
export function encodeHostLastUsed(lastUsed: Map<string, number>): string {
  const obj: Record<string, number> = {};
  lastUsed.forEach((value: number, key: string) => {
    obj[key] = value;
  });
  return JSON.stringify(obj);
}

/** 记下某主机此刻被使用；空 id 忽略。本机偏好，不上云。 */
export function recordHostLastUsed(hostId: string): void {
  if (hostId.length === 0) {
    return;
  }
  const current: Map<string, number> = decodeHostLastUsed(SettingsRepository.getHostLastUsed());
  current.set(hostId, Date.now());
  SettingsRepository.setHostLastUsed(encodeHostLastUsed(current));
}

// ---------------------------------------------------------------- 折叠集合与持久化编解码

/** 折叠切换：返回新集合（不可变更新，@Trace 字段整体替换保证刷新） */
export function toggleCollapsed(collapsedGroupIds: Set<string>, groupId: string): Set<string> {
  const next: Set<string> = new Set();
  collapsedGroupIds.forEach((id: string) => {
    next.add(id);
  });
  if (next.has(groupId)) {
    next.delete(groupId);
  } else {
    next.add(groupId);
  }
  return next;
}

/** 折叠集合 → JSON 串（Record<groupId, true>；ArkTS 禁非空 Record 字面量，空字面量逐键赋值） */
export function encodeCollapsedGroups(collapsedGroupIds: Set<string>): string {
  const obj: Record<string, boolean> = {};
  collapsedGroupIds.forEach((id: string) => {
    obj[id] = true;
  });
  return JSON.stringify(obj);
}

/**
 * JSON 串 → 折叠集合；脏数据收敛规则：
 *   空串 / 非法 JSON / null / 数组 / 标量 → 空集；
 *   对象中仅保留值为布尔 true 的键（false 与折叠语义重复、其余类型为脏值，一律剔除）。
 */
export function decodeCollapsedGroups(json: string): Set<string> {
  const result: Set<string> = new Set();
  const trimmed: string = json.trim();
  if (trimmed.length === 0) {
    return result;
  }
  let parsed: Object | null;
  try {
    parsed = JSON.parse(trimmed);
  } catch (err) {
    Logger.warn(`分组折叠状态 JSON 非法，收敛为空集：${JSON.stringify(err)}`, LOG_TAG);
    return result;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    Logger.warn('分组折叠状态不是对象，收敛为空集', LOG_TAG);
    return result;
  }
  const record: Record<string, Object> = parsed as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    if (record[keys[i]] === true) {
      result.add(keys[i]);
    }
  }
  return result;
}

// ---------------------------------------------------------------- 扁平行列表（LazyForEach 数据项）

/** 行类别：组头 / 主机行 */
export type HostListRowKind = 'groupHeader' | 'host';

/**
 * 扁平行（LazyForEach + IDataSource 的数据项；组头与主机行共用同一结构，
 * 规避 ArkTS 联合类型判别开销与 as 强转）：kind=groupHeader 时 host 为 null，
 * kind=host 时分组字段取所属组头信息（仅 rowId 参与键生成）。
 */
export interface HostListRow {
  /** 行稳定 id：组头 = 'group:<groupId>'（未分组 = 'group:'），主机行 = 'host:<hostId>' */
  readonly rowId: string;
  readonly kind: HostListRowKind;
  /** 组头行：分组 id（未分组为空串，即折叠持久化键） */
  readonly groupId: string;
  /** 组头行：组名（未分组为「未分组」） */
  readonly groupName: string;
  /** 组头行：该组（过滤后）主机数 */
  readonly groupHostCount: number;
  /** 组头行：是否折叠 */
  readonly collapsed: boolean;
  /** 主机行：主机实体（组头行为 null） */
  readonly host: HostProfile | null;
  /** 主机行：连接状态点（构建时从 connStatusMap 查表固化） */
  readonly connStatus: HostConnStatus;
}

/**
 * 构建扁平行列表：分组按 order 升序、未分组置后；折叠组只保留组头行；
 * 空组（或搜索过滤后无成员的组）不产出行；groupId 指向已不存在分组的
 * 主机按未分组处理（脏数据防御）。未分组区组头仅在有未分组主机时产出。
 */
export function buildHostRows(hosts: HostProfile[], groups: HostGroup[],
  collapsedGroupIds: Set<string>, connStatusMap: Map<string, HostConnStatus>,
  lastUsedMap?: Map<string, number>): HostListRow[] {
  const usedMap: Map<string, number> = lastUsedMap === undefined ? new Map() : lastUsedMap;
  const rows: HostListRow[] = [];
  const sortedGroups: HostGroup[] = sortGroupsByOrder(groups);
  const knownGroupIds: Set<string> = new Set();
  for (let i = 0; i < sortedGroups.length; i++) {
    knownGroupIds.add(sortedGroups[i].id);
  }
  for (let i = 0; i < sortedGroups.length; i++) {
    const group: HostGroup = sortedGroups[i];
    const members: HostProfile[] = [];
    for (let j = 0; j < hosts.length; j++) {
      if (hosts[j].groupId === group.id) {
        members.push(hosts[j]);
      }
    }
    if (members.length === 0) {
      continue;
    }
    pushGroupSection(rows, group.id, group.name, members, collapsedGroupIds, connStatusMap, usedMap);
  }
  const ungrouped: HostProfile[] = [];
  for (let i = 0; i < hosts.length; i++) {
    const groupId: string | null = hosts[i].groupId;
    if (groupId === null || !knownGroupIds.has(groupId)) {
      ungrouped.push(hosts[i]);
    }
  }
  if (ungrouped.length > 0) {
    pushGroupSection(rows, GROUP_ID_UNGROUPED, '未分组', ungrouped, collapsedGroupIds,
      connStatusMap, usedMap);
  }
  return rows;
}

/** 产出一个分组区（组头行 + 未折叠时的主机行，组内按最后使用时间降序） */
function pushGroupSection(rows: HostListRow[], groupId: string, groupName: string,
  members: HostProfile[], collapsedGroupIds: Set<string>,
  connStatusMap: Map<string, HostConnStatus>, lastUsedMap: Map<string, number>): void {
  const collapsed: boolean = collapsedGroupIds.has(groupId);
  rows.push({
    rowId: `group:${groupId}`,
    kind: 'groupHeader',
    groupId: groupId,
    groupName: groupName,
    groupHostCount: members.length,
    collapsed: collapsed,
    host: null,
    connStatus: 'none'
  });
  if (collapsed) {
    return;
  }
  const sorted: HostProfile[] = sortHostsByLastUsed(members, lastUsedMap);
  for (let i = 0; i < sorted.length; i++) {
    const host: HostProfile = sorted[i];
    const status: HostConnStatus | undefined = connStatusMap.get(host.id);
    rows.push({
      rowId: `host:${host.id}`,
      kind: 'host',
      groupId: groupId,
      groupName: groupName,
      groupHostCount: members.length,
      collapsed: false,
      host: host,
      connStatus: status === undefined ? 'none' : status
    });
  }
}

// ---------------------------------------------------------------- 快速连接地址解析

/** 快速连接目标（host[:port] 解析结果） */
export interface QuickConnectTarget {
  readonly host: string;
  readonly port: number;
}

/**
 * 解析快速连接地址 host[:port]：
 *   - 无冒号或冒号后为空 → 默认端口 22；
 *   - 端口必须是 1–65535 的纯数字，否则整体判非法返回 null；
 *   - 多个冒号按 IPv6 字面量处理（不带端口；带端口的方括号写法归 U2 完整编辑器）。
 */
export function parseQuickConnectAddress(input: string): QuickConnectTarget | null {
  const trimmed: string = input.trim();
  if (trimmed.length === 0) {
    return null;
  }
  const firstSep: number = trimmed.indexOf(':');
  if (firstSep < 0) {
    return { host: trimmed, port: 22 };
  }
  if (firstSep !== trimmed.lastIndexOf(':')) {
    return { host: trimmed, port: 22 };
  }
  const hostPart: string = trimmed.substring(0, firstSep).trim();
  const portPart: string = trimmed.substring(firstSep + 1).trim();
  if (hostPart.length === 0) {
    return null;
  }
  if (portPart.length === 0) {
    return { host: hostPart, port: 22 };
  }
  if (!isAllDigits(portPart)) {
    return null;
  }
  const port: number = parseInt(portPart, 10);
  if (Number.isNaN(port) || port < 1 || port > 65535) {
    return null;
  }
  return { host: hostPart, port: port };
}

function isAllDigits(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return text.length > 0;
}

// ---------------------------------------------------------------- 视图模型

/** 主机 DAO 窄接口（生产 = AppDatabase.hosts()，单测注入内存 fake） */
export interface HostDaoLike {
  listAll(): HostProfile[];
  deleteById(id: string): void;
}

/** 分组 DAO 窄接口（生产 = AppDatabase.groups()，单测注入内存 fake） */
export interface GroupDaoLike {
  listAll(): HostGroup[];
}

/** 折叠状态持久化窄接口（生产 = SettingsRepository 适配器，单测注入内存 fake） */
export interface CollapsedStoreLike {
  load(): string;
  save(json: string): void;
}

/** 生产折叠存储：转发 C3 SettingsRepository 的 hostGroupCollapsed 键 */
class SettingsCollapsedStore implements CollapsedStoreLike {
  load(): string {
    return SettingsRepository.getHostGroupCollapsed();
  }

  save(json: string): void {
    SettingsRepository.setHostGroupCollapsed(json);
  }
}

/** 可选依赖集：缺省项走生产实现（惰性解析，见文件头）；单测全部注入 fake */
export interface HostListViewModelDeps {
  hostDao?: HostDaoLike;
  groupDao?: GroupDaoLike;
  collapsedStore?: CollapsedStoreLike;
}

@ObservedV2
export class HostListViewModel {
  /** 全量主机（reload 拉取，未过滤） */
  @Trace hosts: HostProfile[] = [];
  /** 全量分组（已按 order 升序） */
  @Trace groups: HostGroup[] = [];
  /** 搜索串（顶栏搜索框实时写入） */
  @Trace searchText: string = '';
  /** 折叠的分组 id 集（空串 = 未分组区） */
  @Trace collapsedGroupIds: Set<string> = new Set();
  /** hostId → 状态点（refreshConnStatus 整体替换驱动刷新） */
  @Trace connStatusMap: Map<string, HostConnStatus> = new Map();

  private readonly injectedHostDao: HostDaoLike | null;
  private readonly injectedGroupDao: GroupDaoLike | null;
  private readonly injectedCollapsedStore: CollapsedStoreLike | null;

  constructor(deps?: HostListViewModelDeps) {
    this.injectedHostDao = deps?.hostDao ?? null;
    this.injectedGroupDao = deps?.groupDao ?? null;
    this.injectedCollapsedStore = deps?.collapsedStore ?? null;
  }

  /**
   * 拉取主机/分组并恢复折叠状态（页面 aboutToAppear 与每次增删后调用）。
   * 失败（数据库未就绪/存储故障抛 SshError）记日志并保留旧数据，返回 false 供页面提示。
   */
  reload(): boolean {
    try {
      this.hosts = this.hostDao().listAll();
      this.groups = sortGroupsByOrder(this.groupDao().listAll());
      this.collapsedGroupIds = decodeCollapsedGroups(this.collapsedStore().load());
      return true;
    } catch (err) {
      Logger.error(`主机列表加载失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  setSearchText(text: string): void {
    this.searchText = text;
  }

  /** 折叠切换并立即持久化（C3 hostGroupCollapsed 键） */
  toggleGroupCollapsed(groupId: string): void {
    this.collapsedGroupIds = toggleCollapsed(this.collapsedGroupIds, groupId);
    try {
      this.collapsedStore().save(encodeCollapsedGroups(this.collapsedGroupIds));
    } catch (err) {
      Logger.error(`分组折叠状态持久化失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 过滤后的主机列表（搜索框实时过滤结果） */
  filteredHosts(): HostProfile[] {
    return filterHosts(this.hosts, this.searchText);
  }

  /** 构建扁平行列表（搜索 + 分组 + 折叠 + 状态点的最终派生，LazyForEach 数据源内容） */
  buildRows(): HostListRow[] {
    return buildHostRows(this.filteredHosts(), this.groups, this.collapsedGroupIds, this.connStatusMap,
      decodeHostLastUsed(SettingsRepository.getHostLastUsed()));
  }

  /** 从会话列表（C4 SessionManager.listSessions()）派生状态点；整体替换 Map 保证 @Trace 刷新 */
  refreshConnStatus(sessions: HostSessionStateLike[]): void {
    this.connStatusMap = buildConnStatusMap(sessions);
  }

  /**
   * 删除主机配置并刷新（仅 hosts 行；凭据级联清理 C2 与活跃会话关闭 C4
   * 由页面编排，见 HostListPage.deleteHost）。失败记日志返回 false。
   */
  deleteHost(hostId: string): boolean {
    try {
      this.hostDao().deleteById(hostId);
    } catch (err) {
      Logger.error(`删除主机失败（hostId=${hostId}）: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
    const ok: boolean = this.reload();
    if (ok) {
      notifyConfigSaved();
    }
    return ok;
  }

  private hostDao(): HostDaoLike {
    return this.injectedHostDao ?? AppDatabase.hosts();
  }

  private groupDao(): GroupDaoLike {
    return this.injectedGroupDao ?? AppDatabase.groups();
  }

  private collapsedStore(): CollapsedStoreLike {
    return this.injectedCollapsedStore ?? new SettingsCollapsedStore();
  }
}
