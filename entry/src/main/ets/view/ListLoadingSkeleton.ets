/**
 * ListLoadingSkeleton —— 全列表统一脉冲骨架屏与流光扫描加载组件。
 *
 * 支持三种布局形态（variant）：
 *   - 'card'：标准双行圆角卡片（主机列表 / 配置中心 / 密钥管理 / 端口转发 / 云同步 / 开源许可）；
 *   - 'compact'：紧凑单行条目（SFTP 页面与侧栏 / 片段侧栏 / 转发侧栏 / 键条编辑器 / 连接选择器）；
 *   - 'grid'：胶囊芯片阵列（外观主题预设等）。
 *
 * 动效纪律：
 *   - 只动 opacity / scale / translate 等合成层属性，零重排；
 *   - 各骨架行按行号带 55ms 相位差做无限往返呼吸脉冲（0.38 ↔ 0.88），呈现自上而下的流光波浪感；
 *   - 顶部附带 2vp 电青色往返扫描流光条；
 *   - Motion.enabled = false 时静止展示，不启动无线循环。
 */

import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';
import { SkeletonRowSpec, buildSkeletonRowSpecs } from '../viewmodel/Astro3DSceneModel';

export type SkeletonVariant = 'card' | 'compact' | 'grid';

/** 呼吸脉冲每行相位差（ms） */
const ROW_PHASE_DELAY_MS: number = 55;
/** 顶部扫描流光条高度（vp） */
const SCAN_BAR_HEIGHT_VP: number = 2;
/** 骨架条占位高度（vp） */
const TITLE_BAR_HEIGHT_VP: number = 14;
const SUBTITLE_BAR_HEIGHT_VP: number = 10;
const BADGE_BAR_HEIGHT_VP: number = 20;
const DOT_SIZE_VP: number = 10;
const COMPACT_ICON_SIZE_VP: number = 20;
const GRID_CHIP_WIDTH_VP: number = 84;
const GRID_CHIP_HEIGHT_VP: number = 30;

@Component
export struct ListLoadingSkeleton {
  /** 骨架形态：'card' | 'compact' | 'grid' */
  variant: SkeletonVariant = 'card';
  /** 骨架行数（或芯片数） */
  rows: number = 4;
  /** 可选加载提示文案（空串则不显示文字，纯视觉骨架） */
  hint: string = '';

  @State private pulsed: boolean = false;
  @State private scanRight: boolean = false;
  private specs: SkeletonRowSpec[] = [];

  aboutToAppear(): void {
    this.specs = buildSkeletonRowSpecs(this.rows);
    if (!Motion.enabled) {
      return;
    }
    setTimeout(() => {
      this.getUIContext().animateTo({
        duration: Motion.SKELETON_PULSE_MS,
        curve: Curve.EaseInOut,
        iterations: -1,
        playMode: PlayMode.Alternate
      }, () => {
        this.pulsed = true;
      });
      this.getUIContext().animateTo({
        duration: Motion.SKELETON_PULSE_MS * 1.4,
        curve: Curve.FastOutSlowIn,
        iterations: -1,
        playMode: PlayMode.Alternate
      }, () => {
        this.scanRight = true;
      });
    }, 16);
  }

  build() {
    Column() {
      // 顶部电青色微光扫描轨道条
      Stack({ alignContent: Alignment.Start }) {
        Column()
          .width('100%')
          .height(SCAN_BAR_HEIGHT_VP)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)
        Column()
          .width('36%')
          .height(SCAN_BAR_HEIGHT_VP)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.xs)
          .opacity(this.pulsed ? 0.9 : 0.45)
          .offset({ x: this.scanRight ? '175%' : '0%' })
      }
      .width('100%')
      .height(SCAN_BAR_HEIGHT_VP)
      .clip(true)
      .margin({ bottom: Tokens.space.xs })

      if (this.hint.length > 0) {
        Row() {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(Tokens.Color.accent)
            .opacity(this.pulsed ? 1 : 0.35)
            .margin({ right: Tokens.space.xs })
          Text(this.hint)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
        }
        .width('100%')
        .margin({ bottom: Tokens.space.xs })
      }

