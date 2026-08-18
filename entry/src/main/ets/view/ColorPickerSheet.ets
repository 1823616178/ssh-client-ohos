/**
 * ColorPickerSheet —— 终端配色选盘。
 *
 * 饱和度/明度平面 + 色相条 + 主题预设色块 + 十六进制输入。
 * 拖动过程走 onPreview，确定/取消由宿主决定是否落库。
 * 光谱色是 HSV 定义本身，不是页面主题 Token。
 */
import { Tokens } from '../theme/Tokens';
import { areaLengthToVp } from './terminal/TerminalLayout';
import {
  HsvColor,
  clamp01,
  hexToHsv,
  hsvToHex,
  hueToHex,
  isHexColor,
  normalizeHexColor
} from '../common/utils/HexColor';

/** 选盘卡片最大宽度：Token 表无此项，沿用密码补录框惯例 */
const PICKER_MAX_WIDTH_VP: number = 420;
/** 饱和度/明度平面高度 */
const SV_PLANE_HEIGHT_VP: number = 168;
/** 色相条高度 */
const HUE_BAR_HEIGHT_VP: number = 20;
/** 拖动手柄边长 */
const THUMB_SIZE_VP: number = 18;
/** 预设色块边长 */
const PRESET_CHIP_SIZE_VP: number = 28;
/** 当前色预览条高度 */
const PREVIEW_HEIGHT_VP: number = 36;
/** 选盘遮罩不透明度，与终端页密码补录框一致 */
const PICKER_SCRIM_OPACITY: number = 0.72;


@Component
export struct ColorPickerSheet {
  @Prop @Watch('onVisibleChanged') visible: boolean = false;
  @Prop value: string = '#0E131D';
  @Prop title: string = '选择颜色';
  @Prop presets: string[] = [];
  onPreview: (hex: string) => void = (_hex: string) => {};
  onConfirm: (hex: string) => void = (_hex: string) => {};
  onCancel: () => void = () => {};

  @State private hue: number = 220;
  @State private sat: number = 0.5;
  @State private val: number = 0.1;
  @State private hexDraft: string = '#0E131D';
  @State private svWidth: number = 1;
  @State private hueWidth: number = 1;

  aboutToAppear(): void {
    this.applyHex(this.value);
  }

  private onVisibleChanged(): void {
    if (this.visible) {
      this.applyHex(this.value);
    }
  }

  private applyHex(hex: string): void {
    const normalized: string = isHexColor(hex) ? normalizeHexColor(hex) : '#0E131D';
    const hsv: HsvColor = hexToHsv(normalized);
    this.hue = hsv.h;
    this.sat = hsv.s;
    this.val = hsv.v;
    this.hexDraft = normalized;
  }

  private currentHex(): string {
    return hsvToHex(this.hue, this.sat, this.val);
  }

  private emitPreview(): void {
    const hex: string = this.currentHex();
    this.hexDraft = hex;
    this.onPreview(hex);
  }

  private selectHex(hex: string): void {
    if (!isHexColor(hex)) {
      return;
    }
    this.applyHex(hex);
    this.onPreview(normalizeHexColor(hex));
  }

  private pickSv(localX: number, localY: number): void {
    if (this.svWidth <= 0) {
      return;
    }
    this.sat = clamp01(localX / this.svWidth);
    this.val = clamp01(1 - localY / SV_PLANE_HEIGHT_VP);
    this.emitPreview();
  }

  private pickHue(localX: number): void {
    if (this.hueWidth <= 0) {
      return;
    }
    this.hue = clamp01(localX / this.hueWidth) * 360;
    this.emitPreview();
  }

  private svThumbX(): number {
    return this.sat * this.svWidth - THUMB_SIZE_VP / 2;
  }

  private svThumbY(): number {
    return (1 - this.val) * SV_PLANE_HEIGHT_VP - THUMB_SIZE_VP / 2;
  }

  private hueThumbX(): number {
    return (this.hue / 360) * this.hueWidth - THUMB_SIZE_VP / 2;
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Tokens.Color.appBg)
          .opacity(PICKER_SCRIM_OPACITY)
          .onClick(() => {
            this.onCancel();
          })

        Column() {
          Text(this.title)
            .fontSize(Tokens.fontSize.title)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.text)
            .width('100%')

          Row() {
            Column()
              .width(PREVIEW_HEIGHT_VP)
              .height(PREVIEW_HEIGHT_VP)
              .borderRadius(Tokens.radius.xs)
              .backgroundColor(this.currentHex())
              .border({ width: 1, color: Tokens.Color.border })
            Text(this.hexDraft)
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .margin({ left: Tokens.space.sm })
          }
          .width('100%')
          .margin({ top: Tokens.space.md })

