/**
 * KeyBarEditorPage —— 功能键条编辑器。
 *
 * 入口：设置 › 工具 › 功能键条；终端页 ⚙ 面板「编辑功能键条…」。
 * 能力：预览 / 上移下移 / 删除 / 添加内置键（Esc、方向、Home/End、⌨ 软键盘…）/
 *       添加常用字符或自定义单字符 / 恢复默认 / 保存。
 * 存储：SettingsRepository.setKeyBarLayout；等同内置默认时写空串（默认布局升级可自动跟上）。
 * 纯逻辑全部在 view/KeyBarLayout.ets（有单测），本页只做呈现与状态。
 */

import { router } from '@kit.ArkUI';
import { Logger } from '../common/utils/Logger';
import { SettingsRepository } from '../repository/SettingsRepository';
import { Tokens } from '../theme/Tokens';
import { PageHeader } from '../view/PageHeader';
import { accessibilityNameOf } from '../view/KeyBar';
import {
  DEFAULT_KEY_BAR_LAYOUT,
  KEY_BAR_MAX_KEYS,
  KEY_BAR_MIN_KEYS,
  KeyBarKeySpec,
  addableKnownKeys,
  addableSuggestedChars,
  appendKeyBarKey,
  keyBarLayoutToStore,
  makeKeyBarCharKey,
  moveKeyBarKey,
  parseKeyBarLayout,
  removeKeyBarKey
} from '../view/KeyBarLayout';

const LOG_TAG: string = 'KeyBarEditor';
/** 最小触控热区（vp） */
const TOUCH_VP: number = 40;
/** 预览键面高度（与终端页键条一致） */
const PREVIEW_KEY_HEIGHT_VP: number = 40;
const PREVIEW_KEY_MIN_WIDTH_VP: number = 44;

interface EditorRowParams {
  spec: KeyBarKeySpec;
  index: number;
}

@Entry
@Component
struct KeyBarEditorPage {
  @State private keys: KeyBarKeySpec[] = [];
  @State private dirty: boolean = false;
  @State private customChar: string = '';
  @State private message: string = '';

  aboutToAppear(): void {
    let json: string = '';
    try {
      json = SettingsRepository.getKeyBarLayout();
    } catch (err) {
      Logger.warn(`键条布局读取失败，使用默认：${JSON.stringify(err)}`, LOG_TAG);
    }
    this.keys = parseKeyBarLayout(json).slice();
  }

  onBackPress(): boolean {
    if (!this.dirty) {
      return false;
    }
    AlertDialog.show({
      title: '放弃修改？',
      message: '功能键条的修改尚未保存。',
      autoCancel: true,
      primaryButton: {
        value: '继续编辑',
        action: () => {
        }
      },
      secondaryButton: {
        value: '放弃',
        fontColor: Tokens.Color.danger,
        action: () => {
          this.dirty = false;
          router.back();
        }
      }
    });
    return true;
  }

  private setKeys(next: KeyBarKeySpec[]): void {
    this.keys = next;
    this.dirty = true;
    this.message = '';
  }

  private addCustomChar(): void {
    const spec: KeyBarKeySpec | null = makeKeyBarCharKey(this.customChar);
    if (spec === null) {
      this.message = '请输入单个字符';
      return;
    }
    if (this.keys.length >= KEY_BAR_MAX_KEYS) {
      this.message = `最多 ${KEY_BAR_MAX_KEYS} 个键`;
      return;
    }
    const before: number = this.keys.length;
    const next: KeyBarKeySpec[] = appendKeyBarKey(this.keys, spec);
    if (next.length === before) {
      this.message = '该字符已在键条中';
      return;
    }
    this.setKeys(next);
    this.customChar = '';
  }

