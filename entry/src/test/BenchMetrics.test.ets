/**
 * Q2 基准门禁纯逻辑测试（BenchMetrics）。
 *
 * 与 scripts/bench/gate.sh 双面对拍：阈值默认 50 fps / 400 MB、
 * dry-run 不判失败、等于 RSS 上限算失败、requireAll 校验四场景齐全。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  BENCH_SCENARIO_IDS,
  BENCH_REPORT_SCHEMA_VERSION,
  DEFAULT_MAX_RSS_MB,
  DEFAULT_MIN_FPS,
  DEFAULT_RSS_GROWTH_LIMIT_PCT,
  BenchScenarioMetrics,
  evaluateReportGate,
  evaluateScenarioGate,
  fpsFromFrameDurationsMs,
  isMeasuredScenario,
  isSkippedStatus,
  passesFpsGate,
  passesRssGate,
  passesRssGrowthGate,
  percentileFps,
  rssGrowthPercent,
  scenarioFromFrameDurations
} from './BenchMetrics';

function mk(id: string, status: string, fpsAvg: number | null,
  rssPeakMb: number | null): BenchScenarioMetrics {
  return { id: id, status: status, fpsAvg: fpsAvg, fpsP1: null, rssPeakMb: rssPeakMb };
}

export default function benchMetricsTest() {
  describe('BenchMetricsTest', () => {

    it('defaults_match_design_section_1_2', 0, () => {
      expect(DEFAULT_MIN_FPS).assertEqual(50);
      expect(DEFAULT_MAX_RSS_MB).assertEqual(400);
      expect(DEFAULT_RSS_GROWTH_LIMIT_PCT).assertEqual(5);
      expect(BENCH_REPORT_SCHEMA_VERSION).assertEqual(1);
      expect(BENCH_SCENARIO_IDS.length).assertEqual(4);
      expect(BENCH_SCENARIO_IDS.indexOf('pane_4_concurrent') >= 0).assertTrue();
    });

    it('fpsFromFrameDurations_平均帧率', 0, () => {
      // 20ms → 50fps；16ms ≈ 62.5fps
      const avg: number = fpsFromFrameDurationsMs([20, 20, 20, 20]);
      expect(avg).assertEqual(50);
      const mixed: number = fpsFromFrameDurationsMs([16, 20]);
      expect(mixed > 55 && mixed < 57).assertTrue();
      expect(fpsFromFrameDurationsMs([])).assertEqual(0);
      expect(fpsFromFrameDurationsMs([0, -1, 20])).assertEqual(50);
    });

    it('percentileFps_1pct_low', 0, () => {
      // 100 个样本：1 个 10fps，其余 60fps → p1 取最低
      const samples: number[] = [];
      samples.push(10);
      for (let i = 0; i < 99; i++) {
        samples.push(60);
      }
      expect(percentileFps(samples, 1)).assertEqual(10);
      expect(percentileFps(samples, 50)).assertEqual(60);
      expect(percentileFps([], 1)).assertEqual(0);
    });

    it('passesFpsGate_边界等于50通过', 0, () => {
      expect(passesFpsGate(50)).assertTrue();
      expect(passesFpsGate(49.9)).assertFalse();
      expect(passesFpsGate(58.4)).assertTrue();
      expect(passesFpsGate(null)).assertFalse();
      expect(passesFpsGate(50, 55)).assertFalse();
    });

    it('passesRssGate_等于400失败', 0, () => {
      expect(passesRssGate(399.9)).assertTrue();
      expect(passesRssGate(400)).assertFalse();
      expect(passesRssGate(400.1)).assertFalse();
      expect(passesRssGate(null)).assertFalse();
    });

    it('rssGrowth_and_longrun_gate', 0, () => {
      expect(rssGrowthPercent(200, 204)).assertEqual(2);
      expect(passesRssGrowthGate(200, 204)).assertTrue();
      expect(passesRssGrowthGate(200, 212)).assertFalse();
      // start<=0 → Infinity，不通过
      expect(passesRssGrowthGate(0, 10)).assertFalse();
    });

    it('isMeasured_and_skipped_status', 0, () => {
      expect(isSkippedStatus('dry-run')).assertTrue();
      expect(isSkippedStatus('skipped')).assertTrue();
      expect(isSkippedStatus('pass')).assertFalse();
      expect(isMeasuredScenario(mk('a', 'pass', 55, null))).assertTrue();
      expect(isMeasuredScenario(mk('a', 'pass', null, 100))).assertTrue();
      expect(isMeasuredScenario(mk('a', 'pass', null, null))).assertFalse();
    });

    it('evaluateScenarioGate_pass_and_fail', 0, () => {
      expect(evaluateScenarioGate(mk('cat_5mb', 'pass', 58, 210))).assertEqual('');
      const failFps: string = evaluateScenarioGate(mk('cat_5mb', 'pass', 40, 210));
      expect(failFps.indexOf('fpsAvg') >= 0).assertTrue();
      const failRss: string = evaluateScenarioGate(mk('pane_4_concurrent', 'pass', 52, 450));
      expect(failRss.indexOf('rssPeakMb') >= 0).assertTrue();
      // dry-run 不判失败
      expect(evaluateScenarioGate(mk('yes_burst', 'dry-run', null, null))).assertEqual('');
    });

    it('evaluateReportGate_sample_like_pass', 0, () => {
      const scenarios: BenchScenarioMetrics[] = [
        mk('cat_5mb', 'pass', 58.4, 210.5),
        mk('yes_burst', 'pass', 54.0, 245.0),
        mk('host_list_100', 'pass', 60.0, 180.0),
        mk('pane_4_concurrent', 'pass', 51.5, 320.0)
      ];
      const result = evaluateReportGate(scenarios, 50, 400, true);
      expect(result.ok).assertTrue();
      expect(result.measuredCount).assertEqual(4);
      expect(result.reasons.length).assertEqual(0);
    });

    it('evaluateReportGate_missing_scenario_requireAll', 0, () => {
      const scenarios: BenchScenarioMetrics[] = [
        mk('cat_5mb', 'pass', 58.4, 210.5)
      ];
      const result = evaluateReportGate(scenarios, 50, 400, true);
      expect(result.ok).assertFalse();
      expect(result.reasons.length >= 3).assertTrue();
    });

    it('evaluateReportGate_dryrun_soft_pass', 0, () => {
      const scenarios: BenchScenarioMetrics[] = [
        mk('cat_5mb', 'dry-run', null, null),
        mk('yes_burst', 'dry-run', null, null),
        mk('host_list_100', 'dry-run', null, null),
        mk('pane_4_concurrent', 'dry-run', null, null)
      ];
      const soft = evaluateReportGate(scenarios, 50, 400, false);
      expect(soft.ok).assertTrue();
      expect(soft.measuredCount).assertEqual(0);
      const strict = evaluateReportGate(scenarios, 50, 400, true);
      expect(strict.ok).assertFalse();
    });

    it('scenarioFromFrameDurations_builds_pass_entry', 0, () => {
      const s: BenchScenarioMetrics = scenarioFromFrameDurations(
        'cat_5mb', [20, 20, 20], 120);
      expect(s.status).assertEqual('pass');
      expect(s.fpsAvg).assertEqual(50);
      expect(s.rssPeakMb).assertEqual(120);
      expect(passesFpsGate(s.fpsAvg)).assertTrue();
      expect(passesRssGate(s.rssPeakMb)).assertTrue();
    });
  });
}
