import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../common/utils/Logger';
import { AppDatabase } from '../repository/AppDatabase';
import { SettingsRepository } from '../repository/SettingsRepository';
import { SessionManager } from '../service/SessionManager';
import { BackgroundKeepAlive } from '../service/background/BackgroundKeepAlive';
import { SyncRuntime } from '../service/sync/SyncRuntime';
import { registerTerminalFonts } from '../theme/FontService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 初始化日志（X4）：注入上下文以启用 filesDir/logs 文件输出，失败自动降级为仅 hilog
    Logger.init(this.context);
    Logger.info('应用启动', 'App');
    // 初始化应用设置（C3）：获取 preferences store，并对缺失键写入默认值（不覆盖已有值）
    SettingsRepository.init(this.context);
    SettingsRepository.ensureDefaults();
    // 初始化数据库（C1）：打开/迁移 ssh_client.db，失败只记日志不阻断启动
    AppDatabase.init(this.context);
    // 注册终端内置字体（T5）：JetBrains Mono + Sarasa Term SC；失败只记日志不阻断启动
    registerTerminalFonts();
    // 同步运行时（S6）：保存防抖 / 轮询 / 网络恢复；start() 内部先 hydrate 账号 token（asset），fire-and-forget
    void SyncRuntime.get().start();
    // 后台保活（P1，§7.5）：长时任务 + 息屏策略 + 切网收敛；系统能力缺失时内部降级，不阻断启动
    BackgroundKeepAlive.get().start(this.context);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    // 应用退出/系统回收：先停后台保活（还电、摘系统监听），再优雅关闭全部 SSH 会话
    // （C4，DESIGN §7.5；幂等，native 后台完成回收）
    BackgroundKeepAlive.get().stop();
    SessionManager.get().closeAll();
    SyncRuntime.get().stop();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.getMainWindow().then((win: window.Window) => {
      try {
        win.setWindowBackgroundColor('#03060A');
      } catch (_e) {
      }
    }).catch((_err: Object) => {
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    SyncRuntime.get().notifyForeground();
    // P1：还电、解除静默、恢复被策略挂起的会话；没挂起过也会做一次切网收敛
    BackgroundKeepAlive.get().notifyForeground();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // P1：按设置申请长时任务保活，或走宽限窗口优雅断开（§7.5，绝不静默失联）
    BackgroundKeepAlive.get().notifyBackground();
  }
}