/**
 * 同步 API 客户端（任务 S3）。
 *
 * 全部 /api/v1 端点；401 AUTH_TOKEN_EXPIRED 自动 refresh 后重放一次；
 * AUTH_TOKEN_REUSED 清 token；429 按 Retry-After 退避（可注入 sleeper）；
 * SYNC_DOCUMENT_NOT_FOUND 与 VAULT_NOT_FOUND 以 ApiError.code 区分。
 * 传输经 HttpTransport 注入，单测用 fake，生产用 @ohos.net.http。
 */

import { JSON } from '@kit.ArkTS';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { BuildConfig } from '../../common/constants/BuildConfig';
import { Logger } from '../../common/utils/Logger';
import { AES_ALGORITHM, ARGON2_ITERATIONS, ARGON2_MEMORY_KIB, ARGON2_PARALLELISM } from
  '../../common/sync/SyncProtocol';
import {
  ApiError,
  AuthResult,
  DeviceItem,
  EncryptedDocument,
  HttpRequest,
  HttpResponse,
  HttpTransport,
  RevisionItem,
  TokenProvider,
  VaultEnvelope,
  headerOf,
  revisionEtag
} from './ApiTypes';

const LOG_TAG: string = 'SyncApi';

/** 429 自动退避重试的时长上限（秒）：超过则不阻塞调用方，直接把 429 抛给上层提示 */
const MAX_RATE_LIMIT_BACKOFF_SEC: number = 5;

export type Sleeper = (ms: number) => Promise<void>;

function asRecord(raw: Object): Record<string, Object> {
  return raw as Record<string, Object>;
}

function readString(rec: Record<string, Object>, key: string): string {
  const value: Object | undefined = rec[key];
  return typeof value === 'string' ? value : '';
}

function readNumber(rec: Record<string, Object>, key: string): number {
  const value: Object | undefined = rec[key];
  return typeof value === 'number' ? value : 0;
}

/**
 * 数值字段的宽松读取：兼容服务端把整数序列化成字符串的情况。
 * 服务端确实有这种习惯（api-v1.md §1.5：revision 是「无符号 64 位整数，字符串形式」），
 * 一旦 keyVersion 也走这条路，严格版 readNumber 会静默返回 0，而 keyVersion 参与包裹 AAD，
 * 结果就是保险库永远解不开、还被误报成「同步密码错误」。
 */
