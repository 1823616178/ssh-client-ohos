/**
 * 屏幕常亮与「连接后自动执行」单元测试。
 *
 * 两块本来无关，但都服务于同一个用户抱怨——「挂着不动一会儿，回来连接就断了」：
 *   1. ScreenAwake：不让终端页在有会话时自动息屏，从源头掐掉「息屏 → 切后台 →
 *      长时任务被判低速回收 → 优雅断开」这条链（DESIGN §7.5 的上游）；
 *   2. AutoRun：断线终究挡不住，现场挂在 tmux 里才不会丢，重连后 attach 回原会话。
 *
 * 系统能力（窗口 API）全部经窄接口注入 fake，纯逻辑（真值表、会话名归一）直接断言。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ScreenAwake,
  ScreenAwakeGateway,
  shouldKeepScreenOn
} from '../main/ets/service/ScreenAwake';
import { KeepScreenOnMode } from '../main/ets/repository/SettingsRepository';
import { SessionControl, SessionCountListener } from '../main/ets/service/background/SessionControl';
import {
  buildAutoRunCommands,
  DEFAULT_TMUX_SESSION_NAME,
  encodeAutoRunCommands,
  sanitizeTmuxSessionName,
  tmuxAttachCommand
} from '../main/ets/common/utils/AutoRun';
import { createDefaultHostProfile, HostProfile } from '../main/ets/common/model/models';
import {
  keepScreenOnLabels,
  keepScreenOnModeOf,
  keepScreenOnOptionIndex,
  keepScreenOnSummary,
  KEEP_SCREEN_ON_OPTIONS
} from '../main/ets/viewmodel/SettingsViewModel';

// ---------- fake ----------

class FakeAwakeGateway implements ScreenAwakeGateway {
  /** 每次下发都记一笔（用于断言「不重复下发」） */
  readonly calls: boolean[] = [];

  apply(keepOn: boolean): void {
    this.calls.push(keepOn);
  }

  get last(): boolean {
    return this.calls.length === 0 ? false : this.calls[this.calls.length - 1];
  }
}

/** 只实现常亮用得到的两个口，其余按窄接口给空实现 */
class FakeSessionControl implements SessionControl {
  count: number = 0;
  private readonly listeners: SessionCountListener[] = [];

  activeSessionCount(): number {
    return this.count;
  }

  setQuiet(_quiet: boolean): void {
  }

  notifyNetworkChanged(): number {
    return 0;
  }

  suspendAllForPolicy(_reason: string): number {
    return 0;
  }

  resumeAllSuspended(): number {
    return 0;
  }

  addSessionCountListener(listener: SessionCountListener): void {
    this.listeners.push(listener);
  }

  removeSessionCountListener(listener: SessionCountListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 测试脚本：改会话数并广播 */
  emitCount(count: number): void {
    this.count = count;
    for (const listener of this.listeners) {
      listener();
    }
  }

  get listenerCount(): number {
    return this.listeners.length;
  }
}

class AwakeEnv {
  readonly gateway: FakeAwakeGateway = new FakeAwakeGateway();
  readonly sessions: FakeSessionControl = new FakeSessionControl();
  readonly awake: ScreenAwake;

