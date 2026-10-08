import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { MAIN_WINDOW_KEY } from '../common/constants/WindowKeys';
import { createWindowStorage } from '../common/utils/WindowContext';
import { WindowLifecycle } from '../service/window/WindowLifecycle';

const DOMAIN = 0x0000;

/**
 * 主窗口（launchType 缺省 singleton，仍是唯一的主机列表入口）。
 *
 * 多窗口改造：进程级初始化与收尾、前后台、屏幕常亮都改走 WindowLifecycle——
 * 终端窗口（TerminalWindowAbility）与本 Ability 共用一套记账，关闭任意一个
 * 窗口不再 closeAll，只有最后一个窗口销毁才收尾。单窗口时行为与改造前逐拍一致。
 */
export default class EntryAbility extends UIAbility {
  /** 本窗口的 LocalStorage（windowKey = MAIN_WINDOW_KEY），loadContent 时绑定给页面 */
  private storage: LocalStorage = createWindowStorage(MAIN_WINDOW_KEY, null);
  private windowStage: window.WindowStage | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 进程级一次性初始化（日志 / 设置 / 数据库 / 字体 / 同步 / 后台保活 / colorMode）+ 窗口登记
    WindowLifecycle.onAbilityCreate(MAIN_WINDOW_KEY, this.context);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    // 引用计数减一：最后一个窗口销毁才停后台保活、优雅关闭全部 SSH 会话
    // （C4，DESIGN §7.5；幂等，native 后台完成回收）；还有终端窗口时它们的会话不受影响
    WindowLifecycle.onAbilityDestroy(MAIN_WINDOW_KEY);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;
    // 屏幕常亮 / 窗口底色 / 窗口获焦订阅（本窗口）
    WindowLifecycle.onWindowStageCreate(MAIN_WINDOW_KEY, windowStage);

    windowStage.loadContent('pages/Index', this.storage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    WindowLifecycle.onWindowStageDestroy(MAIN_WINDOW_KEY, this.windowStage);
    this.windowStage = null;
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground：应用级前后台由 WindowRegistry 计数后驱动同步 / 后台保活
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    WindowLifecycle.onForeground(MAIN_WINDOW_KEY);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    WindowLifecycle.onBackground(MAIN_WINDOW_KEY);
  }
}
