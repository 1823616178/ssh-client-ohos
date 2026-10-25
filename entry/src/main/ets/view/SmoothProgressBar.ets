/**
 * SmoothProgressBar —— 传输进度细条（SFTP 页 / 侧栏共用）。
 *
 * 进度事件是离散的（native 每 ≥64 KiB 且 ≥100 ms 上报一次），直接改宽度会一跳一跳。
 * 这里在两次上报之间用 Motion.SLOW_MS 线性补间，看起来是连续推进。
 *
 * 只动 scale（合成层属性，不触发布局）：填充条恒为 100% 宽，scale.x = 百分比。
 * 传输行以 `id|state|bytes` 作 ForEach key，每次进度都会重建行，组件实例随之重建；
 * 因此「上一次显示到哪」记在模块级表里（按 trackKey），新实例从旧值补间到新值。
 */
import { Motion } from '../theme/Motion';
import { Tokens } from '../theme/Tokens';

const LAST_SHOWN: Map<string, number> = new Map();
/** 进度表上限：只是补间起点缓存，超出直接清空（最坏退化为一次不补间） */
const LAST_SHOWN_MAX = 64;

function clampPercent(p: number): number {
  if (!(p > 0)) {
    return 0;
  }
  return p > 100 ? 100 : p;
}

@Component
export struct SmoothProgressBar {
  @Prop trackKey: string = '';
  @Prop @Watch('onPercentChanged') percent: number = 0;
  @Prop barHeight: number = 3;
  @State private shown: number = 0;

  aboutToAppear(): void {
    const prev: number | undefined = LAST_SHOWN.get(this.trackKey);
    this.shown = prev !== undefined ? prev : clampPercent(this.percent);
  }

  private onPercentChanged(): void {
    this.animateToTarget();
  }

  private animateToTarget(): void {
    const target: number = clampPercent(this.percent);
    if (LAST_SHOWN.size >= LAST_SHOWN_MAX && !LAST_SHOWN.has(this.trackKey)) {
      LAST_SHOWN.clear();
    }
    LAST_SHOWN.set(this.trackKey, target);
    if (target === this.shown) {
      return;
    }
    this.getUIContext().animateTo({
      duration: Motion.duration(Motion.SLOW_MS),
      curve: Curve.Linear
    }, () => {
      this.shown = target;
    });
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Tokens.Color.accent)
        .scale({ x: this.shown / 100, y: 1, centerX: 0, centerY: 0 })
    }
    .width('100%')
    .height(this.barHeight)
    .backgroundColor(Tokens.Color.surfaceHover)
    .borderRadius(this.barHeight / 2)
    .clip(true)
    .onAppear(() => {
      this.animateToTarget();
    })
  }
}
