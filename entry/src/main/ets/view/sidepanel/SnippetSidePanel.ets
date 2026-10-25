import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import { Tokens } from '../../theme/Tokens';
import { Motion } from '../../theme/Motion';
import { Snippet } from '../../common/model/models';
import { AppDatabase } from '../../repository/AppDatabase';
import { SnippetSendHub } from '../terminal/SnippetSendHub';
import { Logger } from '../../common/utils/Logger';

const LOG_TAG: string = 'SnippetSidePanel';

@Component
export struct SnippetSidePanel {
  /** 首屏入场窗口已过：列表行改用 IDENTITY 过渡（Motion.listItemTransition 注释） */
  @State private introDone: boolean = !Motion.enabled;
  onOpenFullPage: () => void = () => {};

  @State private snippets: Snippet[] = [];
  @State private searchText: string = '';
  @State private showAddForm: boolean = false;
  @State private newName: string = '';
  @State private newContent: string = '';

  aboutToAppear(): void {
    this.openIntroWindow();
    this.reloadSnippets();
  }

  private reloadSnippets(): void {
    try {
      this.snippets = AppDatabase.snippets().listAll();
    } catch (err) {
      Logger.warn(`加载片段列表失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.snippets = [];
    }
  }

  private filteredSnippets(): Snippet[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.snippets;
    }
    return this.snippets.filter((s: Snippet) =>
      s.name.toLowerCase().includes(q) || s.content.toLowerCase().includes(q)
    );
  }

  private sendSnippet(snippet: Snippet): void {
    const hub = SnippetSendHub.get();
    if (!hub.available) {
      this.toast('未连接或未聚焦终端');
      return;
    }
    const ok: boolean = hub.send(snippet.content, snippet.name);
    this.toast(ok ? `已向终端发送: ${snippet.name}` : '发送失败，请确认终端就绪');
  }

  private copySnippet(snippet: Snippet): void {
    try {
      const board = pasteboard.getSystemPasteboard();
      board.setDataSync(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, snippet.content));
      this.toast('已复制到剪贴板');
    } catch (err) {
      Logger.warn(`复制失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast('复制失败');
    }
  }

  private deleteSnippet(snippet: Snippet): void {
    try {
      AppDatabase.snippets().deleteById(snippet.id);
      this.reloadSnippets();
      this.toast('已删除片段');
    } catch (err) {
      Logger.warn(`删除片段失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast('删除失败');
    }
  }

  private saveNewSnippet(): void {
    const name: string = this.newName.trim();
    const content: string = this.newContent.trim();
    if (name.length === 0 || content.length === 0) {
      this.toast('请填写名称与命令内容');
      return;
    }
    try {
      const s: Snippet = {
        id: util.generateRandomUUID(),
        name: name,
        content: content,
        groupId: null
      };
      AppDatabase.snippets().insert(s);
      this.newName = '';
      this.newContent = '';
      this.showAddForm = false;
      this.reloadSnippets();
      this.toast('片段添加成功');
    } catch (err) {
      Logger.warn(`添加片段失败: ${JSON.stringify(err)}`, LOG_TAG);
      this.toast('添加失败');
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 显示失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 首屏入场窗口：INTRO_WINDOW_MS 内插入的列表行交错入场，之后直接终态 */
  private openIntroWindow(): void {
    if (this.introDone) {
      return;
    }
    setTimeout(() => {
      this.introDone = true;
    }, Motion.INTRO_WINDOW_MS);
  }

  build() {
    Column() {
      // 头部搜索与新建按钮
      Row() {
        TextInput({ text: this.searchText, placeholder: '搜索片段...' })
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)
          .height(30)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.searchText = v;
          })
        Button(this.showAddForm ? '取消' : '+ 新建')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(this.showAddForm ? Tokens.Color.surfaceHover : Tokens.Color.accent)
          .borderRadius(Tokens.radius.xs)
          .height(30)
          .margin({ left: Tokens.space.xs })
          .onClick(() => {
            this.showAddForm = !this.showAddForm;
            if (!this.showAddForm) {
              this.newName = '';
              this.newContent = '';
            }
          })
      }
      .width('100%')
      .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs, bottom: Tokens.space.xs })

      // 新建表单展开态
      if (this.showAddForm) {
        Column({ space: Tokens.space.xs }) {
          TextInput({ text: this.newName, placeholder: '片段名称 (如: 重启 Nginx)' })
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.xs)
            .height(32)
            .onChange((v: string) => {
              this.newName = v;
            })
          TextArea({ text: this.newContent, placeholder: '命令内容 (可含 ${host}, ${user})' })
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.xs)
            .height(64)
            .onChange((v: string) => {
              this.newContent = v;
            })
          Row() {
            Blank()
            Button('保存片段')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.xs)
              .height(28)
              .onClick(() => {
                this.saveNewSnippet();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(Tokens.space.sm)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ left: Tokens.space.sm, right: Tokens.space.sm, bottom: Tokens.space.xs })
        .transition(Motion.riseTransition())
      }

      // 片段列表
      if (this.filteredSnippets().length === 0) {
        Column() {
          Text(this.searchText.trim().length > 0 ? '没有匹配的命令片段' : '暂无命令片段，点上方添加')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .transition(Motion.fadeTransition())
      } else {
        Scroll() {
          Column({ space: Tokens.space.xs }) {
            ForEach(this.filteredSnippets(), (snippet: Snippet, index: number) => {
              Column() {
                Row() {
                  Text(snippet.name)
                    .fontSize(Tokens.fontSize.body)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.Color.text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('删除')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.danger)
                    .padding({ left: Tokens.space.xs, right: Tokens.space.xs })
                    .clickEffect(Motion.pressEffect())
                    .onClick(() => {
                      this.deleteSnippet(snippet);
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Text(snippet.content)
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.textDim)
                  .fontFamily('monospace')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: Tokens.space.xs2, bottom: Tokens.space.xs })

                Row({ space: Tokens.space.xs }) {
                  Button('发送')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.onAccent)
                    .backgroundColor(Tokens.Color.accent)
                    .borderRadius(Tokens.radius.xs)
                    .height(26)
                    .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
                    .onClick(() => {
                      this.sendSnippet(snippet);
                    })
                  Button('复制')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.text)
                    .backgroundColor(Tokens.Color.surfaceHover)
                    .borderRadius(Tokens.radius.xs)
                    .height(26)
                    .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
                    .onClick(() => {
                      this.copySnippet(snippet);
                    })
                }
                .width('100%')
                .justifyContent(FlexAlign.End)
              }
              .width('100%')
              .padding(Tokens.space.sm)
              .backgroundColor(Tokens.Color.surface)
              .borderRadius(Tokens.radius.sm)
              .border({ width: 1, color: Tokens.Color.border })
              // 首屏交错入场（INTRO_WINDOW_MS 后 IDENTITY：滚动复用/数据刷新不重播）
              .transition(this.introDone ? TransitionEffect.IDENTITY : Motion.listItemTransition(index))
            }, (snippet: Snippet) => snippet.id)
          }
          .width('100%')
          .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs, bottom: Tokens.space.xs })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      // 底部链接
      Row() {
        Text('打开配置管理页 ›')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .clickEffect(Motion.pressEffect())
          .onClick(() => {
            this.onOpenFullPage();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding(Tokens.space.xs)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }
}
