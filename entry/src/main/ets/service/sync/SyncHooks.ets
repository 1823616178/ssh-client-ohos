/**
 * 配置已保存钩子（任务 S6）：HostEdit / HostList 只依赖本文件，避免拉起 NetworkKit。
 */

let savedHook: (() => void) | null = null;

export function setConfigSavedHook(fn: (() => void) | null): void {
  savedHook = fn;
}

export function notifyConfigSaved(): void {
  if (savedHook !== null) {
    savedHook();
  }
}
