/**
 * 同步层单测（S3–S7）：错误码分支、401 refresh、设备复用、稳定序列化、三方合并、协调器 409。
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseApiError } from '../main/ets/service/sync/ApiClient';
import { ApiClient } from '../main/ets/service/sync/ApiClient';
import { ApiError, EncryptedDocument, HttpRequest, HttpResponse, TokenProvider, VaultEnvelope } from
  '../main/ets/service/sync/ApiTypes';
import { AuthSession } from '../main/ets/service/sync/AuthSession';
import { MemoryAuthStore, envelopeIntegrityError, kdfParamsCompatible } from
  '../main/ets/viewmodel/AccountSyncViewModel';
import {
  canonicalizeDocument,
  emptySyncDocument,
  serializeDocument,
  parseDocumentJson,
  validateDocumentLimits,
  applySensitiveFlags,
  SyncDocument,
  SyncServerRecord
} from '../main/ets/service/sync/SyncSerializer';
import { mergeDocuments } from '../main/ets/service/sync/SyncMerge';
import { MemoryDocumentStore } from '../main/ets/viewmodel/AccountSyncViewModel';
import { PlainCrypto, RotateOutcome, SyncCoordinator, SyncCrypto } from
  '../main/ets/service/sync/SyncCoordinator';
import { SyncTriggers } from '../main/ets/service/sync/SyncTriggers';
import { HOST_COUNT_MAX } from '../main/ets/common/sync/SyncProtocol';

/** 保险库未解锁的测试替身：encrypt/decrypt/rotate 不应被调用到 */
class LockedCrypto implements SyncCrypto {
  isReady(): boolean {
    return false;
  }

  encrypt(_plain: string): EncryptedDocument {
    throw new Error('保险库未解锁');
  }

  decrypt(_doc: EncryptedDocument): string {
    throw new Error('保险库未解锁');
  }

  rotate(_password: string): RotateOutcome | null {
    return null;
  }
}

class MemTokens implements TokenProvider {
  access: string = 'a1';
  refresh: string = 'r1';

  getAccessToken(): string {
    return this.access;
  }

  getRefreshToken(): string {
    return this.refresh;
  }

  setTokens(access: string, refresh: string): void {
    this.access = access;
    this.refresh = refresh;
  }

  clearTokens(): void {
    this.access = '';
    this.refresh = '';
  }
}

class ScriptedHttp {
  readonly reqs: HttpRequest[] = [];
  readonly queue: HttpResponse[] = [];
  throwNext: boolean = false;

  push(status: number, body: string, headers?: Record<string, string>): void {
    const h: Record<string, string> = headers === undefined ? {} : headers;
    const resp: HttpResponse = { status: status, body: body, headers: h };
    this.queue.push(resp);
  }

  transport = (req: HttpRequest): Promise<HttpResponse> => {
    this.reqs.push(req);
    if (this.throwNext) {
      this.throwNext = false;
      return Promise.reject(new Error('network down'));
    }
    const next: HttpResponse | undefined = this.queue.shift();
    if (next === undefined) {
      const emptyHeaders: Record<string, string> = {};
      const fallback: HttpResponse = {
        status: 500,
        body: '{"data":{"code":"HTTP_ERROR"}}',
        headers: emptyHeaders
      };
      return Promise.resolve(fallback);
    }
    return Promise.resolve(next);
  };
}

function sampleAuth(): string {
  return '{"accessToken":"tok","refreshToken":"ref","expiresIn":900,' +
    '"user":{"id":"u1","email":"a@b.c"},"device":{"id":"d1","name":"HarmonyOS"}}';
}

function encDocJson(doc: SyncDocument, revision: string): string {
  const json: string = serializeDocument(doc);
  return '{"revision":"' + revision + '","schemaVersion":1,"keyVersion":1,' +
    '"algorithm":"AES-256-GCM","nonce":"AAAAAAAAAAAAAAAA","ciphertext":' +
    JSON.stringify(json) +
    ',"ciphertextHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",' +
    '"updatedAt":"2026-08-15T00:00:00.000Z"}';
}

/** 构造一条 V1 server 记录（对端 portableServerSchema 的 8 个字段） */
function server(id: string, name: string): SyncServerRecord {
  return {
    id: id,
    profile: {
      id: id, name: name, host: '10.0.0.1', port: 22, username: 'root',
      authType: 'password', hostFingerprint: '', keepalive: 30
    }
  };
}