  private save(): void {
    try {
      SettingsRepository.setKeyBarLayout(keyBarLayoutToStore(this.keys));
      this.dirty = false;
      try {
        this.getUIContext().getPromptAction().showToast({ message: '功能键条已保存', duration: 1500 });
      } catch (toastErr) {
        Logger.warn(`toast 失败：${JSON.stringify(toastErr)}`, LOG_TAG);
      }
      router.back();
    } catch (err) {
      Logger.error(`键条布局保存失败：${JSON.stringify(err)}`, LOG_TAG);
      this.message = '保存失败，请稍后重试';
    }
  }

  build() {
    Column() {
      PageHeader({
        title: '功能键条',
        subtitle: '终端底部的快捷键：调整顺序、增删按键，长按方向键 / 退格会自动连发'
      })

      Scroll() {
        Column() {
          this.Preview()
          this.CurrentKeys()
          this.AddKnownKeys()
          this.AddChars()
        }
        .width('100%')
        .padding({ left: Tokens.space.md, right: Tokens.space.md, bottom: Tokens.space.lg })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.danger)
          .width('100%')
          .padding({ left: Tokens.space.md, right: Tokens.space.md })
      }

      Row({ space: Tokens.space.sm }) {
        Button('恢复默认')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .height(TOUCH_VP)
          .layoutWeight(1)
          .onClick(() => {
            this.setKeys(DEFAULT_KEY_BAR_LAYOUT.slice());
          })
        Button('保存')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .height(TOUCH_VP)
          .layoutWeight(1)
          .opacity(this.dirty ? 1 : 0.5)
          .enabled(this.dirty)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding(Tokens.space.md)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }

  @Builder
  SectionTitle(title: string, subtitle: string) {
    Column() {
      Text(title)
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: Tokens.space.md, bottom: Tokens.space.xs })
  }

  /** 预览：与终端页键条同尺寸，横向滑动 */
  @Builder
  Preview() {
    this.SectionTitle('预览', '')
    Scroll() {
      Row({ space: 4 }) {
        ForEach(this.keys, (spec: KeyBarKeySpec) => {
          Text(spec.label)
            .fontSize(Tokens.fontSize.body)
            .fontColor('#E8EEFB')
            .height(PREVIEW_KEY_HEIGHT_VP)
            .constraintSize({ minWidth: PREVIEW_KEY_MIN_WIDTH_VP })
            .padding({ left: Tokens.space.xs, right: Tokens.space.xs })
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.radius.sm)
            .backgroundColor('#1FFFFFFF')
        }, (spec: KeyBarKeySpec) => spec.id)
      }
      .padding(4)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .borderRadius(Tokens.radius.md)
    .backgroundColor('#0E131D')
  }

  @Builder
  CurrentKeys() {
    this.SectionTitle(`当前按键（${this.keys.length}）`, '自左向右的顺序；至少保留一个键')
    Column() {
      ForEach(this.keys, (spec: KeyBarKeySpec, index: number) => {
        this.EditorRow({ spec: spec, index: index })
      }, (spec: KeyBarKeySpec, index: number) => `${spec.id}|${index}|${this.keys.length}`)
    }
    .width('100%')
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
  }

