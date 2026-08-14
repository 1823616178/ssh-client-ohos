import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../common/utils/Logger';
import { AppDatabase } from '../repository/AppDatabase';
import { SettingsRepository } from '../repository/SettingsRepository';
import { SessionManager } from '../service/SessionManager';
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
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    // 应用退出/系统回收：优雅关闭全部 SSH 会话（C4，DESIGN §7.5；幂等，native 后台完成回收）
    SessionManager.get().closeAll();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

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
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}