/**
 * KeyManagerPage —— 私钥管理（任务 U3）。
 *
 * 导入（粘贴 OpenSSH/PEM / PKCS#8）/ native 生成 ed25519 / 指纹展示 /
 * 导出公钥 / 删除 / 解锁进应用内 agent。
 * 生成：私钥 PKCS#8 PEM + OpenSSH 公钥行，指纹 SHA256（ssh-keygen -lf 同口径）。
 * 颜色尺寸一律 Design Token。
 */

import { Tokens } from '../theme/Tokens';
import { Logger } from '../common/utils/Logger';
import { KeyEntryMeta } from '../common/utils/KeyManagerLogic';
import { KeyManagerViewModel } from '../viewmodel/KeyManagerViewModel';
import { PageHeader } from '../view/PageHeader';

const LOG_TAG: string = 'KeyManagerPage';

@Entry
@ComponentV2
struct KeyManagerPage {
  private readonly vm: KeyManagerViewModel = new KeyManagerViewModel();
  @Local private nameDraft: string = '';
  @Local private privateKeyDraft: string = '';
  @Local private passphraseDraft: string = '';
  @Local private publicKeyDraft: string = '';
  @Local private showImport: boolean = false;
  @Local private showGenerate: boolean = false;
  @Local private genNameDraft: string = '';
  @Local private genPassphraseDraft: string = '';
  @Local private genCommentDraft: string = '';
  @Local private exportText: string = '';