  @Builder
  EditorRow($$: EditorRowParams) {
    Row() {
      Text($$.spec.label)
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .constraintSize({ minWidth: 56 })
      Text(accessibilityNameOf($$.spec))
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: Tokens.space.xs })
      Text('↑')
        .fontSize(Tokens.fontSize.title)
        .fontColor($$.index > 0 ? Tokens.Color.text : Tokens.Color.textFaint)
        .width(TOUCH_VP)
        .height(TOUCH_VP)
        .textAlign(TextAlign.Center)
        .accessibilityText(`上移 ${accessibilityNameOf($$.spec)}`)
        .onClick(() => {
          if ($$.index > 0) {
            this.setKeys(moveKeyBarKey(this.keys, $$.index, $$.index - 1));
          }
        })
      Text('↓')
        .fontSize(Tokens.fontSize.title)
        .fontColor($$.index < this.keys.length - 1 ? Tokens.Color.text : Tokens.Color.textFaint)
        .width(TOUCH_VP)
        .height(TOUCH_VP)
        .textAlign(TextAlign.Center)
        .accessibilityText(`下移 ${accessibilityNameOf($$.spec)}`)
        .onClick(() => {
          if ($$.index < this.keys.length - 1) {
            this.setKeys(moveKeyBarKey(this.keys, $$.index, $$.index + 1));
          }
        })
      Text('✕')
        .fontSize(Tokens.fontSize.body)
        .fontColor(this.keys.length > KEY_BAR_MIN_KEYS ? Tokens.Color.danger : Tokens.Color.textFaint)
        .width(TOUCH_VP)
        .height(TOUCH_VP)
        .textAlign(TextAlign.Center)
        .accessibilityText(`删除 ${accessibilityNameOf($$.spec)}`)
        .onClick(() => {
          this.setKeys(removeKeyBarKey(this.keys, $$.index));
        })
    }
    .width('100%')
    .padding({ left: Tokens.space.sm, right: Tokens.space.xs })
    .border({ width: { bottom: 1 }, color: Tokens.Color.border })
  }

  @Builder
  AddKnownKeys() {
    this.SectionTitle('添加内置键', '')
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(addableKnownKeys(this.keys), (spec: KeyBarKeySpec) => {
        this.AddChip(spec)
      }, (spec: KeyBarKeySpec) => spec.id)
    }
    .width('100%')
  }

  @Builder
  AddChars() {
    this.SectionTitle('添加字符键', '点选常用符号，或输入任意单个字符')
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(addableSuggestedChars(this.keys), (ch: string) => {
        this.AddCharChip(ch)
      }, (ch: string) => ch)
    }
    .width('100%')
    Row({ space: Tokens.space.xs }) {
      TextInput({ text: this.customChar, placeholder: '自定义字符' })
        .maxLength(2)
        .height(TOUCH_VP)
        .layoutWeight(1)
        .onChange((value: string) => {
          this.customChar = value;
        })
        .onSubmit(() => {
          this.addCustomChar();
        })
      Button('添加')
        .fontSize(Tokens.fontSize.body)
        .height(TOUCH_VP)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .onClick(() => {
          this.addCustomChar();
        })
    }
    .width('100%')
    .margin({ top: Tokens.space.xs })
  }

  @Builder
  AddChip(spec: KeyBarKeySpec) {
    Text(`+ ${spec.label}`)
      .fontSize(Tokens.fontSize.body)
      .fontColor(Tokens.Color.text)
      .height(TOUCH_VP)
      .constraintSize({ minWidth: 56 })
      .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
      .textAlign(TextAlign.Center)
      .borderRadius(Tokens.radius.sm)
      .backgroundColor(Tokens.Color.surface)
      .margin({ right: Tokens.space.xs, bottom: Tokens.space.xs })
      .accessibilityText(`添加 ${accessibilityNameOf(spec)}`)
      .onClick(() => {
        if (this.keys.length >= KEY_BAR_MAX_KEYS) {
          this.message = `最多 ${KEY_BAR_MAX_KEYS} 个键`;
          return;
        }
        this.setKeys(appendKeyBarKey(this.keys, spec));
      })
  }

  @Builder
  AddCharChip(ch: string) {
    Text(ch)
      .fontSize(Tokens.fontSize.body)
      .fontColor(Tokens.Color.text)
      .width(TOUCH_VP)
      .height(TOUCH_VP)
      .textAlign(TextAlign.Center)
      .borderRadius(Tokens.radius.sm)
      .backgroundColor(Tokens.Color.surface)
      .margin({ right: Tokens.space.xs, bottom: Tokens.space.xs })
      .accessibilityText(`添加字符 ${ch}`)
      .onClick(() => {
        const spec: KeyBarKeySpec | null = makeKeyBarCharKey(ch);
        if (spec === null) {
          return;
        }
        if (this.keys.length >= KEY_BAR_MAX_KEYS) {
          this.message = `最多 ${KEY_BAR_MAX_KEYS} 个键`;
          return;
        }
        this.setKeys(appendKeyBarKey(this.keys, spec));
      })
  }
}
