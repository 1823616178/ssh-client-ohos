/**
 * 默认网监听（任务 P1，DESIGN §7.5「网络切换…主动触发重连而不是干等超时」）。
 *
 * 为什么要单独一份：切网感知有两个消费方——会话层（切网后要在 5 s 内收敛，
 * 见 SessionManager.notifyNetworkChanged）与同步层（网络恢复要补一次同步，S6）。
 * 各自 createNetConnection 会注册两份系统回调，白费一份订阅，故收拢成单例广播。
 *
 * 「切网」的判据（isNetworkSwitch，纯函数、可单测）：
 *   netId 变了，或承载类型变了（WiFi ⇄ 蜂窝）。
 * 只看 netAvailable 是不够的：WiFi ⇄ 蜂窝切换未必先发 netLost，多数是默认网
 * 直接换一个 netId；而同一张网的 capability 抖动（信号强弱、计费属性变化）会反复
 * 发 netCapabilitiesChange，不能每次都当切网去踢会话。
 */

import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/utils/Logger';

const LOG_TAG: string = 'NetworkWatcher';

/** 默认网快照：netId + 主承载类型（connection.NetBearType，-1 = 未知） */
export interface NetSnapshot {
  netId: number;
  bearerType: number;
}

/** 未知网（尚未观测到默认网时的初值） */
export const UNKNOWN_NET: NetSnapshot = { netId: -1, bearerType: -1 };

/**
 * 是否算一次「切网」（纯函数）：首次观测到网络、netId 变化、承载类型变化都算；
 * 同一张网重复上报（capability 抖动）不算。
 */
export function isNetworkSwitch(previous: NetSnapshot, next: NetSnapshot): boolean {
  if (next.netId < 0) {
    return false; // 无效上报，忽略
  }
  if (previous.netId < 0) {
    return true; // 首次拿到默认网
  }
  if (previous.netId !== next.netId) {
    return true;
  }
  // 同一张网上承载类型「从未知变已知」不算切换：真机启动时 netAvailable 先到
  // （只有 netId，承载未知 = -1），紧接着 netCapabilitiesChange 才补上 bearer=WIFI，
  // 若按变化算会在启动瞬间白白多踢一次全部会话
  if (previous.bearerType < 0 || next.bearerType < 0) {
    return false;
  }
  return previous.bearerType !== next.bearerType;
}

/** 从 NetCapabilities 取主承载类型；取不到返回 -1 */
function bearerOf(caps: connection.NetCapabilities | undefined): number {
  const types: connection.NetBearType[] | undefined = caps?.bearerTypes;
  if (types === undefined || types.length === 0) {
    return -1;
  }
  return types[0] as number;
}

export type NetworkChangeListener = (snapshot: NetSnapshot) => void;
export type NetworkLostListener = () => void;

export class NetworkWatcher {
  private static instance: NetworkWatcher | null = null;

  static get(): NetworkWatcher {
    if (NetworkWatcher.instance === null) {
      NetworkWatcher.instance = new NetworkWatcher();
    }
    return NetworkWatcher.instance;
  }

  private net: connection.NetConnection | null = null;
  private current: NetSnapshot = UNKNOWN_NET;
  private readonly changeListeners: NetworkChangeListener[] = [];
  private readonly lostListeners: NetworkLostListener[] = [];

  /** 当前默认网快照（未观测到时为 UNKNOWN_NET） */
  get snapshot(): NetSnapshot {
    return this.current;
  }

  addChangeListener(listener: NetworkChangeListener): void {
    this.changeListeners.push(listener);
  }

  removeChangeListener(listener: NetworkChangeListener): void {
    const index: number = this.changeListeners.indexOf(listener);
    if (index >= 0) {
      this.changeListeners.splice(index, 1);
    }
  }

  addLostListener(listener: NetworkLostListener): void {
    this.lostListeners.push(listener);
  }

  removeLostListener(listener: NetworkLostListener): void {
    const index: number = this.lostListeners.indexOf(listener);
    if (index >= 0) {
      this.lostListeners.splice(index, 1);
    }
  }

  /** 起监听（幂等）；系统能力不可用只记日志降级，不阻断应用 */
  start(): void {
    if (this.net !== null) {
      return;
    }
    try {
      const net: connection.NetConnection = connection.createNetConnection();
      net.register((err: BusinessError) => {
        if (err !== undefined && err !== null) {
          Logger.warn(`网络监听注册失败: ${JSON.stringify(err)}`, LOG_TAG);
        }
      });
      net.on('netAvailable', (handle: connection.NetHandle): void => {
        this.onNet(handle.netId, this.current.bearerType);
      });
      net.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo): void => {
        this.onNet(info.netHandle.netId, bearerOf(info.netCap));
      });
      net.on('netLost', (_handle: connection.NetHandle): void => {
        this.current = UNKNOWN_NET;
        for (const listener of this.lostListeners) {
          this.safeLost(listener);
        }
      });
      this.net = net;
    } catch (err) {
      Logger.warn(`网络监听不可用: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 停监听（幂等） */
  stop(): void {
    if (this.net === null) {
      return;
    }
    try {
      this.net.unregister((err: BusinessError) => {
        if (err !== undefined && err !== null) {
          Logger.warn(`网络监听注销失败: ${JSON.stringify(err)}`, LOG_TAG);
        }
      });
    } catch (_err) {
    }
    this.net = null;
    this.current = UNKNOWN_NET;
  }

  private onNet(netId: number, bearerType: number): void {
    const next: NetSnapshot = { netId: netId, bearerType: bearerType };
    if (!isNetworkSwitch(this.current, next)) {
      this.current = next; // 同一张网，只更新快照，不惊动订阅者
      return;
    }
    this.current = next;
    Logger.info(`默认网变化：netId=${netId} bearer=${bearerType}`, LOG_TAG);
    for (const listener of this.changeListeners) {
      this.safeChange(listener, next);
    }
  }

  private safeChange(listener: NetworkChangeListener, snapshot: NetSnapshot): void {
    try {
      listener(snapshot);
    } catch (err) {
      Logger.error(`网络变化监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  private safeLost(listener: NetworkLostListener): void {
    try {
      listener();
    } catch (err) {
      Logger.error(`网络断开监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }
}
