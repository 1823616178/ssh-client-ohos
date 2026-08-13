import { BuildConfig } from '../common/constants/BuildConfig';

@Entry
@Component
struct Index {
  // X5 运行时验证点：直接展示构建期注入的同步服务器地址
  @State message: string = `同步服务器: ${BuildConfig.SYNC_API_URL}`;

  build() {
    RelativeContainer() {
      Text(this.message)
        .id('SyncApiUrl')
        .fontSize($r('app.float.page_text_font_size'))
        .fontWeight(FontWeight.Bold)
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
    }
    .height('100%')
    .width('100%')
  }
}
