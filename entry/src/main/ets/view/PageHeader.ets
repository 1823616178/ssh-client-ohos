/**
 * PageHeader —— 二级页统一顶栏（UI 收敛 P0）。
 *
 * 版式：40×40 返回钮（Tokens.fontSize.display 的「‹」）+ 中文标题/可选副标题 + 右侧动作。
 * 标题只用产品中文：设置 / 密钥管理 / 外观 / 开源许可 / 配置中心 / 文件传输 /
 * 端口转发 / 账号与同步 等；禁止全大写英文眉题。颜色尺寸一律 Design Token。
 * 次级按钮使用细描边，页头底部以同色分隔线收束内容区。
 * 右侧动作建议 ≤2 个；主操作 primary=true（accent 底 + onAccent 字）。
 */

import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';

/** 顶栏右侧动作（最多建议 2 个） */
export interface PageHeaderAction {
  label: string;
  onClick: () => void;
  /** true = accent 主按钮；false/缺省 = 次操作 */
  primary?: boolean;
  /** true 时禁用（半透明） */
  disabled?: boolean;
  accessibilityText?: string;
}

@Component
export struct PageHeader {
  /** 中文标题（产品文案） */
  title: string = '';
  /** 副标题（可选，caption 级说明） */
  subtitle: string = '';
  /** 是否显示返回（首页可 false） */
  showBack: boolean = true;
  /** 返回无障碍文案 */
  backLabel: string = '返回';
  /** 右侧动作 */
  actions: PageHeaderAction[] = [];

  build() {
    Column() {
      Row() {
        if (this.showBack) {
          Button() {
            Text('‹')
              .fontSize(Tokens.fontSize.display)
              .fontColor(Tokens.Color.text)
              .fontWeight(FontWeight.Regular)
          }
          .backgroundColor(Tokens.Color.surface)
          .border({ width: Tokens.size.strokeThin, color: Tokens.Color.border })
          .borderRadius(Tokens.radius.sm)
          .width(Tokens.size.control)
          .height(Tokens.size.control)
          .accessibilityText(this.backLabel)
          .clickEffect(Motion.pressEffect())
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
          .margin({ right: Tokens.space.sm })
        }

        Column() {
          Text(this.title)
            .fontSize(Tokens.fontSize.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: Tokens.space.xs2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        ForEach(this.actions, (action: PageHeaderAction, index: number) => {
          Button(action.label)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(action.primary === true ? Tokens.Color.onAccent : Tokens.Color.text)
            .backgroundColor(action.primary === true ? Tokens.Color.accent : Tokens.Color.surface)
            .border({
              width: Tokens.size.strokeThin,
              color: action.primary === true ? Tokens.Color.accent : Tokens.Color.border
            })
            .borderRadius(Tokens.radius.sm)
            .height(Tokens.size.control)
            .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
            .enabled(!(action.disabled === true))
            .opacity(action.disabled === true ? 0.45 : 1)
            .accessibilityText(action.accessibilityText === undefined ? action.label : action.accessibilityText)
            .clickEffect(Motion.pressEffect())
            .margin({ left: Tokens.space.xs })
            .onClick(() => {
              if (action.disabled !== true) {
                action.onClick();
              }
            })
        }, (action: PageHeaderAction, index: number) => `${index}-${action.label}`)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: Tokens.space.md,
        right: Tokens.space.md,
        top: Tokens.space.sm,
        bottom: Tokens.space.sm
      })
    }
    .width('100%')
    .backgroundColor(Tokens.Color.appBg)
    .border({ width: { bottom: Tokens.size.strokeThin }, color: Tokens.Color.border })
  }
}
