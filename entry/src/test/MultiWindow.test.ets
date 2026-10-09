/**
 * 多窗口改造单元测试。
 *
 * 覆盖纯逻辑部分（系统窗口 / Ability 能力不在 Node 单测里跑）：
 *   1. WindowKeys：specified key 生成、want 参数往返、窗格 id 前缀；
 *   2. WindowRegistry：引用计数、应用级前后台（单窗口立即 / 多窗口防抖）、
 *      窗口获焦广播、onNewWant 打开请求的积压与补投；
 *   3. PrefixedPaneIdFactory：非主窗口窗格 id 带前缀、主窗口与改造前逐字相同；
 *   4. FocusManager / ScreenAwake 按窗口分实例。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  MAIN_WINDOW_KEY,
  SPECIFIED_KEY_NEW_PREFIX,
  SPECIFIED_KEY_SESSION_PREFIX,
  TerminalWindowLaunch,
  acceptWantKey,
  buildTerminalWindowParams,
  paneIdPrefixOf,
  parseTerminalWindowParams,
  specifiedKeyFor,
  splitSessionIds,
  windowKeyOfPaneId
} from '../main/ets/common/constants/WindowKeys';
import {
  APP_BACKGROUND_SETTLE_MS,
  SettleScheduler,
  TerminalOpenRequest,
  WindowRegistry
} from '../main/ets/service/window/WindowRegistry';
import { PaneTabSet, PrefixedPaneIdFactory } from '../main/ets/viewmodel/PaneTree';
import { FocusManager } from '../main/ets/view/terminal/FocusManager';
import { ScreenAwake } from '../main/ets/service/ScreenAwake';

// ---------- fake：手动推进的延时器 ----------

class ManualScheduler implements SettleScheduler {
  private seq: number = 0;
  private readonly tasks: Map<number, () => void> = new Map();
  readonly delays: number[] = [];

  schedule(delayMs: number, task: () => void): number {
    this.seq++;
    this.tasks.set(this.seq, task);
    this.delays.push(delayMs);
    return this.seq;
  }

  cancel(timerId: number): void {
    this.tasks.delete(timerId);
  }

  get pending(): number {
    return this.tasks.size;
  }

  /** 触发全部到期任务 */
  flush(): void {
    const all: (() => void)[] = [];
    this.tasks.forEach((task: () => void) => {
      all.push(task);
    });
    this.tasks.clear();
    for (const task of all) {
      task();
    }
  }
}

function fixedId(): string {
  return 'uuid-1';
}

