/**
 * MiniTerminalModel 单测：活动会话行派生、后台活动记账、迷你窗口目标编解码、
 * 点按主机决策、全页返回取回决策。
 */
import { describe, it, expect } from '@ohos/hypium';
import { ActiveSessionLike } from '../main/ets/viewmodel/HostListViewModel';
import {
  ActiveSessionRow,
  MINI_TARGET_NONE,
  MINI_TERMINAL_PANE_ID,
  MiniTarget,
  SessionActivityLookup,
  SessionActivityState,
  SessionActivityTracker,
  activeSessionsHeader,
  buildActiveSessionRows,
  decideHostTap,
  decideMiniResume,
  encodeMiniTarget,
  miniPresentationOf,
  parseMiniTarget
} from '../main/ets/viewmodel/MiniTerminalModel';

class MapActivity implements SessionActivityLookup {
  readonly states: Map<string, SessionActivityState> = new Map();

  stateOf(sessionId: string): SessionActivityState {
    const state: SessionActivityState | undefined = this.states.get(sessionId);
    return state === undefined ? { unread: false, bell: false, title: '' } : state;
  }
}

function session(id: string, hostId: string, hostName: string, state: string,
  paneId: string | null): ActiveSessionLike {
  return { sessionId: id, hostId: hostId, hostName: hostName, state: state, paneId: paneId };
}

