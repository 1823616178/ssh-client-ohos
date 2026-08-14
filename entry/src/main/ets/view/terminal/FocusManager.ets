/**
 * FocusManager —— 全局单一「聚焦窗格」管理（任务 T6，DESIGN §4.3.1
 * 「焦点与输入路由」：键盘、粘贴、片段发送只投递给聚焦窗格）。
 *
 * 语义：
 *   - register/unregister 登记窗格 id（TerminalCanvas focusId / U4b Leaf id）；
 *   - 首个登记的窗格自动获得焦点（单窗格场景开箱即用）；
 *   - focus(id) 切换焦点（未知 id 返回 false，不抛）；焦点变化时按注册序
 *     回调监听器（U4b 用来重绘聚焦边框 app_accent 高亮）；
 *   - 聚焦窗格被 unregister 后不自动改投他人（focusedId 置空），
 *     由用户点击/U4b 显式 focus——避免输入误投到非预期会话。
 *
 * 单测用 `new FocusManager()` 拿隔离实例；生产用 `FocusManager.get()` 全局单例
 * （与 FrameScheduler.get() 同模式）。粘贴/片段发送的路由接线属 T8/U10，
 * 本任务只交付焦点状态与键盘/IME 输入的投递判定。
 */

/** 焦点变化监听：newFocusedId 为空串 = 当前无聚焦窗格 */
export type FocusChangedListener = (newFocusedId: string) => void;

export class FocusManager {
  private static instance: FocusManager | null = null;

  /** 全局单例（窗格树/终端组件共用） */
  static get(): FocusManager {
    if (FocusManager.instance === null) {
      FocusManager.instance = new FocusManager();
    }
    return FocusManager.instance;
  }

  /** 已登记窗格（保持登记序；聚焦失败回退与测试断言用） */
  private readonly paneIds: string[] = [];
  private focused: string = '';
  private readonly listeners: FocusChangedListener[] = [];

  /** 登记窗格；重复登记返回 false。首个窗格自动聚焦 */
  register(id: string): boolean {
    if (id.length === 0 || this.paneIds.indexOf(id) >= 0) {
      return false;
    }
    this.paneIds.push(id);
    if (this.focused.length === 0) {
      this.setFocused(id);
    }
    return true;
  }

  /** 注销窗格；注销的恰是聚焦窗格时焦点置空（不自动改投，见头注） */
  unregister(id: string): boolean {
    const idx = this.paneIds.indexOf(id);
    if (idx < 0) {
      return false;
    }
    this.paneIds.splice(idx, 1);
    if (this.focused === id) {
      this.setFocused('');
    }
    return true;
  }

  /** 切换焦点；未知 id 返回 false（焦点保持不动） */
  focus(id: string): boolean {
    if (this.paneIds.indexOf(id) < 0) {
      return false;
    }
    this.setFocused(id);
    return true;
  }

  /** 当前聚焦窗格 id；空串 = 无聚焦窗格 */
  get focusedId(): string {
    return this.focused;
  }

  /** 输入投递判定：只有聚焦窗格应收键盘/IME 输入 */
  isFocused(id: string): boolean {
    return id.length > 0 && this.focused === id;
  }

  /** 已登记窗格数 */
  get size(): number {
    return this.paneIds.length;
  }

  /** 监听焦点变化（重复添加同一回调只保留一份）；返回解除函数 */
  addListener(cb: FocusChangedListener): () => void {
    if (this.listeners.indexOf(cb) < 0) {
      this.listeners.push(cb);
    }
    return () => {
      const idx = this.listeners.indexOf(cb);
      if (idx >= 0) {
        this.listeners.splice(idx, 1);
      }
    };
  }

  private setFocused(id: string): void {
    if (this.focused === id) {
      return;
    }
    this.focused = id;
    for (const cb of this.listeners) {
      cb(id);
    }
  }
}