      if (this.variant === 'grid') {
        this.GridSkeleton()
      } else if (this.variant === 'compact') {
        this.CompactSkeleton()
      } else {
        this.CardSkeleton()
      }
    }
    .width('100%')
    .transition(Motion.fadeTransition())
  }

  @Builder
  CardSkeleton() {
    Column() {
      ForEach(this.specs, (spec: SkeletonRowSpec) => {
        Row() {
          // 左侧状态点占位
          Column()
            .width(DOT_SIZE_VP)
            .height(DOT_SIZE_VP)
            .borderRadius(DOT_SIZE_VP / 2)
            .backgroundColor(Tokens.Color.accentMuted)
            .margin({ right: Tokens.space.sm })

          // 中间双行标题与副标题占位
          Column() {
            Column()
              .width(spec.titleWidth)
              .height(TITLE_BAR_HEIGHT_VP)
              .borderRadius(Tokens.radius.xs)
              .backgroundColor(Tokens.Color.surfaceHover)
            Column()
              .width(spec.subtitleWidth)
              .height(SUBTITLE_BAR_HEIGHT_VP)
              .borderRadius(Tokens.radius.xs)
              .backgroundColor(Tokens.Color.surfaceHover)
              .margin({ top: Tokens.space.xs })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 右侧胶囊徽标占位
          Column()
            .width(spec.badgeWidthVp)
            .height(BADGE_BAR_HEIGHT_VP)
            .borderRadius(Tokens.radius.xs)
            .backgroundColor(Tokens.Color.surfaceHover)
            .margin({ left: Tokens.space.sm })
        }
        .width('100%')
        .padding(Tokens.space.md)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
        .margin({ bottom: Tokens.space.xs })
        .opacity(this.pulsed ? 0.88 : 0.42)
        .scale({ x: this.pulsed ? 1.0 : 0.992, y: this.pulsed ? 1.0 : 0.992 })
        .animation({
          duration: Motion.duration(Motion.SKELETON_PULSE_MS),
          curve: Curve.EaseInOut,
          delay: Motion.enabled ? spec.index * ROW_PHASE_DELAY_MS : 0
        })
      }, (spec: SkeletonRowSpec) => `sk-card-${spec.index}`)
    }
    .width('100%')
  }

  @Builder
  CompactSkeleton() {
    Column() {
      ForEach(this.specs, (spec: SkeletonRowSpec) => {
        Row() {
          Column()
            .width(COMPACT_ICON_SIZE_VP)
            .height(COMPACT_ICON_SIZE_VP)
            .borderRadius(Tokens.radius.xs)
            .backgroundColor(Tokens.Color.surfaceHover)
            .margin({ right: Tokens.space.xs })

          Column() {
            Column()
              .width(spec.titleWidth)
              .height(SUBTITLE_BAR_HEIGHT_VP + 2)
              .borderRadius(Tokens.radius.xs)
              .backgroundColor(Tokens.Color.surfaceHover)
            Column()
              .width(spec.subtitleWidth)
              .height(SUBTITLE_BAR_HEIGHT_VP - 2)
              .borderRadius(Tokens.radius.xs)
              .backgroundColor(Tokens.Color.surfaceHover)
              .margin({ top: Tokens.space.xs2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column()
            .width(spec.badgeWidthVp - 8)
            .height(BADGE_BAR_HEIGHT_VP)
            .borderRadius(Tokens.radius.xs)
            .backgroundColor(Tokens.Color.surfaceHover)
            .margin({ left: Tokens.space.xs })
        }
        .width('100%')
        .padding(Tokens.space.sm)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.sm)
        .margin({ bottom: Tokens.space.xs2 })
        .opacity(this.pulsed ? 0.88 : 0.42)
        .animation({
          duration: Motion.duration(Motion.SKELETON_PULSE_MS),
          curve: Curve.EaseInOut,
          delay: Motion.enabled ? spec.index * ROW_PHASE_DELAY_MS : 0
        })
      }, (spec: SkeletonRowSpec) => `sk-compact-${spec.index}`)
    }
    .width('100%')
  }

  @Builder
  GridSkeleton() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.specs, (spec: SkeletonRowSpec) => {
        Column()
          .width(GRID_CHIP_WIDTH_VP + (spec.index % 3) * 14)
          .height(GRID_CHIP_HEIGHT_VP)
          .borderRadius(Tokens.radius.xs)
          .backgroundColor(Tokens.Color.surfaceHover)
          .margin({ right: Tokens.space.xs, bottom: Tokens.space.xs })
          .opacity(this.pulsed ? 0.85 : 0.4)
          .animation({
            duration: Motion.duration(Motion.SKELETON_PULSE_MS),
            curve: Curve.EaseInOut,
            delay: Motion.enabled ? spec.index * ROW_PHASE_DELAY_MS : 0
          })
      }, (spec: SkeletonRowSpec) => `sk-grid-${spec.index}`)
    }
    .width('100%')
  }
}
