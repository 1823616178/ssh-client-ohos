/**
 * 数据库 schema 与版本迁移框架（DESIGN §5.1 / §5.2 / §6.3，任务 C1）。
 *
 * 六张表与 models.ets 实体一一对应（纯模块，不依赖 context / Kit，可纯测）：
 *   hosts        → HostProfile      （init_commands / env_vars 为 JSON TEXT 列）
 *   host_groups  → HostGroup        （表名 groups 与 SQLite 关键字 GROUPS 冲突，改用 host_groups；
 *                                    字段 order 同为 SQL 关键字，列名改用 order_index）
 *   appearance   → AppearanceProfile（palette 为 JSON TEXT 列；布尔列以 INTEGER 0/1 存储）
 *   snippets     → Snippet
 *   known_hosts  → KnownHostEntry   （added_at 为 ISO 时间串 TEXT；UNIQUE(host, port, key_type)）
 *   forwards     → PortForwardRule  （enabled 以 INTEGER 0/1 存储）
 *
 * 版本迁移：schemaVersion 从 1 起，当前版本以 PRAGMA user_version 持久化（0 = 全新库）。
 * MIGRATIONS 是按序迁移步骤表，每步 fromVersion -> toVersion 携带该步全部 SQL；
 * planMigration(from, to) 纯函数把两段版本间的 SQL 按序拼成执行计划，由 AppDatabase 执行。
 * 所有 DDL 带 IF NOT EXISTS：迁移中途失败时 user_version 不推进，下次启动重放是幂等的。
 *
 * 升级 schema 的流程：SCHEMA_VERSION +1，向 MIGRATIONS 末尾追加一步（fromVersion = 旧版本），
 * 并在本文件补充对应 DDL；单测会校验版本链完整且终点等于 SCHEMA_VERSION。
 *
 * TableDef.columns 同时承担两个职责：建表 SQL 的列清单镜像（单测校验两者一致）、
 * RdbGateway 读 ResultSet 时的逐列类型依据（TEXT/INTEGER/REAL 对应 getString/getLong/getDouble）。
 */

/** 列类型（本库只用 SQLite 三种标量存储类） */
export type ColumnType = 'TEXT' | 'INTEGER' | 'REAL';

/** 单列定义：名称、存储类型、是否可空 */
export interface ColumnDef {
  readonly name: string;
  readonly type: ColumnType;
  readonly nullable: boolean;
}

/** 单表定义：表名、建表 SQL、列清单 */
export interface TableDef {
  readonly name: string;
  readonly createSql: string;
  readonly columns: ColumnDef[];
}

/** 单步迁移：fromVersion -> toVersion 要执行的全部 SQL（按序） */
export interface MigrationStep {
  readonly fromVersion: number;
  readonly toVersion: number;
  readonly sqls: string[];
  readonly comment: string;
}

/** 当前 schema 版本（从 1 起；PRAGMA user_version 的 0 表示全新库） */
export const SCHEMA_VERSION: number = 3;

// ---------- hosts → HostProfile ----------

