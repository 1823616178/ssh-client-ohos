/**
 * SshError 单元测试（hypium，任务 X4）。
 *
 * 覆盖：每个错误码都有非空中文文案（UNKNOWN 兜底为「未知错误」且不被其他码复用）、
 * SshError 实例的 code / message / cause 与实例方法。
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