  constructor(mode: KeepScreenOnMode) {
    this.awake = new ScreenAwake({
      gateway: this.gateway,
      sessions: this.sessions,
      readMode: (): KeepScreenOnMode => mode
    });
    this.awake.start();
  }
}

function hostWithTmux(enabled: boolean, sessionName: string): HostProfile {
  const host: HostProfile = createDefaultHostProfile('h1');
  host.tmuxAutoAttach = enabled;
  host.tmuxSessionName = sessionName;
  return host;
}

export default function screenAwakeTest() {

  // ================================================================ 纯逻辑：常亮真值表

  describe('ScreenAwakeDecisionTest', () => {
    it('不在终端页一律不常亮', 0, () => {
      expect(shouldKeepScreenOn('always', false, true, 3)).assertFalse();
      expect(shouldKeepScreenOn('session', false, true, 3)).assertFalse();
    });

    it('应用不在前台一律不常亮', 0, () => {
      expect(shouldKeepScreenOn('always', true, false, 3)).assertFalse();
      expect(shouldKeepScreenOn('session', true, false, 3)).assertFalse();
    });

    it('session档只在有活跃会话时常亮', 0, () => {
      expect(shouldKeepScreenOn('session', true, true, 0)).assertFalse();
      expect(shouldKeepScreenOn('session', true, true, 1)).assertTrue();
    });

    it('always档只要在终端页就常亮', 0, () => {
      expect(shouldKeepScreenOn('always', true, true, 0)).assertTrue();
    });

    it('never档任何情况都不常亮', 0, () => {
      expect(shouldKeepScreenOn('never', true, true, 5)).assertFalse();
    });
  });

  // ================================================================ 服务：状态 → 网关

  describe('ScreenAwakeServiceTest', () => {
    it('进终端页且有会话才点亮', 0, () => {
      const env: AwakeEnv = new AwakeEnv('session');
      env.sessions.emitCount(1);
      expect(env.awake.isKeepingScreenOn).assertFalse(); // 还没进终端页

      env.awake.setTerminalVisible(true);
      expect(env.awake.isKeepingScreenOn).assertTrue();
      expect(env.gateway.last).assertTrue();
    });

    it('离开终端页立刻还回去', 0, () => {
      const env: AwakeEnv = new AwakeEnv('session');
      env.sessions.emitCount(1);
      env.awake.setTerminalVisible(true);
      env.awake.setTerminalVisible(false);
      expect(env.awake.isKeepingScreenOn).assertFalse();
      expect(env.gateway.last).assertFalse();
    });

    it('会话全关掉后不再压着屏幕', 0, () => {
      const env: AwakeEnv = new AwakeEnv('session');
      env.awake.setTerminalVisible(true);
      env.sessions.emitCount(2);
      expect(env.awake.isKeepingScreenOn).assertTrue();

      env.sessions.emitCount(0);
      expect(env.awake.isKeepingScreenOn).assertFalse();
    });

    it('切后台还回去回前台再点亮', 0, () => {
      const env: AwakeEnv = new AwakeEnv('session');
      env.sessions.emitCount(1);
      env.awake.setTerminalVisible(true);
      env.awake.setForeground(false);
      expect(env.awake.isKeepingScreenOn).assertFalse();

      env.awake.setForeground(true);
      expect(env.awake.isKeepingScreenOn).assertTrue();
    });

    it('状态没变不重复下发系统调用', 0, () => {
      const env: AwakeEnv = new AwakeEnv('session');
      env.awake.setTerminalVisible(true);
      env.sessions.emitCount(1);
      const calls: number = env.gateway.calls.length;
      env.sessions.emitCount(2); // 会话数变了但结论没变
      env.sessions.emitCount(3);
      expect(env.gateway.calls.length).assertEqual(calls);
    });

    it('never档进终端页也不点亮', 0, () => {
      const env: AwakeEnv = new AwakeEnv('never');
      env.sessions.emitCount(1);
      env.awake.setTerminalVisible(true);
      expect(env.awake.isKeepingScreenOn).assertFalse();
    });

    it('always档没有会话也点亮', 0, () => {
      const env: AwakeEnv = new AwakeEnv('always');
      env.awake.setTerminalVisible(true);
      expect(env.awake.isKeepingScreenOn).assertTrue();
    });

    it('stop还回常亮并摘监听且幂等', 0, () => {
      const env: AwakeEnv = new AwakeEnv('always');
      env.awake.setTerminalVisible(true);
      env.awake.stop();
      expect(env.awake.isKeepingScreenOn).assertFalse();
      expect(env.sessions.listenerCount).assertEqual(0);
      env.awake.stop(); // 幂等
    });
  });

  // ================================================================ 设置页档位换算

  describe('KeepScreenOnOptionTest', () => {
    it('档位与下标往返一致', 0, () => {
      for (let i: number = 0; i < KEEP_SCREEN_ON_OPTIONS.length; i++) {
        expect(keepScreenOnOptionIndex(keepScreenOnModeOf(i))).assertEqual(i);
      }
      expect(keepScreenOnLabels().length).assertEqual(KEEP_SCREEN_ON_OPTIONS.length);
    });

    it('越界下标落回默认档', 0, () => {
      expect(keepScreenOnModeOf(-1)).assertEqual('session');
      expect(keepScreenOnModeOf(99)).assertEqual('session');
    });

    it('副标题按档位区分', 0, () => {
      expect(keepScreenOnSummary('never') === keepScreenOnSummary('session')).assertFalse();
      expect(keepScreenOnSummary('always') === keepScreenOnSummary('session')).assertFalse();
    });
  });

  // ================================================================ 连接后自动执行

  describe('AutoRunTest', () => {
    it('会话名归一只留安全字符', 0, () => {
      // tmux 会话名含 : 或 . 会被当成 window/pane 定位符，空格与引号会拆坏命令行
      expect(sanitizeTmuxSessionName('my sess:1.2')).assertEqual('mysess12');
      expect(sanitizeTmuxSessionName('  dev-box_1  ')).assertEqual('dev-box_1');
    });

    it('空名与全非法字符落回默认名', 0, () => {
      expect(sanitizeTmuxSessionName('')).assertEqual(DEFAULT_TMUX_SESSION_NAME);
      expect(sanitizeTmuxSessionName('...:::')).assertEqual(DEFAULT_TMUX_SESSION_NAME);
    });

    it('超长名截断到上限', 0, () => {
      expect(sanitizeTmuxSessionName('a'.repeat(100)).length).assertEqual(32);
    });

    it('附着命令用new-A而不是attach', 0, () => {
      // attach 在会话不存在时会直接报错退出，-A 才是「有就附着没有就建」
      expect(tmuxAttachCommand('work')).assertEqual('tmux new -A -s work');
      expect(tmuxAttachCommand('')).assertEqual(`tmux new -A -s ${DEFAULT_TMUX_SESSION_NAME}`);
    });

    it('未开启tmux时不发附着命令', 0, () => {
      const host: HostProfile = hostWithTmux(false, 'work');
      expect(buildAutoRunCommands(host).length).assertEqual(0);
    });

    it('tmux在initCommands之前发', 0, () => {
      const host: HostProfile = hostWithTmux(true, 'work');
      host.initCommands = ['cd /var/log', 'tail -f app.log'];
      const commands: string[] = buildAutoRunCommands(host);
      expect(commands.join('|')).assertEqual('tmux new -A -s work|cd /var/log|tail -f app.log');
    });

    it('空白行不发出去', 0, () => {
      const host: HostProfile = hostWithTmux(false, '');
      host.initCommands = ['', '   ', 'ls'];
      expect(buildAutoRunCommands(host).join('|')).assertEqual('ls');
    });

    it('每条命令以换行收尾', 0, () => {
      expect(encodeAutoRunCommands(['a', 'b'])).assertEqual('a\nb\n');
      expect(encodeAutoRunCommands([])).assertEqual('');
    });
  });
}
