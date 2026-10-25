/**
 * OpenSourceLicensesPage —— 应用内开源许可页。
 * 统一 PageHeader（中文标题 + 无英文眉题）。
 */

import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';
import { OPEN_SOURCE_LICENSES, OpenSourceLicenseEntry } from '../common/constants/OpenSourceLicenses';
import { PageHeader } from '../view/PageHeader';

@Entry
@ComponentV2
struct OpenSourceLicensesPage {
  /** 首屏入场窗口已过：列表行改用 IDENTITY 过渡（Motion.listItemTransition 注释） */
  @Local private introDone: boolean = !Motion.enabled;
  aboutToAppear(): void {
    this.openIntroWindow();
  }

  /** 首屏入场窗口：INTRO_WINDOW_MS 内插入的列表行交错入场，之后直接终态 */
  private openIntroWindow(): void {
    if (this.introDone) {
      return;
    }
    setTimeout(() => {
      this.introDone = true;
    }, Motion.INTRO_WINDOW_MS);
  }

  /**
   * 页面转场（router 路由，pageTransition）：push 新页自右 PAGE_OFFSET_VP 淡入推入、旧页轻微左移；
   * pop 反向。只动 opacity/translate（合成层属性，画布不重绘）；Motion 总开关关闭时时长 0。
   */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: Motion.pageOffset() })
      .opacity(0)
    PageTransitionEnter({ type: RouteType.Pop, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: -Motion.pageOffset() / 2 })
    PageTransitionExit({ type: RouteType.Push, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: -Motion.pageOffset() / 2 })
    PageTransitionExit({ type: RouteType.Pop, duration: Motion.duration(Motion.SLOW_MS), curve: Curve.FastOutSlowIn })
      .translate({ x: Motion.pageOffset() })
      .opacity(0)
  }

  build() {
    Column() {
      PageHeader({
        title: '开源许可',
        subtitle: '第三方组件与许可证摘要'
      })

      Scroll() {
        Column() {
          Text('本应用链接或随包分发以下开源组件。完整条款见仓库 OPEN_SOURCE_LICENSES.md 与字体 OFL 全文。')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .margin({ bottom: Tokens.space.sm })
          ForEach(OPEN_SOURCE_LICENSES, (entry: OpenSourceLicenseEntry, index: number) => {
            Column() {
              Text(`${entry.name} ${entry.version}`)
                .fontSize(Tokens.fontSize.body)
                .fontWeight(FontWeight.Bold)
                .fontColor(Tokens.Color.text)
              Text(entry.license)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.accent)
                .margin({ top: Tokens.space.xs2 })
              Text(entry.usage)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
                .margin({ top: Tokens.space.xs2 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(Tokens.space.md)
            .backgroundColor(Tokens.Color.surface)
            .borderRadius(Tokens.radius.md)
            .margin({ bottom: Tokens.space.sm })
            // 首屏交错入场（INTRO_WINDOW_MS 后 IDENTITY：滚动复用/数据刷新不重播）
            .transition(this.introDone ? TransitionEffect.IDENTITY : Motion.listItemTransition(index))
          }, (entry: OpenSourceLicenseEntry) => entry.name)
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
}
