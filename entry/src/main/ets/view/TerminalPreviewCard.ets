/**
 * TerminalPreviewCard —— 外观页实时预览（A3 + A5）。
 *
 * 用 TerminalAppearance 的 20 色与字号行高绘制静态示意网格，
 * 不驱动 displaySync（避免与 T4 全局帧调度器抢资源）。
 * 颜色来自 appearance 字段，不是 Design Token（终端主题色位本身可配）。
 *
 * A5 背景图：本卡片以 Image + opacity + blur 合成示意；
 * TerminalCanvas 全链路合成属 residual（帧率门禁优先），字段已落库可在后续接入。
 */

import { Tokens } from '../theme/Tokens';
import { TerminalAppearance } from './terminal/TerminalAppearance';

const PREVIEW_ROWS: number = 4;
const PREVIEW_COLS: number = 24;

@Component
export struct TerminalPreviewCard {
  @Prop appearance: TerminalAppearance = {
    fontFamily: '',
    fontSize: 14,
    lineHeight: 1.2,
    letterSpacing: 0,
    fontWeight: 400,
    boldAsBright: true,
    cursorStyle: 'block',
    cursorBlink: true,
    backgroundOpacity: 1,
    padding: 8,
    palette: [],
    foreground: '#E8EEFB',
    background: '#0E131D',
    cursorColor: '#4D8DFF',
    selectionColor: '#26314A'
  };
  /** A5：背景图路径（'' = 无；仅预览合成） */
  @Prop backgroundImagePath: string = '';
  /** A5：背景图不透明度 0–1 */
  @Prop backgroundImageOpacity: number = 1;
  /** A5：背景模糊 vp（0 = 不模糊） */
  @Prop backgroundBlur: number = 0;

  private sampleLine(row: number): string {
    if (row === 0) {
      return 'user@harmony:~$ ls';
    }
    if (row === 1) {
      return 'src  docs  hap';
    }
    if (row === 2) {
      return 'user@harmony:~$ _';
    }
    return '0123456789abcdef';
  }

  build() {
    Stack() {
      if (this.backgroundImagePath.length > 0) {
        Image(this.backgroundImagePath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.backgroundImageOpacity)
          .blur(this.backgroundBlur)
      }
      Column() {
        ForEach([0, 1, 2, 3], (row: number) => {
          Text(this.sampleLine(row))
            .fontFamily(this.appearance.fontFamily.length > 0 ? this.appearance.fontFamily : 'monospace')
            .fontSize(this.appearance.fontSize)
            .fontColor(row === 2 ? this.appearance.cursorColor : this.appearance.foreground)
            .backgroundColor(this.appearance.background)
            .opacity(this.appearance.backgroundOpacity)
            .padding(this.appearance.padding > 0 ? this.appearance.padding / 2 : 4)
            .width('100%')
            .maxLines(1)
        }, (row: number) => `${row}`)
        Row() {
          ForEach(this.appearance.palette.slice(0, 16), (color: string, index: number) => {
            Column()
              .layoutWeight(1)
              .height(10)
              .backgroundColor(color)
          }, (color: string, index: number) => `${index}-${color}`)
        }
        .width('100%')
        .margin({ top: Tokens.space.xs })
        if (this.backgroundImagePath.length > 0) {
          Text(`背景图 · 不透明度 ${Math.round(this.backgroundImageOpacity * 100)}% · 模糊 ${this.backgroundBlur}vp`)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
            .margin({ top: Tokens.space.xs2 })
            .width('100%')
        }
      }
      .width('100%')
      .borderRadius(Tokens.radius.sm)
      .clip(true)
      .backgroundColor(this.backgroundImagePath.length > 0
        ? Color.Transparent : this.appearance.background)
    }
    .width('100%')
    .borderRadius(Tokens.radius.sm)
    .clip(true)
    .backgroundColor(this.appearance.background)
  }
}
