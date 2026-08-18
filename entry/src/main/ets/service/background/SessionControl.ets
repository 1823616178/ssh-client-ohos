/**
 * 后台保活看会话的窄接口（任务 P1）。
 *
 * 单独成文件有两个理由：
 *   1. ArkTS 不做结构性类型匹配（arkts-no-structural-typing），SessionManager 必须
 *      显式 implements 才能喂给策略外壳，接口若定义在 BackgroundKeepAlive.ets 里
 *      就成了 SessionManager ↔ BackgroundKeepAlive 的循环 import；
 *   2. 单测注入 fake 时只需实现这五个方法 + 两个监听口，不必伪造整个 SessionManager。
 */
/** 会话数/状态变化监听器 */
export type SessionCountListener = () => void;

export interface SessionControl {
  /** 活跃会话数（连接中/已建立/退避重连中；策略挂起的不算） */
  activeSessionCount(): number;
  /** 静默模式：后台抑制 dirty 唤醒（事件仍透传） */
  setQuiet(quiet: boolean): void;
  /** 默认网变化后的收敛：退避提前重连 + established 主动探测。返回被处理的会话数 */
  notifyNetworkChanged(): number;
  /** 按策略优雅断开全部会话（保留会话面孔与窗格绑定）。返回被挂起的会话数 */
  suspendAllForPolicy(reason: string): number;
  /** 恢复被策略挂起的会话。返回被恢复的会话数 */
  resumeAllSuspended(): number;
  /** 会话集合或状态变化时回调（策略机据此及时申请/释放长时任务） */
  addSessionCountListener(listener: SessionCountListener): void;
  removeSessionCountListener(listener: SessionCountListener): void;
}
