/**
 * Motion —— 全应用动效令牌（页面转场 / 列表入场 / 按压 / 弹层 / 颜色过渡）。
 *
 * 约定：
 *   - 时长 150–300ms，曲线默认 Curve.FastOutSlowIn；按压回弹走 springMotion；
 *   - 只做 opacity / translate / scale / 颜色这类合成层属性，不触发终端画布重排；
 *   - `Motion.enabled = false` 时所有时长归零（为「减少动态效果」设置预留的总开关，
 *     项目目前没有该设置项，系统级开关亦无公开 API 可读，缺省开启）。
 */
export class Motion {
  /** 总开关：false = 一律无动画（时长 0） */
  static enabled: boolean = true;

  static readonly FAST_MS: number = 150;
  static readonly BASE_MS: number = 220;
  static readonly SLOW_MS: number = 300;
  /** 列表交错入场：每行延迟与封顶行数（超出部分同时入场，避免长列表拖尾） */
  static readonly STAGGER_STEP_MS: number = 30;
  static readonly STAGGER_MAX_ROWS: number = 10;
  /** 入场位移（vp） */
  static readonly ENTER_OFFSET_VP: number = 8;
  /** 连接中状态点呼吸周期（单程） */
  static readonly PULSE_MS: number = 700;
  /** 按压缩放 */
  static readonly PRESS_SCALE: number = 0.97;
  /** 页面转场位移（vp）：push 新页自右轻推入，旧页轻微左移淡出 */
  static readonly PAGE_OFFSET_VP: number = 24;
  /** 首屏入场窗口：页面出现后该时长内新建的列表行才交错入场，之后（滚动/增删）直接终态 */
  static readonly INTRO_WINDOW_MS: number = 600;
  /** 底部弹层入场位移（vp） */
  static readonly SHEET_OFFSET_VP: number = 24;

  static duration(ms: number): number {
    return Motion.enabled ? ms : 0;
  }

  static stagger(index: number): number {
    if (!Motion.enabled || index <= 0) {
      return 0;
    }
    return Math.min(index, Motion.STAGGER_MAX_ROWS) * Motion.STAGGER_STEP_MS;
  }

  static enterOffset(): number {
    return Motion.enabled ? Motion.ENTER_OFFSET_VP : 0;
  }

  /** 页面转场位移：总开关关闭时为 0（配合 duration=0 即无转场） */
  static pageOffset(): number {
    return Motion.enabled ? Motion.PAGE_OFFSET_VP : 0;
  }

  /** 按压反馈：系统 clickEffect（渲染侧弹簧缩放，零 JS 开销）；总开关关闭时为 null */
  static pressEffect(): ClickEffect | null {
    if (!Motion.enabled) {
      return null;
    }
    const effect: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: Motion.PRESS_SCALE };
    return effect;
  }

  /**
   * 列表行首屏交错入场的隐式动画参数。introDone 之后 delay 归零：.animation 仍挂在行上，
   * 之后的颜色等变化不应再继承交错延迟。
   */
  static reveal(index: number, introDone: boolean): AnimateParam {
    const param: AnimateParam = {
      duration: Motion.duration(Motion.BASE_MS),
      curve: Curve.FastOutSlowIn,
      delay: introDone ? 0 : Motion.stagger(index)
    };
    return param;
  }

  /** 颜色 / 选中态过渡（隐式 .animation 用） */
  static colorAnim(): AnimateParam {
    const param: AnimateParam = { duration: Motion.duration(Motion.FAST_MS), curve: Curve.FastOutSlowIn };
    return param;
  }

  /** 空状态 / 加载态 / 提示条出现：纯淡入 */
  static fadeTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .animation({ duration: Motion.duration(Motion.BASE_MS), curve: Curve.FastOutSlowIn });
  }

  /** 内容块出现：淡入 + 轻微上移 */
  static riseTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: Motion.enterOffset() }))
      .animation({ duration: Motion.duration(Motion.BASE_MS), curve: Curve.FastOutSlowIn });
  }

  /** 弹层卡片：淡入 + 自下方 SHEET_OFFSET_VP 上浮 + 0.96→1 缩放 */
  static sheetTransition(): TransitionEffect {
    const offset: number = Motion.enabled ? Motion.SHEET_OFFSET_VP : 0;
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: offset }))
      .combine(TransitionEffect.scale({ x: Motion.enabled ? 0.96 : 1, y: Motion.enabled ? 0.96 : 1 }))
      .animation({ duration: Motion.duration(Motion.BASE_MS), curve: Curve.FastOutSlowIn });
  }

  /**
   * 列表行入场：淡入 + 上移 + 按行号交错。插入时由框架播放（数据异步到达 / 新增行）；
   * 调用方在 INTRO_WINDOW_MS 之后改传 TransitionEffect.IDENTITY，滚动复用 / 进度刷新不再重播。
   */
  static listItemTransition(index: number): TransitionEffect {
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: Motion.enterOffset() }))
      .animation({
        duration: Motion.duration(Motion.BASE_MS),
        curve: Curve.FastOutSlowIn,
        delay: Motion.stagger(index)
      });
  }
}
