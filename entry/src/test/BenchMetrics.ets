/**
 * Q2 基准门禁纯指标计算 —— 与 scripts/bench/gate.sh 语义对齐。
 *
 * 放在 test 树内（entry/src/test/）作为纯逻辑 helper：不依赖设备/hdc，
 * hypium 可测；真机采集器产出 report JSON 后由 gate.sh 门禁，本模块锁定
 * 「怎样算过线」的数值语义，防止脚本与未来 ArkTS 侧报告代码漂移。
 *
 * 阈值默认值来自 DESIGN §1.2 / TASKS Q2：
 *   cat 5MB / 4 分屏并发 ≥ 50 fps；内存峰值 < 400 MB。
 * 脚本侧可用 BENCH_MIN_FPS / BENCH_MAX_RSS_MB 覆盖；两侧默认必须一致。
 */

/** DESIGN §1.2：终端不掉帧下限 */
export const DEFAULT_MIN_FPS: number = 50;

/** TASKS Q2：内存峰值上限（MB） */
export const DEFAULT_MAX_RSS_MB: number = 400;

/** TASKS Q3：长稳 RSS 增长上限百分比 */
export const DEFAULT_RSS_GROWTH_LIMIT_PCT: number = 5;

/** 报告契约版本（scripts/bench/report-schema.json） */
export const BENCH_REPORT_SCHEMA_VERSION: number = 1;

/** Q2 四场景 ID */
export const BENCH_SCENARIO_IDS: string[] = [
  'cat_5mb',
  'yes_burst',
  'host_list_100',
  'pane_4_concurrent'
];

/** 报告中的单场景度量（子集，与 JSON 字段名对齐） */
export interface BenchScenarioMetrics {
  readonly id: string;
  /** pass | fail | skipped | dry-run */
  readonly status: string;
  readonly fpsAvg: number | null;
  readonly fpsP1: number | null;
  readonly rssPeakMb: number | null;
}

/** 门禁结论 */
export interface BenchGateResult {
  readonly ok: boolean;
  /** 未过线/缺失原因，人可读；ok=true 时为空 */
  readonly reasons: string[];
  /** 参与数值门禁的场景数 */
  readonly measuredCount: number;
}

function isFiniteNumber(v: number | null): boolean {
  return v !== null && v !== undefined && typeof v === 'number' &&
    isFinite(v) && !isNaN(v);
}

/**
 * 由帧间隔序列（ms）求平均 fps：fps = mean(1000/d_i)，跳过非正间隔。
 * 空序列返回 0。
 */
export function fpsFromFrameDurationsMs(frameDurationsMs: number[]): number {
  if (frameDurationsMs.length === 0) {
    return 0;
  }
  let sum: number = 0;
  let n: number = 0;
  for (let i = 0; i < frameDurationsMs.length; i++) {
    const d: number = frameDurationsMs[i];
    if (typeof d === 'number' && isFinite(d) && d > 0) {
      sum += 1000 / d;
      n++;
    }
  }
  if (n === 0) {
    return 0;
  }
  return sum / n;
}

/**
 * 帧率序列的百分位（线性插值与 numpy 默认一致的 nearest-rank 变体：
 * 排序后取 index = ceil(p/100 * n) - 1，p∈(0,100]）。空序列返回 0。
 * 用于 fpsP1（1% low）等门禁辅证。
 */
export function percentileFps(fpsSamples: number[], p: number): number {
  const n: number = fpsSamples.length;
  if (n === 0) {
    return 0;
  }
  const clean: number[] = [];
  for (let i = 0; i < n; i++) {
    const v: number = fpsSamples[i];
    if (typeof v === 'number' && isFinite(v)) {
      clean.push(v);
    }
  }
  if (clean.length === 0) {
    return 0;
  }
  clean.sort((a: number, b: number): number => a - b);
  const clamped: number = Math.min(100, Math.max(0, p));
  let idx: number = Math.ceil((clamped / 100) * clean.length) - 1;
  if (idx < 0) {
    idx = 0;
  }
  if (idx >= clean.length) {
    idx = clean.length - 1;
  }
  return clean[idx];
}

/** fps 是否达到门槛（严格：>= min） */
export function passesFpsGate(fpsAvg: number | null, minFps: number = DEFAULT_MIN_FPS): boolean {
  if (!isFiniteNumber(fpsAvg)) {
    return false;
  }
  return (fpsAvg as number) >= minFps;
}

/** RSS 峰值是否低于上限（严格：< max，等于上限算失败，与 gate.sh 一致） */
export function passesRssGate(rssPeakMb: number | null,
  maxRssMb: number = DEFAULT_MAX_RSS_MB): boolean {
  if (!isFiniteNumber(rssPeakMb)) {
    return false;
  }
  return (rssPeakMb as number) < maxRssMb;
}

/**
 * 长稳 RSS 增长百分比：(end-start)/start*100。
 * start 非正时返回 Infinity（视为失败信号，避免除零静默通过）。
 */
