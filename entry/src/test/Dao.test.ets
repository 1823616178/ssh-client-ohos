/**
 * DAO 与行映射单元测试（任务 C1）。
 *
 * relationalStore 的真实读写依赖 context（设备沙箱），单测用 InMemoryRdbGateway
 * 内存 fake 实现同一 RdbGateway 接口（Map 保持插入序，模拟 SQLite rowid 序；
 * 等值过滤、单列排序、IS NULL 语义与生产实现一致），从而在无 context 环境下
 * 覆盖全部六个 DAO 的 CRUD 与按外键查询，以及 toRow/fromRow 行映射往返。
 * fake 与生产实现的行为对齐点：update 不存在的 id 不报错、getById 未命中返回 null。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  AppearanceProfile,
  HostGroup,
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  Snippet,
  createDefaultAppearanceProfile,
  createDefaultHostGroup,
  createDefaultHostProfile,
  createDefaultPortForwardRule,
  createDefaultSnippet
} from '../main/ets/common/model/models';
import { SshError, SshErrorCode } from '../main/ets/common/SshError';
import { ColumnDef } from '../main/ets/repository/DatabaseSchema';
import { RdbGateway, RowObject, RowValue } from '../main/ets/repository/RdbGateway';
import {
  AppearanceDao,
  ForwardDao,
  GroupDao,
  HostDao,
  KnownHostDao,
  SnippetDao
} from '../main/ets/repository/Daos';
import {
  appearanceToRow,
  forwardToRow,
  hostToRow,
  rowToAppearance,
  rowToForward,
  rowToHost
} from '../main/ets/repository/RowMappers';

// ---------- 内存 fake ----------

/** 排序比较：数值列按数值，其余按字符串（null 视为空串） */
function compareRowValue(a: RowValue, b: RowValue): number {
  if (typeof a === 'number' && typeof b === 'number') {
    return a - b;
  }
  const as: string = a === null ? '' : `${a}`;
  const bs: string = b === null ? '' : `${b}`;
  if (as === bs) {
    return 0;
  }
  return as < bs ? -1 : 1;
}

/** RdbGateway 内存实现：table -> 主键 id -> 行 */
class InMemoryRdbGateway implements RdbGateway {
  private readonly tables: Map<string, Map<string, RowObject>> = new Map();
  /** 记录执行过的 DDL（本测试不依赖，留作排查用） */
  readonly executedSqls: string[] = [];

  private tableOf(name: string): Map<string, RowObject> {
    let table = this.tables.get(name);
    if (table === undefined) {
      table = new Map<string, RowObject>();
      this.tables.set(name, table);
    }
    return table;
  }

  insert(table: string, row: RowObject): void {
    this.tableOf(table).set(row['id'] as string, row);
  }

  updateById(table: string, id: string, row: RowObject): void {
    const store: Map<string, RowObject> = this.tableOf(table);
    if (!store.has(id)) {
      return;
    }
    store.set(id, row);
  }

  deleteById(table: string, id: string): void {
    this.tableOf(table).delete(id);
  }

  getById(table: string, id: string, columns: ColumnDef[]): RowObject | null {
    const row: RowObject | undefined = this.tableOf(table).get(id);
    return row === undefined ? null : row;
  }

  queryWhere(table: string, filters: Record<string, RowValue>, orderBy: string, columns: ColumnDef[]): RowObject[] {
    const keys: string[] = Object.keys(filters);
    const result: RowObject[] = [];
    this.tableOf(table).forEach((row: RowObject) => {
      let match: boolean = true;
      for (let i = 0; i < keys.length; i++) {
        if (row[keys[i]] !== filters[keys[i]]) {
          match = false;
          break;
        }
      }
      if (match) {
        result.push(row);
      }
    });
    if (orderBy.length > 0) {
      result.sort((a: RowObject, b: RowObject) => compareRowValue(a[orderBy], b[orderBy]));
    }
    return result;
  }

  executeSql(sql: string): void {
    this.executedSqls.push(sql);
  }

  queryScalarInt(sql: string): number {
    return 0;
  }
}

