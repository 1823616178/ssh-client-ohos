/**
 * HostListViewModel 单元测试（任务 U1）。
 *
 * 全部用例不依赖 context：过滤/分组/折叠编解码/状态点派生直接测纯函数；
 * 视图模型层注入内存 fake（FakeHostDao / FakeGroupDao / FakeCollapsedStore，
 * 对齐 C1 的 InMemoryRdbGateway 与 C4 的 fake 注入惯例）验证编排与持久化回路。
 *
 * 覆盖：搜索过滤（名称/主机/用户名、大小写、空串复原、首尾空白）/
 * 分组排序（order 升序、未分组置后、组内最后使用近者优先、空组隐藏、脏 groupId 归未分组）/
 * 折叠切换与持久化（JSON 往返、脏数据收敛空集、非布尔脏值剔除）/
 * 状态点派生（多会话同主机取最严重：error>connecting>disconnected>established>none）/
 * 快速连接地址解析。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  HostGroup,
  HostProfile,
  createDefaultHostGroup,
  createDefaultHostProfile
} from '../main/ets/common/model/models';
import {
  CollapsedStoreLike,
  GROUP_ID_UNGROUPED,
  GroupDaoLike,
  HostConnStatus,
  HostDaoLike,
  HostListRow,
  HostListViewModel,
  HostListViewModelDeps,
  HostSessionStateLike,
  QuickConnectTarget,
  buildConnStatusMap,
  ActiveSessionItem,
  ActiveSessionLike,
  buildActiveSessionItems,
  buildHostRows,
  decodeCollapsedGroups,
  deriveHostConnStatus,
  decodeHostLastUsed,
  encodeCollapsedGroups,
  encodeHostLastUsed,
  filterHosts,
  parseQuickConnectAddress,
  sessionStateToStatus,
  sortGroupsByOrder,
  sortHostsByLastUsed,
  toggleCollapsed
} from '../main/ets/viewmodel/HostListViewModel';

// ---------- 内存 fake ----------

class FakeHostDao implements HostDaoLike {
  hosts: HostProfile[] = [];
  readonly deletedIds: string[] = [];

  listAll(): HostProfile[] {
    return this.hosts;
  }

  deleteById(id: string): void {
    this.deletedIds.push(id);
    this.hosts = this.hosts.filter((host: HostProfile) => host.id !== id);
  }
}

class FakeGroupDao implements GroupDaoLike {
  groups: HostGroup[] = [];

  listAll(): HostGroup[] {
    return this.groups;
  }
}

class FakeCollapsedStore implements CollapsedStoreLike {
  value: string = '{}';

  load(): string {
    return this.value;
  }

  save(json: string): void {
    this.value = json;
  }
}

// ---------- 测试数据辅助 ----------

function makeHost(id: string, name: string, host: string, username: string,
  groupId: string | null): HostProfile {
  const profile: HostProfile = createDefaultHostProfile(id);
  profile.name = name;
  profile.host = host;
  profile.username = username;
  profile.groupId = groupId;
  return profile;
}

function makeGroup(id: string, name: string, order: number): HostGroup {
  const group: HostGroup = createDefaultHostGroup(id);
  group.name = name;
  group.order = order;
  return group;
}

function makeSession(hostId: string, state: string): HostSessionStateLike {
  return { hostId: hostId, state: state };
}

/** 提取行序列中全部主机行的 hostId（保持出现顺序） */
function hostIdsOf(rows: HostListRow[]): string[] {
  const ids: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    const host: HostProfile | null = rows[i].host;
    if (host !== null) {
      ids.push(host.id);
    }
  }
  return ids;
}

/** 提取行序列中全部组头行的分组 id（保持出现顺序） */
function groupIdsOf(rows: HostListRow[]): string[] {
  const ids: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].kind === 'groupHeader') {
      ids.push(rows[i].groupId);
    }
  }
  return ids;
}

/** 空状态点表（不涉及状态点的用例统一使用） */
function emptyStatusMap(): Map<string, HostConnStatus> {
  return new Map();
}

