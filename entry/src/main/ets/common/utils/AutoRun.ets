/**
 * 连接建立后的自动执行（tmux 自动附着 + 主机的 initCommands）—— 纯逻辑，可单测。
 *
 * 两件事合成一条通路：
 *   1. **tmux 自动附着**：`tmux new -A -s <name>`（`-A` = 已存在就 attach，不存在才 new）。
 *      移动端保活再努力也挡不住系统回收后台任务，而只要现场挂在 tmux 里，
 *      断线重连后 attach 回去就是原样，跑到一半的编译/日志都还在。这是「断了也不心疼」的真解。
 *   2. **initCommands**：主机配置里「连接后自动执行」此前只存不发（没有任何执行点），
 *      顺手在同一处接上；顺序在 tmux 之后，这样命令是在 tmux 会话里跑的。
 *
 * 每条命令按 `\n` 收尾发给远端 pty，等同用户手敲回车。字节出口在 TerminalViewModel，
 * 本文件只负责「该发哪几行」。
 */

import { HostProfile } from '../model/models';

/** tmux 会话名默认值（用户没填时用它；短、稳定、跨设备一眼认得出） */
export const DEFAULT_TMUX_SESSION_NAME: string = 'harmony';

/** 会话名允许的最大长度（tmux 本身不限，长了纯粹难认） */
const MAX_TMUX_SESSION_NAME_LEN: number = 32;

/**
 * 会话名归一：tmux 的会话名不能含 `:` 与 `.`，含空格/引号还会把命令行拆坏，
 * 所以只保留字母数字与 `_` `-`，其余一律丢弃；清空后落回默认名。
 * 这里做的是「保证发出去的命令一定安全」，而不是替用户纠正输入——
 * 输入合法性另由 HostEditViewModel 的表单校验提示。
 */
export function sanitizeTmuxSessionName(name: string): string {
  const trimmed: string = name.trim();
  let result: string = '';
  for (let i: number = 0; i < trimmed.length && result.length < MAX_TMUX_SESSION_NAME_LEN; i++) {
    const ch: string = trimmed.charAt(i);
    const isDigit: boolean = ch >= '0' && ch <= '9';
    const isLower: boolean = ch >= 'a' && ch <= 'z';
    const isUpper: boolean = ch >= 'A' && ch <= 'Z';
    if (isDigit || isLower || isUpper || ch === '_' || ch === '-') {
      result += ch;
    }
  }
  return result.length === 0 ? DEFAULT_TMUX_SESSION_NAME : result;
}

/** tmux 附着命令：已存在即 attach，不存在才新建 */
export function tmuxAttachCommand(sessionName: string): string {
  return `tmux new -A -s ${sanitizeTmuxSessionName(sessionName)}`;
}

/**
 * 一次连接建立后要自动执行的命令行（按序）。
 * 空行与 `#` 注释行在 initCommands 解析阶段已被剔除，这里只做兜底过滤。
 */
export function buildAutoRunCommands(host: HostProfile): string[] {
  const commands: string[] = [];
  if (host.tmuxAutoAttach) {
    commands.push(tmuxAttachCommand(host.tmuxSessionName));
  }
  for (const command of host.initCommands) {
    if (command.trim().length > 0) {
      commands.push(command);
    }
  }
  return commands;
}

/** 命令行 → 待写入远端的字节（每行以 `\n` 收尾，等同敲回车） */
export function encodeAutoRunCommands(commands: string[]): string {
  let payload: string = '';
  for (const command of commands) {
    payload += `${command}\n`;
  }
  return payload;
}
