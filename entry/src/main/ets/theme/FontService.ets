/**
 * 终端字体注册服务（任务 T5，DESIGN §4.4 字体节）。
 *
 * 随包字体（entry/src/main/resources/rawfile/font/，均为 OFL 许可，许可文本同目录，
 * P3 合规取用）：
 *  - JetBrains Mono Regular / Bold：ASCII 等宽基准（cell 宽 = measureText('W')）；
 *  - Sarasa Term SC Regular：CJK 等宽，与 JetBrains Mono 严格 1:2 对齐（宽字符 = 2 cell）。
 *    单只 TTF 约 25 MB，远超随包体积阈值（~15 MB），首版取舍：**Bold 不随包**——
 *    粗体中文由系统合成粗体或回落 Regular，格宽不变、对齐不破；真机观感若不接受，
 *    再评估子集化方案（见 TASKS T5 真机待验清单）。
 *
 * 注册：EntryAbility.onCreate 调 registerTerminalFonts()，逐只 try/catch，
 * 失败记日志不崩——渲染侧度量失败时有保底格宽兜底（FontMetrics / TerminalCanvas）。
 *
 * ⚠️ 真机待验（DESIGN §4.4 / TASKS T5）：
 *  1. 同一 familyName 注册 Regular + Bold 两只文件，HarmonyOS 字体匹配是否按
 *     字重分发；若后者覆盖前者，当前注册顺序（先 Bold 后 Regular）保底常规可用；
 *  2. Canvas font 的字族列表回退（"A, B" 中 A 缺字形时落 B）是否逐字生效；
 *     不生效则绘制层需按 ASCII/CJK 分段分别设置 font（影响 TerminalDrawCommands
 *     的文本合并策略）。
 *
 * 注：@ohos.font.registerFont 自 API 18 标记 deprecated（替代品
 * UIContext.registerFont 需要 UIContext 实例，EntryAbility.onCreate 阶段拿不到）；
 * 旧接口仍可用，T5 按任务约定走 onCreate 注册，后续 A 系列任务可评估迁移。
 */
import { font } from '@kit.ArkUI';
import { Logger } from '../common/utils/Logger';

/** ASCII 等宽字族（度量基准） */
export const FONT_STACK_ASCII = 'JetBrains Mono';
/** CJK 等宽字族（宽字符回退） */
export const FONT_STACK_CJK = 'Sarasa Term SC';

/** 注册结果汇总（供启动日志与自检） */
export interface FontRegisterResult {
  /** 计划注册只数 */
  total: number;
  /** 成功只数 */
  succeeded: number;
  /** 失败的 rawfile 路径 */
  failed: string[];
}

let lastResult: FontRegisterResult | null = null;

/**
 * Canvas font 用的字族栈串："JetBrains Mono, Sarasa Term SC"。
 * 列表回退语义是否生效需真机验证（见文件头注待验 2）。
 */
export function buildTerminalFontFamily(): string {
  return `${FONT_STACK_ASCII}, ${FONT_STACK_CJK}`;
}

/**
 * 启动时注册全部随包字体；重复调用幂等（onCreate 可能多次触发，如多窗口）。
 * 任何一只失败只记日志不抛异常。
 */
export function registerTerminalFonts(): FontRegisterResult {
  if (lastResult !== null) {
    return lastResult;
  }
  let total = 0;
  let succeeded = 0;
  const failed: string[] = [];
  const tryRegister = (familyName: string, src: Resource, pathForLog: string): void => {
    total++;
    if (registerOne(familyName, src, pathForLog)) {
      succeeded++;
    } else {
      failed.push(pathForLog);
    }
  };
  // 顺序有意：同 familyName 的 Bold 先注册、Regular 后注册——若系统对同名注册
  // 相互覆盖（待验 1），留下的也是常规体，粗体最多退化为合成粗体
  tryRegister(FONT_STACK_ASCII, $rawfile('font/JetBrainsMono-Bold.ttf'), 'font/JetBrainsMono-Bold.ttf');
  tryRegister(FONT_STACK_ASCII, $rawfile('font/JetBrainsMono-Regular.ttf'), 'font/JetBrainsMono-Regular.ttf');
  tryRegister(FONT_STACK_CJK, $rawfile('font/SarasaTermSC-Regular.ttf'), 'font/SarasaTermSC-Regular.ttf');
  lastResult = { total: total, succeeded: succeeded, failed: failed };
  if (failed.length > 0) {
    Logger.warn(`终端字体注册 ${succeeded}/${total} 成功，失败：${failed.join(', ')}` +
      '（渲染走保底格宽，混排对齐可能失效）', 'Terminal');
  } else {
    Logger.info(`终端字体注册完成（${succeeded}/${total}）：${buildTerminalFontFamily()}`, 'Terminal');
  }
  return lastResult;
}

function registerOne(familyName: string, src: Resource, pathForLog: string): boolean {
  try {
    font.registerFont({ familyName: familyName, familySrc: src });
    return true;
  } catch (e) {
    Logger.error(`registerFont 失败：${pathForLog}（${familyName}）：${JSON.stringify(e)}`, 'Terminal');
    return false;
  }
}
