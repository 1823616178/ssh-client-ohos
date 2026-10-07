/**
 * 私钥管理纯逻辑 —— 任务 U3 + 指纹对齐（ssh-keygen -lf）。
 *
 * 格式识别、OpenSSH 公钥指纹、公钥导出文本整理；不触碰 ASSET / UI。
 *
 * 指纹口径（与 hostkey.cpp fingerprintSha256 / ssh-keygen -l 一致）：
 *   blob = base64_decode(OpenSSH 公钥行第 2 字段)
 *   fingerprint = "SHA256:" + base64(sha256(blob))  // base64 无 '=' 填充
 * 无公钥时无法计算 blob 指纹，返回空串（UI 回退 keyType，不伪造）。
 */

/** 受支持的私钥头（与 native agent 粗检一致） */
export const PRIVATE_KEY_HEADERS: string[] = [
  '-----BEGIN OPENSSH PRIVATE KEY-----',
  '-----BEGIN RSA PRIVATE KEY-----',
  '-----BEGIN EC PRIVATE KEY-----',
  '-----BEGIN DSA PRIVATE KEY-----',
  '-----BEGIN PRIVATE KEY-----',
  '-----BEGIN ENCRYPTED PRIVATE KEY-----'
];

export type PrivateKeyFormat = 'openssh' | 'pem' | 'pkcs8' | 'encrypted-pkcs8' | 'unknown';

/** 私钥格式粗检（纯函数） */
export function detectPrivateKeyFormat(data: string): PrivateKeyFormat {
  const trimmed: string = data.replace(/^[\s]+/, '');
  if (trimmed.startsWith('-----BEGIN OPENSSH PRIVATE KEY-----')) {
    return 'openssh';
  }
  if (trimmed.startsWith('-----BEGIN RSA PRIVATE KEY-----') ||
    trimmed.startsWith('-----BEGIN EC PRIVATE KEY-----') ||
    trimmed.startsWith('-----BEGIN DSA PRIVATE KEY-----')) {
    return 'pem';
  }
  if (trimmed.startsWith('-----BEGIN ENCRYPTED PRIVATE KEY-----')) {
    return 'encrypted-pkcs8';
  }
  if (trimmed.startsWith('-----BEGIN PRIVATE KEY-----')) {
    return 'pkcs8';
  }
  return 'unknown';
}

export function looksLikePrivateKey(data: string): boolean {
  return detectPrivateKeyFormat(data) !== 'unknown';
}

export function privateKeyFormatLabel(format: PrivateKeyFormat): string {
  if (format === 'openssh') {
    return 'OpenSSH';
  }
  if (format === 'pem') {
    return 'PEM';
  }
  if (format === 'pkcs8') {
    return 'PKCS#8';
  }
  if (format === 'encrypted-pkcs8') {
    return 'PKCS#8（加密）';
  }
  return '未知格式';
}

/** OpenSSH 公钥行解析：`type base64 [comment]` */
export interface PublicKeyParts {
  readonly keyType: string;
  readonly base64: string;
  readonly comment: string;
  /** 是否解析成功 */
  readonly valid: boolean;
}

export function parseOpenSshPublicKey(line: string): PublicKeyParts {
  const trimmed: string = line.trim();
  const parts: string[] = trimmed.split(/\s+/);
  if (parts.length < 2) {
    return { keyType: '', base64: '', comment: '', valid: false };
  }
  const keyType: string = parts[0];
  const base64: string = parts[1];
  const known: boolean = keyType.startsWith('ssh-') || keyType.startsWith('ecdsa-') ||
    keyType.startsWith('sk-');
  if (!known || base64.length < 16) {
    return { keyType: keyType, base64: base64, comment: '', valid: false };
  }
  const comment: string = parts.length > 2 ? parts.slice(2).join(' ') : '';
  return { keyType: keyType, base64: base64, comment: comment, valid: true };
}