function signedStore(): MemoryAuthStore {
  const store: MemoryAuthStore = new MemoryAuthStore();
  store.access = 'a';
  store.refresh = 'r';
  store.mail = 'a@b.c';
  store.uid = 'u1';
  store.device = 'd1';
  return store;
}

export default function syncLayerTest() {
  describe('SyncLayerTest', () => {

    it('S3_错误码区分文档不存在与保险库不存在', 0, () => {
      const missDoc: ApiError = parseApiError(404,
        '{"data":{"code":"SYNC_DOCUMENT_NOT_FOUND","message":"x"}}');
      const missVault: ApiError = parseApiError(404,
        '{"data":{"code":"VAULT_NOT_FOUND","message":"y"}}');
      expect(missDoc.code).assertEqual('SYNC_DOCUMENT_NOT_FOUND');
      expect(missVault.code).assertEqual('VAULT_NOT_FOUND');
      expect(missDoc.code === missVault.code).assertFalse();
    });

    it('S3_401过期自动refresh再重放', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(401, '{"data":{"code":"AUTH_TOKEN_EXPIRED"}}');
      http.push(200, sampleAuth());
      http.push(200, '{"items":[]}');
      const tokens: MemTokens = new MemTokens();
      const api: ApiClient = new ApiClient(http.transport, tokens, (_ms: number) => Promise.resolve());
      const devices = await api.listDevices();
      expect(devices.length).assertEqual(0);
      expect(http.reqs.length).assertEqual(3);
      expect(http.reqs[0].path).assertEqual('/devices');
      expect(http.reqs[1].path).assertEqual('/auth/refresh');
      expect(http.reqs[2].path).assertEqual('/devices');
      expect(tokens.access).assertEqual('tok');
    });

    it('S3_401重用refresh会清token', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(401, '{"data":{"code":"AUTH_TOKEN_REUSED"}}');
      const tokens: MemTokens = new MemTokens();
      const api: ApiClient = new ApiClient(http.transport, tokens, (_ms: number) => Promise.resolve());
      let code: string = '';
      try {
        await api.listDevices();
      } catch (err) {
        if (err instanceof ApiError) {
          code = err.code;
        }
      }
      expect(code).assertEqual('AUTH_TOKEN_REUSED');
      expect(tokens.access).assertEqual('');
      expect(tokens.refresh).assertEqual('');
    });

    it('S3_429按RetryAfter退避后重试', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      const slept: number[] = [];
      http.push(429, '{"data":{"code":"RATE_LIMITED"}}', { 'Retry-After': '2' });
      http.push(200, '{"items":[]}');
      const api: ApiClient =
        new ApiClient(http.transport, new MemTokens(), (ms: number) => {
          slept.push(ms);
          return Promise.resolve();
        });
      await api.listDevices();
      expect(slept.length).assertEqual(1);
      expect(slept[0]).assertEqual(2000);
      expect(http.reqs.length).assertEqual(2);
    });

    it('S4_已登录不再次login避免新建设备', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(200, sampleAuth());
      const store: MemoryAuthStore = new MemoryAuthStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      await auth.login('a@b.c', 'password12', 'HarmonyOS');
      expect(store.device).assertEqual('d1');
      expect(http.reqs.length).assertEqual(1);
      await auth.login('a@b.c', 'password12', 'HarmonyOS');
      expect(http.reqs.length).assertEqual(1);
      expect(auth.isSignedIn()).assertTrue();
    });

    it('S4_换邮箱登录必须发真实请求', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(200, sampleAuth());
      http.push(200, '{"accessToken":"tok2","refreshToken":"ref2","expiresIn":900,' +
        '"user":{"id":"u2","email":"x@y.z"},"device":{"id":"d2","name":"HarmonyOS"}}');
      const store: MemoryAuthStore = new MemoryAuthStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      await auth.login('a@b.c', 'password12', 'HarmonyOS');
      expect(http.reqs.length).assertEqual(1);
      await auth.login('x@y.z', 'password34', 'HarmonyOS');
      expect(http.reqs.length).assertEqual(2);
      expect(store.mail).assertEqual('x@y.z');
      expect(store.device).assertEqual('d2');
    });

    it('S4_改密后需要重新登录', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(200, '{"reauthenticationRequired":true}');
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const need: boolean = await auth.changePassword('oldpassword', 'newpassword1');
      expect(need).assertTrue();
      expect(auth.isSignedIn()).assertFalse();
      expect(store.device).assertEqual('d1');
    });

    it('S5_同一配置两次序列化字节一致且按id排序', 0, () => {
      const doc: SyncDocument = emptySyncDocument();
      doc.servers.push(server('b-id', 'B'));
      doc.servers.push(server('a-id', 'A'));
      doc.updatedAt = '2026-08-15T00:00:00.000Z';
      const s1: string = serializeDocument(doc);
      const s2: string = serializeDocument(parseDocumentJson(s1));
      expect(s1).assertEqual(s2);
      const canon = canonicalizeDocument(doc);
      expect(canon.servers[0].id).assertEqual('a-id');
    });

    it('S5_产出的文档只含对端 strictObject 允许的顶层键', 0, () => {
      const doc: SyncDocument = emptySyncDocument();
      doc.updatedAt = '2026-08-15T00:00:00.000Z';
      doc.servers.push(server('h1', '主机'));
      const parsed: Record<string, Object> =
        JSON.parse(serializeDocument(doc)) as Record<string, Object>;
      const keys: string[] = Object.keys(parsed).sort();
      expect(keys.join(',')).assertEqual('groups,preferences,schemaVersion,servers,tunnels,updatedAt');
      const first: Record<string, Object> = (parsed['servers'] as Object[])[0] as Record<string, Object>;
      // server 记录只允许 profile / secrets，本地对齐用的 id 不得写出
      expect(Object.keys(first).sort().join(',')).assertEqual('profile');
    });

    it('S5_主机数超限在序列化前拦截', 0, () => {
      const doc: SyncDocument = emptySyncDocument();
      for (let i = 0; i < HOST_COUNT_MAX + 1; i++) {
        doc.servers.push(server(`h-${i}`, `h${i}`));
      }
      expect(validateDocumentLimits(doc).length > 0).assertTrue();
    });

    it('S5_隧道引用不存在的主机会被拦截', 0, () => {
      const doc: SyncDocument = emptySyncDocument();
      doc.servers.push(server('h1', '主机'));
      doc.tunnels.push({
        id: 't1', name: 'L-8080', serverId: 'missing', groupId: null, type: 'local',
        listenHost: '127.0.0.1', listenPort: 8080, destHost: '10.0.0.2', destPort: 80,
        destServerId: '', autoReconnect: false, enabled: true
      });
      expect(validateDocumentLimits(doc).length > 0).assertTrue();
    });

    it('S5_关闭敏感开关会裁掉secrets', 0, () => {
      const doc: SyncDocument = emptySyncDocument();
      const item: SyncServerRecord = server('h1', '主机');
      item.secrets = { password: 'p', passphrase: 'x' };
      doc.servers.push(item);
      applySensitiveFlags(doc, false, false);
      expect(doc.servers[0].secrets === undefined).assertTrue();
    });

    it('S5_三方合并_字段_双方新增_删除修改', 0, () => {
      const base: SyncDocument = emptySyncDocument();
      const local: SyncDocument = emptySyncDocument();
      const remote: SyncDocument = emptySyncDocument();
      base.servers.push(server('h1', '原名'));
      local.servers.push(server('h1', '本机'));
      remote.servers.push(server('h1', '云端'));
      const field = mergeDocuments(base, local, remote);
      expect(field.conflicts.length).assertEqual(1);
      expect(field.conflicts[0].kind).assertEqual('field');
      expect(field.conflicts[0].entity).assertEqual('server');

      const b2: SyncDocument = emptySyncDocument();
      const l2: SyncDocument = emptySyncDocument();
      const r2: SyncDocument = emptySyncDocument();
      l2.servers.push(server('n1', 'mine'));
      r2.servers.push(server('n1', 'other'));
      const add = mergeDocuments(b2, l2, r2);
      expect(add.conflicts[0].kind).assertEqual('add-add');

      const b3: SyncDocument = emptySyncDocument();
      const l3: SyncDocument = emptySyncDocument();
      const r3: SyncDocument = emptySyncDocument();
      b3.servers.push(server('d1', '原名'));
      l3.servers.push(server('d1', '改过'));
      const del = mergeDocuments(b3, l3, r3);
      expect(del.conflicts[0].kind).assertEqual('delete-modify');
    });

    it('S6_云端无文档则首次上传', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      // HEAD 无响应体裁剪，headDocument() 会先收到空 404 再补一次 GET 拿 data.code
      http.push(404, '');
      http.push(404, '{"data":{"code":"SYNC_DOCUMENT_NOT_FOUND"}}');
      http.push(200, '{"revision":"1"}');
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      await coord.syncNow();
      expect(coord.phase).assertEqual('synced');
      expect(http.reqs[0].method).assertEqual('HEAD');
      expect(http.reqs[0].path).assertEqual('/sync/document');
      expect(http.reqs[1].method).assertEqual('GET');
      expect(http.reqs[2].method).assertEqual('PUT');
    });

    it('S6_HEAD404区分保险库不存在_转locked不报错', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(404, '');
      http.push(404, '{"data":{"code":"VAULT_NOT_FOUND"}}');
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      await coord.syncNow();
      expect(coord.phase).assertEqual('locked');
      expect(coord.lastError).assertEqual('VAULT_NOT_FOUND');
    });

    it('S6_保险库未解锁时不发网络请求_直接转locked', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const locked: LockedCrypto = new LockedCrypto();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, locked);
      await coord.syncNow();
      expect(coord.phase).assertEqual('locked');
      expect(coord.lastError).assertEqual('VAULT_LOCKED');
      expect(http.reqs.length).assertEqual(0);
    });

    it('S6_上传遇到密钥版本不匹配转locked而非普通错误', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(404, '');
      http.push(404, '{"data":{"code":"SYNC_DOCUMENT_NOT_FOUND"}}');
      http.push(409, '{"data":{"code":"VAULT_KEY_VERSION_MISMATCH"}}');
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      await coord.syncNow();
      expect(coord.phase).assertEqual('locked');
      expect(coord.lastError).assertEqual('VAULT_KEY_VERSION_MISMATCH');
    });

    it('S6_409拉远端合并后重试成功', 0, async () => {
      const localDoc: SyncDocument = emptySyncDocument();
      localDoc.updatedAt = '2026-08-15T00:00:00.000Z';
      localDoc.servers.push(server('h1', '本机'));

      const remote1: SyncDocument = emptySyncDocument();
      remote1.updatedAt = '2026-08-15T00:00:00.000Z';
      remote1.servers.push(server('h2', '云端新增'));

      const remote2: SyncDocument = emptySyncDocument();
      remote2.updatedAt = '2026-08-15T00:00:01.000Z';
      remote2.servers.push(server('h2', '云端新增'));
      remote2.servers.push(server('h3', '并发写入'));

      const http: ScriptedHttp = new ScriptedHttp();
      http.push(200, '', { 'x-sync-revision': '1' });
      http.push(200, encDocJson(remote1, '1'));
      http.push(409, '{"data":{"code":"SYNC_REVISION_CONFLICT"}}');
      http.push(200, encDocJson(remote2, '2'));
      http.push(200, '{"revision":"3"}');

      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      docs.doc = localDoc;
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      await coord.syncNow();
      expect(coord.phase).assertEqual('synced');
      expect(http.reqs[2].method).assertEqual('PUT');
      expect(http.reqs[4].method).assertEqual('PUT');
      expect(docs.doc.servers.length >= 2).assertTrue();
    });

    it('S6_断网标脏_联网自动补传', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      const pending: Array<() => void> = [];
      const triggers: SyncTriggers = new SyncTriggers(coord, (ms: number, fn: () => void) => {
        pending.push(fn);
        return pending.length;
      }, (_id: number) => {
      }, 10);
      http.throwNext = true;
      await coord.syncNow();
      expect(coord.phase).assertEqual('offline');
      await coord.markDirty();
      http.push(404, '');
      http.push(404, '{"data":{"code":"SYNC_DOCUMENT_NOT_FOUND"}}');
      http.push(200, '{"revision":"1"}');
      triggers.notifyNetworkAvailable();
      if (pending.length > 0) {
        await Promise.resolve();
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 0);
      });
      expect(coord.phase).assertEqual('synced');
    });

    it('S6_保存防抖到期才同步', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      http.push(404, '');
      http.push(404, '{"data":{"code":"SYNC_DOCUMENT_NOT_FOUND"}}');
      http.push(200, '{"revision":"1"}');
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      const box: Array<() => void> = [];
      const triggers: SyncTriggers = new SyncTriggers(coord, (_ms: number, fn: () => void) => {
        box.push(fn);
        return 1;
      }, (_id: number) => {
      }, 3000);
      triggers.notifySaved();
      expect(http.reqs.length).assertEqual(0);
      expect(box.length).assertEqual(1);
      box[0]();
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 0);
      });
      expect(http.reqs.length > 0).assertTrue();
    });

    it('S7_关闭敏感开关标记需要轮换', 0, () => {
      const http: ScriptedHttp = new ScriptedHttp();
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      coord.setSensitiveFlags(true, false);
      expect(coord.rotateRequired).assertFalse();
      coord.setSensitiveFlags(false, false);
      expect(coord.rotateRequired).assertTrue();
    });

    it('S7_轮换后恢复密钥只生成一次并可确认清空', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      // rotateAndClearHistory 先探测 baseRevision（HEAD 404 空体 + GET 404 补 code），
      // 再 POST /vault/rotate，最后 DELETE /sync/revisions 兜底清空历史
      http.push(404, '');
      http.push(404, '{"data":{"code":"SYNC_DOCUMENT_NOT_FOUND"}}');
      http.push(200, '{"revision":"4"}');
      http.push(200, '{}');
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new PlainCrypto());
      coord.setSensitiveFlags(true, true);
      coord.setSensitiveFlags(false, false);
      const key: string = await coord.rotateAndClearHistory('password12', 'password12');
      expect(key.indexOf('SPM1-') === 0).assertTrue();
      expect(coord.rotateRequired).assertFalse();
      expect(coord.phase).assertEqual('synced');
      expect(http.reqs[0].method).assertEqual('HEAD');
      expect(http.reqs[1].method).assertEqual('GET');
      expect(http.reqs[2].path).assertEqual('/vault/rotate');
      expect(http.reqs[3].path).assertEqual('/sync/revisions');
    });

    it('S7_保险库未解锁时拒绝轮换', 0, async () => {
      const http: ScriptedHttp = new ScriptedHttp();
      const store: MemoryAuthStore = signedStore();
      const api: ApiClient = new ApiClient(http.transport, store);
      const auth: AuthSession = new AuthSession(api, store);
      const docs: MemoryDocumentStore = new MemoryDocumentStore();
      const coord: SyncCoordinator = new SyncCoordinator(api, auth, docs, new LockedCrypto());
      const key: string = await coord.rotateAndClearHistory('password12', 'password12');
      expect(key).assertEqual('');
      expect(coord.phase).assertEqual('locked');
      expect(http.reqs.length).assertEqual(0);
    });

    it('S8_KDF参数与本机常量不一致时判定不兼容', 0, () => {
      const envelope = (memory: number, iterations: number, parallelism: number): VaultEnvelope => {
        return {
          id: 'v1', keyVersion: 1, passwordWrappedKey: 'A', passwordWrapNonce: 'B',
          recoveryWrappedKey: 'C', recoveryWrapNonce: 'D', kdfSalt: 'E',
          kdfMemory: memory, kdfIterations: iterations, kdfParallelism: parallelism
        };
      };
      expect(kdfParamsCompatible(envelope(65536, 3, 1))).assertTrue();
      expect(kdfParamsCompatible(envelope(19456, 2, 1))).assertFalse();
      expect(kdfParamsCompatible(envelope(0, 0, 0))).assertTrue();
    });

    it('S8_信封形状自检把坏信封与密码错分开', 0, () => {
      // 合法长度：salt 16B→24 字符，nonce 12B→16 字符，wrappedKey (32+16)B→64 字符
      const salt: string = 'A'.repeat(24);
      const nonce: string = 'B'.repeat(16);
      const wrapped: string = 'C'.repeat(64);
      const envelope = (keyVersion: number, s: string, w: string, n: string): VaultEnvelope => {
        return {
          id: 'v1', keyVersion: keyVersion, passwordWrappedKey: w, passwordWrapNonce: n,
          recoveryWrappedKey: 'x', recoveryWrapNonce: 'y', kdfSalt: s,
          kdfMemory: 65536, kdfIterations: 3, kdfParallelism: 1
        };
      };
      // 形状正常 → 放行，后续失败才归因到密码
      expect(envelopeIntegrityError(envelope(1, salt, wrapped, nonce))).assertEqual('');
      // keyVersion 被 readNumber 静默吃成 0（服务端发字符串/漏字段）→ 参与 AAD，必然解不开
      expect(envelopeIntegrityError(envelope(0, salt, wrapped, nonce)).length > 0).assertTrue();
      // 字段缺失
      expect(envelopeIntegrityError(envelope(1, '', wrapped, nonce)).length > 0).assertTrue();
      // 长度被截断
      expect(envelopeIntegrityError(envelope(1, 'A'.repeat(20), wrapped, nonce)).length > 0).assertTrue();
      expect(envelopeIntegrityError(envelope(1, salt, wrapped, 'B'.repeat(12))).length > 0).assertTrue();
      expect(envelopeIntegrityError(envelope(1, salt, 'C'.repeat(44), nonce)).length > 0).assertTrue();
    });
  });
}
