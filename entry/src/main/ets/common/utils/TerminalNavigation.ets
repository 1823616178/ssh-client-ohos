/**
 * 终端路由导航辅助 —— U5 双栏 residual（Index lg 右栏 / HostList 点按统一出口）。
 *
 * 与 HostListPage.openTerminal / TerminalPage.parseTerminalRouteParams 同参数口径：
 *   hostId / sessionId 二选一；sessionId 优先（TerminalViewModel.start 语义）。
 * Index lg 右栏与全页 push 共用本模块，避免散落字符串字面量。
 *
 * 多窗口改造：
 *   - 页内跳转一律走调用方 UIContext 的 Router（全局 router 在多实例下绑定哪个窗口不确定）；
 *   - openTerminalWindow：startAbility 拉起 TerminalWindowAbility（launchType=specified），
 *     每次一个新的系统窗口；reuseWindow 时同一会话复用已有窗口（onNewWant）。
 */
import { Want, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import {
  MAIN_ABILITY_NAME,
  MAIN_WINDOW_KEY,
  TERMINAL_WINDOW_ABILITY_NAME,
  buildTerminalWindowParams,
  specifiedKeyFor
} from '../constants/WindowKeys';
import { Logger } from './Logger';

const LOG_TAG: string = 'TerminalNavigation';

export const TERMINAL_PAGE_URL: string = 'pages/TerminalPage';

/** 终端页路由参数（Record 形式，arkts 禁空对象字面量直接赋键，调用方用 builder） */
export function buildTerminalRouteParams(hostId: string, sessionId: string): Record<string, Object> {
  const params: Record<string, Object> = {};
  if (hostId.length > 0) {
    params['hostId'] = hostId;
  }
  if (sessionId.length > 0) {
    params['sessionId'] = sessionId;
  }
  return params;
}

/** push 全页 TerminalPage（hostId 新拨；sessionId 复用既有会话） */
export function pushTerminalPage(uiContext: UIContext, hostId: string, sessionId: string): void {
  const params: Record<string, Object> = buildTerminalRouteParams(hostId, sessionId);
  uiContext.getRouter().pushUrl({ url: TERMINAL_PAGE_URL, params: params }).catch((err: Object) => {
    Logger.error(`push TerminalPage 失败: ${JSON.stringify(err)}`, LOG_TAG);
  });
}

/** 按 hostId 打开终端（主机列表点按 / 双栏「全页打开」） */
export function pushTerminalForHost(uiContext: UIContext, hostId: string): void {
  pushTerminalPage(uiContext, hostId, '');
}

/** 按 sessionId 打开终端（快速连接受理后） */
export function pushTerminalForSession(uiContext: UIContext, sessionId: string): void {
  pushTerminalPage(uiContext, '', sessionId);
}

/**
 * 在新的系统窗口里打开终端（平板 / 2in1）：hostId 新拨，或接管 sessionIds（首个为主会话，
 * 其余各开一个标签——会话须已从原窗格解绑，见 TerminalViewModel.detachTab）。
 * reuseWindow=true 且只带一个会话时，同一会话已有窗口则拉到前台而不新开。
 * 返回是否拉起成功（失败只记日志，调用方负责回滚）。
 */
export function openTerminalWindow(context: common.UIAbilityContext, hostId: string, sessionIds: string[],
  reuseWindow: boolean): Promise<boolean> {
  const windowKey: string = specifiedKeyFor(sessionIds, reuseWindow, (): string => util.generateRandomUUID());
  return startTerminalWindow(context, windowKey, hostId, sessionIds);
}

/**
 * 把某个会话所在的窗口带到前台（多窗口：会话正显示在别的窗口时，不抢绑定而是切过去）。
 * windowKey 为终端窗口：按原 key 拉起 → 命中已有 specified 实例 → onNewWant 聚焦该会话；
 * windowKey 为主窗口：拉起 EntryAbility（singleton，仅回到前台）。
 */
export function focusWindowOfSession(context: common.UIAbilityContext, windowKey: string,
  sessionId: string): Promise<boolean> {
  if (windowKey === MAIN_WINDOW_KEY) {
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: MAIN_ABILITY_NAME
    };
    return startWant(context, want);
  }
  return startTerminalWindow(context, windowKey, '', [sessionId]);
}

function startTerminalWindow(context: common.UIAbilityContext, windowKey: string, hostId: string,
  sessionIds: string[]): Promise<boolean> {
  const want: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: TERMINAL_WINDOW_ABILITY_NAME,
    parameters: buildTerminalWindowParams(windowKey, hostId, sessionIds)
  };
  Logger.info(`拉起终端窗口 ${windowKey}（会话 ${sessionIds.length} 个，hostId=${hostId.length > 0 ? '有' : '无'}）`,
    LOG_TAG);
  return startWant(context, want);
}

function startWant(context: common.UIAbilityContext, want: Want): Promise<boolean> {
  try {
    return context.startAbility(want).then((): boolean => true).catch((err: Object): boolean => {
      Logger.error(`拉起窗口失败: ${JSON.stringify(err)}`, LOG_TAG);
      return false;
    });
  } catch (err) {
    Logger.error(`拉起窗口异常: ${JSON.stringify(err)}`, LOG_TAG);
    return Promise.resolve(false);
  }
}
