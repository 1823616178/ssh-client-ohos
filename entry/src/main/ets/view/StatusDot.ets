/**
 * StatusDot —— 主机 / 会话连接状态点。connecting 时做轻量呼吸（仅 opacity，
 * 无限往返），其余状态静止。颜色映射与 HostListPage.connStatusColor 一致。
 */
import { HostConnStatus } from '../viewmodel/HostListViewModel';
import { Motion } from '../theme/Motion';
import { Tokens } from '../theme/Tokens';

export function hostConnStatusColor(status: HostConnStatus): Resource {
  switch (status) {
    case 'connecting':
      return Tokens.Color.accent;
    case 'established':
      return Tokens.Color.success;
    case 'disconnected':
      return Tokens.Color.warn;
    case 'error':
      return Tokens.Color.danger;
    default:
      return Tokens.Color.textFaint;
  }
}

@Component
export struct StatusDot {
  @Prop @Watch('onStatusChanged') status: HostConnStatus = 'none';
  @Prop dotSize: number = 8;
  @State private dimmed: boolean = false;
  private mounted: boolean = false;

  private onStatusChanged(): void {
    if (this.mounted) {
      this.syncPulse();
    }
  }

  private syncPulse(): void {
    if (this.status === 'connecting' && Motion.enabled) {
      this.getUIContext().animateTo({
        duration: Motion.PULSE_MS,
        curve: Curve.EaseInOut,
        iterations: -1,
        playMode: PlayMode.Alternate
      }, () => {
        this.dimmed = true;
      });
    } else {
      // duration 0 的 animateTo 覆盖并终止无限呼吸
      this.getUIContext().animateTo({ duration: 0 }, () => {
        this.dimmed = false;
      });
    }
  }

  build() {
    Column()
      .width(this.dotSize)
      .height(this.dotSize)
      .borderRadius(this.dotSize / 2)
      .backgroundColor(hostConnStatusColor(this.status))
      .opacity(this.dimmed ? 0.3 : 1)
      .onAppear(() => {
        this.mounted = true;
        this.syncPulse();
      })
      .onDisAppear(() => {
        this.mounted = false;
      })
  }
}
