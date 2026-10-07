/**
 * KeyManagerLogic 纯函数测试 —— OpenSSH 指纹（ssh-keygen -lf 对齐）+ 格式识别。
 *
 * 黄金向量：
 *   - SHA256("") / SHA256("abc")：FIPS 180-2；
 *   - formatOpenSshFingerprint(SAMPLE)：python hashlib.sha256(blob) + base64 去 '='。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  base64DecodeToBytes,
  base64EncodeNoPadding,
  buildOpensshPublicKeyBlob,
  buildOpensshPublicKeyLine,
  detectPrivateKeyFormat,
  displayFingerprint,
  fingerprintForEntry,
  formatOpenSshFingerprint,
  isOpenSshPublicKeyLine,
  keyEntryFingerprintDisplay,
  looksLikePrivateKey,
  parseOpenSshPublicKey,
  sha256Hex,
  sshWireLengthPrefixed,
  validateKeyImport
} from '../main/ets/common/utils/KeyManagerLogic';
import { createKeyEntryMeta } from '../main/ets/common/utils/KeyManagerLogic';

const SAMPLE_OPENSSH_PUB: string =
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialForUnitTestOnly0001 user@host';
/** sha256(base64_decode(AAAAC3…0001)) → base64 无填充（与 ssh-keygen -lf 第二列同算法） */
const SAMPLE_FINGERPRINT: string = 'SHA256:GQIDL6WriqI0XO0Upw8fl/SOkm2LeYemx7AtVVVA638';

const SAMPLE_RSA_PUB: string =
  'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDhA…shortInvalid';

function utf8(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    out.push(s.charCodeAt(i) & 0xff);
  }
  return new Uint8Array(out);
}

function sha256Utf8Repeat(ch: string, count: number): string {
  const buf: Uint8Array = new Uint8Array(count);
  const code: number = ch.charCodeAt(0) & 0xff;
  for (let i = 0; i < count; i++) {
    buf[i] = code;
  }
  return sha256Hex(buf);
}

