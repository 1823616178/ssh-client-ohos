/**
 * SettingsPage —— 通用设置（DESIGN §8）。
 *
 * 本次只落「后台与续航」一段（P1 的两个设置键此前没有任何界面可改）：
 *   - 后台保持连接（`keepAliveInBackground`，默认开）
 *   - 息屏 N 分钟后断开（`screenOffDisconnectMinutes`，默认关）
 *   - 终端页屏幕常亮（`keepScreenOnMode`，默认「有会话时」）
 * 主题 / 字号 / 关于 / 开源许可等留给后续任务往下追加分段。
 *
 * 改动即时生效：写 preferences 之后立刻 `BackgroundKeepAlive.refreshSettings()`，
 * 由策略机按新设置纠正当前姿态（例如在后台关掉保活开关 → 立即还电并走宽限断开），
 * 不必等下一次前后台切换。
 *
 * 纪律：颜色与尺寸一律走 Design Token（`theme/Tokens`），不写魔法数字。
 */

import { router } from '@kit.ArkUI';
import { Tokens } from '../theme/Tokens';
import { PageHeader } from '../view/PageHeader';
import { Logger } from '../common/utils/Logger';
import { KeepScreenOnMode, SettingsRepository } from '../repository/SettingsRepository';
import { BackgroundKeepAlive } from '../service/background/BackgroundKeepAlive';
import { ScreenAwake } from '../service/ScreenAwake';
import {
  backgroundSummary,
  keepScreenOnLabels,
  keepScreenOnModeOf,
  keepScreenOnOptionIndex,
  keepScreenOnSummary,
  screenOffLabels,
  screenOffMinutesOf,
  screenOffOptionIndex
} from '../viewmodel/SettingsViewModel';
import { OPEN_SOURCE_LICENSES } from '../common/constants/OpenSourceLicenses';
import { I18nKeys, t } from '../common/i18n/I18n';

const LOG_TAG: string = 'SettingsPage';

@Entry
@ComponentV2
struct SettingsPage {
  @Local private keepAliveInBackground: boolean = true;
  @Local private screenOffMinutes: number = 0;
  @Local private keepScreenOnMode: KeepScreenOnMode = 'session';

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  private reload(): void {
    this.keepAliveInBackground = SettingsRepository.isKeepAliveInBackground();
    this.screenOffMinutes = SettingsRepository.getScreenOffDisconnectMinutes();
    this.keepScreenOnMode = SettingsRepository.getKeepScreenOnMode();
  }

  /** 常亮档位落库 + 通知常亮服务（当前若正开着终端页，立刻按新档生效） */
  private applyKeepScreenOn(): void {
    SettingsRepository.setKeepScreenOnMode(this.keepScreenOnMode);
    ScreenAwake.get().refreshSettings();
    Logger.info(`屏幕常亮档位已更新：${this.keepScreenOnMode}`, LOG_TAG);
  }

  /** 落库 + 通知策略机（两个开关共用一条出口，避免漏通知） */
  private applyBackgroundSettings(): void {
    SettingsRepository.setKeepAliveInBackground(this.keepAliveInBackground);
    SettingsRepository.setScreenOffDisconnectMinutes(this.screenOffMinutes);
    BackgroundKeepAlive.get().refreshSettings();
    Logger.info(
      `后台设置已更新：保活=${this.keepAliveInBackground} 息屏断开=${this.screenOffMinutes}min`,
      LOG_TAG);
  }

  build() {
    Column() {
      PageHeader({
        title: t(I18nKeys.SETTINGS_TITLE, '设置'),
        subtitle: '后台续航、工具与关于',
        backLabel: t(I18nKeys.NAV_BACK, '返回')
      })


      Scroll() {
        Column() {
          this.BackgroundSection()
          this.ToolsSection()
          this.AboutSection()
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

  /** 后台与续航段 */
  @Builder
  BackgroundSection() {
    Column() {
      Text(t(I18nKeys.SETTINGS_BACKGROUND_SECTION, '后台与续航'))
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .margin({ bottom: Tokens.space.xs2 })

      Text(backgroundSummary(this.keepAliveInBackground, this.screenOffMinutes))
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ bottom: Tokens.space.sm })

      // 后台保持连接
      Row() {
        Column() {
          Text(t(I18nKeys.SETTINGS_BACKGROUND_KEEP_ALIVE, '后台保持连接'))
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
          Text('切到后台时申请系统长时任务维持 SSH 会话')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.xs2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.keepAliveInBackground })
          .selectedColor(Tokens.Color.accent)
          .onChange((isOn: boolean) => {
            this.keepAliveInBackground = isOn;
            this.applyBackgroundSettings();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(Tokens.Color.border)
        .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

      // 息屏断开
      Text('息屏后断开')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
      Text('息屏满设定时长即优雅断开，亮屏取消计时')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.xs })

      this.ScreenOffPicker()

      Divider()
        .color(Tokens.Color.border)
        .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

      // 屏幕常亮：把「自动息屏」这个触发源直接掐掉，比事后保活更有效
      Text('屏幕常亮')
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
      Text(keepScreenOnSummary(this.keepScreenOnMode))
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ top: Tokens.space.xs2, bottom: Tokens.space.xs })

      this.KeepScreenOnPicker()

      // 系统行为说明：让用户明白「后台掉线不是应用崩了」，也知道回前台会自动重连
      Text('说明：系统可能在长时间低速传输时回收后台任务。发生时会话会优雅断开并保留在标签里，' +
        '回到应用后自动重连，不会静默失联。')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textFaint)
        .margin({ top: Tokens.space.sm })
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
  }