export const HOSTS_TABLE: TableDef = {
  name: 'hosts',
  createSql:
    'CREATE TABLE IF NOT EXISTS hosts (' +
    'id TEXT PRIMARY KEY, ' +
    'name TEXT NOT NULL, ' +
    'host TEXT NOT NULL, ' +
    'port INTEGER NOT NULL, ' +
    'username TEXT NOT NULL, ' +
    'auth_type TEXT NOT NULL, ' +
    'host_fingerprint TEXT NOT NULL, ' +
    'keepalive INTEGER NOT NULL, ' +
    'group_id TEXT REFERENCES host_groups(id), ' +
    'appearance_id TEXT REFERENCES appearance(id), ' +
    'jump_host_id TEXT REFERENCES hosts(id), ' +
    "init_commands TEXT NOT NULL DEFAULT '[]', " +
    "env_vars TEXT NOT NULL DEFAULT '{}', " +
    'term_type TEXT NOT NULL, ' +
    'tmux_auto_attach INTEGER NOT NULL DEFAULT 0, ' +
    "tmux_session_name TEXT NOT NULL DEFAULT ''" +
    ')',
  columns: [
    { name: 'id', type: 'TEXT', nullable: false },
    { name: 'name', type: 'TEXT', nullable: false },
    { name: 'host', type: 'TEXT', nullable: false },
    { name: 'port', type: 'INTEGER', nullable: false },
    { name: 'username', type: 'TEXT', nullable: false },
    { name: 'auth_type', type: 'TEXT', nullable: false },
    { name: 'host_fingerprint', type: 'TEXT', nullable: false },
    { name: 'keepalive', type: 'INTEGER', nullable: false },
    { name: 'group_id', type: 'TEXT', nullable: true },
    { name: 'appearance_id', type: 'TEXT', nullable: true },
    { name: 'jump_host_id', type: 'TEXT', nullable: true },
    { name: 'init_commands', type: 'TEXT', nullable: false },
    { name: 'env_vars', type: 'TEXT', nullable: false },
    { name: 'term_type', type: 'TEXT', nullable: false },
    { name: 'tmux_auto_attach', type: 'INTEGER', nullable: false },
    { name: 'tmux_session_name', type: 'TEXT', nullable: false }
  ]
};

/**
 * v1 时期的 hosts 建表 SQL（冻结快照）。
 *
 * 迁移步骤必须引用**当时**的 DDL 而不是 HOSTS_TABLE.createSql：后者会随 schema 演进，
 * 若 v0→v1 直接建出 v2 形态的表，紧接着的 v1→v2 `ALTER TABLE ADD COLUMN` 就会
 * 撞上 duplicate column 而失败（SQLite 的 ADD COLUMN 没有 IF NOT EXISTS 可用），
 * 全新安装反而起不来。
 */
const HOSTS_TABLE_SQL_V1: string =
  'CREATE TABLE IF NOT EXISTS hosts (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL, ' +
  'host TEXT NOT NULL, ' +
  'port INTEGER NOT NULL, ' +
  'username TEXT NOT NULL, ' +
  'auth_type TEXT NOT NULL, ' +
  'host_fingerprint TEXT NOT NULL, ' +
  'keepalive INTEGER NOT NULL, ' +
  'group_id TEXT REFERENCES host_groups(id), ' +
  'appearance_id TEXT REFERENCES appearance(id), ' +
  'jump_host_id TEXT REFERENCES hosts(id), ' +
  "init_commands TEXT NOT NULL DEFAULT '[]', " +
  "env_vars TEXT NOT NULL DEFAULT '{}', " +
  'term_type TEXT NOT NULL' +
  ')';

// ---------- host_groups → HostGroup ----------

export const HOST_GROUPS_TABLE: TableDef = {
  name: 'host_groups',
  createSql:
    'CREATE TABLE IF NOT EXISTS host_groups (' +
    'id TEXT PRIMARY KEY, ' +
    'name TEXT NOT NULL, ' +
    'order_index INTEGER NOT NULL' +
    ')',
  columns: [
    { name: 'id', type: 'TEXT', nullable: false },
    { name: 'name', type: 'TEXT', nullable: false },
    { name: 'order_index', type: 'INTEGER', nullable: false }
  ]
};

// ---------- appearance → AppearanceProfile ----------

/**
 * v2 时期的 appearance 建表 SQL（冻结快照，A5 之前）。
 * 迁移步骤必须引用冻结 SQL 而不是 APPEARANCE_TABLE.createSql（与 hosts 同理，
 * 见 HOSTS_TABLE_SQL_V1 头注：否则 v0→v1 建出 v3 形态后 v2→v3 ADD COLUMN 会撞 duplicate）。
 */
