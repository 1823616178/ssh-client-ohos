/**
 * TerminalActionHub 扩展：片段发送通路（任务 U10）。
 *
 * ConfigManager / 未来 Snippet 侧栏 → 聚焦终端。
 * TerminalViewModel 在 start 后注册 sender，dispose 注销。
 * 无终端时 send 返回 false。
 */

/** 片段发送出口：payload 已是「替换变量 + 补 \\n」的最终字节串 */
export type SnippetSender = (payload: string) => boolean;

export class SnippetSendHub {
  private static instance: SnippetSendHub | null = null;

  static get(): SnippetSendHub {
    if (SnippetSendHub.instance === null) {
      SnippetSendHub.instance = new SnippetSendHub();
    }
    return SnippetSendHub.instance;
  }

  private sender: SnippetSender | null = null;
  /** 最近一次发送的预览文本（UI 展示「发送前预览」） */
  lastPreview: string = '';

  register(sender: SnippetSender): void {
    this.sender = sender;
  }

  unregister(sender: SnippetSender): void {
    if (this.sender === sender) {
      this.sender = null;
    }
  }

  /** 发送到聚焦终端；无注册出口返回 false */
  send(payload: string, preview?: string): boolean {
    this.lastPreview = preview ?? payload;
    if (this.sender === null || payload.length === 0) {
      return false;
    }
    return this.sender(payload);
  }

  get available(): boolean {
    return this.sender !== null;
  }
}
