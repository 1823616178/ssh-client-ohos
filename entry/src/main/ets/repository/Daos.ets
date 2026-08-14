/**
 * 六个实体的 DAO（任务 C1）：HostDao / GroupDao / AppearanceDao / SnippetDao / KnownHostDao / ForwardDao。
 *
 * DAO 只依赖 RdbGateway 窄接口（见 RdbGateway.ets），不触碰 relationalStore：
 * 生产环境由 AppDatabase 注入包装 RdbStore 的 RdbStoreGateway，单测注入内存 fake，
 * 因此本文件全部逻辑可在无 context 的单元测试中覆盖。
 *
 * 每个 DAO 提供 CRUD 五件套（insert / update / deleteById / getById / listAll），
 * 另加业务查询：hosts / snippets 按 groupId 列表，forwards 按 hostId 列表，
 * known_hosts 按 (host, port, keyType) 精确查（TOFU 核对入口）。
 *
 * 错误处理策略（与 SettingsRepository「记日志不崩溃」不同，写库失败必须让调用方知晓）：
 *   - 查询无结果 → 返回 null / 空数组，这是正常语义，不算错误；
 *   - 底层网关或行映射抛出的任何异常 → Logger.error 记录后统一包装为
 *     SshError(SshErrorCode.INTERNAL_ERROR) 抛给调用方（存储故障归 5xx 内部错误段，
 *     SSH 业务码不适用于本地存储）；
 *   - 调用方只允许依赖「null = 不存在」「抛 SshError = 操作失败」两种结果。
 *
 * update 语义为按实体 id 整行覆盖；id 不存在时不报错（与 SQLite UPDATE 语义一致）。
 */

import { SshError, SshErrorCode } from '../common/SshError';
import { Logger } from '../common/utils/Logger';
import {
  AppearanceProfile,
  HostGroup,
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  Snippet
} from '../common/model/models';
import {
  APPEARANCE_TABLE,
  FORWARDS_TABLE,
  HOSTS_TABLE,
  HOST_GROUPS_TABLE,
  KNOWN_HOSTS_TABLE,
  SNIPPETS_TABLE,
  TableDef
} from './DatabaseSchema';
import { RdbGateway, RowObject, RowValue } from './RdbGateway';
import {
  appearanceToRow,
  forwardToRow,
  hostGroupToRow,
  hostToRow,
  knownHostToRow,
  rowToAppearance,
  rowToForward,
  rowToHost,
  rowToHostGroup,
  rowToKnownHost,
  rowToSnippet,
  snippetToRow
} from './RowMappers';

const LOG_TAG: string = 'Database';

/** DAO 基类：持有网关 + 统一错误包装 + 行映射循环 */
abstract class BaseDao {
  protected readonly gateway: RdbGateway;
  private readonly daoName: string;
  private readonly table: TableDef;

  constructor(gateway: RdbGateway, daoName: string, table: TableDef) {
    this.gateway = gateway;
    this.daoName = daoName;
    this.table = table;
  }

  /** 统一执行入口：异常记日志后包装为 SshError(INTERNAL_ERROR) */
  protected run<T>(op: string, action: () => T): T {
    try {
      return action();
    } catch (err) {
      Logger.error(`${this.daoName} ${op} 失败: ${JSON.stringify(err)}`, LOG_TAG);
      throw new SshError(SshErrorCode.INTERNAL_ERROR, `数据库操作失败：${this.daoName} ${op}`);
    }
  }

  protected insertRow(op: string, row: RowObject): void {
    this.run(op, () => {
      this.gateway.insert(this.table.name, row);
    });
  }

  protected updateRow(op: string, id: string, row: RowObject): void {
    this.run(op, () => {
      this.gateway.updateById(this.table.name, id, row);
    });
  }

  /** 按主键 id 删除 */
  deleteById(id: string): void {
    this.run('deleteById', () => {
      this.gateway.deleteById(this.table.name, id);
    });
  }

  /** 按主键 id 查询并映射；不存在返回 null */
  protected getRowById<T>(id: string, mapRow: (row: RowObject) => T): T | null {
    return this.run('getById', () => {
      const row: RowObject | null = this.gateway.getById(this.table.name, id, this.table.columns);
      return row === null ? null : mapRow(row);
    });
  }

  /** 条件查询并逐行映射 */
  protected queryRows<T>(op: string, filters: Record<string, RowValue>, orderBy: string,
    mapRow: (row: RowObject) => T): T[] {
    return this.run(op, () => {
      const rows: RowObject[] = this.gateway.queryWhere(this.table.name, filters, orderBy, this.table.columns);
      const result: T[] = [];
      for (let i = 0; i < rows.length; i++) {
        result.push(mapRow(rows[i]));
      }
      return result;
    });
  }
}

/** 主机配置 DAO（hosts 表） */
export class HostDao extends BaseDao {
  constructor(gateway: RdbGateway) {
    super(gateway, 'HostDao', HOSTS_TABLE);
  }

  insert(host: HostProfile): void {
    this.insertRow('insert', hostToRow(host));
  }

  update(host: HostProfile): void {
    this.updateRow('update', host.id, hostToRow(host));
  }

  getById(id: string): HostProfile | null {
    return this.getRowById(id, rowToHost);
  }