const APPEARANCE_TABLE_SQL_V2: string =
  'CREATE TABLE IF NOT EXISTS appearance (' +
  'id TEXT PRIMARY KEY, ' +
  'name TEXT NOT NULL, ' +
  'font_family TEXT NOT NULL, ' +
  'font_size INTEGER NOT NULL, ' +
  'line_height REAL NOT NULL, ' +
  'letter_spacing REAL NOT NULL, ' +
  'font_weight INTEGER NOT NULL, ' +
  'ligatures INTEGER NOT NULL DEFAULT 0, ' +
  'bold_as_bright INTEGER NOT NULL DEFAULT 1, ' +
  'cursor_style TEXT NOT NULL, ' +
  'cursor_blink INTEGER NOT NULL DEFAULT 1, ' +
  'background_opacity REAL NOT NULL DEFAULT 1, ' +
  'padding REAL NOT NULL DEFAULT 0, ' +
  "palette TEXT NOT NULL DEFAULT '[]', " +
  'foreground TEXT NOT NULL, ' +
  'background TEXT NOT NULL, ' +
  'cursor_color TEXT NOT NULL, ' +
  'selection_color TEXT NOT NULL' +
  ')';

/** 当前 appearance 表（v3：A5 背景图路径 / 不透明度 / 模糊） */
export const APPEARANCE_TABLE: TableDef = {
  name: 'appearance',
  createSql:
    'CREATE TABLE IF NOT EXISTS appearance (' +
    'id TEXT PRIMARY KEY, ' +
    'name TEXT NOT NULL, ' +
    'font_family TEXT NOT NULL, ' +
    'font_size INTEGER NOT NULL, ' +
    'line_height REAL NOT NULL, ' +
    'letter_spacing REAL NOT NULL, ' +
    'font_weight INTEGER NOT NULL, ' +
    'ligatures INTEGER NOT NULL DEFAULT 0, ' +
    'bold_as_bright INTEGER NOT NULL DEFAULT 1, ' +
    'cursor_style TEXT NOT NULL, ' +
    'cursor_blink INTEGER NOT NULL DEFAULT 1, ' +
    'background_opacity REAL NOT NULL DEFAULT 1, ' +
    'padding REAL NOT NULL DEFAULT 0, ' +
    "palette TEXT NOT NULL DEFAULT '[]', " +
    'foreground TEXT NOT NULL, ' +
    'background TEXT NOT NULL, ' +
    'cursor_color TEXT NOT NULL, ' +
    'selection_color TEXT NOT NULL, ' +
    "background_image_path TEXT NOT NULL DEFAULT '', " +
    'background_image_opacity REAL NOT NULL DEFAULT 1, ' +
    'background_blur REAL NOT NULL DEFAULT 0' +
    ')',
  columns: [
    { name: 'id', type: 'TEXT', nullable: false },
    { name: 'name', type: 'TEXT', nullable: false },
    { name: 'font_family', type: 'TEXT', nullable: false },
    { name: 'font_size', type: 'INTEGER', nullable: false },
    { name: 'line_height', type: 'REAL', nullable: false },
    { name: 'letter_spacing', type: 'REAL', nullable: false },
    { name: 'font_weight', type: 'INTEGER', nullable: false },
    { name: 'ligatures', type: 'INTEGER', nullable: false },
    { name: 'bold_as_bright', type: 'INTEGER', nullable: false },
    { name: 'cursor_style', type: 'TEXT', nullable: false },
    { name: 'cursor_blink', type: 'INTEGER', nullable: false },
    { name: 'background_opacity', type: 'REAL', nullable: false },
    { name: 'padding', type: 'REAL', nullable: false },
    { name: 'palette', type: 'TEXT', nullable: false },
    { name: 'foreground', type: 'TEXT', nullable: false },
    { name: 'background', type: 'TEXT', nullable: false },
    { name: 'cursor_color', type: 'TEXT', nullable: false },
    { name: 'selection_color', type: 'TEXT', nullable: false },
    { name: 'background_image_path', type: 'TEXT', nullable: false },
    { name: 'background_image_opacity', type: 'REAL', nullable: false },
    { name: 'background_blur', type: 'REAL', nullable: false }
  ]
};

// ---------- snippets → Snippet ----------

