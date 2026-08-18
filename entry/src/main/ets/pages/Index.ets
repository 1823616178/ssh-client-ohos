/**
 * 首页：以 HostListPage（主机列表）作为主体全屏呈现。
 */

import { Tokens } from '../theme/Tokens';
import { HostListPage } from './HostListPage';

@Entry
@Component
struct Index {
  // 从 HostEditPage / ConfigManagerPage 等子页面返回时递增，驱动内嵌 HostListPage 重载
  @State listRefreshTick: number = 0;

  /** 页面重新显示（含从编辑页/配置管理页返回）：递增 tick 通知主机列表重载 */
  onPageShow(): void {
    this.listRefreshTick = this.listRefreshTick + 1;
  }

  build() {
    Column() {
      HostListPage({ refreshTick: this.listRefreshTick })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