/** 视图模型测试夹具：VM + 三个内存 fake（避免 describe 内嵌套函数，arkts-no-nested-funcs） */
interface VmFixture {
  readonly vm: HostListViewModel;
  readonly hostDao: FakeHostDao;
  readonly groupDao: FakeGroupDao;
  readonly store: FakeCollapsedStore;
}

function makeVmFixture(): VmFixture {
  const hostDao: FakeHostDao = new FakeHostDao();
  hostDao.hosts = [
    makeHost('h2', 'bbb', 'db.internal', 'dba', 'g2'),
    makeHost('h1', 'aaa', 'web.example.com', 'deploy', 'g1'),
    makeHost('h3', 'ccc', '10.0.0.1', 'ops', null)
  ];
  const groupDao: FakeGroupDao = new FakeGroupDao();
  groupDao.groups = [makeGroup('g2', '二组', 2), makeGroup('g1', '一组', 1)];
  const store: FakeCollapsedStore = new FakeCollapsedStore();
  const deps: HostListViewModelDeps = {
    hostDao: hostDao,
    groupDao: groupDao,
    collapsedStore: store
  };
  return { vm: new HostListViewModel(deps), hostDao: hostDao, groupDao: groupDao, store: store };
}

export default function hostListViewModelTest() {
  // ---------- 搜索过滤 ----------

  describe('HostListFilterTest', () => {

    const hosts: HostProfile[] = [
      makeHost('h1', '生产 Web', 'web.example.com', 'deploy', 'g1'),
      makeHost('h2', '数据库', 'db.internal', 'DBA', 'g1'),
      makeHost('h3', '跳板机', '10.0.0.1', 'ops', null)
    ];

    it('空串与纯空白复原全量', 0, () => {
      expect(filterHosts(hosts, '').length).assertEqual(3);
      expect(filterHosts(hosts, '   ').length).assertEqual(3);
    });

    it('按名称匹配_大小写不敏感_首尾空白忽略', 0, () => {
      const hits: HostProfile[] = filterHosts(hosts, '  WEB ');
      expect(hits.length).assertEqual(1);
      expect(hits[0].id).assertEqual('h1');
    });

    it('按主机地址匹配', 0, () => {
      const hits: HostProfile[] = filterHosts(hosts, 'DB.INTERNAL');
      expect(hits.length).assertEqual(1);
      expect(hits[0].id).assertEqual('h2');
      expect(filterHosts(hosts, '10.0').length).assertEqual(1);
    });

    it('按用户名匹配', 0, () => {
      const hits: HostProfile[] = filterHosts(hosts, 'dba');
      expect(hits.length).assertEqual(1);
      expect(hits[0].id).assertEqual('h2');
    });

    it('无匹配返回空_输入不被修改', 0, () => {
      expect(filterHosts(hosts, '不存在').length).assertEqual(0);
      expect(hosts.length).assertEqual(3);
    });
  });

  // ---------- 分组排序与行构建 ----------

  describe('HostListGroupTest', () => {

    it('分组按order升序_同序按name码元序', 0, () => {
      // 同序 tie-break 为 name 码元序：'B'(66) < 'C'(67)，顺序与直觉一致且无歧义
      const groups: HostGroup[] = [
        makeGroup('g2', 'B组', 2),
        makeGroup('g1', '甲组', 0),
        makeGroup('g3', 'C组', 2)
      ];
      const sorted: HostGroup[] = sortGroupsByOrder(groups);
      expect(sorted[0].id).assertEqual('g1');
      expect(sorted[1].id).assertEqual('g2');
      expect(sorted[2].id).assertEqual('g3');
    });

    it('行序列_分组区按序_未分组置后_组内未使用按name字典序', 0, () => {
      const hosts: HostProfile[] = [
        makeHost('h-b', 'bbb', 'x', 'u', 'g1'),
        makeHost('h-a', 'aaa', 'x', 'u', 'g1'),
        makeHost('h-u', 'zzz', 'x', 'u', null),
        makeHost('h2', 'mid', 'x', 'u', 'g2')
      ];
      const groups: HostGroup[] = [makeGroup('g2', '二组', 2), makeGroup('g1', '一组', 1)];
      const rows: HostListRow[] = buildHostRows(hosts, groups, new Set(), emptyStatusMap());
      expect(groupIdsOf(rows).join(',')).assertEqual('g1,g2,');
      // 从未使用时退化为 name 字典序：h-a 排在 h-b 前
      expect(hostIdsOf(rows).join(',')).assertEqual('h-a,h-b,h2,h-u');
    });

    it('行序列_组内按最后使用近者优先', 0, () => {
      const hosts: HostProfile[] = [
        makeHost('h-a', 'aaa', 'x', 'u', 'g1'),
        makeHost('h-b', 'bbb', 'x', 'u', 'g1'),
        makeHost('h-c', 'ccc', 'x', 'u', 'g1')
      ];
      const groups: HostGroup[] = [makeGroup('g1', '一组', 1)];
      const lastUsed: Map<string, number> = new Map();
      lastUsed.set('h-c', 30);
      lastUsed.set('h-a', 10);
      const rows: HostListRow[] = buildHostRows(hosts, groups, new Set(), emptyStatusMap(), lastUsed);
      expect(hostIdsOf(rows).join(',')).assertEqual('h-c,h-a,h-b');
    });

    it('最后使用编解码往返_脏数据收敛', 0, () => {
      const source: Map<string, number> = new Map();
      source.set('h1', 100);
      source.set('h2', 200);
      const back: Map<string, number> = decodeHostLastUsed(encodeHostLastUsed(source));
      expect(back.get('h1')).assertEqual(100);
      expect(back.get('h2')).assertEqual(200);
      expect(decodeHostLastUsed('').size).assertEqual(0);
      expect(decodeHostLastUsed('[]').size).assertEqual(0);
      expect(decodeHostLastUsed('not-json').size).assertEqual(0);
    });

    it('sortHostsByLastUsed_近者优先_未使用靠后_同时间按name', 0, () => {
      const hosts: HostProfile[] = [
        makeHost('h-b', 'bbb', 'x', 'u', null),
        makeHost('h-a', 'aaa', 'x', 'u', null),
        makeHost('h-c', 'ccc', 'x', 'u', null)
      ];
      const lastUsed: Map<string, number> = new Map();
      lastUsed.set('h-b', 5);
      lastUsed.set('h-c', 5);
      const sorted: HostProfile[] = sortHostsByLastUsed(hosts, lastUsed);
      expect(sorted[0].id).assertEqual('h-b');
      expect(sorted[1].id).assertEqual('h-c');
      expect(sorted[2].id).assertEqual('h-a');
    });

    it('折叠组只保留组头行_未分组区同样可折叠', 0, () => {
      const hosts: HostProfile[] = [
        makeHost('h1', 'a', 'x', 'u', 'g1'),
        makeHost('h2', 'b', 'x', 'u', null)
      ];
      const groups: HostGroup[] = [makeGroup('g1', '一组', 0)];
      const collapsed: Set<string> = new Set();
      collapsed.add('g1');
      collapsed.add(GROUP_ID_UNGROUPED);
      const rows: HostListRow[] = buildHostRows(hosts, groups, collapsed, emptyStatusMap());
      expect(rows.length).assertEqual(2);
      expect(rows[0].kind).assertEqual('groupHeader');
      expect(rows[0].collapsed).assertTrue();
      expect(rows[1].kind).assertEqual('groupHeader');
      expect(rows[1].groupId).assertEqual(GROUP_ID_UNGROUPED);
      expect(rows[1].groupName).assertEqual('未分组');
    });

    it('空组不产出行_脏groupId归入未分组', 0, () => {
      const hosts: HostProfile[] = [makeHost('h1', 'a', 'x', 'u', 'g-ghost')];
      const groups: HostGroup[] = [makeGroup('g1', '空组', 0)];
      const rows: HostListRow[] = buildHostRows(hosts, groups, new Set(), emptyStatusMap());
      expect(rows.length).assertEqual(2);
      expect(rows[0].groupId).assertEqual(GROUP_ID_UNGROUPED);
      expect(hostIdsOf(rows).join(',')).assertEqual('h1');
    });

    it('无未分组主机时不产出未分组组头', 0, () => {
      const hosts: HostProfile[] = [makeHost('h1', 'a', 'x', 'u', 'g1')];
      const groups: HostGroup[] = [makeGroup('g1', '一组', 0)];
      const rows: HostListRow[] = buildHostRows(hosts, groups, new Set(), emptyStatusMap());
      expect(groupIdsOf(rows).join(',')).assertEqual('g1');
    });

    it('主机行携带状态点_组头行状态恒为none', 0, () => {
      const hosts: HostProfile[] = [makeHost('h1', 'a', 'x', 'u', null)];
      const statusMap: Map<string, HostConnStatus> = new Map();
      statusMap.set('h1', 'established');
      const rows: HostListRow[] = buildHostRows(hosts, [], new Set(), statusMap);
      expect(rows.length).assertEqual(2);
      expect(rows[0].connStatus).assertEqual('none');
      expect(rows[1].connStatus).assertEqual('established');
    });
  });

  // ---------- 折叠集合与持久化编解码 ----------

  describe('CollapsedCodecTest', () => {

    it('编码解码往返_空集编码为空对象', 0, () => {
      expect(encodeCollapsedGroups(new Set())).assertEqual('{}');
      const collapsed: Set<string> = new Set();
      collapsed.add('g1');
      collapsed.add(GROUP_ID_UNGROUPED);
      const restored: Set<string> = decodeCollapsedGroups(encodeCollapsedGroups(collapsed));
      expect(restored.size).assertEqual(2);
      expect(restored.has('g1')).assertTrue();
      expect(restored.has(GROUP_ID_UNGROUPED)).assertTrue();
    });

    it('toggle往返_新增再取消_不可变更新', 0, () => {
      const before: Set<string> = new Set();
      const added: Set<string> = toggleCollapsed(before, 'g1');
      expect(added.has('g1')).assertTrue();
      // 不可变更新：原集合不受影响
      expect(before.size).assertEqual(0);
      const removed: Set<string> = toggleCollapsed(added, 'g1');
      expect(removed.size).assertEqual(0);
    });

    it('脏数据_非法JSON或非对象收敛空集', 0, () => {
      expect(decodeCollapsedGroups('').size).assertEqual(0);
      expect(decodeCollapsedGroups('not-a-json').size).assertEqual(0);
      expect(decodeCollapsedGroups('null').size).assertEqual(0);
      expect(decodeCollapsedGroups('["g1"]').size).assertEqual(0);
      expect(decodeCollapsedGroups('42').size).assertEqual(0);
    });

    it('脏数据_仅保留布尔true键_其余剔除', 0, () => {
      const restored: Set<string> = decodeCollapsedGroups('{"g1":true,"g2":false,"g3":1,"g4":"yes"}');
      expect(restored.size).assertEqual(1);
      expect(restored.has('g1')).assertTrue();
    });
  });

  // ---------- 状态点派生 ----------

  describe('HostConnStatusTest', () => {

    it('会话状态映射_进行中为connecting_瞬态与未知归none', 0, () => {
      expect(sessionStateToStatus('connecting')).assertEqual('connecting');
      expect(sessionStateToStatus('handshaking')).assertEqual('connecting');
      expect(sessionStateToStatus('authenticating')).assertEqual('connecting');
      expect(sessionStateToStatus('established')).assertEqual('established');
      expect(sessionStateToStatus('disconnected')).assertEqual('disconnected');
      expect(sessionStateToStatus('error')).assertEqual('error');
      expect(sessionStateToStatus('idle')).assertEqual('none');
      expect(sessionStateToStatus('closing')).assertEqual('none');
      expect(sessionStateToStatus('closed')).assertEqual('none');
      expect(sessionStateToStatus('bogus')).assertEqual('none');
    });

    it('无会话为none_只统计本主机会话', 0, () => {
      const sessions: HostSessionStateLike[] = [makeSession('h-other', 'error')];
      expect(deriveHostConnStatus(sessions, 'h1')).assertEqual('none');
      expect(deriveHostConnStatus([], 'h1')).assertEqual('none');
    });

    it('多会话同主机取最严重_error>connecting>disconnected>established', 0, () => {
      const sessions: HostSessionStateLike[] = [
        makeSession('h1', 'established'),
        makeSession('h1', 'disconnected')
      ];
      expect(deriveHostConnStatus(sessions, 'h1')).assertEqual('disconnected');
      sessions.push(makeSession('h1', 'connecting'));
      expect(deriveHostConnStatus(sessions, 'h1')).assertEqual('connecting');
      sessions.push(makeSession('h1', 'error'));
      expect(deriveHostConnStatus(sessions, 'h1')).assertEqual('error');
    });

    it('buildConnStatusMap按主机聚合_互不串扰', 0, () => {
      const map: Map<string, HostConnStatus> = buildConnStatusMap([
        makeSession('h1', 'established'),
        makeSession('h1', 'error'),
        makeSession('h2', 'authenticating'),
        makeSession('h3', 'closed')
      ]);
      expect(map.get('h1')).assertEqual('error');
      expect(map.get('h2')).assertEqual('connecting');
      expect(map.get('h3')).assertEqual('none');
      expect(map.get('h9')).assertUndefined();
    });
  });

  // ---------- 快速连接地址解析 ----------

  describe('QuickConnectAddressTest', () => {

    it('纯主机默认22_host_port解析', 0, () => {
      const plain: QuickConnectTarget | null = parseQuickConnectAddress('example.com');
      expect(plain !== null).assertTrue();
      if (plain !== null) {
        expect(plain.host).assertEqual('example.com');
        expect(plain.port).assertEqual(22);
      }
      const withPort: QuickConnectTarget | null = parseQuickConnectAddress(' example.com :2222 ');
      expect(withPort !== null).assertTrue();
      if (withPort !== null) {
        expect(withPort.host).assertEqual('example.com');
        expect(withPort.port).assertEqual(2222);
      }
      const emptyPort: QuickConnectTarget | null = parseQuickConnectAddress('example.com:');
      expect(emptyPort !== null && emptyPort.port === 22).assertTrue();
    });

    it('非法输入返回null_多冒号按IPv6字面量', 0, () => {
      expect(parseQuickConnectAddress('')).assertNull();
      expect(parseQuickConnectAddress('  ')).assertNull();
      expect(parseQuickConnectAddress(':22')).assertNull();
      expect(parseQuickConnectAddress('example.com:abc')).assertNull();
      expect(parseQuickConnectAddress('example.com:0')).assertNull();
      expect(parseQuickConnectAddress('example.com:65536')).assertNull();
      const v6: QuickConnectTarget | null = parseQuickConnectAddress('2001:db8::1');
      expect(v6 !== null).assertTrue();
      if (v6 !== null) {
        expect(v6.host).assertEqual('2001:db8::1');
        expect(v6.port).assertEqual(22);
      }
    });
  });

  // ---------- 视图模型编排（注入 fake） ----------

  describe('HostListViewModelTest', () => {

    it('reload拉取并排序_行序列分组按order', 0, () => {
      const vm: HostListViewModel = makeVmFixture().vm;
      expect(vm.reload()).assertTrue();
      expect(vm.hosts.length).assertEqual(3);
      const rows: HostListRow[] = vm.buildRows();
      expect(groupIdsOf(rows).join(',')).assertEqual('g1,g2,');
      expect(hostIdsOf(rows).join(',')).assertEqual('h1,h2,h3');
    });

    it('搜索串驱动行过滤_清空复原', 0, () => {
      const vm: HostListViewModel = makeVmFixture().vm;
      vm.reload();
      vm.setSearchText('WEB');
      expect(hostIdsOf(vm.buildRows()).join(',')).assertEqual('h1');
      vm.setSearchText('');
      expect(hostIdsOf(vm.buildRows()).length).assertEqual(3);
    });

    it('折叠切换持久化JSON_重载后复原', 0, () => {
      const store: FakeCollapsedStore = new FakeCollapsedStore();
      const hostDao: FakeHostDao = new FakeHostDao();
      hostDao.hosts = [makeHost('h1', 'a', 'x', 'u', 'g1')];
      const groupDao: FakeGroupDao = new FakeGroupDao();
      groupDao.groups = [makeGroup('g1', '一组', 0)];
      const deps: HostListViewModelDeps = {
        hostDao: hostDao, groupDao: groupDao, collapsedStore: store
      };
      const vm: HostListViewModel = new HostListViewModel(deps);
      vm.reload();
      vm.toggleGroupCollapsed('g1');
      // 持久化内容即 JSON 串 groupId→true
      expect(store.value).assertEqual('{"g1":true}');
      // 折叠后组内主机行消失
      expect(hostIdsOf(vm.buildRows()).length).assertEqual(0);
      // 模拟重启：新实例从同一存储恢复折叠状态
      const vm2: HostListViewModel = new HostListViewModel(deps);
      vm2.reload();
      expect(vm2.collapsedGroupIds.has('g1')).assertTrue();
      expect(hostIdsOf(vm2.buildRows()).length).assertEqual(0);
      vm2.toggleGroupCollapsed('g1');
      expect(store.value).assertEqual('{}');
      expect(hostIdsOf(vm2.buildRows()).join(',')).assertEqual('h1');
    });

    it('refreshConnStatus驱动行状态点', 0, () => {
      const vm: HostListViewModel = makeVmFixture().vm;
      vm.reload();
      vm.refreshConnStatus([makeSession('h1', 'error'), makeSession('h1', 'established')]);
      const rows: HostListRow[] = vm.buildRows();
      let h1Status: HostConnStatus = 'none';
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].host !== null && rows[i].host?.id === 'h1') {
          h1Status = rows[i].connStatus;
        }
      }
      expect(h1Status).assertEqual('error');
    });

    it('deleteHost经DAO删除并刷新列表', 0, () => {
      const hostDao: FakeHostDao = new FakeHostDao();
      hostDao.hosts = [makeHost('h1', 'a', 'x', 'u', null), makeHost('h2', 'b', 'y', 'u', null)];
      const deps: HostListViewModelDeps = {
        hostDao: hostDao, groupDao: new FakeGroupDao(), collapsedStore: new FakeCollapsedStore()
      };
      const vm: HostListViewModel = new HostListViewModel(deps);
      vm.reload();
      expect(vm.deleteHost('h1')).assertTrue();
      expect(hostDao.deletedIds.join(',')).assertEqual('h1');
      expect(hostIdsOf(vm.buildRows()).join(',')).assertEqual('h2');
    });
    it('活动会话_只列未绑窗格的非终态会话_标题优先已保存主机名', 0, () => {
      const sessions: ActiveSessionLike[] = [
        { sessionId: 's1', hostId: 'h1', hostName: 'root@1.2.3.4', state: 'established', paneId: null },
        { sessionId: 's2', hostId: 'h2', hostName: 'dba@db', state: 'disconnected', paneId: null },
        { sessionId: 's3', hostId: 'h1', hostName: 'x', state: 'established', paneId: 'terminal-main' },
        { sessionId: 's4', hostId: 'h3', hostName: 'y', state: 'closed', paneId: null },
        { sessionId: 's5', hostId: 'tmp', hostName: '', state: 'connecting', paneId: null }
      ];
      const names: Map<string, string> = new Map();
      names.set('h1', '生产机');
      const items: ActiveSessionItem[] = buildActiveSessionItems(sessions, names);
      expect(items.length).assertEqual(3);
      expect(items[0].title).assertEqual('生产机');
      expect(items[0].statusLabel).assertEqual('运行中');
      expect(items[1].title).assertEqual('dba@db');
      expect(items[1].status).assertEqual('disconnected');
      expect(items[2].title).assertEqual('终端');
      expect(items[2].status).assertEqual('connecting');
    });
  });
}
