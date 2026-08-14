/**
 * SshError 单元测试（hypium，任务 X4 / N13）。
 *
 * 覆盖：每个错误码都有非空中文文案（UNKNOWN 兜底为「未知错误」且不被其他码复用）、
 * 错误码数值锚定（与 native cpp/ssh/error_codes.h 一致，scripts/check-error-codes.sh
 * 在 CI 对拍两份码表）、fromNativeCode 跨层收口、SshError 实例字段与方法。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ALL_SSH_ERROR_CODES, SshError, SshErrorCode } from '../main/ets/common/SshError';

export default function sshErrorTest() {
  describe('SshErrorTest', () => {

    it('toUserMessage_每个错误码都有中文文案', 0, () => {
      expect(ALL_SSH_ERROR_CODES.length > 0).assertTrue();
      for (let i = 0; i < ALL_SSH_ERROR_CODES.length; i++) {
        const code: SshErrorCode = ALL_SSH_ERROR_CODES[i];
        const text: string = SshError.toUserMessage(code);
        expect(text.length > 0).assertTrue();
        if (code !== SshErrorCode.UNKNOWN) {
          // 除兜底外，任何错误码都不应落到「未知错误」
          expect(text !== '未知错误').assertTrue();
        }
      }
    });

    it('toUserMessage_UNKNOWN兜底', 0, () => {
      expect(SshError.toUserMessage(SshErrorCode.UNKNOWN)).assertEqual('未知错误');
    });

    it('toUserMessage_关键文案抽查', 0, () => {
      expect(SshError.toUserMessage(SshErrorCode.DNS_FAILED)).assertContain('主机名');
      expect(SshError.toUserMessage(SshErrorCode.HOST_KEY_MISMATCH)).assertContain('不匹配');
      expect(SshError.toUserMessage(SshErrorCode.AUTH_PASSWORD_FAILED)).assertContain('密码');
      expect(SshError.toUserMessage(SshErrorCode.HOST_KEY_UNKNOWN)).assertContain('指纹');
      expect(SshError.toUserMessage(SshErrorCode.AUTH_PASSPHRASE_FAILED)).assertContain('短语');
      expect(SshError.toUserMessage(SshErrorCode.HANDSHAKE_FAILED)).assertContain('握手');
      expect(SshError.toUserMessage(SshErrorCode.KEEPALIVE_TIMEOUT)).assertContain('心跳');
    });

    // 数值锚定：与 native cpp/ssh/error_codes.h 的 kSshErrorCode* 常量逐一对应
    // （两份码表由 scripts/check-error-codes.sh 在 CI 对拍，改一侧必须同步另一侧）
    it('错误码数值_与native码表锚定', 0, () => {
      expect(SshErrorCode.DNS_FAILED).assertEqual(101);
      expect(SshErrorCode.CONNECT_TIMEOUT).assertEqual(102);
      expect(SshErrorCode.CONNECT_REFUSED).assertEqual(103);
      expect(SshErrorCode.NETWORK_UNREACHABLE).assertEqual(104);
      expect(SshErrorCode.AUTH_PASSWORD_FAILED).assertEqual(201);
      expect(SshErrorCode.AUTH_PUBLICKEY_FAILED).assertEqual(202);
      expect(SshErrorCode.AUTH_KEYBOARD_INTERACTIVE_FAILED).assertEqual(203);
      expect(SshErrorCode.AUTH_PASSPHRASE_FAILED).assertEqual(204);
      expect(SshErrorCode.AUTH_TIMEOUT).assertEqual(205);
      expect(SshErrorCode.ALGORITHM_NEGOTIATION_FAILED).assertEqual(301);
      expect(SshErrorCode.HOST_KEY_UNKNOWN).assertEqual(302);
      expect(SshErrorCode.HOST_KEY_MISMATCH).assertEqual(303);
      expect(SshErrorCode.HANDSHAKE_FAILED).assertEqual(304);
      expect(SshErrorCode.HANDSHAKE_TIMEOUT).assertEqual(305);
      expect(SshErrorCode.CONNECTION_CLOSED_BY_REMOTE).assertEqual(401);
      expect(SshErrorCode.SESSION_TIMEOUT).assertEqual(402);
      expect(SshErrorCode.SOCKET_ERROR).assertEqual(403);
      expect(SshErrorCode.KEEPALIVE_TIMEOUT).assertEqual(404);
      expect(SshErrorCode.INTERNAL_ERROR).assertEqual(500);
      expect(SshErrorCode.UNKNOWN).assertEqual(999);
      // 清单与枚举同数（20 个）：新增枚举忘了追加 ALL 清单时此处先红
      expect(ALL_SSH_ERROR_CODES.length).assertEqual(20);
    });

    it('fromNativeCode_已识别数值原样返回', 0, () => {
      for (let i = 0; i < ALL_SSH_ERROR_CODES.length; i++) {
        const code: SshErrorCode = ALL_SSH_ERROR_CODES[i];
        expect(SshError.fromNativeCode(code as number)).assertEqual(code);
      }
    });

    it('fromNativeCode_未识别数值归UNKNOWN', 0, () => {
      expect(SshError.fromNativeCode(0)).assertEqual(SshErrorCode.UNKNOWN); // 保留值「无错误」
      expect(SshError.fromNativeCode(105)).assertEqual(SshErrorCode.UNKNOWN);
      expect(SshError.fromNativeCode(-1)).assertEqual(SshErrorCode.UNKNOWN);
      expect(SshError.fromNativeCode(12345)).assertEqual(SshErrorCode.UNKNOWN);
    });

    it('SshError_实例字段与方法', 0, () => {
      const cause: Error = new Error('socket ECONNREFUSED');
      const err: SshError = new SshError(SshErrorCode.CONNECT_REFUSED, 'connect failed', cause);
      expect(err.code).assertEqual(SshErrorCode.CONNECT_REFUSED);
      expect(err.message).assertEqual('connect failed');
      expect(err.cause === cause).assertTrue();
      expect(err instanceof Error).assertTrue();
      expect(err.toUserMessage()).assertEqual(SshError.toUserMessage(SshErrorCode.CONNECT_REFUSED));
    });

    it('SshError_cause可缺省', 0, () => {
      const err: SshError = new SshError(SshErrorCode.DNS_FAILED, 'getaddrinfo failed');
      expect(err.cause === undefined).assertTrue();
      expect(err.toUserMessage()).assertEqual(SshError.toUserMessage(SshErrorCode.DNS_FAILED));
    });
  });
}
