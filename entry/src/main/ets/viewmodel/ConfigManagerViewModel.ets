/**
 * ConfigManagerViewModel —— 配置管理页视图模型。
 *
 * 统一聚合展示与管理本地数据库中的全部配置实体：
 *   - 主机 (HostProfile)
 *   - 主机分组 (HostGroup)
 *   - 端口转发 (PortForwardRule)
 *   - 外观主题 (AppearanceProfile)
 *   - 命令片段 (Snippet)
 *   - Known Hosts (KnownHostEntry)
 */

import { util } from '@kit.ArkTS';
import {
  AppearanceProfile,
  HostGroup,
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  Snippet,
  createDefaultHostGroup,
  createDefaultSnippet
} from '../common/model/models';
import { AppDatabase } from '../repository/AppDatabase';
import { CredentialStore } from '../repository/CredentialStore';
import { Logger } from '../common/utils/Logger';
import { notifyConfigSaved } from '../service/sync/SyncHooks';

const LOG_TAG: string = 'ConfigManagerVM';

export type ConfigTabType = 'hosts' | 'groups' | 'forwards' | 'themes' | 'snippets' | 'knownHosts';

@ObservedV2
export class ConfigManagerViewModel {
  @Trace currentTab: ConfigTabType = 'hosts';
  @Trace hosts: HostProfile[] = [];
  @Trace groups: HostGroup[] = [];
  @Trace forwards: PortForwardRule[] = [];
  @Trace appearances: AppearanceProfile[] = [];
  @Trace snippets: Snippet[] = [];
  @Trace knownHosts: KnownHostEntry[] = [];
  @Trace searchText: string = '';
  @Trace groupNameMap: Record<string, string> = {};
  @Trace hostNameMap: Record<string, string> = {};

  constructor() {
    this.reload();
  }

