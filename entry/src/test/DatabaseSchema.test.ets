/**
 * DatabaseSchema 单元测试（任务 C1）。
 *
 * 覆盖纯函数 planMigration 与 schema 静态结构：
 *   - v1 -> v1 空计划；v0 -> v1 全新建库计划（六张表 + 索引，按序）；
 *   - 用注入的临时步骤表模拟 v1 -> vN：跨多步顺序拼接、从中间版本起的部分升级；
 *   - 非法输入报错：降级、负版本、目标版本超出已知范围、迁移链断裂/跨过目标版本；
 *   - MIGRATIONS 版本链完整（从 0 连续到 SCHEMA_VERSION）、建表 SQL 与 TableDef 列清单一致。
 * relationalStore 真实执行依赖 context，不在单测覆盖（见 Dao.test.ets 与真机联调）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ALL_TABLES,
  APPEARANCE_TABLE,
  FORWARDS_TABLE,
  HOSTS_TABLE,
  HOST_GROUPS_TABLE,
  KNOWN_HOSTS_TABLE,
  MIGRATIONS,
  SCHEMA_VERSION,
  SNIPPETS_TABLE,
  ColumnDef,
  MigrationStep,
  TableDef,
  planMigration
} from '../main/ets/repository/DatabaseSchema';

/** 断言 action 抛异常（配置错误必须暴露） */
function expectThrows(action: () => void, caseName: string): void {
  let threw: boolean = false;
  try {
    action();
  } catch (err) {
    threw = true;
  }
  expect(threw).assertTrue();
}

/** 构造临时迁移步骤（模拟未来 vN 链路） */
function makeStep(from: number, to: number, sqls: string[]): MigrationStep {
  return { fromVersion: from, toVersion: to, sqls: sqls, comment: 'test' };
}

