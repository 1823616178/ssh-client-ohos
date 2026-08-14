/**
 * 应用数据库入口（DESIGN §5.1 / §5.2，任务 C1）。
 *
 * 持有 relationalStore 库句柄与六个 DAO 的单例。风格对齐 SettingsRepository：
 * 静态类、init(context) 幂等、失败只记日志不抛给调用方（isReady() 可探查状态）。
 *
 * init 流程：打开/创建 ssh_client.db → 读 PRAGMA user_version → planMigration 生成
 * 迁移计划 → 按序 executeSql → 推进 user_version → 构造六个 DAO。
 * 迁移失败时 user_version 未推进，下次 init 重放整条链；全部 DDL 带 IF NOT EXISTS，
 * 重放幂等。注意：迁移未包事务（relationalStore 同步 API 无显式事务入口），
 * 多步迁移中途失败可能留下中间状态，未来新增步骤时应保持单步小、可重入。
 *
 * 使用方式：EntryAbility.onCreate 中（Logger.init 之后）调用
 *   AppDatabase.init(this.context);
 * 之后各处直接 AppDatabase.hosts() / groups() / … 取 DAO。
 * 未初始化或初始化失败时访问器抛 SshError(INTERNAL_ERROR)（见 Daos.ets 错误策略）。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/utils/Logger';
import { SshError, SshErrorCode } from '../common/SshError';
import { planMigration, SCHEMA_VERSION } from './DatabaseSchema';
import { RdbGateway, RdbStoreGateway } from './RdbGateway';
import { AppearanceDao, ForwardDao, GroupDao, HostDao, KnownHostDao, SnippetDao } from './Daos';

/** 数据库文件名（位于应用沙箱 database 目录） */
const DB_NAME: string = 'ssh_client.db';
const LOG_TAG: string = 'Database';

export class AppDatabase {
  /** 生产网关；null 表示未初始化或初始化失败 */
  private static gateway: RdbGateway | null = null;
  private static hostDao: HostDao | null = null;
  private static groupDao: GroupDao | null = null;
  private static appearanceDao: AppearanceDao | null = null;
  private static snippetDao: SnippetDao | null = null;
  private static knownHostDao: KnownHostDao | null = null;
  private static forwardDao: ForwardDao | null = null;

  /** 打开/创建数据库并执行迁移，构造 DAO；重复调用幂等。失败只记日志，不抛给调用方 */
  static init(context: common.Context): void {
    if (AppDatabase.gateway !== null) {
      return;
    }
    try {
      const store: relationalStore.RdbStore = relationalStore.getRdbStoreSync(context, {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      });
      const gateway: RdbGateway = new RdbStoreGateway(store);
      AppDatabase.migrate(gateway);
      AppDatabase.gateway = gateway;
      AppDatabase.hostDao = new HostDao(gateway);
      AppDatabase.groupDao = new GroupDao(gateway);
      AppDatabase.appearanceDao = new AppearanceDao(gateway);
      AppDatabase.snippetDao = new SnippetDao(gateway);
      AppDatabase.knownHostDao = new KnownHostDao(gateway);
      AppDatabase.forwardDao = new ForwardDao(gateway);
      Logger.info(`数据库就绪（schema v${SCHEMA_VERSION}）`, LOG_TAG);
    } catch (err) {
      AppDatabase.reset();
      Logger.error(`数据库初始化失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 数据库是否可用（init 成功） */
  static isReady(): boolean {
    return AppDatabase.gateway !== null;
  }

  static hosts(): HostDao {
    return AppDatabase.requireDao(AppDatabase.hostDao);
  }

  static groups(): GroupDao {
    return AppDatabase.requireDao(AppDatabase.groupDao);
  }

  static appearances(): AppearanceDao {
    return AppDatabase.requireDao(AppDatabase.appearanceDao);
  }

  static snippets(): SnippetDao {
    return AppDatabase.requireDao(AppDatabase.snippetDao);
  }

  static knownHosts(): KnownHostDao {
    return AppDatabase.requireDao(AppDatabase.knownHostDao);
  }

  static forwards(): ForwardDao {
    return AppDatabase.requireDao(AppDatabase.forwardDao);
  }

  /** 按 user_version 生成并执行迁移计划，最后推进版本号 */
  private static migrate(gateway: RdbGateway): void {
    const fromVersion: number = gateway.queryScalarInt('PRAGMA user_version');
    if (fromVersion === SCHEMA_VERSION) {
      return;
    }
    const sqls: string[] = planMigration(fromVersion, SCHEMA_VERSION);
    for (let i = 0; i < sqls.length; i++) {
      gateway.executeSql(sqls[i]);
    }
    gateway.executeSql(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    Logger.info(`数据库迁移完成：v${fromVersion} -> v${SCHEMA_VERSION}（${sqls.length} 条 SQL）`, LOG_TAG);
  }

  private static requireDao<T>(dao: T | null): T {
    if (dao === null) {
      Logger.error('数据库未初始化（AppDatabase.init 未调用或曾失败）', LOG_TAG);
      throw new SshError(SshErrorCode.INTERNAL_ERROR, '数据库未初始化');
    }
    return dao;
  }

  /** init 失败时清空全部引用，保持「未初始化」语义一致 */
  private static reset(): void {
    AppDatabase.gateway = null;
    AppDatabase.hostDao = null;
    AppDatabase.groupDao = null;
    AppDatabase.appearanceDao = null;
    AppDatabase.snippetDao = null;
    AppDatabase.knownHostDao = null;
    AppDatabase.forwardDao = null;
  }
}
