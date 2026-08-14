/**
 * RdbGateway：DAO 与 relationalStore 之间的窄接口层（任务 C1）。
 *
 * 分层动机：relationalStore.RdbStore 的真实读写依赖 context（设备沙箱），单测无法直接覆盖；
 * 因此 DAO 只依赖本文件定义的 RdbGateway 接口——生产环境由 RdbStoreGateway 包装
 * relationalStore.RdbStore（@kit.ArkData），单测用内存 fake 实现同一接口，
 * 全部 DAO 逻辑从而可以在无 context 的单元测试中覆盖。
 *
 * 接口只承载当前 DAO 需要的最小操作集：按主键 id 的增/删/改/查、等值条件查询、
 * 迁移用的 DDL 执行与标量读取（PRAGMA user_version）。需要新查询形态时先扩接口，
 * 而不是把 RdbStore 泄漏给 DAO。
 *
 * 行表示：RowObject = 列名 → string/number/null。布尔列在写入前由 RowMappers 转成 0/1，
 * JSON 列转成 TEXT，因此本层不需要 boolean/数组类型。
 *
 * 安全说明：拼进 SQL 的表名/列名/排序列全部来自 DatabaseSchema 的常量与本模块内部逻辑，
 * 绝不接收用户输入；运行时值一律经 ? 绑定参数传递。
 */

import { relationalStore } from '@kit.ArkData';
import { ColumnDef } from './DatabaseSchema';

/** 行值标量（本库只用 TEXT/INTEGER/REAL 三种存储类） */
export type RowValue = string | number | null;

/** 一行数据：列名 → 值 */
export type RowObject = Record<string, RowValue>;

/** DAO 依赖的最小存储操作集 */
export interface RdbGateway {
  /** 插入一行（row 必须含主键列 id） */
  insert(table: string, row: RowObject): void;

  /** 按主键 id 整行更新；id 不存在时与 SQLite 语义一致：不影响任何行、不报错 */
  updateById(table: string, id: string, row: RowObject): void;

  /** 按主键 id 删除；id 不存在时不报错 */
  deleteById(table: string, id: string): void;

  /** 按主键 id 查询；不存在返回 null */
  getById(table: string, id: string, columns: ColumnDef[]): RowObject | null;

  /**
   * 等值条件查询：filters 为空对象时返回全表；值为 null 的过滤条件翻译为 IS NULL。
   * orderBy 为单列名（空串 = 不排序，按存储序返回）。
   */
  queryWhere(table: string, filters: Record<string, RowValue>, orderBy: string, columns: ColumnDef[]): RowObject[];

  /** 执行 DDL / 迁移 SQL（CREATE TABLE / CREATE INDEX / PRAGMA 写入等） */
  executeSql(sql: string): void;

  /** 执行返回单个整数的查询（用于读 PRAGMA user_version）；无行或 NULL 时返回 0 */
  queryScalarInt(sql: string): number;
}

/** RowObject → relationalStore.ValuesBucket（逐字段拷贝，类型是 ValuesBucket 的子集） */
function toBucket(row: RowObject): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  const keys: string[] = Object.keys(row);
  for (let i = 0; i < keys.length; i++) {
    bucket[keys[i]] = row[keys[i]];
  }
  return bucket;
}

/** 生产实现：包装 relationalStore.RdbStore 的同步 API */
export class RdbStoreGateway implements RdbGateway {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  insert(table: string, row: RowObject): void {
    this.store.insertSync(table, toBucket(row));
  }

  updateById(table: string, id: string, row: RowObject): void {
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('id', id);
    this.store.updateSync(toBucket(row), predicates);
  }

  deleteById(table: string, id: string): void {
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('id', id);
    this.store.deleteSync(predicates);
  }

  getById(table: string, id: string, columns: ColumnDef[]): RowObject | null {
    const rows: RowObject[] = this.select(table, 'id = ?', [id], '', columns);
    return rows.length > 0 ? rows[0] : null;
  }

  queryWhere(table: string, filters: Record<string, RowValue>, orderBy: string, columns: ColumnDef[]): RowObject[] {
    const whereParts: string[] = [];
    const args: relationalStore.ValueType[] = [];
    const keys: string[] = Object.keys(filters);
    for (let i = 0; i < keys.length; i++) {
      const value: RowValue = filters[keys[i]];
      if (value === null) {
        whereParts.push(`${keys[i]} IS NULL`);
      } else {
        whereParts.push(`${keys[i]} = ?`);
        args.push(value);
      }
    }
    return this.select(table, whereParts.join(' AND '), args, orderBy, columns);
  }

  executeSql(sql: string): void {
    this.store.executeSync(sql);
  }

  queryScalarInt(sql: string): number {
    const resultSet: relationalStore.ResultSet = this.store.querySqlSync(sql, []);
    try {
      if (!resultSet.goToNextRow() || resultSet.isColumnNull(0)) {
        return 0;
      }
      return resultSet.getLong(0);
    } finally {
      resultSet.close();
    }
  }

  /** SELECT 公共路径：拼 SQL → querySqlSync → 按 ColumnDef 逐列取类型化值 */
  private select(table: string, where: string, args: relationalStore.ValueType[],
    orderBy: string, columns: ColumnDef[]): RowObject[] {
    const names: string[] = [];
    for (let i = 0; i < columns.length; i++) {
      names.push(columns[i].name);
    }
    let sql: string = `SELECT ${names.join(', ')} FROM ${table}`;
    if (where.length > 0) {
      sql += ` WHERE ${where}`;
    }
    if (orderBy.length > 0) {
      sql += ` ORDER BY ${orderBy}`;
    }
    const resultSet: relationalStore.ResultSet = this.store.querySqlSync(sql, args);
    const rows: RowObject[] = [];
    try {
      while (resultSet.goToNextRow()) {
        rows.push(RdbStoreGateway.readRow(resultSet, columns));
      }
    } finally {
      resultSet.close();
    }
    return rows;
  }

  /** 按列定义从 ResultSet 当前行取值；列缺失或 NULL 统一读为 null，由上层映射函数判定是否合法 */
  private static readRow(resultSet: relationalStore.ResultSet, columns: ColumnDef[]): RowObject {
    const row: RowObject = {};
    for (let i = 0; i < columns.length; i++) {
      const col: ColumnDef = columns[i];
      const index: number = resultSet.getColumnIndex(col.name);
      if (index < 0 || resultSet.isColumnNull(index)) {
        row[col.name] = null;
        continue;
      }
      if (col.type === 'INTEGER') {
        row[col.name] = resultSet.getLong(index);
      } else if (col.type === 'REAL') {
        row[col.name] = resultSet.getDouble(index);
      } else {
        row[col.name] = resultSet.getString(index);
      }
    }
    return row;
  }
}