export default function multiWindowTest() {
  describe('MultiWindowTest', () => {

    it('WindowKeys_specifiedKey_单会话复用时按会话_否则新开', 0, () => {
      expect(specifiedKeyFor(['s-1'], true, fixedId)).assertEqual(`${SPECIFIED_KEY_SESSION_PREFIX}s-1`);
      expect(specifiedKeyFor(['s-1'], false, fixedId)).assertEqual(`${SPECIFIED_KEY_NEW_PREFIX}uuid-1`);
      expect(specifiedKeyFor(['s-1', 's-2'], true, fixedId)).assertEqual(`${SPECIFIED_KEY_NEW_PREFIX}uuid-1`);
      expect(specifiedKeyFor([], true, fixedId)).assertEqual(`${SPECIFIED_KEY_NEW_PREFIX}uuid-1`);
    });

    it('WindowKeys_want参数往返_onAcceptWant优先采用发起方key', 0, () => {
      const params: Record<string, Object> = buildTerminalWindowParams('new:abc', 'h1', ['s-1', 's-2']);
      const launch: TerminalWindowLaunch = parseTerminalWindowParams(params);
      expect(launch.windowKey).assertEqual('new:abc');
      expect(launch.hostId).assertEqual('h1');
      expect(launch.sessionIds.length).assertEqual(2);
      expect(launch.sessionIds[0]).assertEqual('s-1');
      expect(launch.sessionIds[1]).assertEqual('s-2');
      expect(acceptWantKey(params, fixedId)).assertEqual('new:abc');

      // 缺省 key：单会话按会话复用，否则新开
      const single: Record<string, Object> = {};
      single['sessionId'] = 's-9';
      expect(acceptWantKey(single, fixedId)).assertEqual(`${SPECIFIED_KEY_SESSION_PREFIX}s-9`);
      expect(acceptWantKey(undefined, fixedId)).assertEqual(`${SPECIFIED_KEY_NEW_PREFIX}uuid-1`);
      expect(acceptWantKey(null, fixedId)).assertEqual(`${SPECIFIED_KEY_NEW_PREFIX}uuid-1`);

      const empty: TerminalWindowLaunch = parseTerminalWindowParams(undefined);
      expect(empty.windowKey).assertEqual('');
      expect(empty.sessionIds.length).assertEqual(0);
      // 无 hostId / 会话时不写多余键
      const bare: Record<string, Object> = buildTerminalWindowParams('new:x', '', []);
      expect(bare['hostId'] === undefined).assertTrue();
      expect(bare['sessionIds'] === undefined).assertTrue();
    });

    it('WindowKeys_splitSessionIds去空白去空项_前缀主窗口为空串', 0, () => {
      const ids: string[] = splitSessionIds(' s-1, ,s-2,, ');
      expect(ids.length).assertEqual(2);
      expect(ids[0]).assertEqual('s-1');
      expect(ids[1]).assertEqual('s-2');
      expect(splitSessionIds('').length).assertEqual(0);
      expect(paneIdPrefixOf(MAIN_WINDOW_KEY)).assertEqual('');
      expect(paneIdPrefixOf('new:abc')).assertEqual('new:abc:');
      // 逆运算：窗格 id → 所在窗口
      expect(windowKeyOfPaneId('terminal-main')).assertEqual(MAIN_WINDOW_KEY);
      expect(windowKeyOfPaneId('pane-3')).assertEqual(MAIN_WINDOW_KEY);
      expect(windowKeyOfPaneId('new:abc:pane-3')).assertEqual('new:abc');
      expect(windowKeyOfPaneId(`${paneIdPrefixOf('session:s-1')}terminal-main`)).assertEqual('session:s-1');
    });

    it('WindowRegistry_引用计数_最后一个窗口注销才归零', 0, () => {
      const registry: WindowRegistry = new WindowRegistry(new ManualScheduler());
      expect(registry.register(MAIN_WINDOW_KEY, null)).assertEqual(1);
      expect(registry.register(MAIN_WINDOW_KEY, null)).assertEqual(1); // 幂等
      expect(registry.register('new:a', null)).assertEqual(2);
      expect(registry.keys().length).assertEqual(2);
      expect(registry.has('new:a')).assertTrue();
      expect(registry.unregister(MAIN_WINDOW_KEY)).assertEqual(1);
      expect(registry.unregister('unknown')).assertEqual(1);
      expect(registry.unregister('new:a')).assertEqual(0);
      expect(registry.count()).assertEqual(0);
      expect(registry.windowOf('new:a')).assertNull();
      expect(registry.firstOtherKey('x')).assertEqual('');
    });

    it('WindowRegistry_单窗口前后台立即通知_与改造前逐拍一致', 0, () => {
      const scheduler: ManualScheduler = new ManualScheduler();
      const registry: WindowRegistry = new WindowRegistry(scheduler);
      const events: boolean[] = [];
      registry.addAppVisibilityListener((fg: boolean): void => {
        events.push(fg);
      });
      registry.register(MAIN_WINDOW_KEY, null);
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, true);
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, true); // 重复不重发
      expect(events.length).assertEqual(1);
      expect(events[0]).assertTrue();
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, false);
      expect(events.length).assertEqual(2);
      expect(events[1]).assertFalse();
      expect(scheduler.pending).assertEqual(0);
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, true);
      expect(events.length).assertEqual(3);
      expect(registry.isAppForeground()).assertTrue();
    });

    it('WindowRegistry_多窗口切换的瞬时空档不误判转后台_真正全部后台才通知', 0, () => {
      const scheduler: ManualScheduler = new ManualScheduler();
      const registry: WindowRegistry = new WindowRegistry(scheduler);
      const events: boolean[] = [];
      registry.addAppVisibilityListener((fg: boolean): void => {
        events.push(fg);
      });
      registry.register(MAIN_WINDOW_KEY, null);
      registry.register('new:a', null);
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, true);
      expect(events.length).assertEqual(1);
      // A 先进后台、B 随后进前台：防抖期内恢复，不发转后台
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, false);
      expect(scheduler.pending).assertEqual(1);
      expect(scheduler.delays[0]).assertEqual(APP_BACKGROUND_SETTLE_MS);
      registry.notifyWindowForeground('new:a', true);
      expect(scheduler.pending).assertEqual(0);
      scheduler.flush();
      expect(events.length).assertEqual(1);
      // 两个窗口都进后台：防抖到期后才发
      registry.notifyWindowForeground('new:a', false);
      expect(events.length).assertEqual(1);
      scheduler.flush();
      expect(events.length).assertEqual(2);
      expect(events[1]).assertFalse();
      expect(registry.isAppForeground()).assertFalse();
    });

    it('WindowRegistry_前台窗口被销毁时摘掉前台标记', 0, () => {
      const registry: WindowRegistry = new WindowRegistry(new ManualScheduler());
      const events: boolean[] = [];
      registry.addAppVisibilityListener((fg: boolean): void => {
        events.push(fg);
      });
      registry.register(MAIN_WINDOW_KEY, null);
      registry.notifyWindowForeground(MAIN_WINDOW_KEY, true);
      registry.unregister(MAIN_WINDOW_KEY);
      expect(events.length).assertEqual(2);
      expect(events[1]).assertFalse();
    });

    it('WindowRegistry_窗口获焦只通知本窗口订阅者_注销后不再通知', 0, () => {
      const registry: WindowRegistry = new WindowRegistry(new ManualScheduler());
      registry.register(MAIN_WINDOW_KEY, null);
      registry.register('new:a', null);
      let mainHits: number = 0;
      let otherHits: number = 0;
      const unsub: () => void = registry.addWindowActiveListener(MAIN_WINDOW_KEY, (): void => {
        mainHits++;
      });
      registry.addWindowActiveListener('new:a', (): void => {
        otherHits++;
      });
      registry.notifyWindowActive(MAIN_WINDOW_KEY);
      expect(mainHits).assertEqual(1);
      expect(otherHits).assertEqual(0);
      unsub();
      registry.notifyWindowActive(MAIN_WINDOW_KEY);
      expect(mainHits).assertEqual(1);
      registry.unregister('new:a');
      registry.notifyWindowActive('new:a');
      expect(otherHits).assertEqual(0);
    });

    it('WindowRegistry_打开请求_页面未就绪时积压_订阅后补投', 0, () => {
      const registry: WindowRegistry = new WindowRegistry(new ManualScheduler());
      registry.register('session:s-1', null);
      const first: TerminalOpenRequest = { hostId: '', sessionIds: ['s-1'] };
      registry.postOpenRequest('session:s-1', first);
      const received: TerminalOpenRequest[] = [];
      const unsub: () => void = registry.setOpenRequestListener('session:s-1',
        (request: TerminalOpenRequest): void => {
          received.push(request);
        });
      expect(received.length).assertEqual(1);
      registry.postOpenRequest('session:s-1', { hostId: 'h1', sessionIds: [] });
      expect(received.length).assertEqual(2);
      expect(received[1].hostId).assertEqual('h1');
      unsub();
      registry.postOpenRequest('session:s-1', first);
      expect(received.length).assertEqual(2);
    });

    it('PrefixedPaneIdFactory_非主窗口带前缀_空前缀与默认序列逐字相同', 0, () => {
      const plainSet: PaneTabSet = new PaneTabSet();
      const sameSet: PaneTabSet = new PaneTabSet(new PrefixedPaneIdFactory(''));
      const plainAdded = plainSet.addTab('t');
      const sameAdded = sameSet.addTab('t');
      expect(sameAdded.tab.tabId).assertEqual(plainAdded.tab.tabId);
      expect(sameAdded.leaf.paneId).assertEqual(plainAdded.leaf.paneId);
      expect(sameSet.newPaneId()).assertEqual(plainSet.newPaneId());

      const prefixed: PrefixedPaneIdFactory = new PrefixedPaneIdFactory('new:w1:');
      expect(prefixed.newPaneId().startsWith('new:w1:')).assertTrue();
      const tabSet: PaneTabSet = new PaneTabSet(new PrefixedPaneIdFactory('new:w2:'));
      const added = tabSet.addTab('t');
      expect(added.tab.tabId.startsWith('new:w2:')).assertTrue();
      expect(added.leaf.paneId.startsWith('new:w2:')).assertTrue();
      // 与主窗口同序号的 id 不再相同
      const mainSet: PaneTabSet = new PaneTabSet();
      const mainAdded = mainSet.addTab('t');
      expect(mainAdded.leaf.paneId === added.leaf.paneId).assertFalse();
    });

    it('FocusManager与ScreenAwake_按窗口分实例_get等于主窗口', 0, () => {
      expect(FocusManager.get() === FocusManager.forWindow(MAIN_WINDOW_KEY)).assertTrue();
      const other: FocusManager = FocusManager.forWindow('new:fm-test');
      expect(other === FocusManager.get()).assertFalse();
      expect(FocusManager.forWindow('new:fm-test') === other).assertTrue();
      other.register('p1');
      other.focus('p1');
      expect(other.isFocused('p1')).assertTrue();
      expect(FocusManager.get().isFocused('p1')).assertFalse();
      FocusManager.releaseWindow('new:fm-test');
      expect(FocusManager.forWindow('new:fm-test') === other).assertFalse();
      FocusManager.releaseWindow('new:fm-test');
      // 主窗口实例不随 release 丢弃
      const main: FocusManager = FocusManager.get();
      FocusManager.releaseWindow(MAIN_WINDOW_KEY);
      expect(FocusManager.get() === main).assertTrue();

      expect(ScreenAwake.get() === ScreenAwake.forWindow(MAIN_WINDOW_KEY)).assertTrue();
      const awake: ScreenAwake = ScreenAwake.forWindow('new:sa-test');
      expect(awake === ScreenAwake.get()).assertFalse();
      ScreenAwake.releaseWindow('new:sa-test');
      expect(ScreenAwake.forWindow('new:sa-test') === awake).assertFalse();
      ScreenAwake.releaseWindow('new:sa-test');
    });
  });
}
