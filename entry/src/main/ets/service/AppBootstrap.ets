/**
 * AppBootstrap —— 进程级一次性初始化与收尾（多窗口改造）。
 *
 * 改造前这些都写在 EntryAbility.onCreate / onDestroy 里：只有一个 Ability 时没问题；
 * 多个 UIAbility 实例（终端窗口）共用一个进程后，每开一个窗口都会重复初始化，
 * 关任意一个窗口就 closeAll 把所有窗口的会话一起断掉。现在：
 *   - ensureStarted：首个窗口创建时执行一次（日志 / 设置 / 数据库 / 字体 / 同步 /
 *     后台保活 / 主题色模式），之后幂等；
 *   - onWindowDestroyed：WindowRegistry 引用计数归零（最后一个窗口销毁）才走
 *     shutdown（停保活 → 停常亮 → 优雅关闭全部会话 → 停同步，与改造前 onDestroy 同序）；
 *     否则若销毁的恰是长时任务所属的 Ability，把后台保活移交给仍存活的窗口
 *     （长时任务绑定在申请它的 Ability 上，宿主销毁后不能再依赖它）。
 *   - 应用级前后台：订阅 WindowRegistry，统一驱动 SyncRuntime / BackgroundKeepAlive
 *     （窗口级的屏幕常亮仍由各窗口自己的 onForeground/onBackground 驱动）。
 *
 * 为什么不放进 AbilityStage.onCreate：BackgroundKeepAlive 的长时任务申请需要
 * UIAbilityContext（backgroundTaskManager.startBackgroundRunning），字体注册也属
 * UI 侧能力；保守起见仍在首个 UIAbility 的 onCreate 里、用它的 context 执行。
 */

import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { Logger } from '../common/utils/Logger';
import { AppDatabase } from '../repository/AppDatabase';
import { SettingsRepository } from '../repository/SettingsRepository';
import { registerTerminalFonts } from '../theme/FontService';
import { themeModeToColorModeName } from '../theme/ThemePresets';
import { ScreenAwake } from './ScreenAwake';
import { SessionManager } from './SessionManager';
import { BackgroundKeepAlive } from './background/BackgroundKeepAlive';
import { SyncRuntime } from './sync/SyncRuntime';
import { WindowRegistry } from './window/WindowRegistry';

const LOG_TAG: string = 'App';

export class AppBootstrap {
  private static started: boolean = false;
  private static visibilityHooked: boolean = false;
  /** 后台保活长时任务所属窗口（其 UIAbilityContext 用于申请长时任务） */
  private static keepAliveOwnerKey: string = '';

  /** 首个窗口创建时调用（幂等）：与改造前 EntryAbility.onCreate 同序 */
  static ensureStarted(windowKey: string, context: common.UIAbilityContext): void {
    AppBootstrap.hookAppVisibility();
    if (AppBootstrap.started) {
      return;
    }
    AppBootstrap.started = true;
    // 初始化日志（X4）：注入上下文以启用 filesDir/logs 文件输出，失败自动降级为仅 hilog
    Logger.init(context);
    Logger.info('应用启动', LOG_TAG);
    // 初始化应用设置（C3）：获取 preferences store，并对缺失键写入默认值（不覆盖已有值）
    SettingsRepository.init(context);
    SettingsRepository.ensureDefaults();
    // 初始化数据库（C1）：打开/迁移 ssh_client.db，失败只记日志不阻断启动
    AppDatabase.init(context);
    // 注册终端内置字体（T5）：JetBrains Mono + Sarasa Term SC；失败只记日志不阻断启动
    registerTerminalFonts();
    // 同步运行时（S6）：保存防抖 / 轮询 / 网络恢复；start() 内部先 hydrate 账号 token（asset），fire-and-forget
    void SyncRuntime.get().start();
    // 后台保活（P1，§7.5）：长时任务 + 息屏策略 + 切网收敛；系统能力缺失时内部降级，不阻断启动
    BackgroundKeepAlive.get().start(context);
    AppBootstrap.keepAliveOwnerKey = windowKey;
    AppBootstrap.applyColorMode(context);
  }

  /**
   * 窗口销毁（Ability.onDestroy）。返回剩余窗口数。
   * 只有最后一个窗口销毁才关闭全部会话；其余窗口的会话不受影响。
   */
  static onWindowDestroyed(windowKey: string): number {
    const registry: WindowRegistry = WindowRegistry.get();
    const remaining: number = registry.unregister(windowKey);
    if (remaining === 0) {
      AppBootstrap.shutdown();
      return 0;
    }
    if (AppBootstrap.started && windowKey === AppBootstrap.keepAliveOwnerKey) {
      AppBootstrap.handOverKeepAlive(registry.firstOtherKey(windowKey));
    }
    return remaining;
  }

  /** 应用真正退出：停后台保活（还电、摘系统监听）→ 停常亮 → 优雅关闭全部 SSH 会话 → 停同步 */
  private static shutdown(): void {
    BackgroundKeepAlive.get().stop();
    ScreenAwake.stopAll();
    SessionManager.get().closeAll();
    SyncRuntime.get().stop();
    AppBootstrap.started = false;
    AppBootstrap.keepAliveOwnerKey = '';
    Logger.info('最后一个窗口已销毁，应用资源已收尾', LOG_TAG);
  }

  /** 长时任务宿主窗口销毁：先还回旧任务，再用存活窗口的 context 重新起服务 */
  private static handOverKeepAlive(nextKey: string): void {
    const context: common.UIAbilityContext | null =
      nextKey.length > 0 ? WindowRegistry.get().contextOf(nextKey) : null;
    BackgroundKeepAlive.get().stop();
    if (context === null) {
      AppBootstrap.keepAliveOwnerKey = '';
      Logger.warn('后台保活宿主窗口已销毁且无可移交窗口，后台保活暂停', LOG_TAG);
      return;
    }
    BackgroundKeepAlive.get().start(context);
    AppBootstrap.keepAliveOwnerKey = nextKey;
    Logger.info(`后台保活已移交给窗口 ${nextKey}`, LOG_TAG);
  }

  /** 应用级前后台 → 同步与后台保活（只挂一次；单窗口时与改造前逐拍一致） */
  private static hookAppVisibility(): void {
    if (AppBootstrap.visibilityHooked) {
      return;
    }
    AppBootstrap.visibilityHooked = true;
    WindowRegistry.get().addAppVisibilityListener((foreground: boolean): void => {
      if (foreground) {
        SyncRuntime.get().notifyForeground();
        // P1：还电、解除静默、恢复被策略挂起的会话；没挂起过也会做一次切网收敛
        BackgroundKeepAlive.get().notifyForeground();
      } else {
        // P1：按设置申请长时任务保活，或走宽限窗口优雅断开（§7.5，绝不静默失联）
        BackgroundKeepAlive.get().notifyBackground();
      }
    });
  }

  /**
   * A6：按 SettingsRepository.themeMode 应用 colorMode（system → NOT_SET 跟随系统；
   * dark/light 强制；resources/dark/element 的 token 覆盖随之生效）。应用级设置，执行一次。
   */
  private static applyColorMode(context: common.UIAbilityContext): void {
    try {
      const colorModeName = themeModeToColorModeName(SettingsRepository.getThemeMode());
      let colorMode: ConfigurationConstant.ColorMode =
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (colorModeName === 'dark') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      } else if (colorModeName === 'light') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      }
      context.getApplicationContext().setColorMode(colorMode);
      Logger.info(`A6 themeMode 应用 colorMode=${colorModeName}`, LOG_TAG);
    } catch (err) {
      Logger.error(`Failed to set colorMode. Cause: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }
}
