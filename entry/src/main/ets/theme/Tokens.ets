/**
 * Design Token 封装（DESIGN §4.2）。
 *
 * 全部 Token 以资源引用（`$r`）形式暴露：颜色深浅色切换由
 * resources/dark/element/color.json 的同名覆盖机制自动生效，
 * 圆角/间距/字号统一从 resources/base/element/float.json 取值。
 * 组件内出现颜色或尺寸时引用本类（或直接 `$r`），禁止写魔法数字。
 *
 * 注意：分组属性均为只读，初始化后不可变；ArkTS 严格模式下不使用 any/unknown。
 */

/** 颜色 Token：名称与 color.json 一一对应（camelCase 形式） */
class ColorTokens {
  /** 页面底 */
  readonly appBg: Resource = $r('app.color.app_bg');
  /** 卡片 */
  readonly surface: Resource = $r('app.color.app_surface');
  /** 按压/悬浮 */
  readonly surfaceHover: Resource = $r('app.color.app_surface_hover');
  /** 分隔线 */
  readonly border: Resource = $r('app.color.app_border');
  /** 主文字 */
  readonly text: Resource = $r('app.color.app_text');
  /** 次要文字 */
  readonly textDim: Resource = $r('app.color.app_text_dim');
  /** 占位/提示 */
  readonly textFaint: Resource = $r('app.color.app_text_faint');
  /** 强调（电青） */
  readonly accent: Resource = $r('app.color.app_accent');
  /** 强调浅底（卡片描边/徽标底） */
  readonly accentMuted: Resource = $r('app.color.app_accent_muted');
  /** 强调色上的文字 */
  readonly onAccent: Resource = $r('app.color.app_on_accent');
  /** 状态：成功 */
  readonly success: Resource = $r('app.color.app_success');
  /** 状态：警告 */
  readonly warn: Resource = $r('app.color.app_warn');
  /** 状态：危险 */
  readonly danger: Resource = $r('app.color.app_danger');
}

/** 圆角 Token（vp） */
class RadiusTokens {
  readonly xs: Resource = $r('app.float.radius_xs');
  readonly sm: Resource = $r('app.float.radius_sm');
  readonly md: Resource = $r('app.float.radius_md');
  readonly lg: Resource = $r('app.float.radius_lg');
}

/** 间距 Token（vp） */
class SpaceTokens {
  readonly xs2: Resource = $r('app.float.space_2xs');
  readonly xs: Resource = $r('app.float.space_xs');
  readonly sm: Resource = $r('app.float.space_sm');
  readonly md: Resource = $r('app.float.space_md');
  readonly lg: Resource = $r('app.float.space_lg');
  readonly xl: Resource = $r('app.float.space_xl');
}

/** 字号 Token（fp） */
class FontSizeTokens {
  readonly caption: Resource = $r('app.float.font_caption');
  readonly body: Resource = $r('app.float.font_body');
  readonly title: Resource = $r('app.float.font_title');
  readonly headline: Resource = $r('app.float.font_headline');
  readonly display: Resource = $r('app.float.font_display');
}

/** Design Token 统一入口 */
export class Tokens {
  static readonly Color: ColorTokens = new ColorTokens();
  static readonly radius: RadiusTokens = new RadiusTokens();
  static readonly space: SpaceTokens = new SpaceTokens();
  static readonly fontSize: FontSizeTokens = new FontSizeTokens();
}
