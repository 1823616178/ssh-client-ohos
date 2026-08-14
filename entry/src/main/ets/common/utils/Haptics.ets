/**
 * Haptics —— 轻触感反馈统一入口（DESIGN §4.4「触感」：连接成功/断开/复制/
 * 粘滞键切换用 @ohos.vibrator 轻震）。
 *
 * 收敛到这里的原因：vibrator.startVibration 需要 ohos.permission.VIBRATE
 * （module.json5 已声明）；设备无马达、权限未授予或系统拒绝时抛
 * BusinessError——触感是体验增强而非功能路径，一律 try/catch 吞掉只记日志，
 * 绝不让震动失败影响按键/复制主流程。
 */

import { vibrator } from '@kit.SensorServiceKit';
import { Logger } from './Logger';

/** 轻震时长（ms）：粘滞键切换/复制成功等「确认型」反馈 */
const LIGHT_VIBRATE_DURATION_MS = 20;

/**
 * 轻震一次（异步发起，不等结果；失败静默降级只记日志）。
 *
 * @param enabled 触感总开关（C3 hapticEnabled），false 时直接返回
 */
export function vibrateLight(enabled: boolean): void {
  if (!enabled) {
    return;
  }
  try {
    vibrator.startVibration(
      { type: 'time', duration: LIGHT_VIBRATE_DURATION_MS },
      { usage: 'touch' }
    ).then(() => {
      // 成功无需处理
    }).catch((err: Object) => {
      Logger.warn(`轻震反馈失败（已忽略）：${JSON.stringify(err)}`, 'Haptics');
    });
  } catch (err) {
    // 同步异常（权限未授予/设备不支持）：忽略，不影响主流程
    Logger.warn(`轻震反馈不可用（已忽略）：${JSON.stringify(err)}`, 'Haptics');
  }
}