          Stack() {
            Column()
              .width('100%')
              .height(SV_PLANE_HEIGHT_VP)
              .linearGradient({
                angle: 90,
                colors: [['#FFFFFF', 0], [hueToHex(this.hue), 1]]
              })
            Column()
              .width('100%')
              .height(SV_PLANE_HEIGHT_VP)
              .linearGradient({
                angle: 180,
                colors: [['#00000000', 0], ['#000000', 1]]
              })
            Column()
              .width(THUMB_SIZE_VP)
              .height(THUMB_SIZE_VP)
              .borderRadius(THUMB_SIZE_VP / 2)
              .border({ width: 2, color: '#FFFFFFFF' })
              .backgroundColor(Color.Transparent)
              .position({ x: this.svThumbX(), y: this.svThumbY() })
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .height(SV_PLANE_HEIGHT_VP)
          .borderRadius(Tokens.radius.sm)
          .clip(true)
          .margin({ top: Tokens.space.md })
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.svWidth = areaLengthToVp(newArea.width);
          })
          .onTouch((event: TouchEvent) => {
            if ((event.type === TouchType.Down || event.type === TouchType.Move) &&
              event.touches.length > 0) {
              this.pickSv(event.touches[0].x, event.touches[0].y);
            }
          })

          Stack() {
            Column()
              .width('100%')
              .height(HUE_BAR_HEIGHT_VP)
              .linearGradient({
                angle: 90,
                colors: [
                  ['#FF0000', 0],
                  ['#FFFF00', 0.17],
                  ['#00FF00', 0.33],
                  ['#00FFFF', 0.5],
                  ['#0000FF', 0.67],
                  ['#FF00FF', 0.83],
                  ['#FF0000', 1]
                ]
              })
              .borderRadius(Tokens.radius.xs)
            Column()
              .width(THUMB_SIZE_VP)
              .height(THUMB_SIZE_VP)
              .borderRadius(THUMB_SIZE_VP / 2)
              .border({ width: 2, color: '#FFFFFFFF' })
              .backgroundColor(hueToHex(this.hue))
              .position({
                x: this.hueThumbX(),
                y: (HUE_BAR_HEIGHT_VP - THUMB_SIZE_VP) / 2
              })
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .height(HUE_BAR_HEIGHT_VP)
          .margin({ top: Tokens.space.md })
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.hueWidth = areaLengthToVp(newArea.width);
          })
          .onTouch((event: TouchEvent) => {
            if ((event.type === TouchType.Down || event.type === TouchType.Move) &&
              event.touches.length > 0) {
              this.pickHue(event.touches[0].x);
            }
          })

          if (this.presets.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.presets, (hex: string) => {
                Column()
                  .width(PRESET_CHIP_SIZE_VP)
                  .height(PRESET_CHIP_SIZE_VP)
                  .borderRadius(Tokens.radius.xs)
                  .backgroundColor(hex)
                  .border({
                    width: hex === this.currentHex() ? 2 : 1,
                    color: hex === this.currentHex() ? Tokens.Color.accent : Tokens.Color.border
                  })
                  .margin({ right: Tokens.space.xs, bottom: Tokens.space.xs })
                  .onClick(() => {
                    this.selectHex(hex);
                  })
              }, (hex: string) => hex)
            }
            .width('100%')
            .margin({ top: Tokens.space.md })
          }

          TextInput({ text: this.hexDraft, placeholder: '#RRGGBB' })
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .height(36)
            .width('100%')
            .margin({ top: Tokens.space.sm })
            .onChange((next: string) => {
              this.hexDraft = next;
              if (isHexColor(next)) {
                this.applyHex(next);
                this.onPreview(normalizeHexColor(next));
              }
            })

          Row({ space: Tokens.space.xs }) {
            Button('取消')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .height(36)
              .layoutWeight(1)
              .onClick(() => {
                this.onCancel();
              })
            Button('确定')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .height(36)
              .layoutWeight(1)
              .onClick(() => {
                this.onConfirm(this.currentHex());
              })
          }
          .width('100%')
          .margin({ top: Tokens.space.md })
        }
        .width('100%')
        .constraintSize({ maxWidth: PICKER_MAX_WIDTH_VP })
        .padding(Tokens.space.lg)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
        .onClick(() => {
          // 吃掉卡片点击，避免落到遮罩上取消
        })
      }
      .width('100%')
      .height('100%')
    }
  }
}
