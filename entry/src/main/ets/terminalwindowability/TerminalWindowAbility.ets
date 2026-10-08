import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import {
  SPECIFIED_KEY_NEW_PREFIX,
  TerminalWindowLaunch,
  parseTerminalWindowParams
} from '../common/constants/WindowKeys';
import { createWindowStorage } from '../common/utils/WindowContext';
import { WindowLifecycle } from '../service/window/WindowLifecycle';
import { WindowRegistry } from '../service/window/WindowRegistry';

const DOMAIN = 0x0000;

/**
 * 独立终端窗口（多窗口方案 A）。
 *
 * launchType = specified：每个实例由 EntryAbilityStage.onAcceptWant 返回的 key 区分——
 *   - `new:<uuid>`：每次新开一个窗口（主机列表「新窗口」/ 标签「在新窗口打开」）；
 *   - `session:<id>`：同一会话复用已有窗口，再次拉起走 onNewWant。
 * 发起方把同一个 key 放进 want.parameters.windowKey，本 Ability 用它作为 windowKey，
 * 与 onAcceptWant 口径一致。页面直接加载 TerminalPage，启动参数（hostId / sessionIds）
 * 经窗口级 LocalStorage 交给页面（router.getParams 在根页面上拿不到这些参数）。
 *
 * 只能由本应用拉起（exported=false）；进程内会话池与主窗口共享。
 */
export default class TerminalWindowAbility extends UIAbility {
  private windowKey: string = '';
  private storage: LocalStorage | null = null;
  private windowStage: window.WindowStage | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const launch: TerminalWindowLaunch = parseTerminalWindowParams(want.parameters);
    this.windowKey = launch.windowKey.length > 0 ? launch.windowKey :
      `${SPECIFIED_KEY_NEW_PREFIX}${util.generateRandomUUID()}`;
    const resolved: TerminalWindowLaunch = {
      windowKey: this.windowKey,
      hostId: launch.hostId,
      sessionIds: launch.sessionIds
    };
    this.storage = createWindowStorage(this.windowKey, resolved);
    // 进程已由主窗口初始化时这里只做登记；若系统直接恢复本窗口，则由它完成一次性初始化
    WindowLifecycle.onAbilityCreate(this.windowKey, this.context);
    hilog.info(DOMAIN, 'testTag', 'TerminalWindowAbility onCreate %{public}s', this.windowKey);
  }

  /** 同一 specified key 再次拉起（复用窗口）：把新的打开请求投递给本窗口的终端页 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const launch: TerminalWindowLaunch = parseTerminalWindowParams(want.parameters);
    if (launch.hostId.length === 0 && launch.sessionIds.length === 0) {
      return;
    }
    WindowRegistry.get().postOpenRequest(this.windowKey, {
      hostId: launch.hostId,
      sessionIds: launch.sessionIds
    });
  }

  onDestroy(): void {
    // 只注销本窗口；其它窗口仍在时会话保留（终端页 aboutToDisappear 已把会话转入后台）
    WindowLifecycle.onAbilityDestroy(this.windowKey);
    hilog.info(DOMAIN, 'testTag', 'TerminalWindowAbility onDestroy %{public}s', this.windowKey);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    WindowLifecycle.onWindowStageCreate(this.windowKey, windowStage);
    const storage: LocalStorage = this.storage ?? createWindowStorage(this.windowKey, null);
    windowStage.loadContent('pages/TerminalPage', storage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the terminal window content. Cause: %{public}s',
          JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the terminal window content.');
    });
  }

  onWindowStageDestroy(): void {
    WindowLifecycle.onWindowStageDestroy(this.windowKey, this.windowStage);
    this.windowStage = null;
  }

  onForeground(): void {
    WindowLifecycle.onForeground(this.windowKey);
  }

  onBackground(): void {
    WindowLifecycle.onBackground(this.windowKey);
  }
}
