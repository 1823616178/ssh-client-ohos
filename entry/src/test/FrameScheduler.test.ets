/**
 * T4 帧调度核心语义测试（hypium）。
 *
 * displaySync 本身不可单测（真机 vsync），测试用手动 FrameTicker 注入；
 * 覆盖 D14 验收派生语义：注册/注销、可见性过滤（不可见零调用）、按注册序派发、
 * 自动休眠（连续 N 帧无绘制 → stop）、唤醒（register/setVisible(true)/wakeup）、
 * 回调异常隔离。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  FrameCallback,
  FrameSchedulerCore,
  FrameTicker
} from '../main/ets/view/terminal/FrameSchedulerCore';

/** 手动帧源：tick() 模拟一次 vsync；running=false 时 tick 为空转（模拟已摘出管线） */
class ManualTicker implements FrameTicker {
  startCount = 0;
  stopCount = 0;
  private running = false;
  private cb: () => void = () => {};

  setFrameCallback(cb: () => void): void {
    this.cb = cb;
  }

  start(): void {
    this.running = true;
    this.startCount++;
  }

  stop(): void {
    this.running = false;
    this.stopCount++;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /** 驱动 count 帧（中途休眠则提前停） */
  tick(count: number = 1): void {
    for (let i = 0; i < count && this.running; i++) {
      this.cb();
    }
  }
}

/** 计数回调：worked 控制返回值（true = 本帧有绘制） */
class CallbackSpy {
  calls = 0;
  worked = false;
  throws = false;

