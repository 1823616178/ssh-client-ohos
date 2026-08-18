/**
 * 同步 API 类型（任务 S3，docs/SYNC-PROTOCOL.md §8 / api-v1.md）。
 * 错误只认 data.code，不依赖中文 message。
 */

import { REVISION_ETAG_PREFIX } from '../../common/sync/SyncProtocol';

export interface HttpResponse {
  readonly status: number;
  readonly body: string;
  readonly headers: Record<string, string>;
}

export interface HttpRequest {
  readonly method: string;
  readonly path: string;
  readonly headers: Record<string, string>;
  readonly body: string;
}

export type HttpTransport = (req: HttpRequest) => Promise<HttpResponse>;

export class ApiError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status: number, message: string) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export interface AuthUser {
  id: string;
  email: string;
}

export interface AuthDevice {
  id: string;
  name: string;
}

export interface AuthResult extends TokenPair {
  user: AuthUser;
  device: AuthDevice;
}

export interface DeviceItem {
  id: string;
  name: string;
  platform: string;
  appVersion: string;
  createdAt: string;
  lastSeenAt: string;
  current: boolean;
}

export interface VaultEnvelope {
  id: string;
  keyVersion: number;
  passwordWrappedKey: string;
  passwordWrapNonce: string;
  recoveryWrappedKey: string;
  recoveryWrapNonce: string;
  kdfSalt: string;
  kdfMemory: number;
  kdfIterations: number;
  kdfParallelism: number;
}

export interface EncryptedDocument {
  revision: string;
  schemaVersion: number;
  keyVersion: number;
  algorithm: string;
  nonce: string;
  ciphertext: string;
  ciphertextHash: string;
  updatedAt: string;
}

export interface RevisionItem {
  revision: string;
  schemaVersion: number;
  keyVersion: number;
  algorithm: string;
  ciphertextHash: string;
  createdAt: string;
}

export interface TokenProvider {
  getAccessToken(): string;
  getRefreshToken(): string;
  setTokens(access: string, refresh: string): void;
  clearTokens(): void;
}

export function revisionEtag(revision: string): string {
  return `"${REVISION_ETAG_PREFIX}${revision}"`;
}

export function headerOf(headers: Record<string, string>, name: string): string {
  const want: string = name.toLowerCase();
  const keys: string[] = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === want) {
      return headers[keys[i]];
    }
  }
  return '';
}
