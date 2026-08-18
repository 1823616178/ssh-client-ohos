/**
 * 三方合并（任务 S5）：base / local / remote。
 *
 * 实体按 id 对齐。两侧都改且不同 → 冲突（field / add-add / delete-modify）。
 * 敏感实体（带 secrets 的主机）conflict.sensitive = true，UI 不展示值。
 */

import { JSON } from '@kit.ArkTS';
import { Identified, SyncDocument, emptySyncDocument, SyncServerRecord } from './SyncSerializer';

export type ConflictKind = 'field' | 'add-add' | 'delete-modify';
/** 与 SyncDocumentV1 的三个实体数组对应（本机专有数据不进同步文档，故不参与合并） */
export type EntityKind = 'server' | 'tunnel' | 'group' | 'preferences';

export interface SyncConflict {
  entity: EntityKind;
  id: string;
  kind: ConflictKind;
  sensitive: boolean;
}

export interface MergeResult {
  document: SyncDocument;
  conflicts: SyncConflict[];
}

function jsonOf(value: Object): string {
  return JSON.stringify(value);
}

function indexById<T extends Identified>(items: T[]): Map<string, T> {
  const map: Map<string, T> = new Map();
  for (const item of items) {
    map.set(item.id, item);
  }
  return map;
}

function allIds<T extends Identified>(a: T[], b: T[], c: T[]): string[] {
  const set: Map<string, boolean> = new Map();
  for (const item of a) {
    set.set(item.id, true);
  }
  for (const item of b) {
    set.set(item.id, true);
  }
  for (const item of c) {
    set.set(item.id, true);
  }
  const ids: string[] = [];
  set.forEach((_v: boolean, id: string) => {
    ids.push(id);
  });
  ids.sort();
  return ids;
}

function mergeList<T extends Identified>(base: T[], local: T[], remote: T[],
  entity: EntityKind, conflicts: SyncConflict[], sensitiveId: (item: T) => boolean): T[] {
  const bMap: Map<string, T> = indexById(base);
  const lMap: Map<string, T> = indexById(local);
  const rMap: Map<string, T> = indexById(remote);
  const out: T[] = [];
  const ids: string[] = allIds(base, local, remote);
  for (const id of ids) {
    const b: T | undefined = bMap.get(id);
    const l: T | undefined = lMap.get(id);
    const r: T | undefined = rMap.get(id);
    if (l !== undefined && r !== undefined) {
      if (jsonOf(l) === jsonOf(r)) {
        out.push(l);
        continue;
      }
      if (b !== undefined && jsonOf(l) === jsonOf(b)) {
        out.push(r);
        continue;
      }
      if (b !== undefined && jsonOf(r) === jsonOf(b)) {
        out.push(l);
        continue;
      }
      const kind: ConflictKind = b === undefined ? 'add-add' : 'field';
      conflicts.push({
        entity: entity,
        id: id,
        kind: kind,
        sensitive: sensitiveId(l) || sensitiveId(r)
      });
      out.push(l);
      continue;
    }
    if (l !== undefined && r === undefined) {
      if (b === undefined) {
        out.push(l);
      } else if (jsonOf(l) === jsonOf(b)) {
        // remote deleted unchanged local
      } else {
        conflicts.push({
          entity: entity,
          id: id,
          kind: 'delete-modify',
          sensitive: sensitiveId(l)
        });
        out.push(l);
      }
      continue;
    }
    if (r !== undefined && l === undefined) {
      if (b === undefined) {
        out.push(r);
      } else if (jsonOf(r) === jsonOf(b)) {
        // local deleted unchanged remote
      } else {
        conflicts.push({
          entity: entity,
          id: id,
          kind: 'delete-modify',
          sensitive: sensitiveId(r)
        });
        out.push(r);
      }
    }
  }
  return out;
}

function serverSensitive(item: SyncServerRecord): boolean {
  return item.secrets !== undefined;
}

export function mergeDocuments(base: SyncDocument, local: SyncDocument,
  remote: SyncDocument): MergeResult {
  const conflicts: SyncConflict[] = [];
  const doc: SyncDocument = emptySyncDocument();
  doc.schemaVersion = Math.max(local.schemaVersion, remote.schemaVersion);
  doc.updatedAt = local.updatedAt >= remote.updatedAt ? local.updatedAt : remote.updatedAt;
  const lp = local.preferences;
  const rp = remote.preferences;
  const bp = base.preferences;
  if (lp.syncPasswords === rp.syncPasswords && lp.syncPrivateKeys === rp.syncPrivateKeys) {
    doc.preferences = { syncPasswords: lp.syncPasswords, syncPrivateKeys: lp.syncPrivateKeys };
  } else if (lp.syncPasswords === bp.syncPasswords && lp.syncPrivateKeys === bp.syncPrivateKeys) {
    doc.preferences = { syncPasswords: rp.syncPasswords, syncPrivateKeys: rp.syncPrivateKeys };
  } else if (rp.syncPasswords === bp.syncPasswords && rp.syncPrivateKeys === bp.syncPrivateKeys) {
    doc.preferences = { syncPasswords: lp.syncPasswords, syncPrivateKeys: lp.syncPrivateKeys };
  } else {
    conflicts.push({ entity: 'preferences', id: 'preferences', kind: 'field', sensitive: true });
    doc.preferences = { syncPasswords: lp.syncPasswords, syncPrivateKeys: lp.syncPrivateKeys };
  }
  doc.servers =
    mergeList(base.servers, local.servers, remote.servers, 'server', conflicts, serverSensitive);
  doc.tunnels =
    mergeList(base.tunnels, local.tunnels, remote.tunnels, 'tunnel', conflicts, () => false);
  doc.groups = mergeList(base.groups, local.groups, remote.groups, 'group', conflicts, () => false);
  return { document: doc, conflicts: conflicts };
}

/** 解决冲突：keepLocal 保留本机实体，否则用云端实体覆盖该 id */
export function applyConflictChoice(merged: SyncDocument, local: SyncDocument, remote: SyncDocument,
  conflict: SyncConflict, keepLocal: boolean): SyncDocument {
  const src: SyncDocument = keepLocal ? local : remote;
  if (conflict.entity === 'preferences') {
    merged.preferences = {
      syncPasswords: src.preferences.syncPasswords,
      syncPrivateKeys: src.preferences.syncPrivateKeys
    };
    return merged;
  }
  replaceEntity(merged, src, conflict);
  return merged;
}

function replaceEntity(target: SyncDocument, src: SyncDocument, conflict: SyncConflict): void {
  if (conflict.entity === 'server') {
    target.servers = swap(target.servers, src.servers, conflict.id);
  } else if (conflict.entity === 'tunnel') {
    target.tunnels = swap(target.tunnels, src.tunnels, conflict.id);
  } else if (conflict.entity === 'group') {
    target.groups = swap(target.groups, src.groups, conflict.id);
  }
}

function swap<T extends Identified>(current: T[], src: T[], id: string): T[] {
  const fromSrc: T | undefined = indexById(src).get(id);
  const out: T[] = [];
  let replaced: boolean = false;
  for (const item of current) {
    if (item.id === id) {
      if (fromSrc !== undefined) {
        out.push(fromSrc);
      }
      replaced = true;
    } else {
      out.push(item);
    }
  }
  if (!replaced && fromSrc !== undefined) {
    out.push(fromSrc);
  }
  return out;
}