  callback: FrameCallback = () => {
    this.calls++;
    if (this.throws) {
      throw new Error('spy boom');
    }
    return this.worked;
  }
}

export default function frameSchedulerTest() {
  describe('FrameSchedulerTest', () => {

    it('register后帧循环启动并按帧回调', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker, true, 90);
      expect(core.isRunning).assertFalse();
      expect(ticker.startCount).assertEqual(0); // 无实例不启动

      const spy = new CallbackSpy();
      core.register('a', spy.callback);
      expect(core.isRunning).assertTrue();
      expect(ticker.startCount).assertEqual(1);
      expect(core.has('a')).assertTrue();
      expect(core.size).assertEqual(1);

      ticker.tick(3);
      expect(spy.calls).assertEqual(3);
    });

    it('register重复id与空id抛错', 0, () => {
      const core = new FrameSchedulerCore(new ManualTicker());
      const spy = new CallbackSpy();
      core.register('a', spy.callback);
      let dupThrew = false;
      try {
        core.register('a', spy.callback);
      } catch (e) {
        dupThrew = true;
      }
      expect(dupThrew).assertTrue();
      let emptyThrew = false;
      try {
        core.register('', spy.callback);
      } catch (e) {
        emptyThrew = true;
      }
      expect(emptyThrew).assertTrue();
      expect(core.size).assertEqual(1); // 失败注册不留痕
    });

    it('unregister语义与清空后停帧循环', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker);
      const spy = new CallbackSpy();
      expect(core.unregister('ghost')).assertFalse(); // 未知 id
      core.register('a', spy.callback);
      core.register('b', spy.callback);
      expect(core.unregister('a')).assertTrue();
      expect(core.isRunning).assertTrue(); // 还剩 b
      expect(core.unregister('b')).assertTrue();
      expect(core.isRunning).assertFalse(); // 清空 → 停
      expect(ticker.stopCount).assertEqual(1);
      expect(core.has('a')).assertFalse();
    });

    it('不可见实例零绘制', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker);
      const a = new CallbackSpy();
      const b = new CallbackSpy();
      core.register('a', a.callback);
      core.register('b', b.callback);
      core.setVisible('b', false);
      expect(core.isVisible('b')).assertFalse();
      ticker.tick(3);
      expect(a.calls).assertEqual(3);
      expect(b.calls).assertEqual(0); // 不可见 → 整帧跳过
      // 重新可见后恢复
      core.setVisible('b', true);
      ticker.tick(1);
      expect(b.calls).assertEqual(1);
    });

    it('setVisible未知id静默忽略', 0, () => {
      const core = new FrameSchedulerCore(new ManualTicker());
      core.setVisible('ghost', true);  // 不抛
      core.setVisible('ghost', false);
      expect(core.size).assertEqual(0);
      expect(core.isRunning).assertFalse(); // 未知 id 不唤醒
    });

    it('每帧按注册序派发', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker);
      const order: string[] = [];
      const mk = (id: string): FrameCallback => {
        return () => {
          order.push(id);
          return false;
        };
      };
      core.register('c', mk('c'));
      core.register('a', mk('a'));
      core.register('b', mk('b'));
      ticker.tick(2);
      expect(order.length).assertEqual(6);
      expect(order[0]).assertEqual('c');
      expect(order[1]).assertEqual('a');
      expect(order[2]).assertEqual('b');
      expect(order[3]).assertEqual('c'); // 第二帧同序
    });

    it('连续N帧无绘制自动休眠', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker, true, 3);
      const spy = new CallbackSpy(); // 恒 false
      core.register('a', spy.callback);
      ticker.tick(2);
      expect(core.isRunning).assertTrue(); // 2 < 3 未达阈值
      ticker.tick(1);
      expect(core.isRunning).assertFalse(); // 第 3 帧空转 → 休眠
      expect(ticker.stopCount).assertEqual(1);
      const callsAtSleep = spy.calls;
      ticker.tick(5); // 已休眠：tick 为空转，不再回调
      expect(spy.calls).assertEqual(callsAtSleep);
    });

    it('有绘制重置休眠计数', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker, true, 3);
      const spy = new CallbackSpy();
      core.register('a', spy.callback);
      ticker.tick(2);          // 空转 2 帧
      spy.worked = true;
      ticker.tick(1);          // 有绘制 → 计数归零
      spy.worked = false;
      ticker.tick(2);          // 再空转 2 帧：若未归零此处已休眠
      expect(core.isRunning).assertTrue();
      ticker.tick(1);          // 第 3 帧空转 → 休眠
      expect(core.isRunning).assertFalse();
    });

    it('休眠后wakeup与setVisible唤醒', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker, true, 2);
      const spy = new CallbackSpy();
      core.register('a', spy.callback);
      ticker.tick(2);
      expect(core.isRunning).assertFalse();

      core.wakeup();
      expect(core.isRunning).assertTrue();
      expect(ticker.startCount).assertEqual(2);
      ticker.tick(2); // 再次休眠
      expect(core.isRunning).assertFalse();

      core.setVisible('a', true); // 置可见也唤醒
      expect(core.isRunning).assertTrue();
      expect(ticker.startCount).assertEqual(3);
    });

    it('清空停止后重新register唤醒', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker);
      const spy = new CallbackSpy();
      core.register('a', spy.callback);
      core.unregister('a');
      expect(core.isRunning).assertFalse();
      core.register('b', spy.callback);
      expect(core.isRunning).assertTrue();
      expect(ticker.startCount).assertEqual(2);
    });

    it('回调异常不中断其他实例且不误休眠', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker, true, 2);
      const bad = new CallbackSpy();
      bad.throws = true;
      const good = new CallbackSpy();
      core.register('bad', bad.callback);
      core.register('good', good.callback);
      ticker.tick(3); // bad 每帧抛：按「有绘制」处理（保持循环活着暴露错误）
      expect(good.calls).assertEqual(3);
      expect(core.callbackErrors).assertEqual(3);
      expect(core.isRunning).assertTrue(); // 异常实例不触发休眠
    });

    it('autoSleep关闭时永不休眠', 0, () => {
      const ticker = new ManualTicker();
      const core = new FrameSchedulerCore(ticker, false, 3);
      const spy = new CallbackSpy();
      core.register('a', spy.callback);
      ticker.tick(10);
      expect(core.isRunning).assertTrue();
      expect(ticker.stopCount).assertEqual(0);
      expect(spy.calls).assertEqual(10);
    });

  });
}