export const SNIPPETS_TABLE: TableDef = {
  name: 'snippets',
  createSql:
    'CREATE TABLE IF NOT EXISTS snippets (' +
    'id TEXT PRIMARY KEY, ' +
    'name TEXT NOT NULL, ' +
    'content TEXT NOT NULL, ' +
    'group_id TEXT REFERENCES host_groups(id)' +
    ')',
  columns: [
    { name: 'id', type: 'TEXT', nullable: false },
    { name: 'name', type: 'TEXT', nullable: false },
    { name: 'content', type: 'TEXT', nullable: false },
    { name: 'group_id', type: 'TEXT', nullable: true }
  ]
};

// ---------- known_hosts → KnownHostEntry ----------

export const KNOWN_HOSTS_TABLE: TableDef = {
  name: 'known_hosts',
  createSql:
    'CREATE TABLE IF NOT EXISTS known_hosts (' +
    'id TEXT PRIMARY KEY, ' +
    'host TEXT NOT NULL, ' +
    'port INTEGER NOT NULL, ' +
    'key_type TEXT NOT NULL, ' +
    'fingerprint TEXT NOT NULL, ' +
    'added_at TEXT NOT NULL, ' +
    'UNIQUE(host, port, key_type)' +
    ')',
  columns: [
    { name: 'id', type: 'TEXT', nullable: false },
    { name: 'host', type: 'TEXT', nullable: false },
    { name: 'port', type: 'INTEGER', nullable: false },
    { name: 'key_type', type: 'TEXT', nullable: false },
    { name: 'fingerprint', type: 'TEXT', nullable: false },
    { name: 'added_at', type: 'TEXT', nullable: false }
  ]
};

// ---------- forwards → PortForwardRule ----------

export const FORWARDS_TABLE: TableDef = {
  name: 'forwards',
  createSql:
    'CREATE TABLE IF NOT EXISTS forwards (' +
    'id TEXT PRIMARY KEY, ' +
    'host_id TEXT NOT NULL REFERENCES hosts(id), ' +
    'type TEXT NOT NULL, ' +
    'bind_address TEXT NOT NULL, ' +
    'local_port INTEGER NOT NULL, ' +
    'remote_host TEXT NOT NULL, ' +
    'remote_port INTEGER NOT NULL, ' +
    'enabled INTEGER NOT NULL DEFAULT 1' +
    ')',
  columns: [
    { name: 'id', type: 'TEXT', nullable: false },
    { name: 'host_id', type: 'TEXT', nullable: false },
    { name: 'type', type: 'TEXT', nullable: false },
    { name: 'bind_address', type: 'TEXT', nullable: false },
    { name: 'local_port', type: 'INTEGER', nullable: false },
    { name: 'remote_host', type: 'TEXT', nullable: false },
    { name: 'remote_port', type: 'INTEGER', nullable: false },
    { name: 'enabled', type: 'INTEGER', nullable: false }
  ]
};

/** 全部表定义（单测遍历校验「建表 SQL ↔ 列清单」一致性） */
export const ALL_TABLES: TableDef[] = [
  HOSTS_TABLE,
  HOST_GROUPS_TABLE,
  APPEARANCE_TABLE,
  SNIPPETS_TABLE,
  KNOWN_HOSTS_TABLE,
  FORWARDS_TABLE
];

/** 外键/常用过滤列索引（按 group_id、host_id 的列表查询走索引） */
const INDEX_SQLS: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_hosts_group_id ON hosts(group_id)',
  'CREATE INDEX IF NOT EXISTS idx_snippets_group_id ON snippets(group_id)',
  'CREATE INDEX IF NOT EXISTS idx_forwards_host_id ON forwards(host_id)'
];

/**
 * 迁移步骤表：v0 -> v1 为初始建表（先建被引用的 host_groups / appearance，再建 hosts，
 * 最后建依赖 hosts 的 forwards 与各索引）。未来版本在此末尾追加步骤。
 */
