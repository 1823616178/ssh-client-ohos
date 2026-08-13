import { BuildConfig } from '../common/constants/BuildConfig';
import { Tokens } from '../theme/Tokens';

/**
 * 首页：当前作为 Design Token（X2）与构建期配置（X5）的演示与验证点。
 * 颜色与尺寸一律取自 Tokens，验证深浅色切换与尺度 Token 生效。
 */
@Entry
@Component
struct Index {
  // X5 运行时验证点：直接展示构建期注入的同步服务器地址
  @State message: string = `同步服务器: ${BuildConfig.SYNC_API_URL}`;

  build() {
    Column() {
      // 卡片：app_surface + radius_md + space_md
      Column() {
        Text($r('app.string.app_name'))
          .fontSize(Tokens.fontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)

        Text(this.message)
          .id('SyncApiUrl')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm })

        // 强调色元素：app_accent
        Text('立即连接')
          .fontSize(Tokens.fontSize.title)
          .fontColor(Color.White)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .padding({
            left: Tokens.space.lg,
            right: Tokens.space.lg,
            top: Tokens.space.xs,
            bottom: Tokens.space.xs
          })
          .margin({ top: Tokens.space.lg })
      }
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.md)
      .padding(Tokens.space.md)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.appBg)
  }
}
