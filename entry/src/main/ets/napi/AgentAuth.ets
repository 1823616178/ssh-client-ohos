/**
 * 应用内 SSH Agent 的 ArkTS 侧窄接口 —— 任务 N9 接线 + U3 keygen（DESIGN §7.1）。
 *
 * native 侧（cpp/ssh/agent.h + bridge/agent_bridge.*）已实现内存密钥托管与
 * ed25519 keygen；本文件只做「SessionManager / KeyManager 可注入」的薄封装：
 *   - AgentAuthPort：SessionManager/KeyManager 用到的最小方法集，单测注入 fake；
 *   - NativeAgentAuthPort：生产实现，转发 SshAgentBridge → libssh_core.so；
 *   - agentKeyIdForHost：主机 agent 认证的 keyId 约定（纯函数）。
 *
 * keyId 约定：主机 authType==='agent' 时，托管标识取 host.id。
 * 首次连接若 agent 中还没有该 keyId，SessionManager 会从 CredentialStore
 * 读 private_key/passphrase 并 unlock 进 agent；之后同一主机的后续会话
 * 直接 authenticateAgent，实现 N9「解锁一次后第二个会话免密」。
 * 密钥管理页也可按同一 keyId 提前解锁（unlock 到 host.id 或密钥自身 id）。
 */

import { HostProfile } from '../common/model/models';
import { NativeAgentKeygenResult, SshAgentBridge } from './SshNative';

/** SessionManager / KeyManager 可注入的 agent 窄接口（生产 = NativeAgentAuthPort，测试 = fake） */
export interface AgentAuthPort {
  /** keyId 是否锁定（不存在/已清除/已超时 → true） */
  isLocked(keyId: string): boolean;
  /** 解锁并托管；false = 粗检不通过 / 未受理 */
  unlock(keyId: string, privateKey: string, passphrase: string): boolean;
  /** 锁定指定 keyId；不存在返回 false（幂等语义由调用方忽略返回值） */
  lock(keyId: string): boolean;
  /** 锁定全部（删除密钥 / 退出清理） */
  lockAll(): void;
  /** 当前托管条数（诊断与测试） */
  keyCount(): number;
  /** U3：native 是否具备 agentKeygen（UI 启用生成按钮） */
  keygenSupported(): boolean;
  /**
   * U3：生成 ed25519 密钥对。
   * 私钥 PKCS#8 PEM + OpenSSH 公钥行；失败/未实现返回 null。
   */
  keygen(comment: string, passphrase: string): NativeAgentKeygenResult | null;
}

/** 生产实现：转发到 native 进程级 agent */
export class NativeAgentAuthPort implements AgentAuthPort {
  isLocked(keyId: string): boolean {
    return SshAgentBridge.isLocked(keyId);
  }

  unlock(keyId: string, privateKey: string, passphrase: string): boolean {
    return SshAgentBridge.unlock(keyId, privateKey, passphrase);
  }

  lock(keyId: string): boolean {
    return SshAgentBridge.lock(keyId);
  }

  lockAll(): void {
    SshAgentBridge.lockAll();
  }

  keyCount(): number {
    return SshAgentBridge.keyCount();
  }

  keygenSupported(): boolean {
    return SshAgentBridge.keygenSupported();
  }

  keygen(comment: string, passphrase: string): NativeAgentKeygenResult | null {
    return SshAgentBridge.keygen(comment, passphrase);
  }
}

/**
 * 主机 agent 认证的 keyId 约定（纯函数，可测）。
 * 空 id 返回空串——调用方应视为非法主机配置并拒绝拨号。
 */
export function agentKeyIdForHost(host: HostProfile): string {
  return host.id;
}
