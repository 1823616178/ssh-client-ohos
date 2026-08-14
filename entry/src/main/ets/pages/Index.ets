import { BuildConfig } from '../common/constants/BuildConfig';
import { Tokens } from '../theme/Tokens';
import libsshCore from 'libssh_core.so';

/**
 * 首页：当前作为 Design Token（X2）与构建期配置（X5）的演示与验证点。
 * 颜色与尺寸一律取自 Tokens，验证深浅色切换与尺度 Token 生效。
 * 「测试原生库」为 N3 验证点：调用 libssh_core.so 展示四个原生依赖版本。
 */
@Entry
@Component
struct Index {
  // X5 运行时验证点：直接展示构建期注入的同步服务器地址
  @State message: string = `同步服务器: ${BuildConfig.SYNC_API_URL}`;
  // N3 验证点：原生依赖版本信息或错误文本
  @State nativeResult: string = '';

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

        // N3 验证点：调用原生库，展示 libssh2/OpenSSL/vterm/argon2 版本
        Button('测试原生库')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Color.White)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .margin({ top: Tokens.space.lg })
          .onClick(() => {
            try {
              this.nativeResult = [
                `libssh2: ${libsshCore.getLibssh2Version()}`,
                `OpenSSL: ${libsshCore.getOpensslVersion()}`,
                `libvterm: ${libsshCore.getVtermVersion()}`,
                `argon2: ${libsshCore.getArgon2Version()}`
              ].join('\n');
            } catch (e) {
              this.nativeResult = `原生调用失败: ${JSON.stringify(e)}`;
            }
          })

        if (this.nativeResult.length > 0) {
          Text(this.nativeResult)
            .id('NativeResult')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.sm })
        }
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