export default function miniTerminalModelTest() {
  describe('MiniTerminalModelTest', () => {
    it('活动会话_列出全部存活连接_含迷你窗口与全页持有的_终态不列_保持顺序', 0, () => {
      const sessions: ActiveSessionLike[] = [
        session('s1', 'h1', 'root@1.2.3.4', 'established', null),
        session('s2', 'h2', 'dba@db', 'disconnected', MINI_TERMINAL_PANE_ID),
        session('s3', 'h1', 'x', 'authenticating', 'terminal-main'),
        session('s4', 'h3', 'y', 'closed', null),
        session('s5', 'tmp', '', 'error', null),
        session('s6', 'h4', 'z', 'closing', null)
      ];
      const names: Map<string, string> = new Map();
      names.set('h1', '生产机');
      const rows: ActiveSessionRow[] = buildActiveSessionRows(sessions, names, '', new MapActivity(),
        MINI_TERMINAL_PANE_ID);
      expect(rows.length).assertEqual(4);
      expect(rows.map((r: ActiveSessionRow) => r.sessionId).join(',')).assertEqual('s1,s2,s3,s5');
      expect(rows[0].title).assertEqual('生产机');
      expect(rows[0].inMini).assertFalse();
      expect(rows[1].inMini).assertTrue();
      expect(rows[1].subtitle).assertEqual('已断开，等待重连 · 迷你窗口中');
      expect(rows[2].title).assertEqual('生产机 #2');
      expect(rows[2].inFullPage).assertTrue();
      expect(rows[2].status).assertEqual('connecting');
      expect(rows[3].title).assertEqual('终端');
      expect(rows[3].status).assertEqual('error');
      expect(rows[0].hostId).assertEqual('h1');
    });

    it('活动会话_迷你会话id兜底高亮_徽标只给未显示的会话_副标题带远端标题', 0, () => {
      const activity: MapActivity = new MapActivity();
      activity.states.set('s1', { unread: true, bell: true, title: 'htop' });
      activity.states.set('s2', { unread: true, bell: false, title: '' });
      const rows: ActiveSessionRow[] = buildActiveSessionRows([
        session('s1', 'h1', 'a', 'established', null),
        session('s2', 'h2', 'b', 'established', null)
      ], new Map(), 's2', activity, MINI_TERMINAL_PANE_ID);
      expect(rows[0].unread).assertTrue();
      expect(rows[0].bell).assertTrue();
      expect(rows[0].subtitle).assertEqual('运行中 · htop');
      expect(rows[0].accessibilityText.indexOf('有响铃') >= 0).assertTrue();
      expect(rows[0].accessibilityText.indexOf('有新输出') >= 0).assertTrue();
      // s2 在迷你窗口（还没绑上窗格的过渡态也算）：不挂徽标
      expect(rows[1].inMini).assertTrue();
      expect(rows[1].unread).assertFalse();
      expect(rows[0].renderKey === rows[1].renderKey).assertFalse();
      expect(activeSessionsHeader(rows)).assertEqual('活动会话（2）· 1 个有新动态');
      expect(activeSessionsHeader([])).assertEqual('活动会话（0）');
    });

    it('活动会话_renderKey随状态与徽标变化', 0, () => {
      const activity: MapActivity = new MapActivity();
      const a: ActiveSessionRow[] = buildActiveSessionRows([session('s1', 'h1', 'a', 'established', null)],
        new Map(), '', activity, MINI_TERMINAL_PANE_ID);
      activity.states.set('s1', { unread: true, bell: false, title: '' });
      const b: ActiveSessionRow[] = buildActiveSessionRows([session('s1', 'h1', 'a', 'established', null)],
        new Map(), '', activity, MINI_TERMINAL_PANE_ID);
      const c: ActiveSessionRow[] = buildActiveSessionRows([session('s1', 'h1', 'a', 'disconnected', null)],
        new Map(), '', activity, MINI_TERMINAL_PANE_ID);
      expect(a[0].renderKey === b[0].renderKey).assertFalse();
      expect(b[0].renderKey === c[0].renderKey).assertFalse();
    });

    it('后台活动_未显示会话记新输出与响铃_只在翻转时通知_显示中的不记', 0, () => {
      const viewed: string[] = ['s-view'];
      const tracker: SessionActivityTracker = new SessionActivityTracker((id: string): boolean =>
        viewed.indexOf(id) >= 0);
      let notified: number = 0;
      const unsub: () => void = tracker.addListener((): void => {
        notified++;
      });
      tracker.onSessionEvent('s1', 'terminalData', '', '');
      tracker.onSessionEvent('s1', 'terminalData', '', '');
      tracker.onSessionEvent('s1', 'terminalData', '', '');
      expect(notified).assertEqual(1);
      expect(tracker.stateOf('s1').unread).assertTrue();
      tracker.onSessionEvent('s1', 'terminalBell', '', '');
      tracker.onSessionEvent('s1', 'terminalBell', '', '');
      expect(notified).assertEqual(2);
      expect(tracker.stateOf('s1').bell).assertTrue();
      tracker.onSessionEvent('s-view', 'terminalData', '', '');
      tracker.onSessionEvent('s-view', 'terminalBell', '', '');
      expect(tracker.stateOf('s-view').unread).assertFalse();
      expect(tracker.stateOf('s-view').bell).assertFalse();
      expect(notified).assertEqual(2);
      // 标题：显示中的也记；相同标题不重复通知
      tracker.onSessionEvent('s-view', 'terminalTitle', 'vim', '');
      tracker.onSessionEvent('s-view', 'terminalTitle', 'vim', '');
      expect(tracker.stateOf('s-view').title).assertEqual('vim');
      expect(notified).assertEqual(3);
      // 看过：清徽标、保留标题
      tracker.onSessionEvent('s1', 'terminalTitle', 'top', '');
      tracker.markSeen('s1');
      expect(tracker.stateOf('s1').unread).assertFalse();
      expect(tracker.stateOf('s1').bell).assertFalse();
      expect(tracker.stateOf('s1').title).assertEqual('top');
      const before: number = notified;
      tracker.markSeen('s1'); // 无徽标时不通知
      tracker.markSeen('unknown');
      expect(notified).assertEqual(before);
      // 其他事件忽略
      tracker.onSessionEvent('s1', 'channelData', '', '');
      expect(notified).assertEqual(before);
      unsub();
      tracker.onSessionEvent('s2', 'terminalData', '', '');
      expect(notified).assertEqual(before);
    });

    it('后台活动_会话关闭遗忘_prune只留存活会话', 0, () => {
      const tracker: SessionActivityTracker = new SessionActivityTracker((_id: string): boolean => false);
      tracker.onData('a');
      tracker.onData('b');
      tracker.onBell('c');
      expect(tracker.size()).assertEqual(3);
      tracker.onSessionEvent('a', 'stateChange', '', 'disconnected');
      expect(tracker.size()).assertEqual(3);
      tracker.onSessionEvent('a', 'stateChange', '', 'closed');
      expect(tracker.size()).assertEqual(2);
      expect(tracker.stateOf('a').unread).assertFalse();
      tracker.prune(['c']);
      expect(tracker.size()).assertEqual(1);
      expect(tracker.stateOf('c').bell).assertTrue();
    });

    it('迷你窗口目标_编解码往返_非法输入回落空态', 0, () => {
      const t1: MiniTarget = { kind: 'session', id: 'abc-123', seq: 7 };
      const r1: MiniTarget = parseMiniTarget(encodeMiniTarget(t1));
      expect(r1.kind).assertEqual('session');
      expect(r1.id).assertEqual('abc-123');
      expect(r1.seq).assertEqual(7);
      const r2: MiniTarget = parseMiniTarget(encodeMiniTarget({ kind: 'host', id: 'a:b', seq: 2 }));
      expect(r2.kind).assertEqual('host');
      expect(r2.id).assertEqual('a:b');
      expect(encodeMiniTarget(MINI_TARGET_NONE)).assertEqual('');
      expect(encodeMiniTarget({ kind: 'session', id: '', seq: 1 })).assertEqual('');
      expect(parseMiniTarget('').kind).assertEqual('none');
      expect(parseMiniTarget('bogus:x:1').kind).assertEqual('none');
      expect(parseMiniTarget('session::1').kind).assertEqual('none');
      expect(parseMiniTarget('session:x').kind).assertEqual('none');
      expect(parseMiniTarget('session:x:zz').seq).assertEqual(0);
      // 同一会话再次请求：序号不同 → 字符串不同（@Watch 能触发）
      expect(encodeMiniTarget({ kind: 'session', id: 's', seq: 1 }) ===
        encodeMiniTarget({ kind: 'session', id: 's', seq: 2 })).assertFalse();
    });

    it('点按主机_迷你窗口已显示该主机存活会话则保持_否则新拨', 0, () => {
      expect(decideHostTap('h1', true, 'h1')).assertEqual('keep');
      expect(decideHostTap('h1', false, 'h1')).assertEqual('connect');
      expect(decideHostTap('h1', true, 'h2')).assertEqual('connect');
      expect(decideHostTap('', false, 'h1')).assertEqual('connect');
      expect(miniPresentationOf(true)).assertEqual('sidebar');
      expect(miniPresentationOf(false)).assertEqual('sheet');
    });

    it('全页返回取回_未绑定接管_被全页持有等待_已在迷你窗格无动作_已关闭回空态', 0, () => {
      expect(decideMiniResume(null, MINI_TERMINAL_PANE_ID)).assertEqual('gone');
      expect(decideMiniResume({ state: 'closed', paneId: null }, MINI_TERMINAL_PANE_ID)).assertEqual('gone');
      expect(decideMiniResume({ state: 'closing', paneId: null }, MINI_TERMINAL_PANE_ID)).assertEqual('gone');
      expect(decideMiniResume({ state: 'established', paneId: 'terminal-main' }, MINI_TERMINAL_PANE_ID))
        .assertEqual('wait');
      expect(decideMiniResume({ state: 'established', paneId: MINI_TERMINAL_PANE_ID }, MINI_TERMINAL_PANE_ID))
        .assertEqual('already');
      expect(decideMiniResume({ state: 'disconnected', paneId: null }, MINI_TERMINAL_PANE_ID)).assertEqual('adopt');
      expect(decideMiniResume({ state: 'error', paneId: null }, MINI_TERMINAL_PANE_ID)).assertEqual('adopt');
    });
  });
}
