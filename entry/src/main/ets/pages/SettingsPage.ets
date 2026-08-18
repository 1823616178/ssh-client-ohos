/**
 * SettingsPage —— 通用设置（DESIGN §8）。
 *
 * 本次只落「后台与续航」一段（P1 的两个设置键此前没有任何界面可改）：
 *   - 后台保持连接（`keepAliveInBackground`，默认开）
 *   - 息屏 N 分钟后断开（`screenOffDisconnectMinutes`，默认关）
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
import { Logger } from '../common/utils/Logger';
import { SettingsRepository } from '../repository/SettingsRepository';
import { BackgroundKeepAlive } from '../service/background/BackgroundKeepAlive';
import {
  backgroundSummary,
  screenOffLabels,
  screenOffMinutesOf,
  screenOffOptionIndex
} from '../viewmodel/SettingsViewModel';

const LOG_TAG: string = 'SettingsPage';

@Entry
@ComponentV2
struct SettingsPage {
  @Local private keepAliveInBackground: boolean = true;
  @Local private screenOffMinutes: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  private reload(): void {
    this.keepAliveInBackground = SettingsRepository.isKeepAliveInBackground();
    this.screenOffMinutes = SettingsRepository.getScreenOffDisconnectMinutes();
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
      this.TopBar()

      Scroll() {
        Column() {
          this.BackgroundSection()
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

  @Builder
  TopBar() {
    Row() {
      Button() {
        Text('‹')
          .fontSize(Tokens.fontSize.display)
          .fontColor(Tokens.Color.text)
          .fontWeight(FontWeight.Regular)
      }
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.sm)
      .width(36)
      .height(36)
      .onClick(() => {
        router.back();
      })

      Column() {
        Text('SETTINGS')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.accent)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(1.2)
        Text('设置')
          .fontSize(Tokens.fontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: Tokens.space.sm })

      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(Tokens.space.md)
  }

  /** 后台与续航段 */
  @Builder
  BackgroundSection() {
    Column() {
      Text('后台与续航')
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
          Text('后台保持连接')
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
}
