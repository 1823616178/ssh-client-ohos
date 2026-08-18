/**
 * 账号会话与设备 id（任务 S4）。
 *
 * 登录成功后持久化 device.id；已有「同邮箱」有效 token 时 login/register 不再打网，
 * 避免「每次 login 都新建设备」耗尽 10 台配额（换邮箱登录必须走真实请求）。
 * 改密后 reauthenticationRequired 清 token，强制重新登录。
 *
 * accessToken/refreshToken 属长期敏感凭据（refreshToken 30 天有效），落 CredentialStore
 * 的 asset 存储（sync_token: 命名空间），不进 preferences 明文；SettingsAuthStore 维护一份
 * 内存缓存供 TokenProvider 的同步读取接口使用，需先 hydrate() 一次。
 */

import { CredentialStore } from '../../repository/CredentialStore';
import { Logger } from '../../common/utils/Logger';
import { SettingsRepository } from '../../repository/SettingsRepository';
import { ApiClient } from './ApiClient';
import { AuthResult, TokenProvider } from './ApiTypes';

const LOG_TAG: string = 'AuthSession';
const SYNC_TOKEN_ACCESS: string = 'access';
const SYNC_TOKEN_REFRESH: string = 'refresh';

export interface AuthStore {
  getAccessToken(): string;
  getRefreshToken(): string;
  getDeviceId(): string;
  getEmail(): string;
  getUserId(): string;
  saveSession(result: AuthResult): void;
  clearSession(): void;
}

export class SettingsAuthStore implements AuthStore, TokenProvider {
  private accessCache: string = '';
  private refreshCache: string = '';
  private hydrated: boolean = false;

  /** 从 asset 恢复内存缓存的 token；应用启动早期调用一次（SyncRuntime.start） */
  async hydrate(): Promise<void> {
    if (this.hydrated) {
      return;
    }
    try {
      this.accessCache = (await CredentialStore.getSyncToken(SYNC_TOKEN_ACCESS)) ?? '';
      this.refreshCache = (await CredentialStore.getSyncToken(SYNC_TOKEN_REFRESH)) ?? '';
    } catch (err) {
      Logger.warn(`同步 token 读取失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
    this.hydrated = true;
  }

  getAccessToken(): string {
    return this.accessCache;
  }

  getRefreshToken(): string {
    return this.refreshCache;
  }

  getDeviceId(): string {
    return SettingsRepository.getSyncDeviceId();
  }

  getEmail(): string {
    return SettingsRepository.getSyncUserEmail();
  }

  getUserId(): string {
    return SettingsRepository.getSyncUserId();
  }

  setTokens(access: string, refresh: string): void {
    this.accessCache = access;
    this.refreshCache = refresh;
    this.hydrated = true;
    void CredentialStore.setSyncToken(SYNC_TOKEN_ACCESS, access).catch((err: Object) => {
      Logger.warn(`同步 accessToken 落盘失败: ${JSON.stringify(err)}`, LOG_TAG);
    });
    void CredentialStore.setSyncToken(SYNC_TOKEN_REFRESH, refresh).catch((err: Object) => {
      Logger.warn(`同步 refreshToken 落盘失败: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  clearTokens(): void {
    this.accessCache = '';
    this.refreshCache = '';
    this.hydrated = true;
    void CredentialStore.removeSyncToken(SYNC_TOKEN_ACCESS).catch((err: Object) => {
      Logger.warn(`同步 accessToken 清除失败: ${JSON.stringify(err)}`, LOG_TAG);
    });
    void CredentialStore.removeSyncToken(SYNC_TOKEN_REFRESH).catch((err: Object) => {
      Logger.warn(`同步 refreshToken 清除失败: ${JSON.stringify(err)}`, LOG_TAG);
    });
    SettingsRepository.clearSyncSession();
  }

  saveSession(result: AuthResult): void {
    this.setTokens(result.accessToken, result.refreshToken);
    SettingsRepository.setSyncDeviceId(result.device.id);
    SettingsRepository.setSyncUserEmail(result.user.email);
    SettingsRepository.setSyncUserId(result.user.id);
  }

  clearSession(): void {
    this.clearTokens();
  }
}

export class AuthSession {
  private readonly api: ApiClient;
  private readonly store: AuthStore;

  constructor(api: ApiClient, store: AuthStore) {
    this.api = api;
    this.store = store;
  }

  isSignedIn(): boolean {
    return this.store.getAccessToken().length > 0 && this.store.getRefreshToken().length > 0;
  }

  email(): string {
    return this.store.getEmail();
  }

  deviceId(): string {
    return this.store.getDeviceId();
  }

  /**
   * 注册。成功后落库 session。若本地已登录则直接返回已有身份（不重复注册）。
   */
  async register(email: string, password: string, deviceName: string,
    inviteCode: string): Promise<AuthResult> {
    if (this.isSignedIn() && this.store.getEmail() === email) {
      return this.cachedResult();
    }
    const result: AuthResult = await this.api.register(email, password, deviceName, inviteCode);
    this.store.saveSession(result);
    return result;
  }

  /**
   * 登录。已有「同邮箱」有效 session 则不请求网络（不新建设备）；
   * 换邮箱登录必须发真实请求，否则会静默沿用旧账号的 token。
   */
  async login(email: string, password: string, deviceName: string): Promise<AuthResult> {
    if (this.isSignedIn() && this.store.getEmail() === email) {
      return this.cachedResult();
    }
    const result: AuthResult = await this.api.login(email, password, deviceName);
    this.store.saveSession(result);
    return result;
  }

  async logout(): Promise<void> {
    if (this.isSignedIn()) {
      try {
        await this.api.logout();
      } catch (_err) {
        // 网络失败仍清本地，避免假登录
      }
    }
    this.store.clearSession();
  }

  async logoutAll(): Promise<void> {
    if (this.isSignedIn()) {
      try {
        await this.api.logoutAll();
      } catch (_err) {
      }
    }
    this.store.clearSession();
  }

  async changePassword(currentPassword: string, newPassword: string): Promise<boolean> {
    const needReauth: boolean = await this.api.changePassword(currentPassword, newPassword);
    if (needReauth) {
      this.store.clearSession();
    }
    return needReauth;
  }

  async deleteAccount(currentPassword: string): Promise<void> {
    await this.api.deleteAccount(currentPassword);
    this.store.clearSession();
  }

  private cachedResult(): AuthResult {
    return {
      accessToken: this.store.getAccessToken(),
      refreshToken: this.store.getRefreshToken(),
      expiresIn: 0,
      user: { id: this.store.getUserId(), email: this.store.getEmail() },
      device: { id: this.store.getDeviceId(), name: 'HarmonyOS' }
    };
  }
}
