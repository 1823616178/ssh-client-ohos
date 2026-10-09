/**
 * TerminalImeEditor —— 终端的 inputMethod 自绘编辑器通路（IME 主通路）。
 *
 * 为什么不再用隐藏 TextInput：TextInput 只给出「完整值」，终端只能靠前后值 diff
 * 猜增量——空缓冲上的退格无回调、回车被吃掉、候选态靠 previewText 推断、长会话还要
 * 定期清缓冲。InputMethodController（自绘编辑器）直接给出语义事件：
 *   insertText(text)        → 提交文本（中文整词上屏一次，候选期不回调）
 *   deleteLeft(n)           → 退格 n 次（空行退格照样到达）
 *   sendFunctionKey(enter)  → 回车
 *   moveCursor(dir)         → 软键盘方向键/光标滑动
 *   sendKeyboardStatus      → 软键盘显隐
 * 并且 TextConfig.capitalizeMode=NONE 关闭首字母自动大写（`ls` 不会变成 `Ls`）。
 *
 * 进程内只有一个 InputMethodController：本模块做成单例，事件回调只投递给「当前
 * 客户端」（聚焦窗格的 TerminalCanvas）。attach / getController 任一失败即标记
 * unavailable，TerminalCanvas 退回 ImeInputSink（隐藏 TextInput）兜底通路。
 *
 * 与其它输入框共存：页面里的普通 TextInput（密码框、搜索框）获焦时由 ArkUI 自行
 * attach，会顶掉本编辑器——回到终端时（点按/聚焦）重新 attach 即可。
 *
 * 多窗口：控制器仍是进程唯一，但 attach 绑定的是当时获焦的窗口。记下当前 owner
 * 所在窗口（ownerWindowKey），窗口切换获焦时由该窗口的聚焦画布判断
 * isOwnedByOtherWindow 后重新 attach（见 TerminalCanvas.onHostWindowActive）。
 */
import { inputMethod } from '@kit.IMEKit';
import { MAIN_WINDOW_KEY } from '../../common/constants/WindowKeys';
import { Logger } from '../../common/utils/Logger';

const LOG_TAG: string = 'TerminalIme';

/** 编辑器事件接收方（struct 不能 implements，宿主用 TerminalImeClientAdapter 包一层） */
export interface TerminalImeClient {
  onInsertText(text: string): void;
  onDeleteLeft(length: number): void;
  onDeleteRight(length: number): void;
  onEnter(): void;
  onMoveCursor(direction: number): void;
  onSelectAll(): void;
  onCopy(): void;
  onPaste(): void;
  onKeyboardShown(shown: boolean): void;
  /** IME 联想上下文（左侧文本）；终端拿不到远端行内容，返回本地回显 */
  leftText(length: number): string;
}

/** 可用性监听（attach 失败 → 所有画布切兜底通路） */
export type TerminalImeAvailabilityListener = (available: boolean) => void;

export class TerminalImeEditor {
  private static instance: TerminalImeEditor | null = null;

  private controller: inputMethod.InputMethodController | null = null;
  private available: boolean = true;
  private listening: boolean = false;
  private ownerId: string = '';
  /** 当前 owner 所在窗口（'' = 无 owner） */
  private ownerWindowKey: string = '';
  private client: TerminalImeClient | null = null;
  private attached: boolean = false;
  private attaching: boolean = false;
  private keyboardShown: boolean = false;
  private readonly availabilityListeners: TerminalImeAvailabilityListener[] = [];

  static get(): TerminalImeEditor {
    if (TerminalImeEditor.instance === null) {
      TerminalImeEditor.instance = new TerminalImeEditor();
    }
    return TerminalImeEditor.instance;
  }

  /** 自绘编辑器是否可用（false = 宿主应挂 ImeInputSink 兜底） */
  isAvailable(): boolean {
    if (!this.available) {
      return false;
    }
    return this.ensureController() !== null;
  }

  isKeyboardShown(): boolean {
    return this.keyboardShown;
  }

  /**
   * 当前 owner 是否在别的窗口（多窗口：本窗口获焦时据此决定是否重新 attach）。
   * 无 owner 时为 false——没有人在用输入法，不必抢。
   */
  isOwnedByOtherWindow(windowKey: string): boolean {
    return this.ownerId.length > 0 && this.ownerWindowKey !== windowKey;
  }

  /** 当前客户端是否为 ownerId（多窗格路由用） */
  isOwner(ownerId: string): boolean {
    return this.ownerId === ownerId && this.attached;
  }

  addAvailabilityListener(cb: TerminalImeAvailabilityListener): () => void {
    this.availabilityListeners.push(cb);
    return (): void => {
      const i: number = this.availabilityListeners.indexOf(cb);
      if (i >= 0) {
        this.availabilityListeners.splice(i, 1);
      }
    };
  }