function readIntLoose(rec: Record<string, Object>, key: string): number {
  const value: Object | undefined = rec[key];
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseInt(value as string, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

function readBool(rec: Record<string, Object>, key: string): boolean {
  return rec[key] === true;
}

function parseJsonObject(body: string): Record<string, Object> {
  if (body.length === 0) {
    return {};
  }
  try {
    const parsed: Object = JSON.parse(body) as Object;
    if (parsed === null) {
      return {};
    }
    return asRecord(parsed);
  } catch (err) {
    Logger.warn(`同步响应 JSON 非法: ${JSON.stringify(err)}`, LOG_TAG);
    return {};
  }
}

export function parseApiError(status: number, body: string): ApiError {
  const root: Record<string, Object> = parseJsonObject(body);
  const dataRaw: Object | undefined = root['data'];
  let code: string = '';
  let message: string = readString(root, 'message');
  if (dataRaw !== undefined && dataRaw !== null) {
    const data: Record<string, Object> = asRecord(dataRaw);
    code = readString(data, 'code');
    if (message.length === 0) {
      message = readString(data, 'message');
    }
  }
  if (code.length === 0) {
    code = status === 429 ? 'RATE_LIMITED' : 'HTTP_ERROR';
  }
  return new ApiError(code, status, message.length > 0 ? message : code);
}

function parseAuthResult(body: string): AuthResult {
  const root: Record<string, Object> = parseJsonObject(body);
  const userRec: Record<string, Object> = asRecord(root['user'] as Object);
  const deviceRec: Record<string, Object> = asRecord(root['device'] as Object);
  return {
    accessToken: readString(root, 'accessToken'),
    refreshToken: readString(root, 'refreshToken'),
    expiresIn: readNumber(root, 'expiresIn'),
    user: { id: readString(userRec, 'id'), email: readString(userRec, 'email') },
    device: { id: readString(deviceRec, 'id'), name: readString(deviceRec, 'name') }
  };
}

function parseVault(body: string): VaultEnvelope {
  const root: Record<string, Object> = parseJsonObject(body);
  const kdfRaw: Object | undefined = root['kdfParameters'];
  const kdf: Record<string, Object> = kdfRaw === undefined ? {} : asRecord(kdfRaw);
  return {
    id: readString(root, 'id'),
    keyVersion: readIntLoose(root, 'keyVersion'),
    passwordWrappedKey: readString(root, 'passwordWrappedKey'),
    passwordWrapNonce: readString(root, 'passwordWrapNonce'),
    recoveryWrappedKey: readString(root, 'recoveryWrappedKey'),
    recoveryWrapNonce: readString(root, 'recoveryWrapNonce'),
    kdfSalt: readString(root, 'kdfSalt'),
    kdfMemory: readIntLoose(kdf, 'memory'),
    kdfIterations: readIntLoose(kdf, 'iterations'),
    kdfParallelism: readIntLoose(kdf, 'parallelism')
  };
}

function parseDocument(body: string): EncryptedDocument {
  const root: Record<string, Object> = parseJsonObject(body);
  return {
    revision: `${root['revision'] ?? ''}`,
    schemaVersion: readIntLoose(root, 'schemaVersion'),
    keyVersion: readIntLoose(root, 'keyVersion'),
    algorithm: readString(root, 'algorithm'),
    nonce: readString(root, 'nonce'),
    ciphertext: readString(root, 'ciphertext'),
    ciphertextHash: readString(root, 'ciphertextHash'),
    updatedAt: readString(root, 'updatedAt')
  };
}

function defaultKdf(): Record<string, Object> {
  const kdf: Record<string, Object> = {};
  kdf['algorithm'] = 'argon2id';
  kdf['memory'] = ARGON2_MEMORY_KIB;
  kdf['iterations'] = ARGON2_ITERATIONS;
  kdf['parallelism'] = ARGON2_PARALLELISM;
  return kdf;
}

export function newIdempotencyKey(): string {
  return util.generateRandomUUID();
}

export class ApiClient {
  private readonly transport: HttpTransport;
  private readonly tokens: TokenProvider;
  private readonly sleep: Sleeper;
  private refreshInFlight: Promise<void> | null = null;

  constructor(transport: HttpTransport, tokens: TokenProvider, sleep?: Sleeper) {
    this.transport = transport;
    this.tokens = tokens;
    this.sleep = sleep ?? ((ms: number): Promise<void> => {
      return new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, ms);
      });
    });
  }

  async register(email: string, password: string, deviceName: string,
    inviteCode: string): Promise<AuthResult> {
    const body: Record<string, Object> = {};
    body['email'] = email;
    body['password'] = password;
    if (inviteCode.length > 0) {
      body['inviteCode'] = inviteCode;
    }
    body['device'] = this.devicePayload(deviceName);
    return parseAuthResult(await this.send('POST', '/auth/register', body, false, '', false));
  }

  async login(email: string, password: string, deviceName: string): Promise<AuthResult> {
    const body: Record<string, Object> = {};
    body['email'] = email;
    body['password'] = password;
    body['device'] = this.devicePayload(deviceName);
    return parseAuthResult(await this.send('POST', '/auth/login', body, false, '', false));
  }

  async refresh(): Promise<AuthResult> {
    const body: Record<string, Object> = {};
    body['refreshToken'] = this.tokens.getRefreshToken();
    return parseAuthResult(await this.send('POST', '/auth/refresh', body, false, '', true));
  }

  async logout(): Promise<void> {
    await this.send('POST', '/auth/logout', {}, true, '', false);
  }

  async logoutAll(): Promise<number> {
    const raw: string = await this.send('POST', '/auth/logout-all', {}, true, '', false);
    return readNumber(parseJsonObject(raw), 'revokedDevices');
  }

  async changePassword(currentPassword: string, newPassword: string): Promise<boolean> {
    const body: Record<string, Object> = {};
    body['currentPassword'] = currentPassword;
    body['newPassword'] = newPassword;
    const raw: string = await this.send('POST', '/auth/change-password', body, true, '', false);
    return parseJsonObject(raw)['reauthenticationRequired'] === true;
  }

  async deleteAccount(currentPassword: string): Promise<void> {
    const body: Record<string, Object> = {};
    body['currentPassword'] = currentPassword;
    body['confirmation'] = 'DELETE';
    await this.send('DELETE', '/me', body, true, '', false);
  }

  async listDevices(): Promise<DeviceItem[]> {
    const raw: string = await this.send('GET', '/devices', null, true, '', false);
    const root: Record<string, Object> = parseJsonObject(raw);
    const itemsRaw: Object | undefined = root['items'];
    if (itemsRaw === undefined || !Array.isArray(itemsRaw)) {
      return [];
    }
    const arr: Object[] = itemsRaw as Object[];
    const result: DeviceItem[] = [];
    for (const item of arr) {
      const rec: Record<string, Object> = asRecord(item);
      result.push({
        id: readString(rec, 'id'),
        name: readString(rec, 'name'),
        platform: readString(rec, 'platform'),
        appVersion: readString(rec, 'appVersion'),
        createdAt: readString(rec, 'createdAt'),
        lastSeenAt: readString(rec, 'lastSeenAt'),
        current: readBool(rec, 'current')
      });
    }
    return result;
  }

  async renameDevice(id: string, name: string): Promise<void> {
    const body: Record<string, Object> = {};
    body['name'] = name;
    await this.send('PATCH', `/devices/${id}`, body, true, '', false);
  }

  async revokeDevice(id: string): Promise<void> {
    await this.send('DELETE', `/devices/${id}`, {}, true, '', false);
  }

  async createVault(envelope: VaultEnvelope, idem: string): Promise<string> {
    const body: Record<string, Object> = this.vaultBody(envelope);
    const raw: string = await this.send('POST', '/vault', body, true, idem, false);
    return readString(parseJsonObject(raw), 'id');
  }

  async getVaultEnvelope(): Promise<VaultEnvelope> {
    return parseVault(await this.send('GET', '/vault/key-envelope', null, true, '', false));
  }

  async rewrapVault(currentPassword: string, envelope: VaultEnvelope): Promise<void> {
    const body: Record<string, Object> = this.vaultBody(envelope);
    body['currentPassword'] = currentPassword;
    await this.send('PUT', '/vault/key-envelope', body, true, '', false);
  }

  async rotateVault(currentPassword: string, envelope: VaultEnvelope, document: EncryptedDocument,
    ifMatchRevision: string, idem: string): Promise<string> {
    const body: Record<string, Object> = {};
    body['currentPassword'] = currentPassword;
    body['keyEnvelope'] = this.vaultBody(envelope);
    body['document'] = this.documentBody(document);
    const raw: string =
      await this.send('POST', '/vault/rotate', body, true, idem, false, ifMatchRevision);
    return `${parseJsonObject(raw)['revision'] ?? ''}`;
  }

  async deleteVault(currentPassword: string): Promise<void> {
    const body: Record<string, Object> = {};
    body['currentPassword'] = currentPassword;
    await this.send('DELETE', '/vault', body, true, '', false);
  }

  async headDocument(): Promise<string> {
    const resp: HttpResponse = await this.exchange('HEAD', '/sync/document', '', true, '', false, '');
    if (resp.status >= 200 && resp.status < 300) {
      const rev: string = headerOf(resp.headers, 'x-sync-revision');
      if (rev.length > 0) {
        return rev;
      }
      const etag: string = headerOf(resp.headers, 'etag');
      const prefix: string = 'revision-';
      const idx: number = etag.indexOf(prefix);
      if (idx >= 0) {
        return etag.substring(idx + prefix.length).replace(/"/g, '');
      }
      return '';
    }
    if (resp.status === 404) {
      // HEAD 按 HTTP 语义无响应体（Node http 层会裁剪），SYNC_DOCUMENT_NOT_FOUND 与
      // VAULT_NOT_FOUND 两种 404 无法从 HEAD 本身区分；改发一次 GET 拿带 data.code 的错误体。
      const getResp: HttpResponse =
        await this.exchange('GET', '/sync/document', '', true, '', false, '');
      if (getResp.status >= 200 && getResp.status < 300) {
        return parseDocument(getResp.body).revision;
      }
      this.throwIfError(getResp);
    }
    this.throwIfError(resp);
    return '';
  }

  async getDocument(): Promise<EncryptedDocument> {
    return parseDocument(await this.send('GET', '/sync/document', null, true, '', false));
  }

  async putDocument(doc: EncryptedDocument, ifMatchRevision: string,
    idem: string): Promise<string> {
    const raw: string =
      await this.send('PUT', '/sync/document', this.documentBody(doc), true, idem, false,
        ifMatchRevision);
    return `${parseJsonObject(raw)['revision'] ?? ''}`;
  }

  async listRevisions(): Promise<RevisionItem[]> {
    const raw: string = await this.send('GET', '/sync/revisions', null, true, '', false);
    const root: Record<string, Object> = parseJsonObject(raw);
    const itemsRaw: Object | undefined = root['items'];
    if (itemsRaw === undefined || !Array.isArray(itemsRaw)) {
      return [];
    }
    const result: RevisionItem[] = [];
    for (const item of itemsRaw as Object[]) {
      const rec: Record<string, Object> = asRecord(item);
      result.push({
        revision: `${rec['revision'] ?? ''}`,
        schemaVersion: readNumber(rec, 'schemaVersion'),
        keyVersion: readNumber(rec, 'keyVersion'),
        algorithm: readString(rec, 'algorithm'),
        ciphertextHash: readString(rec, 'ciphertextHash'),
        createdAt: readString(rec, 'createdAt')
      });
    }
    return result;
  }

  async clearRevisions(ifMatchRevision: string): Promise<void> {
    await this.send('DELETE', '/sync/revisions', {}, true, '', false, ifMatchRevision);
  }

  async restoreRevision(revision: string, ifMatchRevision: string, idem: string): Promise<string> {
    const raw: string = await this.send('POST', `/sync/revisions/${revision}/restore`, {}, true, idem,
      false, ifMatchRevision);
    return `${parseJsonObject(raw)['revision'] ?? ''}`;
  }

  private devicePayload(name: string): Record<string, Object> {
    const device: Record<string, Object> = {};
    device['name'] = name.length > 0 ? name : 'HarmonyOS';
    device['platform'] = 'harmonyos';
    device['appVersion'] = '1.0.0';
    return device;
  }

  private vaultBody(envelope: VaultEnvelope): Record<string, Object> {
    const body: Record<string, Object> = {};
    body['keyVersion'] = envelope.keyVersion;
    body['passwordWrappedKey'] = envelope.passwordWrappedKey;
    body['passwordWrapNonce'] = envelope.passwordWrapNonce;
    body['recoveryWrappedKey'] = envelope.recoveryWrappedKey;
    body['recoveryWrapNonce'] = envelope.recoveryWrapNonce;
    body['kdfSalt'] = envelope.kdfSalt;
    const kdf: Record<string, Object> = defaultKdf();
    if (envelope.kdfMemory > 0) {
      kdf['memory'] = envelope.kdfMemory;
    }
    body['kdfParameters'] = kdf;
    return body;
  }

  private documentBody(doc: EncryptedDocument): Record<string, Object> {
    const body: Record<string, Object> = {};
    body['schemaVersion'] = doc.schemaVersion;
    body['keyVersion'] = doc.keyVersion;
    body['algorithm'] = doc.algorithm.length > 0 ? doc.algorithm : AES_ALGORITHM;
    body['nonce'] = doc.nonce;
    body['ciphertext'] = doc.ciphertext;
    body['ciphertextHash'] = doc.ciphertextHash;
    return body;
  }

  private async send(method: string, path: string, body: Record<string, Object> | null,
    auth: boolean, idem: string, isRefresh: boolean, ifMatch: string = ''): Promise<string> {
    const payload: string = body === null ? '' : JSON.stringify(body);
    const resp: HttpResponse =
      await this.exchange(method, path, payload, auth, idem, isRefresh, ifMatch);
    this.throwIfError(resp);
    return resp.body;
  }

  private async exchange(method: string, path: string, payload: string, auth: boolean,
    idem: string, isRefresh: boolean, ifMatch: string): Promise<HttpResponse> {
    let resp: HttpResponse = await this.raw(method, path, payload, auth, idem, ifMatch);
    if (resp.status === 401 && !isRefresh) {
      const err: ApiError = parseApiError(resp.status, resp.body);
      if (err.code === 'AUTH_TOKEN_EXPIRED') {
        await this.refreshOnce();
        resp = await this.raw(method, path, payload, auth, idem, ifMatch);
      } else if (err.code === 'AUTH_TOKEN_REUSED') {
        this.tokens.clearTokens();
        throw err;
      }
    }
    if (resp.status === 429) {
      const retryAfter: string = headerOf(resp.headers, 'retry-after');
      const rawSec: number = retryAfter.length > 0 ? Number.parseInt(retryAfter, 10) : 1;
      const sec: number = Number.isNaN(rawSec) ? 1 : Math.max(1, rawSec);
      if (sec <= MAX_RATE_LIMIT_BACKOFF_SEC) {
        await this.sleep(sec * 1000);
        resp = await this.raw(method, path, payload, auth, idem, ifMatch);
      }
      // 服务端要求的等待时间超过阈值：不阻塞调用方，直接把 429 交给上层提示稍后重试
    }
    return resp;
  }

  private async refreshOnce(): Promise<void> {
    if (this.refreshInFlight !== null) {
      await this.refreshInFlight;
      return;
    }
    this.refreshInFlight = (async (): Promise<void> => {
      try {
        const result: AuthResult = await this.refresh();
        this.tokens.setTokens(result.accessToken, result.refreshToken);
      } catch (err) {
        if (err instanceof ApiError) {
          if (err.code === 'AUTH_TOKEN_REUSED' || err.code === 'AUTH_TOKEN_EXPIRED') {
            this.tokens.clearTokens();
          }
          throw new ApiError(err.code, err.status, err.message);
        }
        throw new Error('刷新令牌失败');
      } finally {
        this.refreshInFlight = null;
      }
    })();
    await this.refreshInFlight;
  }

  private async raw(method: string, path: string, payload: string, auth: boolean, idem: string,
    ifMatch: string): Promise<HttpResponse> {
    const headers: Record<string, string> = {};
    headers['Accept'] = 'application/json';
    if (payload.length > 0) {
      headers['Content-Type'] = 'application/json';
    }
    if (auth) {
      const token: string = this.tokens.getAccessToken();
      if (token.length > 0) {
        headers['Authorization'] = `Bearer ${token}`;
      }
    }
    if (idem.length > 0) {
      headers['Idempotency-Key'] = idem;
    }
    if (ifMatch.length > 0) {
      headers['If-Match'] = revisionEtag(ifMatch);
    }
    const req: HttpRequest = { method: method, path: path, headers: headers, body: payload };
    return this.transport(req);
  }

  private throwIfError(resp: HttpResponse): void {
    if (resp.status >= 200 && resp.status < 300) {
      return;
    }
    throw parseApiError(resp.status, resp.body);
  }
}

