/**
 * TerminalActionHub —— 剪贴板动作的窗格路由（T7 键条「复制/粘贴」接线）。
 *
 * 存在的理由：复制依赖选区、粘贴依赖终端句柄，两者都只在 TerminalCanvas 内部；
 * 而 KeyBar 是 TerminalPage 的兄弟组件，页面拿不到画布实例引用。
 * 故沿用 FocusManager 的单例注册表模式：画布按 paneId 注册执行器，
 * 键条经页面按当前聚焦 paneId 查表执行。
 *
 * 与 onSendBytes 的分工：产出字节的键走 onSendBytes（终端输入通路），
 * 剪贴板动作不产字节，走本 Hub。
 *
 * 生命周期：TerminalCanvas.aboutToAppear 注册、aboutToDisappear 注销；
 * paneId 为空串的单窗格场景不注册（execute 找不到执行器时静默返回 false）。
 */

/**
 * 页面/键条可触发的画布动作：copy/paste 剪贴板；keyboard = 切换软键盘显隐
 * （外接键盘模式下也能显式唤出）；scrollBottom = 回到最新输出；
 * bell = 视觉响铃闪一下（VM 已按 BellLimiter 节流后由页面投递）。
 */
export type TerminalClipboardAction = 'copy' | 'paste' | 'keyboard' | 'scrollBottom' | 'bell';

/** 画布侧执行器（TerminalCanvas 实现；复制取当前选区、粘贴写入终端） */
export interface TerminalActionExecutor {
  executeClipboardAction(action: TerminalClipboardAction): void;
}

export class TerminalActionHub {
  private static instance: TerminalActionHub | null = null;

  static get(): TerminalActionHub {
    if (TerminalActionHub.instance === null) {
      TerminalActionHub.instance = new TerminalActionHub();
    }
    return TerminalActionHub.instance;
  }

  private readonly executors: Map<string, TerminalActionExecutor> = new Map();

  /** 注册（同 paneId 重复注册以最后一次为准——画布重建时新实例顶替旧实例） */
  register(paneId: string, executor: TerminalActionExecutor): void {
    if (paneId.length === 0) {
      return;
    }
    this.executors.set(paneId, executor);
  }

  /**
   * 注销。只有当表内登记的仍是该实例时才删除——画布重建时新实例先 aboutToAppear
   * 注册、旧实例后 aboutToDisappear 注销，不做这层判定会把新实例误删。
   */
  unregister(paneId: string, executor: TerminalActionExecutor): void {
    if (this.executors.get(paneId) === executor) {
      this.executors.delete(paneId);
    }
  }

  /** 对指定窗格执行动作；无对应执行器返回 false */
  execute(paneId: string, action: TerminalClipboardAction): boolean {
    const executor: TerminalActionExecutor | undefined = this.executors.get(paneId);
    if (executor === undefined) {
      return false;
    }
    executor.executeClipboardAction(action);
    return true;
  }
}