export const MIGRATIONS: MigrationStep[] = [
  {
    fromVersion: 0,
    toVersion: 1,
    sqls: [
      HOST_GROUPS_TABLE.createSql,
      APPEARANCE_TABLE_SQL_V2,
      HOSTS_TABLE_SQL_V1,
      SNIPPETS_TABLE.createSql,
      KNOWN_HOSTS_TABLE.createSql,
      FORWARDS_TABLE.createSql,
      INDEX_SQLS[0],
      INDEX_SQLS[1],
      INDEX_SQLS[2]
    ],
    comment: '初始建表：hosts / host_groups / appearance / snippets / known_hosts / forwards + 外键索引'
  },
  {
    fromVersion: 1,
    toVersion: 2,
    sqls: [
      'ALTER TABLE hosts ADD COLUMN tmux_auto_attach INTEGER NOT NULL DEFAULT 0',
      "ALTER TABLE hosts ADD COLUMN tmux_session_name TEXT NOT NULL DEFAULT ''"
    ],
    comment: 'hosts 增加 tmux 自动附着两列（本机专有，不参与同步）'
  },
  {
    fromVersion: 2,
    toVersion: 3,
    sqls: [
      "ALTER TABLE appearance ADD COLUMN background_image_path TEXT NOT NULL DEFAULT ''",
      'ALTER TABLE appearance ADD COLUMN background_image_opacity REAL NOT NULL DEFAULT 1',
      'ALTER TABLE appearance ADD COLUMN background_blur REAL NOT NULL DEFAULT 0'
    ],
    comment: 'A5：appearance 增加背景图路径 / 图不透明度 / 模糊半径（本机专有，不参与同步）'
  }
];

/** 在步骤表中找从 version 出发的一步；找不到返回 null */
function findStepFrom(steps: MigrationStep[], version: number): MigrationStep | null {
  for (let i = 0; i < steps.length; i++) {
    if (steps[i].fromVersion === version) {
      return steps[i];
    }
  }
  return null;
}

/**
 * 生成 fromVersion -> toVersion 的按序 SQL 迁移计划（纯函数）。
 * fromVersion === toVersion 时返回空计划；降级、负版本、目标版本超出已知范围、
 * 迁移链断裂（缺步/环/跨过目标版本）一律抛 Error——这些是配置错误，必须暴露而不是静默跳过。
 * steps 默认取 MIGRATIONS；单测可注入临时步骤表模拟未来的 vN 链路。
 */
export function planMigration(fromVersion: number, toVersion: number, steps: MigrationStep[] = MIGRATIONS): string[] {
  if (!Number.isInteger(fromVersion) || !Number.isInteger(toVersion) || fromVersion < 0 || toVersion < 0) {
    throw new Error(`非法的数据库版本号: ${fromVersion} -> ${toVersion}`);
  }
  if (fromVersion > toVersion) {
    throw new Error(`不支持数据库降级: v${fromVersion} -> v${toVersion}`);
  }
  if (fromVersion === toVersion) {
    return [];
  }
  let maxKnown: number = 0;
  for (let i = 0; i < steps.length; i++) {
    maxKnown = Math.max(maxKnown, steps[i].toVersion);
  }
  if (toVersion > maxKnown) {
    throw new Error(`目标版本 v${toVersion} 超出已知 schema 版本 v${maxKnown}，请先补迁移步骤`);
  }
  const plan: string[] = [];
  let current: number = fromVersion;
  // 步骤数 +1 作为循环上限：正常每步推进一个版本，超出即步骤表存在环
  let guard: number = steps.length + 1;
  while (current < toVersion) {
    const step: MigrationStep | null = findStepFrom(steps, current);
    if (step === null) {
      throw new Error(`迁移链断裂：找不到从 v${current} 出发的迁移步骤`);
    }
    for (let i = 0; i < step.sqls.length; i++) {
      plan.push(step.sqls[i]);
    }
    current = step.toVersion;
    guard--;
    if (guard <= 0) {
      throw new Error('迁移步骤表存在环，已中止');
    }
  }
  if (current !== toVersion) {
    throw new Error(`迁移链越过了目标版本 v${toVersion}（到达 v${current}），步骤配置有误`);
  }
  return plan;
}
