/**
 * Pasteboard —— 终端粘贴/复制助手（任务 T8，DESIGN §4.4「粘贴」：从
 * @ohos.pasteboard 读取、含换行时提示括号粘贴）。
 *
 * 分层：
 *  - 纯逻辑（hypium 覆盖）：wrapBracketedPaste（bracketed paste 包裹）、
 *    containsLineBreak（多行检测）；
 *  - 系统面（真机路径）：copyTextToPasteboard 写入剪贴板（复制出口）、
 *    pasteFromPasteboard 读取剪贴板并发送给终端——多行时先弹确认
 *    「检测到多行，是否使用括号粘贴」（AlertDialog），确认则用
 *    \e[200~ … \e[201~ 包裹发送，否则原样发送。
 *
 * 权限：读取系统剪贴板需 ohos.permission.READ_PASTEBOARD（module.json5
 * 已声明）；写入不需要权限。全部系统调用 try/catch 兜底——剪贴板读写失败
 * 只记日志，不影响终端主流程。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { SshTerminal } from '../../napi/SshTerminal';
import { Logger } from '../../common/utils/Logger';

/** bracketed paste 起始/结束序列（xterm DECSET 2004 惯例） */
const BRACKETED_PASTE_BEGIN = '\x1b[200~';
const BRACKETED_PASTE_END = '\x1b[201~';

/**
 * 括号粘贴包裹（纯函数）：enabled 时用 \e[200~ … \e[201~ 包裹文本，
 * 否则原样返回。远端应用开启 bracketed paste 模式时按标记整体入缓冲，
 * 未开启时包裹序列被当作普通输入序列忽略（\e[200~ 对未开启者无害：
 * bash/readline 未启用时会显示为无——故是否包裹由用户确认决定）。
 */
export function wrapBracketedPaste(text: string, enabled: boolean): string {
  return enabled ? `${BRACKETED_PASTE_BEGIN}${text}${BRACKETED_PASTE_END}` : text;
}

/** 多行检测（含 \n 或 \r 即视为多行内容） */
export function containsLineBreak(text: string): boolean {
  return text.indexOf('\n') >= 0 || text.indexOf('\r') >= 0;
}

/**
 * 复制文本到系统剪贴板（气泡菜单「复制」出口）。
 * 返回是否受理；失败只记日志（复制是非关键路径）。
 */
export async function copyTextToPasteboard(text: string): Promise<boolean> {
  if (text.length === 0) {
    return false;
  }
  try {
    const board = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await board.setData(data);
    return true;
  } catch (err) {
    Logger.warn(`写入剪贴板失败：${JSON.stringify(err)}`, 'Terminal');
    return false;
  }
}

/**
 * 从系统剪贴板粘贴到终端（T7 键条/气泡菜单的公共入口）：
 *   空剪贴板/读取失败 → 静默返回；
 *   单行文本 → 原样发送；
 *   多行文本 → AlertDialog 确认「检测到多行，是否使用括号粘贴」：
 *     「括号粘贴」= \e[200~…\e[201~ 包裹发送，「直接粘贴」= 原样发送。
 */
export async function pasteFromPasteboard(terminal: SshTerminal | null): Promise<void> {
  if (terminal === null) {
    return;
  }
  let text = '';
  try {
    const board = pasteboard.getSystemPasteboard();
    const data = await board.getData();
    text = data.getPrimaryText() ?? '';
  } catch (err) {
    // 空剪贴板/权限未授予/并发粘贴冲突：都按「无可粘贴内容」静默处理
    Logger.warn(`读取剪贴板失败（按无内容处理）：${JSON.stringify(err)}`, 'Terminal');
    return;
  }
  if (text.length === 0) {
    return;
  }
  if (!containsLineBreak(text)) {
    terminal.write(text);
    return;
  }
  AlertDialog.show({
    title: '粘贴确认',
    message: '检测到多行内容，是否使用括号粘贴（bracketed paste）？' +
      '括号粘贴会把多行作为整体提交给远端应用，避免逐行触发自动执行。',
    primaryButton: {
      value: '括号粘贴',
      action: () => {
        terminal.write(wrapBracketedPaste(text, true));
      }
    },
    secondaryButton: {
      value: '直接粘贴',
      action: () => {
        terminal.write(wrapBracketedPaste(text, false));
      }
    }
  });
}