  aboutToAppear(): void {
    this.vm.reload();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  build() {
    Column() {
      PageHeader({
        title: '密钥管理',
        subtitle: '导入或生成 SSH 私钥，用于主机认证与应用内 Agent'
      })
      Scroll() {
        Column() {
          this.MessageBar()
          this.ActionRow()
          if (this.showGenerate && this.vm.generateSupported()) {
            this.GenerateCard()
          }
          if (this.showImport) {
            this.ImportCard()
          }
          if (this.exportText.length > 0) {
            this.ExportCard()
          }
          this.KeyList()
        }
        .width('100%')
        .padding({ left: Tokens.space.md, right: Tokens.space.md, bottom: Tokens.space.xl })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }

  @Builder
  MessageBar() {
    if (this.vm.lastMessage.length > 0) {
      Text(this.vm.lastMessage)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .width('100%')
        .margin({ bottom: Tokens.space.sm })
    }
  }

  @Builder
  ActionRow() {
    Column() {
      Row() {
        // 主操作：导入私钥（accent）；生成密钥对为次操作
        Button(this.showImport ? '收起导入' : '导入私钥')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .padding({ left: Tokens.space.md, right: Tokens.space.md })
          .onClick(() => {
            this.showImport = !this.showImport;
          })
        Button(this.showGenerate ? '收起生成' : '生成')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .margin({ left: Tokens.space.sm })
          .enabled(this.vm.generateSupported())
          .opacity(this.vm.generateSupported() ? 1 : 0.45)
          .accessibilityText(this.showGenerate ? '收起生成' : '生成密钥对')
          .onClick(() => {
            if (this.vm.generateSupported()) {
              this.showGenerate = !this.showGenerate;
              return;
            }
            this.toast(this.vm.generateUnsupportedReason());
          })
      }
      .width('100%')
      if (!this.vm.generateSupported()) {
        Text(this.vm.generateUnsupportedReason())
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
          .width('100%')
          .margin({ top: Tokens.space.xs2 })
      } else {
        Text('支持 ed25519。导入或生成后可用于主机密钥认证与应用内 Agent。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
          .width('100%')
          .margin({ top: Tokens.space.xs2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  GenerateCard() {
    Column() {
      Text('名称')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextInput({ placeholder: '如：平板跳板机', text: this.genNameDraft })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.genNameDraft = value;
        })
      Text('密码短语（可选）')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextInput({ placeholder: '留空则不加密保存', text: this.genPassphraseDraft })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.genPassphraseDraft = value;
        })
      Text('公钥 comment（可选）')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextInput({ placeholder: '如：user@ohos', text: this.genCommentDraft })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.genCommentDraft = value;
        })
      Row() {
        Button('生成并保存')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .onClick(async () => {
            const id: string = await this.vm.generateKeyPair(
              this.genNameDraft, this.genPassphraseDraft, this.genCommentDraft);
            if (id.length > 0) {
              this.genNameDraft = '';
              this.genPassphraseDraft = '';
              this.genCommentDraft = '';
              this.showGenerate = false;
              this.toast('密钥已生成并写入安全存储');
            } else {
              this.toast(this.vm.lastMessage);
            }
          })
        Button('取消')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.sm)
          .margin({ left: Tokens.space.sm })
          .onClick(() => {
            this.showGenerate = false;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  ImportCard() {
    Column() {
      Text('名称')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextInput({ placeholder: '如：生产跳板机', text: this.nameDraft })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.nameDraft = value;
        })
      Text('私钥内容（OpenSSH / PEM / PKCS#8）')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextArea({ placeholder: '-----BEGIN OPENSSH PRIVATE KEY-----', text: this.privateKeyDraft })
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .height(120)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.privateKeyDraft = value;
        })
      Text('密码短语（可选）')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextInput({ placeholder: '私钥有口令时填写', text: this.passphraseDraft })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.passphraseDraft = value;
        })
      Text('公钥（可选，用于指纹与导出）')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
      TextArea({ placeholder: 'ssh-ed25519 AAAA... comment', text: this.publicKeyDraft })
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .height(64)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
        .onChange((value: string) => {
          this.publicKeyDraft = value;
        })
      Row() {
        Button('保存到安全存储')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .onClick(async () => {
            this.vm.setDraft(this.nameDraft, this.privateKeyDraft, this.passphraseDraft,
              this.publicKeyDraft);
            const id: string = await this.vm.importDraft();
            if (id.length > 0) {
              this.nameDraft = '';
              this.privateKeyDraft = '';
              this.passphraseDraft = '';
              this.publicKeyDraft = '';
              this.showImport = false;
              this.toast('私钥已导入');
            } else {
              this.toast(this.vm.lastMessage);
            }
          })
        Button('取消')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.sm)
          .margin({ left: Tokens.space.sm })
          .onClick(() => {
            this.showImport = false;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  ExportCard() {
    Column() {
      Text('导出公钥')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
      Text(this.exportText)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.accent)
        .fontFamily('monospace')
        .margin({ top: Tokens.space.xs })
      Button('关闭')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          this.exportText = '';
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  KeyList() {
    Column() {
      Text('已保存密钥')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: Tokens.space.sm })
      if (this.vm.entries.length === 0) {
        Text('暂无私钥。导入或生成后可用于主机的密钥 / Agent 认证。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
      } else {
        ForEach(this.vm.entries, (entry: KeyEntryMeta) => {
          Column() {
            Text(entry.name)
              .fontSize(Tokens.fontSize.title)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.Color.text)
            Text(this.vm.displayFingerprint(entry))
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.accent)
              .fontFamily('monospace')
              .margin({ top: Tokens.space.xs2 })
            // 次操作：导出 / 解锁；删除独立成行 + 危险底色，与次操作视觉隔离
            Row() {
              Button('导出')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.text)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(36)
                .accessibilityText('导出公钥')
                .onClick(() => {
                  const pub: string = this.vm.exportPublicKey(entry.id);
                  this.exportText = pub.length > 0 ? pub : '该条目未保存公钥内容';
                })
              Button('解锁')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.text)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(36)
                .margin({ left: Tokens.space.xs })
                .accessibilityText('解锁进应用内 Agent')
                .onClick(async () => {
                  const ok: boolean = await this.vm.unlockToAgent(entry.id, '');
                  this.toast(this.vm.lastMessage);
                  if (!ok) {
                    Logger.warn(`agent 解锁失败 entry=${entry.id}`, LOG_TAG);
                  }
                })
            }
            .margin({ top: Tokens.space.sm })
            Button('删除')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.danger)
              .borderRadius(Tokens.radius.sm)
              .height(36)
              .width('100%')
              .margin({ top: Tokens.space.sm })
              .onClick(async () => {
                await this.vm.deleteEntry(entry.id);
                this.toast(this.vm.lastMessage);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .margin({ bottom: Tokens.space.sm })
        }, (entry: KeyEntryMeta) => entry.id)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