/** insert 即抛错的 fake：验证 DAO 错误包装策略 */
class FailingGateway extends InMemoryRdbGateway {
  insert(table: string, row: RowObject): void {
    throw new Error('模拟底层写失败');
  }
}

// ---------- 测试数据与断言辅助 ----------

function sampleHost(id: string, groupId: string | null): HostProfile {
  const host: HostProfile = createDefaultHostProfile(id);
  host.name = `主机${id}`;
  host.host = '192.168.1.10';
  host.port = 2222;
  host.username = 'root';
  host.authType = 'key';
  host.hostFingerprint = 'SHA256:abcdef';
  host.keepalive = 45;
  host.groupId = groupId;
  host.appearanceId = 'ap-1';
  host.jumpHostId = 'h-jump';
  host.initCommands = ['ls -la', 'cd /opt'];
  // ArkTS 禁止 Record 类型的非空字面量，逐键赋值
  host.envVars = {};
  host.envVars['LANG'] = 'zh_CN.UTF-8';
  host.envVars['EDITOR'] = 'vim';
  host.termType = 'xterm-256color';
  return host;
}

function sampleGroup(id: string, order: number): HostGroup {
  const group: HostGroup = createDefaultHostGroup(id);
  group.name = `分组${id}`;
  group.order = order;
  return group;
}

function sampleAppearance(id: string): AppearanceProfile {
  const appearance: AppearanceProfile = createDefaultAppearanceProfile(id);
  appearance.name = `主题${id}`;
  appearance.ligatures = true;
  appearance.cursorBlink = false;
  appearance.cursorStyle = 'underline';
  appearance.lineHeight = 1.5;
  appearance.padding = 12;
  return appearance;
}

function sampleSnippet(id: string, groupId: string | null): Snippet {
  const snippet: Snippet = createDefaultSnippet(id);
  snippet.name = `片段${id}`;
  snippet.content = 'sudo systemctl restart nginx';
  snippet.groupId = groupId;
  return snippet;
}

function sampleKnownHost(id: string, host: string, port: number, keyType: string): KnownHostEntry {
  return {
    id: id,
    host: host,
    port: port,
    keyType: keyType,
    fingerprint: `SHA256:${id}`,
    addedAt: '2026-08-14T12:00:00.000Z'
  };
}

function sampleForward(id: string, hostId: string): PortForwardRule {
  const rule: PortForwardRule = createDefaultPortForwardRule(id, hostId);
  rule.type = 'remote';
  rule.bindAddress = '0.0.0.0';
  rule.localPort = 8080;
  rule.remoteHost = 'internal.example.com';
  rule.remotePort = 3306;
  rule.enabled = false;
  return rule;
}

/** 实体级全等断言（键序由工厂与映射函数共同保证一致） */
function assertJsonEqual(actual: Object, expected: Object): void {
  expect(JSON.stringify(actual)).assertEqual(JSON.stringify(expected));
}

function expectThrows(action: () => void): void {
  let threw: boolean = false;
  try {
    action();
  } catch (err) {
    threw = true;
  }
  expect(threw).assertTrue();
}

