/**
 * WindowContext —— 页面/组件侧的「我在哪个窗口」解析与窗口级 LocalStorage（多窗口改造）。
 *
 * 每个 UIAbility 在 onCreate 建一份 LocalStorage（至少含 windowKey），经
 * windowStage.loadContent(path, storage) 绑定为该窗口的共享存储；页面与组件用
 * UIContext.getSharedLocalStorage()（API 12）取回，从而知道自己所在窗口：
 *   - 主窗口（EntryAbility）：windowKey = MAIN_WINDOW_KEY；
 *   - 终端窗口：windowKey = specified key，另带启动参数（hostId / sessionIds）。
 * 取不到（旧路径 / 预览器）一律按主窗口处理，保证单窗口行为不变。
 */

import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  MAIN_WINDOW_KEY,
  STORAGE_KEY_HOST_ID,
  STORAGE_KEY_LAUNCH_CONSUMED,
  STORAGE_KEY_SESSION_IDS,
  STORAGE_KEY_WINDOW,
  TerminalWindowLaunch,
  splitSessionIds
} from '../constants/WindowKeys';
import { Logger } from './Logger';

const LOG_TAG: string = 'WindowContext';

/** 建窗口级 LocalStorage（Ability.onCreate）；launch 为终端窗口启动参数，主窗口传 null */
export function createWindowStorage(windowKey: string, launch: TerminalWindowLaunch | null): LocalStorage {
  const storage: LocalStorage = new LocalStorage();
  storage.setOrCreate<string>(STORAGE_KEY_WINDOW, windowKey);
  if (launch !== null) {
    storage.setOrCreate<string>(STORAGE_KEY_HOST_ID, launch.hostId);
    storage.setOrCreate<string>(STORAGE_KEY_SESSION_IDS, launch.sessionIds.join(','));
    storage.setOrCreate<boolean>(STORAGE_KEY_LAUNCH_CONSUMED, false);
  }
  return storage;
}

function sharedStorageOf(ui: UIContext): LocalStorage | undefined {
  try {
    return ui.getSharedLocalStorage();
  } catch (err) {
    Logger.warn(`读取窗口共享存储失败：${JSON.stringify(err)}`, LOG_TAG);
    return undefined;
  }
}

/** 组件所在窗口的 windowKey（取不到按主窗口） */
export function windowKeyOf(ui: UIContext): string {
  const storage: LocalStorage | undefined = sharedStorageOf(ui);
  if (storage === undefined) {
    return MAIN_WINDOW_KEY;
  }
  const key: string | undefined = storage.get<string>(STORAGE_KEY_WINDOW);
  return key !== undefined && key.length > 0 ? key : MAIN_WINDOW_KEY;
}

/**
 * 取走终端窗口的启动参数（只给第一个来取的终端页；之后返回 null）。
 * 主窗口没有启动参数，恒为 null（终端页回退 router.getParams()）。
 */
export function takeWindowLaunch(ui: UIContext): TerminalWindowLaunch | null {
  const storage: LocalStorage | undefined = sharedStorageOf(ui);
  if (storage === undefined) {
    return null;
  }
  const consumed: boolean | undefined = storage.get<boolean>(STORAGE_KEY_LAUNCH_CONSUMED);
  if (consumed === undefined || consumed) {
    return null;
  }
  storage.set<boolean>(STORAGE_KEY_LAUNCH_CONSUMED, true);
  const hostId: string = storage.get<string>(STORAGE_KEY_HOST_ID) ?? '';
  const sessionIds: string[] = splitSessionIds(storage.get<string>(STORAGE_KEY_SESSION_IDS) ?? '');
  const key: string = storage.get<string>(STORAGE_KEY_WINDOW) ?? '';
  return { windowKey: key, hostId: hostId, sessionIds: sessionIds };
}

/** 组件宿主 UIAbilityContext（startAbility / terminateSelf 用）；取不到为 null */
export function abilityContextOf(ui: UIContext): common.UIAbilityContext | null {
  try {
    const context: common.Context | undefined = ui.getHostContext();
    return context === undefined ? null : context as common.UIAbilityContext;
  } catch (err) {
    Logger.warn(`读取宿主 Ability 上下文失败：${JSON.stringify(err)}`, LOG_TAG);
    return null;
  }
}

/**
 * 是否提供「在新窗口打开」入口：只在平板 / 2in1 上出现。手机上虽然也能起第二个
 * 实例（最近任务里多一张卡片），但交互与改造前不同，故手机保持原样不露入口。
 */
export function supportsMultiWindow(): boolean {
  try {
    const type: string = deviceInfo.deviceType;
    return type === 'tablet' || type === '2in1';
  } catch (_err) {
    return false;
  }
}
