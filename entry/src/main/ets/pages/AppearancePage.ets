/**
 * AppearancePage —— 终端外观（任务 A3 / A5 / A6）。
 *
 * 主题列表 + 内置预设一键新建 + 实时预览 + 20 色 ColorPickerSheet +
 * 字体/字号/行高/光标 + 背景图（路径/不透明度/模糊，预览卡合成）
 * + 应用主题模式（system/dark/light → colorMode）。
 * 配色导入粘贴。退出不保存可还原（discardDraft）。
 */

import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { AppearanceProfile, CursorStyle } from '../common/model/models';
import { Tokens } from '../theme/Tokens';
import { Logger } from '../common/utils/Logger';
import {
  AppThemeMode,
  THEME_MODE_OPTIONS,
  ThemePreset,
  ColorModeName,
  themeModeLabel,
  themeModeToColorModeName
} from '../theme/ThemePresets';
import { COLOR_SLOT_LABELS, AppearanceViewModel } from '../viewmodel/AppearanceViewModel';
import { ColorPickerSheet } from '../view/ColorPickerSheet';
import { PageHeader, PageHeaderAction } from '../view/PageHeader';
import { TerminalAppearance } from '../view/terminal/TerminalAppearance';
import { TerminalPreviewCard } from '../view/TerminalPreviewCard';

const LOG_TAG: string = 'AppearancePage';

/** A6：themeMode → OHOS colorMode 并立即应用到 ApplicationContext */
export function applyThemeColorMode(colorModeName: ColorModeName, context: common.Context): void {
  try {
    let mode: ConfigurationConstant.ColorMode =
      ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (colorModeName === 'dark') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (colorModeName === 'light') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    context.getApplicationContext().setColorMode(mode);
  } catch (err) {
    Logger.warn(`applyThemeColorMode 失败: ${colorModeName}`, LOG_TAG);
  }
}

@Entry
@ComponentV2
struct AppearancePage {
  private readonly vm: AppearanceViewModel = new AppearanceViewModel();
  @Local private pickerVisible: boolean = false;
  @Local private pickerSlot: number = 0;
  @Local private pickerValue: string = '#000000';
  @Local private importDraft: string = '';
  @Local private importName: string = '';
  @Local private bgPathDraft: string = '';

