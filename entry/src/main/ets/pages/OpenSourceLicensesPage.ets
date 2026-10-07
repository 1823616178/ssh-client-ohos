/**
 * OpenSourceLicensesPage —— 应用内开源许可页。
 * 统一 PageHeader（中文标题 + 无英文眉题）。
 */

import { Tokens } from '../theme/Tokens';
import { OPEN_SOURCE_LICENSES, OpenSourceLicenseEntry } from '../common/constants/OpenSourceLicenses';
import { PageHeader } from '../view/PageHeader';

@Entry
@ComponentV2
struct OpenSourceLicensesPage {
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
          ForEach(OPEN_SOURCE_LICENSES, (entry: OpenSourceLicenseEntry) => {
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