export default function daoTest() {
  // ---------- 行映射往返 ----------

  describe('RowMapperTest', () => {

    it('主机映射往返全等_含JSON列与非空外键', 0, () => {
      const host: HostProfile = sampleHost('h1', 'g1');
      const row: RowObject = hostToRow(host);
      expect(row['port']).assertEqual(2222);
      expect(row['group_id']).assertEqual('g1');
      expect(row['init_commands']).assertEqual(JSON.stringify(['ls -la', 'cd /opt']));
      expect(row['env_vars']).assertEqual('{"LANG":"zh_CN.UTF-8","EDITOR":"vim"}');
      assertJsonEqual(rowToHost(row), host);
    });

    it('主机映射往返_可空外键为null', 0, () => {
      const host: HostProfile = createDefaultHostProfile('h2');
      const row: RowObject = hostToRow(host);
      expect(row['group_id']).assertNull();
      expect(row['appearance_id']).assertNull();
      expect(row['jump_host_id']).assertNull();
      expect(row['init_commands']).assertEqual('[]');
      expect(row['env_vars']).assertEqual('{}');
      assertJsonEqual(rowToHost(row), host);
    });

    it('外观映射_布尔列转01且palette走JSON', 0, () => {
      const appearance: AppearanceProfile = sampleAppearance('ap1');
      const row: RowObject = appearanceToRow(appearance);
      expect(row['ligatures']).assertEqual(1);
      expect(row['cursor_blink']).assertEqual(0);
      expect(row['bold_as_bright']).assertEqual(1);
      const paletteJson: string = row['palette'] as string;
      expect(paletteJson.indexOf('[')).assertEqual(0);
      assertJsonEqual(rowToAppearance(row), appearance);
      // 默认外观（ligatures=false / cursorBlink=true）往返
      const fallback: AppearanceProfile = createDefaultAppearanceProfile('ap2');
      expect(appearanceToRow(fallback)['ligatures']).assertEqual(0);
      assertJsonEqual(rowToAppearance(appearanceToRow(fallback)), fallback);
    });

    it('转发规则映射_enabled布尔转01且类型枚举往返', 0, () => {
      const rule: PortForwardRule = sampleForward('f1', 'h1');
      const row: RowObject = forwardToRow(rule);
      expect(row['enabled']).assertEqual(0);
      expect(row['type']).assertEqual('remote');
      assertJsonEqual(rowToForward(row), rule);
      const enabledRule: PortForwardRule = createDefaultPortForwardRule('f2', 'h1');
      expect(forwardToRow(enabledRule)['enabled']).assertEqual(1);
      assertJsonEqual(rowToForward(forwardToRow(enabledRule)), enabledRule);
    });

    it('行映射_非法枚举值收敛默认值', 0, () => {
      const host: HostProfile = sampleHost('h3', null);
      const row: RowObject = hostToRow(host);
      row['auth_type'] = 'bogus';
      expect(rowToHost(row).authType).assertEqual('password');
      const forwardRow: RowObject = forwardToRow(sampleForward('f3', 'h1'));
      forwardRow['type'] = 'bogus';
      expect(rowToForward(forwardRow).type).assertEqual('local');
    });

    it('行映射_数据损坏抛错', 0, () => {
      const row: RowObject = hostToRow(sampleHost('h4', null));
      row['port'] = null;
      expectThrows(() => rowToHost(row));
      const badJson: RowObject = hostToRow(sampleHost('h5', null));
      badJson['init_commands'] = 'not-a-json';
      expectThrows(() => rowToHost(badJson));
      const badShape: RowObject = hostToRow(sampleHost('h6', null));
      badShape['env_vars'] = '["not-object"]';
      expectThrows(() => rowToHost(badShape));
    });
  });

  // ---------- HostDao ----------

  describe('HostDaoTest', () => {

    it('CRUD_insert后可getById且字段全等', 0, () => {
      const dao = new HostDao(new InMemoryRdbGateway());
      const host: HostProfile = sampleHost('h1', 'g1');
      dao.insert(host);
      const loaded: HostProfile | null = dao.getById('h1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        assertJsonEqual(loaded, host);
      }
    });

    it('CRUD_update整行覆盖', 0, () => {
      const dao = new HostDao(new InMemoryRdbGateway());
      dao.insert(sampleHost('h1', null));
      const changed: HostProfile = sampleHost('h1', 'g2');
      changed.name = '改名后';
      changed.port = 22;
      dao.update(changed);
      const loaded: HostProfile | null = dao.getById('h1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        assertJsonEqual(loaded, changed);
      }
    });

    it('CRUD_deleteById后查不到_未命中返回null', 0, () => {
      const dao = new HostDao(new InMemoryRdbGateway());
      dao.insert(sampleHost('h1', null));
      dao.deleteById('h1');
      expect(dao.getById('h1')).assertNull();
      expect(dao.getById('不存在')).assertNull();
      // update / delete 未命中 id 不抛错（SQLite 语义）
      dao.update(sampleHost('ghost', null));
      dao.deleteById('ghost');
      expect(dao.getById('ghost')).assertNull();
    });

    it('查询_listAll按name排序', 0, () => {
      const dao = new HostDao(new InMemoryRdbGateway());
      const b: HostProfile = sampleHost('h-b', null);
      b.name = 'bbb';
      const a: HostProfile = sampleHost('h-a', null);
      a.name = 'aaa';
      dao.insert(b);
      dao.insert(a);
      const all: HostProfile[] = dao.listAll();
      expect(all.length).assertEqual(2);
      expect(all[0].id).assertEqual('h-a');
      expect(all[1].id).assertEqual('h-b');
    });

    it('查询_listByGroupId按分组过滤', 0, () => {
      const dao = new HostDao(new InMemoryRdbGateway());
      dao.insert(sampleHost('h1', 'g1'));
      dao.insert(sampleHost('h2', 'g1'));
      dao.insert(sampleHost('h3', 'g2'));
      const inG1: HostProfile[] = dao.listByGroupId('g1');
      expect(inG1.length).assertEqual(2);
      expect(inG1[0].groupId).assertEqual('g1');
      expect(inG1[1].groupId).assertEqual('g1');
      expect(dao.listByGroupId('g9').length).assertEqual(0);
    });

    it('错误策略_底层异常包装为SshError_INTERNAL_ERROR', 0, () => {
      const dao = new HostDao(new FailingGateway());
      let caught: SshError | null = null;
      try {
        dao.insert(sampleHost('h1', null));
      } catch (err) {
        caught = err as SshError;
      }
      expect(caught !== null).assertTrue();
      if (caught !== null) {
        expect(caught.code).assertEqual(SshErrorCode.INTERNAL_ERROR);
      }
    });
  });

  // ---------- GroupDao ----------

  describe('GroupDaoTest', () => {

    it('CRUD与listAll按order_index排序', 0, () => {
      const dao = new GroupDao(new InMemoryRdbGateway());
      dao.insert(sampleGroup('g1', 2));
      dao.insert(sampleGroup('g2', 0));
      dao.insert(sampleGroup('g3', 1));
      const all: HostGroup[] = dao.listAll();
      expect(all.length).assertEqual(3);
      expect(all[0].id).assertEqual('g2');
      expect(all[1].id).assertEqual('g3');
      expect(all[2].id).assertEqual('g1');
      const loaded: HostGroup | null = dao.getById('g1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.order).assertEqual(2);
      }
    });

    it('CRUD_update与delete', 0, () => {
      const dao = new GroupDao(new InMemoryRdbGateway());
      dao.insert(sampleGroup('g1', 1));
      const changed: HostGroup = sampleGroup('g1', 5);
      changed.name = '生产环境';
      dao.update(changed);
      const loaded: HostGroup | null = dao.getById('g1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        assertJsonEqual(loaded, changed);
      }
      dao.deleteById('g1');
      expect(dao.getById('g1')).assertNull();
    });
  });

  // ---------- AppearanceDao ----------

  describe('AppearanceDaoTest', () => {

    it('CRUD_布尔与palette列往返全等', 0, () => {
      const dao = new AppearanceDao(new InMemoryRdbGateway());
      const appearance: AppearanceProfile = sampleAppearance('ap1');
      dao.insert(appearance);
      const loaded: AppearanceProfile | null = dao.getById('ap1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        assertJsonEqual(loaded, appearance);
        expect(loaded.ligatures).assertTrue();
        expect(loaded.cursorBlink).assertFalse();
        expect(loaded.palette.length).assertEqual(16);
      }
    });

    it('CRUD_update与delete_listAll按name排序', 0, () => {
      const dao = new AppearanceDao(new InMemoryRdbGateway());
      const b: AppearanceProfile = sampleAppearance('ap-b');
      b.name = 'zzz';
      const a: AppearanceProfile = sampleAppearance('ap-a');
      a.name = 'aaa';
      dao.insert(b);
      dao.insert(a);
      expect(dao.listAll()[0].id).assertEqual('ap-a');
      const changed: AppearanceProfile = sampleAppearance('ap-a');
      changed.fontSize = 18;
      dao.update(changed);
      const loaded: AppearanceProfile | null = dao.getById('ap-a');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.fontSize).assertEqual(18);
      }
      dao.deleteById('ap-a');
      dao.deleteById('ap-b');
      expect(dao.listAll().length).assertEqual(0);
    });
  });

  // ---------- SnippetDao ----------

  describe('SnippetDaoTest', () => {

    it('CRUD与listByGroupId', 0, () => {
      const dao = new SnippetDao(new InMemoryRdbGateway());
      dao.insert(sampleSnippet('s1', 'g1'));
      dao.insert(sampleSnippet('s2', 'g1'));
      dao.insert(sampleSnippet('s3', null));
      const loaded: Snippet | null = dao.getById('s1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        assertJsonEqual(loaded, sampleSnippet('s1', 'g1'));
      }
      expect(dao.listAll().length).assertEqual(3);
      expect(dao.listByGroupId('g1').length).assertEqual(2);
      const changed: Snippet = sampleSnippet('s1', 'g2');
      dao.update(changed);
      expect(dao.listByGroupId('g1').length).assertEqual(1);
      expect(dao.listByGroupId('g2').length).assertEqual(1);
      dao.deleteById('s1');
      expect(dao.getById('s1')).assertNull();
    });
  });

  // ---------- KnownHostDao ----------

  describe('KnownHostDaoTest', () => {

    it('CRUD与getByHostPortKey精确查', 0, () => {
      const dao = new KnownHostDao(new InMemoryRdbGateway());
      dao.insert(sampleKnownHost('k1', 'example.com', 22, 'ssh-ed25519'));
      dao.insert(sampleKnownHost('k2', 'example.com', 22, 'rsa-sha2-256'));
      dao.insert(sampleKnownHost('k3', 'other.com', 2222, 'ssh-ed25519'));
      const hit: KnownHostEntry | null = dao.getByHostPortKey('example.com', 22, 'ssh-ed25519');
      expect(hit !== null).assertTrue();
      if (hit !== null) {
        assertJsonEqual(hit, sampleKnownHost('k1', 'example.com', 22, 'ssh-ed25519'));
      }
      expect(dao.getByHostPortKey('example.com', 22, 'ecdsa-sha2-nistp256')).assertNull();
      expect(dao.getByHostPortKey('example.com', 2222, 'ssh-ed25519')).assertNull();
      expect(dao.listAll().length).assertEqual(3);
      const changed: KnownHostEntry = sampleKnownHost('k1', 'example.com', 22, 'ssh-ed25519');
      changed.fingerprint = 'SHA256:rotated';
      dao.update(changed);
      const rotated: KnownHostEntry | null = dao.getByHostPortKey('example.com', 22, 'ssh-ed25519');
      expect(rotated !== null).assertTrue();
      if (rotated !== null) {
        expect(rotated.fingerprint).assertEqual('SHA256:rotated');
      }
      dao.deleteById('k1');
      expect(dao.getById('k1')).assertNull();
    });
  });

  // ---------- ForwardDao ----------

  describe('ForwardDaoTest', () => {

    it('CRUD与listByHostId', 0, () => {
      const dao = new ForwardDao(new InMemoryRdbGateway());
      dao.insert(sampleForward('f1', 'h1'));
      dao.insert(sampleForward('f2', 'h1'));
      dao.insert(sampleForward('f3', 'h2'));
      const loaded: PortForwardRule | null = dao.getById('f1');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        assertJsonEqual(loaded, sampleForward('f1', 'h1'));
        expect(loaded.enabled).assertFalse();
        expect(loaded.type).assertEqual('remote');
      }
      expect(dao.listAll().length).assertEqual(3);
      const ofH1: PortForwardRule[] = dao.listByHostId('h1');
      expect(ofH1.length).assertEqual(2);
      expect(ofH1[0].hostId).assertEqual('h1');
      expect(dao.listByHostId('h9').length).assertEqual(0);
      const changed: PortForwardRule = sampleForward('f1', 'h1');
      changed.enabled = true;
      changed.localPort = 9090;
      dao.update(changed);
      const updated: PortForwardRule | null = dao.getById('f1');
      expect(updated !== null).assertTrue();
      if (updated !== null) {
        expect(updated.enabled).assertTrue();
        expect(updated.localPort).assertEqual(9090);
      }
      dao.deleteById('f1');
      expect(dao.listByHostId('h1').length).assertEqual(1);
    });
  });
}