function toHttpMethod(method: string): http.RequestMethod {
  if (method === 'POST') {
    return http.RequestMethod.POST;
  }
  if (method === 'PUT') {
    return http.RequestMethod.PUT;
  }
  if (method === 'DELETE') {
    return http.RequestMethod.DELETE;
  }
  if (method === 'HEAD') {
    return http.RequestMethod.HEAD;
  }
  if (method === 'PATCH') {
    return 'PATCH' as http.RequestMethod;
  }
  return http.RequestMethod.GET;
}

/** 生产传输：@kit.NetworkKit http */
export function createProductionTransport(): HttpTransport {
  return async (req: HttpRequest): Promise<HttpResponse> => {
    const client: http.HttpRequest = http.createHttp();
    try {
      const extra: Record<string, string> = req.headers;
      const options: http.HttpRequestOptions = {
        method: toHttpMethod(req.method),
        header: extra,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      if (req.body.length > 0) {
        options.extraData = req.body;
      }
      const resp: http.HttpResponse =
        await client.request(`${BuildConfig.SYNC_API_BASE}${req.path}`, options);
      const headers: Record<string, string> = {};
      const rawHeader: Object = resp.header as Object;
      if (rawHeader !== null) {
        const rec: Record<string, Object> = rawHeader as Record<string, Object>;
        const keys: string[] = Object.keys(rec);
        for (let i = 0; i < keys.length; i++) {
          const value: Object = rec[keys[i]];
          headers[keys[i]] = typeof value === 'string' ? value : `${value}`;
        }
      }
      const body: string = typeof resp.result === 'string' ? resp.result : '';
      return { status: resp.responseCode, body: body, headers: headers };
    } finally {
      client.destroy();
    }
  };
}
