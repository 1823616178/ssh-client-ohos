/**
 * 终端路由导航辅助 —— U5 双栏 residual（Index lg 右栏 / HostList 点按统一出口）。
 *
 * 与 HostListPage.openTerminal / TerminalPage.parseTerminalRouteParams 同参数口径：
 *   hostId / sessionId 二选一；sessionId 优先（TerminalViewModel.start 语义）。
 * Index lg 右栏与全页 push 共用本模块，避免散落字符串字面量。
 */
import { router } from '@kit.ArkUI';
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
export function pushTerminalPage(hostId: string, sessionId: string): void {
  const params: Record<string, Object> = buildTerminalRouteParams(hostId, sessionId);
  router.pushUrl({ url: TERMINAL_PAGE_URL, params: params }).catch((err: Object) => {
    Logger.error(`push TerminalPage 失败: ${JSON.stringify(err)}`, LOG_TAG);
  });
}

/** 按 hostId 打开终端（主机列表点按 / 双栏「全页打开」） */
export function pushTerminalForHost(hostId: string): void {
  pushTerminalPage(hostId, '');
}

/** 按 sessionId 打开终端（快速连接受理后） */
export function pushTerminalForSession(sessionId: string): void {
  pushTerminalPage('', sessionId);
}