  /**
   * 让 ownerId 成为输入目标并 attach（showKeyboard=true 时同时弹软键盘）。
   * 返回 false = attach 失败（已切 unavailable，调用方走兜底）。
   */
  async attach(ownerId: string, client: TerminalImeClient, showKeyboard: boolean,
    windowKey: string = MAIN_WINDOW_KEY): Promise<boolean> {
    const controller = this.ensureController();
    if (controller === null) {
      return false;
    }
    this.ownerId = ownerId;
    this.ownerWindowKey = windowKey;
    this.client = client;
    this.registerListeners(controller);
    if (this.attaching) {
      return true; // 正在 attach：新 owner 已生效，结果由在途请求决定
    }
    this.attaching = true;
    try {
      const config: inputMethod.TextConfig = {
        inputAttribute: {
          textInputType: inputMethod.TextInputType.TEXT,
          enterKeyType: inputMethod.EnterKeyType.NONE
        },
        capitalizeMode: inputMethod.CapitalizeMode.NONE
      };
      await controller.attach(showKeyboard, config);
      this.attached = true;
      return true;
    } catch (err) {
      Logger.warn(`自绘编辑器 attach 失败，切换隐藏输入框兜底：${JSON.stringify(err)}`, LOG_TAG);
      this.markUnavailable();
      return false;
    } finally {
      this.attaching = false;
    }
  }

  /** 已 attach 时只弹软键盘；否则走 attach(showKeyboard=true) */
  async show(ownerId: string, client: TerminalImeClient,
    windowKey: string = MAIN_WINDOW_KEY): Promise<boolean> {
    if (this.controller !== null && this.attached && this.ownerId === ownerId) {
      try {
        await this.controller.showTextInput();
        return true;
      } catch (err) {
        // 被其它输入框顶掉后 showTextInput 会报未绑定：重新 attach
        this.attached = false;
      }
    }
    return this.attach(ownerId, client, true, windowKey);
  }

  /** 收起软键盘（保持 attach，物理键盘/再次弹出不需要重新绑定） */
  hide(ownerId: string): void {
    if (this.controller === null || !this.attached || this.ownerId !== ownerId) {
      return;
    }
    this.controller.hideTextInput().catch((err: Object) => {
      Logger.warn(`收起软键盘失败：${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  /** ownerId 不再需要输入（画布卸载/页面离开）：是当前 owner 才 detach */
  release(ownerId: string): void {
    if (this.ownerId !== ownerId) {
      return;
    }
    this.ownerId = '';
    this.ownerWindowKey = '';
    this.client = null;
    const controller = this.controller;
    if (controller === null || !this.attached) {
      return;
    }
    this.attached = false;
    this.keyboardShown = false;
    controller.detach().catch((err: Object) => {
      Logger.warn(`自绘编辑器 detach 失败：${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  private ensureController(): inputMethod.InputMethodController | null {
    if (!this.available) {
      return null;
    }
    if (this.controller === null) {
      try {
        this.controller = inputMethod.getController();
      } catch (err) {
        Logger.warn(`获取 InputMethodController 失败：${JSON.stringify(err)}`, LOG_TAG);
        this.markUnavailable();
        return null;
      }
    }
    return this.controller;
  }

  private markUnavailable(): void {
    if (!this.available) {
      return;
    }
    this.available = false;
    this.attached = false;
    const listeners: TerminalImeAvailabilityListener[] = this.availabilityListeners.slice();
    for (const cb of listeners) {
      cb(false);
    }
  }

  private registerListeners(controller: inputMethod.InputMethodController): void {
    if (this.listening) {
      return;
    }
    this.listening = true;
    try {
      controller.on('insertText', (text: string): void => {
        if (this.client !== null) {
          this.client.onInsertText(text);
        }
      });
      controller.on('deleteLeft', (length: number): void => {
        if (this.client !== null) {
          this.client.onDeleteLeft(length);
        }
      });
      controller.on('deleteRight', (length: number): void => {
        if (this.client !== null) {
          this.client.onDeleteRight(length);
        }
      });
      controller.on('sendFunctionKey', (_key: inputMethod.FunctionKey): void => {
        if (this.client !== null) {
          this.client.onEnter();
        }
      });
      controller.on('moveCursor', (direction: inputMethod.Direction): void => {
        if (this.client !== null) {
          this.client.onMoveCursor(direction as number);
        }
      });
      controller.on('handleExtendAction', (action: inputMethod.ExtendAction): void => {
        if (this.client === null) {
          return;
        }
        if (action === inputMethod.ExtendAction.SELECT_ALL) {
          this.client.onSelectAll();
        } else if (action === inputMethod.ExtendAction.COPY) {
          this.client.onCopy();
        } else if (action === inputMethod.ExtendAction.PASTE) {
          this.client.onPaste();
        }
      });
      controller.on('sendKeyboardStatus', (status: inputMethod.KeyboardStatus): void => {
        this.keyboardShown = status === inputMethod.KeyboardStatus.SHOW;
        if (this.client !== null) {
          this.client.onKeyboardShown(this.keyboardShown);
        }
      });
      controller.on('getLeftTextOfCursor', (length: number): string => {
        return this.client !== null ? this.client.leftText(length) : '';
      });
      controller.on('getRightTextOfCursor', (_length: number): string => {
        return '';
      });
      controller.on('getTextIndexAtCursor', (): number => {
        return this.client !== null ? this.client.leftText(64).length : 0;
      });
    } catch (err) {
      Logger.warn(`注册自绘编辑器回调失败：${JSON.stringify(err)}`, LOG_TAG);
      this.markUnavailable();
    }
  }
}