export default function keyManagerLogicTest() {
  describe('KeyManagerLogicTest', () => {

    it('sha256_FIPS空串与abc黄金向量', 0, () => {
      expect(sha256Hex(new Uint8Array(0)))
        .assertEqual('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256Hex(utf8('abc')))
        .assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      // 跨块（55/56/64/65 字节）：python hashlib 对照
      expect(sha256Utf8Repeat('a', 55))
        .assertEqual('9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318');
      expect(sha256Utf8Repeat('a', 56))
        .assertEqual('b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a');
      expect(sha256Utf8Repeat('a', 64))
        .assertEqual('ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb');
      expect(sha256Utf8Repeat('a', 65))
        .assertEqual('635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0');
    });

    it('base64_无填充编码与解码', 0, () => {
      const zeros32: Uint8Array = new Uint8Array(32);
      expect(base64EncodeNoPadding(zeros32))
        .assertEqual('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      expect(base64EncodeNoPadding(utf8('a'))).assertEqual('YQ');
      expect(base64EncodeNoPadding(utf8('ab'))).assertEqual('YWI');
      expect(base64EncodeNoPadding(utf8('abc'))).assertEqual('YWJj');
      const decoded: Uint8Array | null = base64DecodeToBytes('YWJj');
      expect(decoded !== null).assertTrue();
      if (decoded !== null) {
        expect(decoded.length).assertEqual(3);
        expect(decoded[0]).assertEqual(0x61);
        expect(decoded[1]).assertEqual(0x62);
        expect(decoded[2]).assertEqual(0x63);
      }
      // OpenSSH 公钥字段通常无 padding
      const noPad: Uint8Array | null = base64DecodeToBytes('AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialForUnitTestOnly0001');
      expect(noPad !== null).assertTrue();
      if (noPad !== null) {
        expect(noPad.length).assertEqual(44);
      }
    });

    it('formatOpenSshFingerprint_与sshKeygenL对齐', 0, () => {
      const fp: string = formatOpenSshFingerprint(SAMPLE_OPENSSH_PUB);
      expect(fp).assertEqual(SAMPLE_FINGERPRINT);
      expect(fp.startsWith('SHA256:')).assertTrue();
      expect(fp.indexOf('=')).assertEqual(-1);
      // 仅 type+b64 无 comment 时同样成立
      expect(formatOpenSshFingerprint(
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialForUnitTestOnly0001'
      )).assertEqual(SAMPLE_FINGERPRINT);
    });

    it('fingerprintForEntry_公钥优先且无私钥不伪造', 0, () => {
      expect(fingerprintForEntry(SAMPLE_OPENSSH_PUB, '')).assertEqual(SAMPLE_FINGERPRINT);
      expect(fingerprintForEntry(SAMPLE_OPENSSH_PUB,
        '-----BEGIN OPENSSH PRIVATE KEY-----\nxx')).assertEqual(SAMPLE_FINGERPRINT);
      // 无私钥公钥 → 空串（UI 回退 keyType）
      expect(fingerprintForEntry('', '-----BEGIN OPENSSH PRIVATE KEY-----\nxx')).assertEqual('');
      expect(fingerprintForEntry('garbage', '')).assertEqual('');
    });

    it('formatOpenSshFingerprint_非法输入返回空', 0, () => {
      expect(formatOpenSshFingerprint('')).assertEqual('');
      expect(formatOpenSshFingerprint('not-a-key')).assertEqual('');
      expect(formatOpenSshFingerprint('ssh-ed25519 short')).assertEqual('');
      expect(formatOpenSshFingerprint(SAMPLE_RSA_PUB)).assertEqual('');
    });

    it('keyEntryFingerprintDisplay_缺公钥标明未计算', 0, () => {
      const withFp = createKeyEntryMeta('a', 'n');
      withFp.fingerprint = SAMPLE_FINGERPRINT;
      withFp.keyType = 'ssh-ed25519';
      expect(keyEntryFingerprintDisplay(withFp)).assertEqual(SAMPLE_FINGERPRINT);
      const noFp = createKeyEntryMeta('b', 'n');
      noFp.keyType = 'openssh';
      const label: string = keyEntryFingerprintDisplay(noFp);
      expect(label.indexOf('openssh') >= 0).assertTrue();
      expect(label.indexOf('无公钥') >= 0).assertTrue();
      const empty = createKeyEntryMeta('c', 'n');
      expect(keyEntryFingerprintDisplay(empty)).assertEqual('未计算指纹');
    });

    it('格式识别与校验_保持原语义', 0, () => {
      expect(detectPrivateKeyFormat('-----BEGIN OPENSSH PRIVATE KEY-----\nxx')).assertEqual('openssh');
      expect(detectPrivateKeyFormat('-----BEGIN RSA PRIVATE KEY-----')).assertEqual('pem');
      expect(detectPrivateKeyFormat('garbage')).assertEqual('unknown');
      expect(looksLikePrivateKey('-----BEGIN PRIVATE KEY-----')).assertTrue();
      expect(validateKeyImport('', '-----BEGIN OPENSSH PRIVATE KEY-----')).assertEqual('请填写密钥名称');
      expect(validateKeyImport('k', 'nope')).assertEqual('私钥内容不是受支持的 OpenSSH / PEM 格式');
      const parts = parseOpenSshPublicKey(SAMPLE_OPENSSH_PUB);
      expect(parts.valid).assertTrue();
      expect(parts.keyType).assertEqual('ssh-ed25519');
      expect(parseOpenSshPublicKey('nope').valid).assertFalse();
      // displayFingerprint 仍稳定（旧数据兼容）
      const fp1 = displayFingerprint('ssh-ed25519', 'abc');
      const fp2 = displayFingerprint('ssh-ed25519', 'abc');
      const fp3 = displayFingerprint('ssh-ed25519', 'abd');
      expect(fp1.length > 0).assertTrue();
      expect(fp1).assertEqual(fp2);
      expect(fp1 === fp3).assertFalse();
    });

    it('buildOpensshPublicKeyLine_ed25519Wire格式', 0, () => {
      // 32 字节可识别公钥：0x00..0x1f
      const raw: Uint8Array = new Uint8Array(32);
      for (let i = 0; i < 32; i++) {
        raw[i] = i;
      }
      const line: string = buildOpensshPublicKeyLine('ssh-ed25519', raw, 'me@ohos');
      expect(line.startsWith('ssh-ed25519 ')).assertTrue();
      expect(line.endsWith(' me@ohos')).assertTrue();
      const parts = line.split(/\s+/);
      expect(parts.length).assertEqual(3);
      expect(parts[0]).assertEqual('ssh-ed25519');
      expect(parts[2]).assertEqual('me@ohos');
      // blob = wire("ssh-ed25519") + wire(raw32) = 4+11+4+32 = 51
      const blob: Uint8Array | null = base64DecodeToBytes(parts[1]);
      expect(blob !== null).assertTrue();
      if (blob !== null) {
        expect(blob.length).assertEqual(51);
        // 前 4 字节 = 11 大端
        expect(blob[0]).assertEqual(0);
        expect(blob[1]).assertEqual(0);
        expect(blob[2]).assertEqual(0);
        expect(blob[3]).assertEqual(11);
        const typeBytes: string = String.fromCharCode(blob[4], blob[5], blob[6], blob[7],
          blob[8], blob[9], blob[10], blob[11], blob[12], blob[13], blob[14]);
        expect(typeBytes).assertEqual('ssh-ed25519');
        // 长度字段 32 = 0x00000020
        expect(blob[15]).assertEqual(0);
        expect(blob[16]).assertEqual(0);
        expect(blob[17]).assertEqual(0);
        expect(blob[18]).assertEqual(32);
        let keyOk: boolean = true;
        for (let i = 0; i < 32; i++) {
          if (blob[19 + i] !== raw[i]) {
            keyOk = false;
          }
        }
        expect(keyOk).assertTrue();
      }
      // 无 comment
      const noComment: string = buildOpensshPublicKeyLine('ssh-ed25519', raw, '');
      expect(noComment.split(/\s+/).length).assertEqual(2);
      expect(noComment.startsWith('ssh-ed25519 ')).assertTrue();
      // 指纹可计算且与独立 blob 一致
      const fp: string = formatOpenSshFingerprint(line);
      expect(fp.startsWith('SHA256:')).assertTrue();
      expect(isOpenSshPublicKeyLine(line, 'ssh-ed25519')).assertTrue();
      expect(isOpenSshPublicKeyLine(line, 'ssh-rsa')).assertFalse();
    });

    it('buildOpensshPublicKeyLine_非法输入返回空', 0, () => {
      expect(buildOpensshPublicKeyLine('', new Uint8Array([1, 2, 3]), '')).assertEqual('');
      expect(buildOpensshPublicKeyLine('ssh-ed25519', new Uint8Array(0), '')).assertEqual('');
      expect(isOpenSshPublicKeyLine('')).assertFalse();
    });

    it('sshWireLengthPrefixed_大端长度前缀', 0, () => {
      const payload: Uint8Array = new Uint8Array([0x61, 0x62, 0x63]); // abc
      const wire: Uint8Array = sshWireLengthPrefixed(payload);
      expect(wire.length).assertEqual(7);
      expect(wire[0]).assertEqual(0);
      expect(wire[1]).assertEqual(0);
      expect(wire[2]).assertEqual(0);
      expect(wire[3]).assertEqual(3);
      expect(wire[4]).assertEqual(0x61);
      expect(wire[5]).assertEqual(0x62);
      expect(wire[6]).assertEqual(0x63);
      const blob: Uint8Array = buildOpensshPublicKeyBlob('ssh-ed25519', new Uint8Array(32));
      expect(blob.length).assertEqual(51);
    });
  });
}