  /** 密钥 / 外观 / 配置工具入口 */
  @Builder
  ToolsSection() {
    Column() {
      Text(t(I18nKeys.SETTINGS_TOOLS_SECTION, '工具'))
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .margin({ bottom: Tokens.space.xs2 })
      this.NavRow('密钥管理', '导入/导出私钥、解锁进应用内 Agent', 'pages/KeyManagerPage')
      this.NavRow('终端外观', '主题预设、20 色取色、配色导入', 'pages/AppearancePage')
      this.NavRow('功能键条', '终端底部快捷键的顺序与增删', 'pages/KeyBarEditorPage')
      this.NavRow('配置中心', '主机/分组/片段/转发集中管理', 'pages/ConfigManagerPage')
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
    .margin({ top: Tokens.space.sm })
  }

  @Builder
  AboutSection() {
    Column() {
      Text(t(I18nKeys.SETTINGS_ABOUT_SECTION, '关于与合规'))
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.text)
        .margin({ bottom: Tokens.space.xs2 })
      Text(`开源组件 ${OPEN_SOURCE_LICENSES.length} 项：OpenSSL / libssh2 / libvterm / libargon2 / 字体等`)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ bottom: Tokens.space.sm })
      this.NavRow(t(I18nKeys.SETTINGS_OPEN_SOURCE, '开源许可'),
        t(I18nKeys.SETTINGS_OPEN_SOURCE_SUB, '第三方许可证摘要'), 'pages/OpenSourceLicensesPage')
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .padding(Tokens.space.md)
    .width('100%')
    .margin({ top: Tokens.space.sm })
  }

  @Builder
  NavRow(title: string, subtitle: string, url: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
        Text(subtitle)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(Tokens.fontSize.title)
        .fontColor(Tokens.Color.textFaint)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
    .accessibilityText(title)
    .accessibilityDescription(subtitle)
    .onClick(() => {
      router.pushUrl({ url: url });
    })
  }

  /** 息屏档位分段控件（档位表见 viewmodel/SettingsViewModel） */
  @Builder
  ScreenOffPicker() {
    Row() {
      ForEach(screenOffLabels(), (label: string, index: number) => {
        Text(label)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(index === screenOffOptionIndex(this.screenOffMinutes)
            ? Tokens.Color.onAccent : Tokens.Color.textDim)
          .backgroundColor(index === screenOffOptionIndex(this.screenOffMinutes)
            ? Tokens.Color.accent : Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)
          .padding({
            left: Tokens.space.sm,
            right: Tokens.space.sm,
            top: Tokens.space.xs2,
            bottom: Tokens.space.xs2
          })
          .margin({ right: Tokens.space.xs })
          .onClick(() => {
            this.screenOffMinutes = screenOffMinutesOf(index);
            this.applyBackgroundSettings();
          })
      }, (label: string) => label)
    }
    .width('100%')
  }

  /** 屏幕常亮档位分段控件（档位表见 viewmodel/SettingsViewModel） */
  @Builder
  KeepScreenOnPicker() {
    Row() {
      ForEach(keepScreenOnLabels(), (label: string, index: number) => {
        Text(label)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(index === keepScreenOnOptionIndex(this.keepScreenOnMode)
            ? Tokens.Color.onAccent : Tokens.Color.textDim)
          .backgroundColor(index === keepScreenOnOptionIndex(this.keepScreenOnMode)
            ? Tokens.Color.accent : Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)
          .padding({
            left: Tokens.space.sm,
            right: Tokens.space.sm,
            top: Tokens.space.xs2,
            bottom: Tokens.space.xs2
          })
          .margin({ right: Tokens.space.xs })
          .onClick(() => {
            this.keepScreenOnMode = keepScreenOnModeOf(index);
            this.applyKeepScreenOn();
          })
      }, (label: string) => label)
    }
    .width('100%')
  }
}