  reload(): void {
    if (!AppDatabase.isReady()) {
      Logger.warn('AppDatabase 未就绪，跳过读取', LOG_TAG);
      return;
    }
    try {
      this.hosts = AppDatabase.hosts().listAll();
      this.groups = AppDatabase.groups().listAll();
      this.forwards = AppDatabase.forwards().listAll();
      this.appearances = AppDatabase.appearances().listAll();
      this.snippets = AppDatabase.snippets().listAll();
      this.knownHosts = AppDatabase.knownHosts().listAll();

      const gMap: Record<string, string> = {};
      for (const g of this.groups) {
        gMap[g.id] = g.name;
      }
      this.groupNameMap = gMap;

      const hMap: Record<string, string> = {};
      for (const h of this.hosts) {
        hMap[h.id] = h.name.length > 0 ? h.name : `${h.username}@${h.host}:${h.port}`;
      }
      this.hostNameMap = hMap;
    } catch (err) {
      Logger.error(`读取配置数据失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  setTab(tab: ConfigTabType): void {
    this.currentTab = tab;
  }

  setSearchText(text: string): void {
    this.searchText = text;
  }

  filteredHosts(): HostProfile[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.hosts;
    }
    return this.hosts.filter((h: HostProfile) => {
      const gName: string = (h.groupId !== null && this.groupNameMap[h.groupId] !== undefined)
        ? this.groupNameMap[h.groupId] : '';
      return h.name.toLowerCase().includes(q) ||
        h.host.toLowerCase().includes(q) ||
        h.username.toLowerCase().includes(q) ||
        `${h.port}`.includes(q) ||
        gName.toLowerCase().includes(q);
    });
  }

  filteredGroups(): HostGroup[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.groups;
    }
    return this.groups.filter((g: HostGroup) => g.name.toLowerCase().includes(q));
  }

  filteredForwards(): PortForwardRule[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.forwards;
    }
    return this.forwards.filter((f: PortForwardRule) => {
      const hName: string = this.hostNameMap[f.hostId] ?? '';
      return f.type.toLowerCase().includes(q) ||
        f.bindAddress.toLowerCase().includes(q) ||
        `${f.localPort}`.includes(q) ||
        f.remoteHost.toLowerCase().includes(q) ||
        `${f.remotePort}`.includes(q) ||
        hName.toLowerCase().includes(q);
    });
  }

  filteredAppearances(): AppearanceProfile[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.appearances;
    }
    return this.appearances.filter((a: AppearanceProfile) => {
      return a.name.toLowerCase().includes(q) ||
        a.fontFamily.toLowerCase().includes(q) ||
        a.cursorStyle.toLowerCase().includes(q);
    });
  }

  filteredSnippets(): Snippet[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.snippets;
    }
    return this.snippets.filter((s: Snippet) => {
      return s.name.toLowerCase().includes(q) || s.content.toLowerCase().includes(q);
    });
  }

  filteredKnownHosts(): KnownHostEntry[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.knownHosts;
    }
    return this.knownHosts.filter((k: KnownHostEntry) => {
      return k.host.toLowerCase().includes(q) ||
        `${k.port}`.includes(q) ||
        k.keyType.toLowerCase().includes(q) ||
        k.fingerprint.toLowerCase().includes(q);
    });
  }

  // ---------------------------------------------------------------- 主机管理

  deleteHost(id: string): boolean {
    try {
      AppDatabase.hosts().deleteById(id);
      void CredentialStore.removeAllSecrets(id).catch((err: Object) => {
        Logger.warn(`删除主机级联清理凭据失败: ${JSON.stringify(err)}`, LOG_TAG);
      });
      notifyConfigSaved();
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`删除主机失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  // ---------------------------------------------------------------- 分组管理

  createGroup(name: string): boolean {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return false;
    }
    try {
      const g: HostGroup = createDefaultHostGroup(util.generateRandomUUID());
      g.name = trimmed;
      g.order = this.groups.length;
      AppDatabase.groups().insert(g);
      notifyConfigSaved();
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`创建分组失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  deleteGroup(id: string): boolean {
    try {
      // 解除组内主机的 groupId 关联
      for (const h of this.hosts) {
        if (h.groupId === id) {
          h.groupId = null;
          AppDatabase.hosts().update(h);
        }
      }
      AppDatabase.groups().deleteById(id);
      notifyConfigSaved();
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`删除分组失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  getGroupHostCount(groupId: string): number {
    let count = 0;
    for (const h of this.hosts) {
      if (h.groupId === groupId) {
        count++;
      }
    }
    return count;
  }

  // ---------------------------------------------------------------- 端口转发管理

  deleteForward(id: string): boolean {
    try {
      AppDatabase.forwards().deleteById(id);
      notifyConfigSaved();
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`删除端口转发规则失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  toggleForward(id: string, enabled: boolean): boolean {
    try {
      const f = AppDatabase.forwards().getById(id);
      if (f !== null) {
        f.enabled = enabled;
        AppDatabase.forwards().update(f);
        notifyConfigSaved();
        this.reload();
        return true;
      }
      return false;
    } catch (err) {
      Logger.error(`切换端口转发状态失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  // ---------------------------------------------------------------- 外观管理

  deleteAppearance(id: string): boolean {
    try {
      // 解除主机引用
      for (const h of this.hosts) {
        if (h.appearanceId === id) {
          h.appearanceId = null;
          AppDatabase.hosts().update(h);
        }
      }
      AppDatabase.appearances().deleteById(id);
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`删除外观主题失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  // ---------------------------------------------------------------- 片段管理

  createSnippet(name: string, content: string): boolean {
    const trimmedName: string = name.trim();
    if (trimmedName.length === 0 || content.length === 0) {
      return false;
    }
    try {
      const s: Snippet = createDefaultSnippet(util.generateRandomUUID());
      s.name = trimmedName;
      s.content = content;
      AppDatabase.snippets().insert(s);
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`创建命令片段失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  deleteSnippet(id: string): boolean {
    try {
      AppDatabase.snippets().deleteById(id);
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`删除命令片段失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }

  // ---------------------------------------------------------------- Known Hosts

  deleteKnownHost(id: string): boolean {
    try {
      AppDatabase.knownHosts().deleteById(id);
      this.reload();
      return true;
    } catch (err) {
      Logger.error(`删除已知主机指纹失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    }
  }
}