export function rssGrowthPercent(rssStartMb: number, rssEndMb: number): number {
  if (!isFiniteNumber(rssStartMb) || !isFiniteNumber(rssEndMb)) {
    return Infinity;
  }
  if ((rssStartMb as number) <= 0) {
    return Infinity;
  }
  return ((rssEndMb as number) - (rssStartMb as number)) / (rssStartMb as number) * 100;
}

/** 长稳是否达标（TASKS Q3：8h RSS 增长 < 5%） */
export function passesRssGrowthGate(rssStartMb: number, rssEndMb: number,
  limitPct: number = DEFAULT_RSS_GROWTH_LIMIT_PCT): boolean {
  const growth: number = rssGrowthPercent(rssStartMb, rssEndMb);
  return growth < limitPct;
}

/** 场景是否携带可门禁的实测数值 */
export function isMeasuredScenario(s: BenchScenarioMetrics): boolean {
  return isFiniteNumber(s.fpsAvg) || isFiniteNumber(s.rssPeakMb);
}

/** dry-run / skipped 不参与数值门禁 */
export function isSkippedStatus(status: string): boolean {
  return status === 'dry-run' || status === 'skipped';
}

/**
 * 单场景门禁：返回失败原因，通过则空串。
 * dry-run/skipped → 空串（未测不判失败，除非 requireAll 在报告级处理）。
 * 有数值则分别检查 fps 与 rss；缺另一项时仅在 requireAllNumeric 下记原因。
 */
export function evaluateScenarioGate(s: BenchScenarioMetrics,
  minFps: number = DEFAULT_MIN_FPS,
  maxRssMb: number = DEFAULT_MAX_RSS_MB,
  requireAllNumeric: boolean = false): string {
  if (isSkippedStatus(s.status)) {
    return '';
  }
  if (!isMeasuredScenario(s)) {
    return requireAllNumeric ? `${s.id}: 缺少实测 fps/rss` : '';
  }
  const reasons: string[] = [];
  if (isFiniteNumber(s.fpsAvg)) {
    if (!passesFpsGate(s.fpsAvg, minFps)) {
      reasons.push(`${s.id}: fpsAvg=${s.fpsAvg} < ${minFps}`);
    }
  } else if (requireAllNumeric) {
    reasons.push(`${s.id}: 缺少 fpsAvg`);
  }
  if (isFiniteNumber(s.rssPeakMb)) {
    if (!passesRssGate(s.rssPeakMb, maxRssMb)) {
      reasons.push(`${s.id}: rssPeakMb=${s.rssPeakMb} >= ${maxRssMb}`);
    }
  } else if (requireAllNumeric) {
    reasons.push(`${s.id}: 缺少 rssPeakMb`);
  }
  return reasons.length > 0 ? reasons.join('; ') : '';
}

/**
 * 报告级门禁（与 scripts/bench/gate.sh 对齐）。
 * requireAll=true 时四个场景 ID 必须都出现且含数值。
 */
export function evaluateReportGate(scenarios: BenchScenarioMetrics[],
  minFps: number = DEFAULT_MIN_FPS,
  maxRssMb: number = DEFAULT_MAX_RSS_MB,
  requireAll: boolean = false): BenchGateResult {
  const reasons: string[] = [];
  let measuredCount: number = 0;
  const seen: string[] = [];
  for (let i = 0; i < scenarios.length; i++) {
    const s: BenchScenarioMetrics = scenarios[i];
    seen.push(s.id);
    if (!isSkippedStatus(s.status) && isMeasuredScenario(s)) {
      measuredCount++;
    }
    const reason: string = evaluateScenarioGate(s, minFps, maxRssMb, requireAll);
    if (reason.length > 0) {
      reasons.push(reason);
    }
  }
  if (requireAll) {
    for (let j = 0; j < BENCH_SCENARIO_IDS.length; j++) {
      const id: string = BENCH_SCENARIO_IDS[j];
      if (seen.indexOf(id) < 0) {
        reasons.push(`缺少场景: ${id}`);
      }
    }
    // requireAll：每个场景必须带可门禁实测数值（dry-run/skipped/缺数值 → 失败）
    if (measuredCount < BENCH_SCENARIO_IDS.length) {
      reasons.push(`requireAll: 实测场景数 ${measuredCount} < ${BENCH_SCENARIO_IDS.length}`);
    }
  }
  return {
    ok: reasons.length === 0,
    reasons: reasons,
    measuredCount: measuredCount
  };
}

/**
 * 由帧间隔序列直接构造一条可过线的场景度量（设备采集器/测试共用）。
 * status 固定 pass（调用方应先确保采集完成）。
 */
export function scenarioFromFrameDurations(id: string,
  frameDurationsMs: number[],
  rssPeakMb: number | null): BenchScenarioMetrics {
  return {
    id: id,
    status: 'pass',
    fpsAvg: fpsFromFrameDurationsMs(frameDurationsMs),
    fpsP1: percentileFps(frameDurationsMs.map((d: number): number =>
      d > 0 ? 1000 / d : 0), 1),
    rssPeakMb: rssPeakMb
  };
}