  aboutToAppear(): void {
    this.vm.reload();
    this.vm.reloadThemeMode();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 失败`, LOG_TAG);
    }
  }

  private applyThemeModeAndToast(mode: AppThemeMode): void {
    this.vm.setThemeMode(mode);
    const colorModeName: ColorModeName = themeModeToColorModeName(this.vm.themeMode);
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      applyThemeColorMode(colorModeName, context);
    } catch (err) {
      Logger.warn('获取 hostContext 失败，colorMode 未立即应用', LOG_TAG);
    }
    this.toast(`主题模式：${themeModeLabel(this.vm.themeMode)}`);
  }

  build() {
    const headerActions: PageHeaderAction[] = [
      {
        label: '保存',
        onClick: (): void => {
          if (this.vm.saveDraft()) {
            this.toast('主题已保存');
          } else {
            this.toast(this.vm.lastMessage);
          }
        },
        primary: true
      },
      {
        label: '还原',
        onClick: (): void => {
          this.vm.discardDraft();
          this.toast('已还原未保存修改');
        }
      }
    ];
    Stack() {
      Column() {
        PageHeader({
          title: '外观',
          subtitle: '主题、字体与配色',
          actions: headerActions
        })
        Scroll() {
          Column() {
            this.ThemeModeSection()
            this.PresetRow()
            this.ProfileList()
            if (this.vm.draft !== null) {
              this.DraftEditor()
            }
            this.ImportCard()
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

      ColorPickerSheet({
        visible: this.pickerVisible,
        value: this.pickerValue,
        title: COLOR_SLOT_LABELS[this.pickerSlot],
        onPreview: (hex: string) => {
          this.vm.setColorSlot(this.pickerSlot, hex);
        },
        onConfirm: (hex: string) => {
          this.vm.setColorSlot(this.pickerSlot, hex);
          this.pickerVisible = false;
        },
        onCancel: () => {
          this.pickerVisible = false;
        }
      })
    }
    .width('100%')
    .height('100%')
  }

  /** A6：应用整体主题（深色 / 浅色 / 跟随系统） */
  @Builder
  ThemeModeSection() {
    Column() {
      Text('应用主题')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
      Text(`当前：${themeModeLabel(this.vm.themeMode)}`)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
      Row() {
        ForEach(THEME_MODE_OPTIONS, (mode: AppThemeMode) => {
          Text(themeModeLabel(mode))
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.vm.themeMode === mode
              ? Tokens.Color.onAccent : Tokens.Color.textDim)
            .backgroundColor(this.vm.themeMode === mode
              ? Tokens.Color.accent : Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.xs)
            .constraintSize({ minHeight: 36 })
            .padding({
              left: Tokens.space.sm,
              right: Tokens.space.sm,
              top: Tokens.space.xs2,
              bottom: Tokens.space.xs2
            })
            .margin({ right: Tokens.space.xs })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.applyThemeModeAndToast(mode);
            })
        }, (mode: AppThemeMode) => mode)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  PresetRow() {
    Column() {
      Text('内置主题预设')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
      Text(this.vm.lastMessage.length > 0 ? this.vm.lastMessage : '点选预设可新建主题；编辑中可「套用配色」')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.vm.presets, (preset: ThemePreset) => {
          Button(preset.name)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(preset.dark ? Tokens.Color.text : Tokens.Color.appBg)
            .backgroundColor(preset.colors.background)
            .borderRadius(Tokens.radius.sm)
            .margin({ right: Tokens.space.xs, bottom: Tokens.space.xs })
            .onClick(() => {
              if (this.vm.draft !== null) {
                this.vm.applyPresetToDraft(preset.id);
                this.toast(`已套用 ${preset.name} 配色到当前草稿`);
              } else {
                this.vm.createFromPreset(preset.id);
                this.toast(`已创建 ${preset.name}`);
              }
            })
        }, (preset: ThemePreset) => preset.id)
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
  ProfileList() {
    Column() {
      Text('已保存主题')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: Tokens.space.sm })
      if (this.vm.profiles.length === 0) {
        Text('暂无自定义主题，点上方预设创建。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textFaint)
      } else {
        ForEach(this.vm.profiles, (profile: AppearanceProfile) => {
          Row() {
            Column() {
              Text(profile.name)
                .fontSize(Tokens.fontSize.body)
                .fontColor(Tokens.Color.text)
                .fontWeight(FontWeight.Medium)
              Row() {
                ForEach(profile.palette.slice(0, 8), (color: string) => {
                  Column()
                    .width(12)
                    .height(12)
                    .backgroundColor(color)
                    .margin({ right: 2 })
                }, (color: string) => color)
              }
              .margin({ top: Tokens.space.xs2 })
              if (profile.backgroundImagePath.length > 0) {
                Text('含背景图')
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.textFaint)
                  .margin({ top: Tokens.space.xs2 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .onClick(() => {
              this.vm.select(profile.id);
              if (this.vm.draft !== null) {
                this.bgPathDraft = this.vm.draft.backgroundImagePath;
              }
            })
            Button('删除')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.danger)
              .borderRadius(Tokens.radius.sm)
              .onClick(() => {
                this.vm.deleteProfile(profile.id);
                this.toast(this.vm.lastMessage);
              })
          }
          .width('100%')
          .padding(Tokens.space.sm)
          .backgroundColor(this.vm.draft !== null && this.vm.draft.id === profile.id
            ? Tokens.Color.surfaceHover : Tokens.Color.surface)
          .borderRadius(Tokens.radius.sm)
          .margin({ bottom: Tokens.space.xs })
        }, (profile: AppearanceProfile) => profile.id)
      }
      Button('新建自定义主题')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.text)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          this.vm.createCustom('自定义主题');
          if (this.vm.draft !== null) {
            this.bgPathDraft = this.vm.draft.backgroundImagePath;
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: Tokens.space.sm })
  }

  @Builder
  DraftEditor() {
    Column() {
      Text('编辑与实时预览')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: Tokens.space.sm })

      // 实时预览：TerminalAppearance 渲染参数卡片 + 背景图合成示意
      if (this.vm.preview !== null) {
        TerminalPreviewCard({
          appearance: this.vm.preview as TerminalAppearance,
          backgroundImagePath: this.vm.draft !== null ? this.vm.draft.backgroundImagePath : '',
          backgroundImageOpacity: this.vm.draft !== null ? this.vm.draft.backgroundImageOpacity : 1,
          backgroundBlur: this.vm.draft !== null ? this.vm.draft.backgroundBlur : 0
        })
          .width('100%')
          .margin({ bottom: Tokens.space.sm })
      }

      if (this.vm.draft !== null) {
        TextInput({ text: this.vm.draft.name, placeholder: '主题名称' })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .margin({ bottom: Tokens.space.sm })
          .onChange((value: string) => {
            this.vm.setName(value);
          })

        this.NumberRow('字号', this.vm.draft.fontSize, (v: number) => {
          this.vm.setFontSize(v);
        })
        // 内部仍以 ×100 整数步进，展示层换算为真实倍数，标签不出现 ×100
        this.NumberRow('行高', Math.round(this.vm.draft.lineHeight * 100), (v: number) => {
          this.vm.setLineHeight(v / 100);
        }, 100)
        this.NumberRow('字间距', Math.round(this.vm.draft.letterSpacing * 100), (v: number) => {
          this.vm.setLetterSpacing(v / 100);
        }, 100)
        this.NumberRow('内边距', this.vm.draft.padding, (v: number) => {
          this.vm.setPadding(v);
        })
        this.NumberRow('背景不透明度', Math.round(this.vm.draft.backgroundOpacity * 100),
          (v: number) => {
            this.vm.setBackgroundOpacity(v / 100);
          }, 1, '%')

        Text('背景图')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs, bottom: Tokens.space.xs2 })
        TextInput({
          placeholder: '背景图路径（sandbox/rawfile；空 = 关闭）',
          text: this.bgPathDraft
        })
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .margin({ bottom: Tokens.space.xs })
          .onChange((value: string) => {
            this.bgPathDraft = value;
            this.vm.setBackgroundImagePath(value);
          })
        this.NumberRow('背景图不透明度',
          Math.round(this.vm.draft.backgroundImageOpacity * 100), (v: number) => {
            this.vm.setBackgroundImageOpacity(v / 100);
          }, 1, '%')
        this.NumberRow('背景模糊', this.vm.draft.backgroundBlur, (v: number) => {
          this.vm.setBackgroundBlur(v);
        }, 1, ' vp')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(['block', 'bar', 'underline'], (style: string) => {
            Text(style === 'block' ? '块' : style === 'bar' ? '竖线' : '下划线')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(this.vm.draft !== null && this.vm.draft.cursorStyle === style
                ? Tokens.Color.onAccent : Tokens.Color.textDim)
              .backgroundColor(this.vm.draft !== null && this.vm.draft.cursorStyle === style
                ? Tokens.Color.accent : Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.xs)
              .constraintSize({ minHeight: 36 })
              .padding({
                left: Tokens.space.sm,
                right: Tokens.space.sm,
                top: Tokens.space.xs2,
                bottom: Tokens.space.xs2
              })
              .margin({ right: Tokens.space.xs })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.vm.setCursorStyle(style as CursorStyle);
              })
          }, (style: string) => style)
        }
        .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

        // 开关行：Flex 换行（Flex 无 alignItems；用 Row 包住每组保证触控对齐）
        Flex({ wrap: FlexWrap.Wrap }) {
          Row() {
            Text('连字')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
            Toggle({ type: ToggleType.Switch, isOn: this.vm.draft.ligatures })
              .selectedColor(Tokens.Color.accent)
              .margin({ left: Tokens.space.sm, right: Tokens.space.md })
              .onChange((isOn: boolean) => {
                this.vm.setLigatures(isOn);
              })
          }
          .margin({ right: Tokens.space.sm, bottom: Tokens.space.xs })
          Row() {
            Text('粗体亮色')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
            Toggle({ type: ToggleType.Switch, isOn: this.vm.draft.boldAsBright })
              .selectedColor(Tokens.Color.accent)
              .margin({ left: Tokens.space.sm, right: Tokens.space.md })
              .onChange((isOn: boolean) => {
                this.vm.setBoldAsBright(isOn);
              })
          }
          .margin({ right: Tokens.space.sm, bottom: Tokens.space.xs })
          Row() {
            Text('光标闪烁')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
            Toggle({ type: ToggleType.Switch, isOn: this.vm.draft.cursorBlink })
              .selectedColor(Tokens.Color.accent)
              .margin({ left: Tokens.space.sm })
              .onChange((isOn: boolean) => {
                this.vm.setCursorBlink(isOn);
              })
          }
          .margin({ bottom: Tokens.space.xs })
        }
        .width('100%')
        .margin({ bottom: Tokens.space.sm })

        Text('20 色位（点按打开取色器）')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ bottom: Tokens.space.xs })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(COLOR_SLOT_LABELS, (label: string, index: number) => {
            Column() {
              Column()
                .width(36)
                .height(28)
                .backgroundColor(this.vm.colorSlot(index))
                .borderRadius(Tokens.radius.xs)
              Text(label)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
                .margin({ top: Tokens.space.xs2 })
            }
            .width(48)
            .height(52)
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Start)
            .margin({ right: Tokens.space.xs, bottom: Tokens.space.xs })
            .onClick(() => {
              this.pickerSlot = index;
              this.pickerValue = this.vm.colorSlot(index);
              this.pickerVisible = true;
            })
          }, (label: string, index: number) => `${index}-${label}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ bottom: Tokens.space.sm })
  }

  /** 步进器展示值：divisor>1 时按真实量纲显示（如 120→1.2），unit 可选拼接 */
  private formatStepperDisplay(value: number, divisor: number, unit: string): string {
    const scaled: number = divisor === 1 ? value : value / divisor;
    const rounded: number = Math.round(scaled * 100) / 100;
    return `${rounded}${unit}`;
  }

  @Builder
  NumberRow(label: string, value: number, onChange: (v: number) => void,
    displayDivisor: number = 1, unit: string = '') {
    Row() {
      Text(label)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .layoutWeight(1)
      Button('-')
        .fontSize(Tokens.fontSize.body)
        .width(36)
        .height(36)
        .backgroundColor(Tokens.Color.surfaceHover)
        .accessibilityText(`减少${label}`)
        .onClick(() => {
          onChange(value - 1);
        })
      Text(this.formatStepperDisplay(value, displayDivisor, unit))
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .margin({ left: Tokens.space.xs, right: Tokens.space.xs })
        .width(56)
        .textAlign(TextAlign.Center)
      Button('+')
        .fontSize(Tokens.fontSize.body)
        .width(36)
        .height(36)
        .backgroundColor(Tokens.Color.surfaceHover)
        .accessibilityText(`增加${label}`)
        .onClick(() => {
          onChange(value + 1);
        })
    }
    .width('100%')
    .margin({ bottom: Tokens.space.xs })
  }

  @Builder
  ImportCard() {
    Column() {
      Text('配色导入（iTerm2 / Windows Terminal）')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .fontWeight(FontWeight.Bold)
      TextArea({
        placeholder: '粘贴 .itermcolors XML 或 Windows Terminal scheme JSON',
        text: this.importDraft
      })
        .fontSize(Tokens.fontSize.caption)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .height(100)
        .margin({ top: Tokens.space.sm })
        .onChange((value: string) => {
          this.importDraft = value;
        })
      Button('导入到当前草稿')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          const result = this.vm.importThemeToDraft(
            this.importName.length > 0 ? this.importName : 'import.json',
            this.importDraft);
          this.toast(result.ok ? this.vm.lastMessage : result.error);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
  }
}