export default function databaseSchemaTest() {
  describe('DatabaseSchemaTest', () => {

    it('planMigration_同版本返回空计划', 0, () => {
      expect(planMigration(1, 1).length).assertEqual(0);
      expect(planMigration(0, 0).length).assertEqual(0);
    });

    it('planMigration_全新库v0到v1_包含六表与索引且按序', 0, () => {
      const plan: string[] = planMigration(0, 1);
      // 6 条 CREATE TABLE + 3 条 CREATE INDEX
      expect(plan.length).assertEqual(9);
      // 建表顺序：被引用的 host_groups / appearance 在前，forwards 最后
      expect(plan[0].indexOf('CREATE TABLE IF NOT EXISTS host_groups')).assertEqual(0);
      expect(plan[1].indexOf('CREATE TABLE IF NOT EXISTS appearance')).assertEqual(0);
      expect(plan[2].indexOf('CREATE TABLE IF NOT EXISTS hosts')).assertEqual(0);
      expect(plan[3].indexOf('CREATE TABLE IF NOT EXISTS snippets')).assertEqual(0);
      expect(plan[4].indexOf('CREATE TABLE IF NOT EXISTS known_hosts')).assertEqual(0);
      expect(plan[5].indexOf('CREATE TABLE IF NOT EXISTS forwards')).assertEqual(0);
      for (let i = 6; i < 9; i++) {
        expect(plan[i].indexOf('CREATE INDEX IF NOT EXISTS')).assertEqual(0);
      }
    });

    it('planMigration_跨多步按序拼接', 0, () => {
      const steps: MigrationStep[] = [
        makeStep(0, 1, ['A0']),
        makeStep(1, 2, ['B0', 'B1']),
        makeStep(2, 3, ['C0'])
      ];
      const plan: string[] = planMigration(0, 3, steps);
      expect(plan.length).assertEqual(4);
      expect(plan[0]).assertEqual('A0');
      expect(plan[1]).assertEqual('B0');
      expect(plan[2]).assertEqual('B1');
      expect(plan[3]).assertEqual('C0');
    });

    it('planMigration_从中间版本起的部分升级', 0, () => {
      const steps: MigrationStep[] = [
        makeStep(0, 1, ['A0']),
        makeStep(1, 2, ['B0']),
        makeStep(2, 3, ['C0'])
      ];
      const plan: string[] = planMigration(1, 3, steps);
      expect(plan.length).assertEqual(2);
      expect(plan[0]).assertEqual('B0');
      expect(plan[1]).assertEqual('C0');
      expect(planMigration(3, 3, steps).length).assertEqual(0);
    });

    it('planMigration_降级报错', 0, () => {
      expectThrows(() => planMigration(2, 1, [makeStep(1, 2, ['B0'])]), '降级');
      expectThrows(() => planMigration(1, 0), '真实表降级');
    });

    it('planMigration_非法版本号报错', 0, () => {
      expectThrows(() => planMigration(-1, 1), '负版本');
      expectThrows(() => planMigration(0, -1), '负目标版本');
      expectThrows(() => planMigration(0, 1.5, [makeStep(0, 1, ['A0'])]), '非整数');
    });

    it('planMigration_目标版本超出已知范围报错', 0, () => {
      // 真实 MIGRATIONS 当前只到 v1，v99 必须报错（未来升到 vN 后此用例用更高的超出值）
      expectThrows(() => planMigration(1, SCHEMA_VERSION + 98), '超出已知版本');
    });

    it('planMigration_迁移链断裂或跨过目标报错', 0, () => {
      // 缺 1->2 这一步
      const gapped: MigrationStep[] = [makeStep(0, 1, ['A0']), makeStep(2, 3, ['C0'])];
      expectThrows(() => planMigration(0, 3, gapped), '迁移链断裂');
      // 一步从 0 直接到 3，目标 v2 被跨过
      const overshoot: MigrationStep[] = [makeStep(0, 3, ['A0', 'A1'])];
      expectThrows(() => planMigration(0, 2, overshoot), '跨过目标版本');
    });

    it('MIGRATIONS_版本链完整且终点等于SCHEMA_VERSION', 0, () => {
      expect(MIGRATIONS.length > 0).assertTrue();
      expect(MIGRATIONS[0].fromVersion).assertEqual(0);
      expect(MIGRATIONS[MIGRATIONS.length - 1].toVersion).assertEqual(SCHEMA_VERSION);
      for (let i = 1; i < MIGRATIONS.length; i++) {
        expect(MIGRATIONS[i].fromVersion).assertEqual(MIGRATIONS[i - 1].toVersion);
      }
      // 从全新库升级到当前版本的完整计划必须可生成
      expect(planMigration(0, SCHEMA_VERSION).length > 0).assertTrue();
    });

    it('表集合_恰为六张约定表', 0, () => {
      expect(ALL_TABLES.length).assertEqual(6);
      const names: string[] = [];
      for (let i = 0; i < ALL_TABLES.length; i++) {
        names.push(ALL_TABLES[i].name);
      }
      // groups 与 SQL 关键字 GROUPS 冲突，表名必须为 host_groups
      expect(names.join(',')).assertEqual('hosts,host_groups,appearance,snippets,known_hosts,forwards');
    });

    it('建表SQL_与TableDef列清单一致且含主键', 0, () => {
      const tables: TableDef[] = [
        HOSTS_TABLE, HOST_GROUPS_TABLE, APPEARANCE_TABLE, SNIPPETS_TABLE, KNOWN_HOSTS_TABLE, FORWARDS_TABLE
      ];
      for (let i = 0; i < tables.length; i++) {
        const table: TableDef = tables[i];
        expect(table.createSql.indexOf(`CREATE TABLE IF NOT EXISTS ${table.name} (`)).assertEqual(0);
        expect(table.createSql.indexOf('id TEXT PRIMARY KEY') >= 0).assertTrue();
        expect(table.columns.length > 0).assertTrue();
        for (let j = 0; j < table.columns.length; j++) {
          const col: ColumnDef = table.columns[j];
          // 每列名必须出现在建表 SQL 中（列名后随空格，防止前缀误配，如 id 命中 id_xxx）
          expect(table.createSql.indexOf(`${col.name} `) >= 0).assertTrue();
        }
      }
    });

    it('建表SQL_关键字避让_分组order列名为order_index', 0, () => {
      expect(HOST_GROUPS_TABLE.createSql.indexOf('order_index INTEGER') >= 0).assertTrue();
      expect(HOST_GROUPS_TABLE.columns[2].name).assertEqual('order_index');
    });

    it('建表SQL_已知主机表有唯一约束防重复指纹', 0, () => {
      expect(KNOWN_HOSTS_TABLE.createSql.indexOf('UNIQUE(host, port, key_type)') >= 0).assertTrue();
    });
  });
}