  /** 全量列表，按名称排序 */
  listAll(): HostProfile[] {
    return this.queryRows('listAll', {}, 'name', rowToHost);
  }

  /** 按分组过滤，按名称排序 */
  listByGroupId(groupId: string): HostProfile[] {
    const filters: Record<string, RowValue> = {};
    filters['group_id'] = groupId;
    return this.queryRows('listByGroupId', filters, 'name', rowToHost);
  }
}

/** 主机分组 DAO（host_groups 表） */
export class GroupDao extends BaseDao {
  constructor(gateway: RdbGateway) {
    super(gateway, 'GroupDao', HOST_GROUPS_TABLE);
  }

  insert(group: HostGroup): void {
    this.insertRow('insert', hostGroupToRow(group));
  }

  update(group: HostGroup): void {
    this.updateRow('update', group.id, hostGroupToRow(group));
  }

  getById(id: string): HostGroup | null {
    return this.getRowById(id, rowToHostGroup);
  }

  /** 全量列表，按排序序号升序 */
  listAll(): HostGroup[] {
    return this.queryRows('listAll', {}, 'order_index', rowToHostGroup);
  }
}

/** 外观主题 DAO（appearance 表） */
export class AppearanceDao extends BaseDao {
  constructor(gateway: RdbGateway) {
    super(gateway, 'AppearanceDao', APPEARANCE_TABLE);
  }

  insert(appearance: AppearanceProfile): void {
    this.insertRow('insert', appearanceToRow(appearance));
  }

  update(appearance: AppearanceProfile): void {
    this.updateRow('update', appearance.id, appearanceToRow(appearance));
  }

  getById(id: string): AppearanceProfile | null {
    return this.getRowById(id, rowToAppearance);
  }

  /** 全量列表，按名称排序 */
  listAll(): AppearanceProfile[] {
    return this.queryRows('listAll', {}, 'name', rowToAppearance);
  }
}

/** 命令片段 DAO（snippets 表） */
export class SnippetDao extends BaseDao {
  constructor(gateway: RdbGateway) {
    super(gateway, 'SnippetDao', SNIPPETS_TABLE);
  }

  insert(snippet: Snippet): void {
    this.insertRow('insert', snippetToRow(snippet));
  }

  update(snippet: Snippet): void {
    this.updateRow('update', snippet.id, snippetToRow(snippet));
  }

  getById(id: string): Snippet | null {
    return this.getRowById(id, rowToSnippet);
  }

  /** 全量列表，按名称排序 */
  listAll(): Snippet[] {
    return this.queryRows('listAll', {}, 'name', rowToSnippet);
  }

  /** 按分组过滤，按名称排序 */
  listByGroupId(groupId: string): Snippet[] {
    const filters: Record<string, RowValue> = {};
    filters['group_id'] = groupId;
    return this.queryRows('listByGroupId', filters, 'name', rowToSnippet);
  }
}

/** known_hosts DAO（known_hosts 表） */
export class KnownHostDao extends BaseDao {
  constructor(gateway: RdbGateway) {
    super(gateway, 'KnownHostDao', KNOWN_HOSTS_TABLE);
  }

  insert(entry: KnownHostEntry): void {
    this.insertRow('insert', knownHostToRow(entry));
  }

  update(entry: KnownHostEntry): void {
    this.updateRow('update', entry.id, knownHostToRow(entry));
  }

  getById(id: string): KnownHostEntry | null {
    return this.getRowById(id, rowToKnownHost);
  }

  /** 全量列表，按主机地址排序 */
  listAll(): KnownHostEntry[] {
    return this.queryRows('listAll', {}, 'host', rowToKnownHost);
  }

  /** TOFU 核对入口：按 (host, port, keyType) 精确查（三列有 UNIQUE 约束），无记录返回 null */
  getByHostPortKey(host: string, port: number, keyType: string): KnownHostEntry | null {
    const filters: Record<string, RowValue> = {};
    filters['host'] = host;
    filters['port'] = port;
    filters['key_type'] = keyType;
    const matches: KnownHostEntry[] = this.queryRows('getByHostPortKey', filters, '', rowToKnownHost);
    return matches.length > 0 ? matches[0] : null;
  }
}

/** 端口转发规则 DAO（forwards 表） */
export class ForwardDao extends BaseDao {
  constructor(gateway: RdbGateway) {
    super(gateway, 'ForwardDao', FORWARDS_TABLE);
  }

  insert(rule: PortForwardRule): void {
    this.insertRow('insert', forwardToRow(rule));
  }

  update(rule: PortForwardRule): void {
    this.updateRow('update', rule.id, forwardToRow(rule));
  }

  getById(id: string): PortForwardRule | null {
    return this.getRowById(id, rowToForward);
  }

  /** 全量列表（存储序） */
  listAll(): PortForwardRule[] {
    return this.queryRows('listAll', {}, '', rowToForward);
  }

  /** 按所属主机过滤（存储序） */
  listByHostId(hostId: string): PortForwardRule[] {
    const filters: Record<string, RowValue> = {};
    filters['host_id'] = hostId;
    return this.queryRows('listByHostId', filters, '', rowToForward);
  }
}