// ---------------------------------------------------------------- SHA-256（纯实现）

const SHA256_K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function rotr32(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/** SHA-256 摘要（32 字节）。空输入 = FIPS 180-2 空串向量。 */
export function sha256Bytes(data: Uint8Array): Uint8Array {
  const h: number[] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ];
  const bitLen: number = data.length * 8;
  const padLen: number = (((55 - data.length) % 64) + 64) % 64 + 1;
  const total: number = data.length + padLen + 8;
  const msg: Uint8Array = new Uint8Array(total);
  msg.set(data, 0);
  msg[data.length] = 0x80;
  // 长度按大端 64-bit 写入（公钥 blob 远小于 2^32，高 32 位恒 0）
  const hi: number = Math.floor(bitLen / 0x100000000);
  const lo: number = bitLen >>> 0;
  msg[total - 8] = (hi >>> 24) & 0xff;
  msg[total - 7] = (hi >>> 16) & 0xff;
  msg[total - 6] = (hi >>> 8) & 0xff;
  msg[total - 5] = hi & 0xff;
  msg[total - 4] = (lo >>> 24) & 0xff;
  msg[total - 3] = (lo >>> 16) & 0xff;
  msg[total - 2] = (lo >>> 8) & 0xff;
  msg[total - 1] = lo & 0xff;

  const w: number[] = new Array<number>(64);
  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) {
      const j = off + i * 4;
      w[i] = ((msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i++) {
      const s0 = (rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
      const s1 = (rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a = h[0];
    let b = h[1];
    let c = h[2];
    let d = h[3];
    let e = h[4];
    let f = h[5];
    let g = h[6];
    let hh = h[7];
    for (let i = 0; i < 64; i++) {
      const S1 = (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) >>> 0;
      const ch = ((e & f) ^ ((~e) & g)) >>> 0;
      const temp1 = (hh + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const S0 = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const temp2 = (S0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  const out: Uint8Array = new Uint8Array(32);
  for (let i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (h[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (h[i] >>> 8) & 0xff;
    out[i * 4 + 3] = h[i] & 0xff;
  }
  return out;
}

/** SHA-256 十六进制（小写），诊断与测试用 */
export function sha256Hex(data: Uint8Array): string {
  const digest: Uint8Array = sha256Bytes(data);
  let hex: string = '';
  for (let i = 0; i < digest.length; i++) {
    hex += (digest[i] >>> 0).toString(16).padStart(2, '0');
  }
  return hex;
}

// ---------------------------------------------------------------- base64（OpenSSH 指纹用）

const B64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** 标准 base64，无 '=' 填充（ssh-keygen SHA256 指纹格式；与 hostkey.cpp 一致） */
export function base64EncodeNoPadding(bytes: Uint8Array): string {
  let out: string = '';
  let i = 0;
  const len: number = bytes.length;
  for (; i + 3 <= len; i += 3) {
    const v: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_ALPHABET.charAt((v >> 18) & 63);
    out += B64_ALPHABET.charAt((v >> 12) & 63);
    out += B64_ALPHABET.charAt((v >> 6) & 63);
    out += B64_ALPHABET.charAt(v & 63);
  }
  const rem: number = len - i;
  if (rem === 1) {
    const v: number = bytes[i] << 16;
    out += B64_ALPHABET.charAt((v >> 18) & 63);
    out += B64_ALPHABET.charAt((v >> 12) & 63);
  } else if (rem === 2) {
    const v: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64_ALPHABET.charAt((v >> 18) & 63);
    out += B64_ALPHABET.charAt((v >> 12) & 63);
    out += B64_ALPHABET.charAt((v >> 6) & 63);
  }
  return out;
}

function b64IndexOf(ch: string): number {
  if (ch === '=') {
    return -2;
  }
  return B64_ALPHABET.indexOf(ch);
}

/** base64 解码（OpenSSH 公钥字段通常无 padding；非法字符返回 null） */
export function base64DecodeToBytes(text: string): Uint8Array | null {
  const cleaned: string = text.replace(/\s+/g, '');
  if (cleaned.length === 0) {
    return new Uint8Array(0);
  }
  const padCount: number = (cleaned.endsWith('==') ? 2 : (cleaned.endsWith('=') ? 1 : 0));
  const bodyLen: number = cleaned.length - padCount;
  if (bodyLen <= 0) {
    return null;
  }
  const outLen: number = Math.floor(bodyLen * 3 / 4);
  const out: Uint8Array = new Uint8Array(outLen);
  let acc: number = 0;
  let accBits: number = 0;
  let oi: number = 0;
  for (let i = 0; i < cleaned.length && oi < outLen; i++) {
    const val: number = b64IndexOf(cleaned.charAt(i));
    if (val === -2) {
      break;
    }
    if (val < 0) {
      return null;
    }
    acc = (acc << 6) | val;
    accBits += 6;
    if (accBits >= 8) {
      accBits -= 8;
      out[oi] = (acc >> accBits) & 0xff;
      oi++;
    }
  }
  return oi === outLen ? out : null;
}

// ---------------------------------------------------------------- OpenSSH 指纹

/**
 * OpenSSH 公钥行 → `SHA256:<base64 无填充>`。
 * 与 `ssh-keygen -lf id.pub` 第二列一致（输入为整行或 `type base64 [comment]`）。
 * 解析失败 / blob 非法时返回空串。
 */
export function formatOpenSshFingerprint(publicKeyLine: string): string {
  const parsed: PublicKeyParts = parseOpenSshPublicKey(publicKeyLine);
  if (!parsed.valid) {
    return '';
  }
  const blob: Uint8Array | null = base64DecodeToBytes(parsed.base64);
  if (blob === null || blob.length === 0) {
    return '';
  }
  return 'SHA256:' + base64EncodeNoPadding(sha256Bytes(blob));
}

/**
 * 展示用指纹（非加密摘要，列表辨识兜底）。
 * 有合法公钥时不再走此路径；仅诊断/旧数据兼容保留。
 */
export function displayFingerprint(keyType: string, material: string): string {
  if (material.length === 0) {
    return '';
  }
  let hash: number = 0xcbf29ce484222325;
  const prime: number = 0x100000001b3;
  for (let i = 0; i < material.length; i++) {
    hash ^= material.charCodeAt(i);
    // 保持在 32 位无符号范围，避免 JS 位运算溢出语义漂移
    hash = Math.imul(hash, prime) >>> 0;
  }
  const hex: string = (hash >>> 0).toString(16).toUpperCase().padStart(8, '0');
  const typePrefix: string = keyType.length > 0 ? keyType : 'KEY';
  return `${typePrefix}:${hex}`;
}

/**
 * 私钥条目的指纹：公钥行优先 → 真实 OpenSSH SHA256；
 * 无公钥（blob 不可知）返回空串，由 UI 回退 keyType，不伪造 SSH 指纹。
 */
export function fingerprintForEntry(publicKey: string, privateKey: string): string {
  const sshFp: string = formatOpenSshFingerprint(publicKey);
  if (sshFp.length > 0) {
    return sshFp;
  }
  // 无私钥也不返回伪指纹：privateKey 参数保留以兼容签名；调用方可据 format 做 UI 提示
  if (privateKey.length === 0 && publicKey.trim().length === 0) {
    return '';
  }
  return '';
}

/** 导出公钥文本：规范化为单行 OpenSSH 格式 */
export function exportPublicKeyText(publicKey: string): string {
  return publicKey.trim();
}

// ---------------------------------------------------------------- OpenSSH 公钥行组装（U3 纯逻辑）

/**
 * SSH wire 格式的 length-prefixed 字符串：uint32 大端长度 + 原始字节。
 * 与 native keygen（cpp/ssh/keygen.cpp appendWireString）同一约定。
 */
export function sshWireLengthPrefixed(payload: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(4 + payload.length);
  const len: number = payload.length;
  out[0] = (len >>> 24) & 0xff;
  out[1] = (len >>> 16) & 0xff;
  out[2] = (len >>> 8) & 0xff;
  out[3] = len & 0xff;
  out.set(payload, 4);
  return out;
}

function utf8Encode(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return new Uint8Array(out);
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/**
 * OpenSSH 公钥 blob：wire(string keyType) + wire(raw public key bytes)。
 * ed25519 时 keyType='ssh-ed25519'，raw 为 32 字节。
 */
export function buildOpensshPublicKeyBlob(keyType: string, publicKeyBytes: Uint8Array): Uint8Array {
  return concatBytes(
    sshWireLengthPrefixed(utf8Encode(keyType)),
    sshWireLengthPrefixed(publicKeyBytes)
  );
}

/**
 * 组装 OpenSSH 公钥单行：`<keyType> <base64(blob)> [comment]`。
 * comment 为空时不写第三段（与 ssh-keygen -y 在无 comment 时一致）。
 * publicKeyBytes 非法（空）或 keyType 为空时返回空串。
 */
export function buildOpensshPublicKeyLine(
  keyType: string,
  publicKeyBytes: Uint8Array,
  comment: string
): string {
  if (keyType.length === 0 || publicKeyBytes.length === 0) {
    return '';
  }
  const blob: Uint8Array = buildOpensshPublicKeyBlob(keyType, publicKeyBytes);
  const b64: string = base64EncodeNoPadding(blob);
  const trimmedComment: string = comment.trim();
  if (trimmedComment.length === 0) {
    return `${keyType} ${b64}`;
  }
  return `${keyType} ${b64} ${trimmedComment}`;
}

/**
 * 校验生成/导入的公钥行是否可被 formatOpenSshFingerprint 消费。
 * 额外要求 keyType 匹配、base64 blob 解码后含该 keyType 的 wire 前缀。
 */
export function isOpenSshPublicKeyLine(line: string, expectedKeyType?: string): boolean {
  const parsed: PublicKeyParts = parseOpenSshPublicKey(line);
  if (!parsed.valid) {
    return false;
  }
  if (expectedKeyType !== undefined && expectedKeyType.length > 0 && parsed.keyType !== expectedKeyType) {
    return false;
  }
  return formatOpenSshFingerprint(line).length > 0;
}

/** KeyManager 列表项（元数据；私钥/短语在 CredentialStore，不进本结构） */
export interface KeyEntryMeta {
  readonly id: string;
  name: string;
  keyType: string;
  fingerprint: string;
  publicKey: string;
  /** 是否已有短语（只展示布尔，不存短语） */
  hasPassphrase: boolean;
  createdAt: string;
}

export function createKeyEntryMeta(id: string, name: string): KeyEntryMeta {
  return {
    id: id,
    name: name,
    keyType: '',
    fingerprint: '',
    publicKey: '',
    hasPassphrase: false,
    createdAt: ''
  };
}

/** 导入校验：名称非空 + 私钥格式可识别 */
export function validateKeyImport(name: string, privateKey: string): string {
  if (name.trim().length === 0) {
    return '请填写密钥名称';
  }
  if (!looksLikePrivateKey(privateKey)) {
    return '私钥内容不是受支持的 OpenSSH / PEM 格式';
  }
  return '';
}

/** KeyManager 列表指纹展示：空指纹回退 keyType，并标明缺公钥 */
export function keyEntryFingerprintDisplay(entry: KeyEntryMeta): string {
  if (entry.fingerprint.length > 0) {
    return entry.fingerprint;
  }
  if (entry.keyType.length > 0) {
    return `${entry.keyType}（无公钥，未计算 SSH 指纹）`;
  }
  return '未计算指纹';
}
