/**
 * Logger 单元测试（hypium，任务 X4）。
 *
 * 覆盖纯函数部分：级别过滤、脱敏（含私钥块）、轮转边界。
 * 文件落盘与 hilog 输出依赖设备沙箱，在 ohosTest / 真机联调中验证。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  LogLevel,
  isLevelEnabled,
  logFileNames,
  parseLogLevel,
  sanitize,
  shouldRotate
} from '../main/ets/common/utils/Logger';

export default function loggerTest() {
  describe('LoggerTest', () => {

    it('parseLogLevel_正常映射', 0, () => {
      expect(parseLogLevel('debug')).assertEqual(LogLevel.DEBUG);
      expect(parseLogLevel('info')).assertEqual(LogLevel.INFO);
      expect(parseLogLevel('warn')).assertEqual(LogLevel.WARN);
      expect(parseLogLevel('error')).assertEqual(LogLevel.ERROR);
    });

    it('parseLogLevel_大小写与空白容错', 0, () => {
      expect(parseLogLevel('DEBUG')).assertEqual(LogLevel.DEBUG);
      expect(parseLogLevel(' Info ')).assertEqual(LogLevel.INFO);
    });

    it('parseLogLevel_无法识别回退INFO', 0, () => {
      expect(parseLogLevel('')).assertEqual(LogLevel.INFO);
      expect(parseLogLevel('verbose')).assertEqual(LogLevel.INFO);
    });

    it('isLevelEnabled_debug门槛输出全部', 0, () => {
      expect(isLevelEnabled(LogLevel.DEBUG, LogLevel.DEBUG)).assertTrue();
      expect(isLevelEnabled(LogLevel.DEBUG, LogLevel.INFO)).assertTrue();
      expect(isLevelEnabled(LogLevel.DEBUG, LogLevel.WARN)).assertTrue();
      expect(isLevelEnabled(LogLevel.DEBUG, LogLevel.ERROR)).assertTrue();
    });

    it('isLevelEnabled_info门槛过滤debug', 0, () => {
      expect(isLevelEnabled(LogLevel.INFO, LogLevel.DEBUG)).assertFalse();
      expect(isLevelEnabled(LogLevel.INFO, LogLevel.INFO)).assertTrue();
      expect(isLevelEnabled(LogLevel.INFO, LogLevel.WARN)).assertTrue();
      expect(isLevelEnabled(LogLevel.INFO, LogLevel.ERROR)).assertTrue();
    });

    it('isLevelEnabled_error门槛只放行error', 0, () => {
      expect(isLevelEnabled(LogLevel.ERROR, LogLevel.DEBUG)).assertFalse();
      expect(isLevelEnabled(LogLevel.ERROR, LogLevel.INFO)).assertFalse();
      expect(isLevelEnabled(LogLevel.ERROR, LogLevel.WARN)).assertFalse();
      expect(isLevelEnabled(LogLevel.ERROR, LogLevel.ERROR)).assertTrue();
    });

    it('sanitize_裸k=v密码脱敏', 0, () => {
      expect(sanitize('login password=hunter2 failed')).assertEqual('login password=*** failed');
      expect(sanitize('Password=Foo123')).assertEqual('Password=***');
    });

    it('sanitize_JSON形态脱敏', 0, () => {
      expect(sanitize('{"password":"abc123","port":22}')).assertEqual('{"password":"***","port":22}');
      expect(sanitize('{"token": "eyJhbGciOiJ9"}')).assertEqual('{"token": "***"}');
    });

    it('sanitize_JSON值含转义引号不截断', 0, () => {
      // 值内的 \" 不应让脱敏提前结束，导致后半段明文残留
      expect(sanitize('{"password":"a\\"b"}')).assertEqual('{"password":"***"}');
    });

    it('sanitize_token与authorization脱敏', 0, () => {
      expect(sanitize('token=abc.def.ghi')).assertEqual('token=***');
      expect(sanitize('accessToken=xyz&scope=all')).assertEqual('accessToken=***&scope=all');
      expect(sanitize('Authorization: Bearer abc.def.ghi')).assertEqual('Authorization: ***');
      expect(sanitize('Bearer abc.def.ghi')).assertEqual('Bearer ***');
    });

    it('sanitize_privateKey脱敏', 0, () => {
      expect(sanitize('privateKey=MIIEvQIBADANBg')).assertEqual('privateKey=***');
      expect(sanitize('{"privateKey":"MIIEvQIBADANBg"}')).assertEqual('{"privateKey":"***"}');
    });

    it('sanitize_私钥块整体脱敏', 0, () => {
      const text: string = 'load key\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nYXJ0aWNsZQ==\n-----END OPENSSH PRIVATE KEY-----\ndone';
      expect(sanitize(text)).assertEqual('load key\n***\ndone');
    });

    it('sanitize_RSA私钥块脱敏', 0, () => {
      const text: string = '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA7\n-----END RSA PRIVATE KEY-----';
      expect(sanitize(text)).assertEqual('***');
    });

    it('sanitize_普通内容保持不变', 0, () => {
      const text: string = 'connecting to 192.168.1.1 port 22, session opened';
      expect(sanitize(text)).assertEqual(text);
    });

    it('shouldRotate_边界', 0, () => {
      const max: number = 5242880;
      expect(shouldRotate(0, 100, max)).assertFalse();
      expect(shouldRotate(100, max - 100, max)).assertFalse();
      expect(shouldRotate(100, max - 99, max)).assertTrue();
      expect(shouldRotate(max, 1, max)).assertTrue();
    });

    it('logFileNames_保留个数', 0, () => {
      expect(JSON.stringify(logFileNames(3))).assertEqual('["app.log","app.log.1","app.log.2"]');
      expect(JSON.stringify(logFileNames(1))).assertEqual('["app.log"]');
    });
  });
}
