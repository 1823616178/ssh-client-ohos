/**
 * 模块级 AbilityStage（任务 P1，DESIGN §7.5「系统回收前收到通知则优雅关闭会话并保存状态」）。
 *
 * 存在的唯一理由是 onMemoryLevel —— UIAbility 没有这个回调，只有 AbilityStage 有。
 * 内存告急时与其等系统把进程杀掉（留下一批没发 SSH disconnect 的半死连接，
 * 服务端要等自己的 keepalive 超时才清理），不如自己优雅收场：
 * 断连接但保留会话面孔与窗格绑定，回前台原地重连。
 */

import { AbilityConstant, AbilityStage } from '@kit.AbilityKit';
import { Logger } from '../common/utils/Logger';
import { BackgroundKeepAlive } from '../service/background/BackgroundKeepAlive';

export default class EntryAbilityStage extends AbilityStage {
  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    // 只对 CRITICAL 两档动手：MODERATE/LOW 系统只是提示回收缓存，断用户的会话过头了
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL ||
      level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_CRITICAL) {
      Logger.warn(`系统内存告急（level=${level}），优雅断开会话`, 'AbilityStage');
      BackgroundKeepAlive.get().notifyMemoryCritical();
    }
  }
}
