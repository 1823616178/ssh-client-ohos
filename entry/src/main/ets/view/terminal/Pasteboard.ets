/**
 * Pasteboard —— 终端粘贴/复制助手（任务 T8，DESIGN §4.4「粘贴」：从
 * @ohos.pasteboard 读取、含换行时提示括号粘贴）。
 *
 * 分层：
 *  - 纯逻辑（hypium 覆盖）：wrapBracketedPaste（bracketed paste 包裹）、
 *    containsLineBreak（多行检测）；
 *  - 系统面（真机路径）：copyTextToPasteboard 写入剪贴板（复制出口）、
 *    pasteFromPasteboard 读取剪贴板并发送给终端——远端开了 bracketed paste
 *    （DECSET 2004，native 帧上报）时自动包裹、不弹窗；未开且多行时确认后发送。
 *
 * 权限：读取系统剪贴板需 ohos.permission.READ_PASTEBOARD（module.json5
 * 已声明）；写入不需要权限。全部系统调用 try/catch 兜底——剪贴板读写失败
 * 只记日志，不影响终端主流程。
 */

import { pasteboard } from '@kit.BasicServicesKit';
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
 * 粘贴文本预处理（纯函数）：
 *   - 换行统一成 CR（终端 Enter 语义；\r\n 折叠为一个，避免每行多发一个空行）；
 *   - bracketed=true（远端已开 DECSET 2004）时用 \e[200~ … \e[201~ 包裹，并剔除文本
 *     自带的 200~/201~ 标记——否则剪贴板里藏一个 \e[201~ 就能提前结束粘贴、
 *     让后续内容被当作键入命令执行（粘贴注入）。
 */
export function preparePasteText(text: string, bracketed: boolean): string {
  let body: string = text.replace(/\r\n/g, '\r').replace(/\n/g, '\r');
  if (!bracketed) {
    return body;
  }
  body = body.split(BRACKETED_PASTE_BEGIN).join('').split(BRACKETED_PASTE_END).join('');
  return wrapBracketedPaste(body, true);
}

/** 粘贴内容的行数（确认框文案用；末尾换行不额外计一行） */
export function countPasteLines(text: string): number {
  const normalized: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const trimmed: string = normalized.endsWith('\n') ? normalized.substring(0, normalized.length - 1) : normalized;
  return trimmed.length === 0 ? 0 : trimmed.split('\n').length;
}

/**
 * 是否需要多行确认：远端没开 bracketed paste 时，多行粘贴会被 shell 逐行执行，
 * 先确认；开了 2004 的应用（bash/zsh/vim）整段作为粘贴处理，不打扰用户。
 */
export function needsMultilinePasteConfirm(text: string, bracketed: boolean): boolean {
  return !bracketed && containsLineBreak(text.replace(/[\r\n]+$/, ''));
}

/** 读取系统剪贴板纯文本；空/失败返回空串 */
export async function readPasteboardText(): Promise<string> {
  try {
    const board = pasteboard.getSystemPasteboard();
    const data = await board.getData();
    return data.getPrimaryText() ?? '';
  } catch (err) {
    // 空剪贴板/权限未授予/并发粘贴冲突：都按「无可粘贴内容」静默处理
    Logger.warn(`读取剪贴板失败（按无内容处理）：${JSON.stringify(err)}`, 'Terminal');
    return '';
  }
}

/** 粘贴写入出口（TerminalCanvas 传入：写终端并唤醒帧循环、回到底部） */
export type PasteWriter = (text: string) => void;

/**
 * 从系统剪贴板粘贴到终端（键条/快捷键/气泡菜单/IME 粘贴的公共入口）：
 *   空剪贴板/读取失败 → 静默返回；
 *   远端已开 bracketed paste → 自动包裹后直接发送（无弹窗）；
 *   未开且为多行 → 确认「将逐行执行 N 行」，确认后发送。
 */
export async function pasteFromPasteboard(writer: PasteWriter, bracketed: boolean): Promise<void> {
  const text: string = await readPasteboardText();
  if (text.length === 0) {
    return;
  }
  if (!needsMultilinePasteConfirm(text, bracketed)) {
    writer(preparePasteText(text, bracketed));
    return;
  }
  AlertDialog.show({
    title: '粘贴多行内容',
    message: `剪贴板有 ${countPasteLines(text)} 行内容。当前程序未开启括号粘贴，` +
      '粘贴后每一行都会被当作命令立即执行。',
    autoCancel: true,
    primaryButton: {
      value: '取消',
      action: () => {
      }
    },
    secondaryButton: {
      value: '粘贴并执行',
      action: () => {
        writer(preparePasteText(text, false));
      }
    }
  });
}
