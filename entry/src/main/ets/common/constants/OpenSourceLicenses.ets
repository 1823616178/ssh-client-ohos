/**
 * 开源许可清单数据 —— 任务 P3（纯数据，Settings/许可页共用）。
 *
 * 覆盖 OpenSSL / libssh2 / libvterm / libargon2 / 字体（JetBrains Mono、
 * Sarasa Term SC）与系统 zlib。全文见仓库根 `OPEN_SOURCE_LICENSES.md`；
 * 应用内只展示摘要 + 许可证名称，完整条款随 rawfile 或文档提供。
 */

export interface OpenSourceLicenseEntry {
  readonly name: string;
  readonly version: string;
  readonly license: string;
  readonly usage: string;
  readonly homepage: string;
}

export const OPEN_SOURCE_LICENSES: OpenSourceLicenseEntry[] = [
  {
    name: 'OpenSSL',
    version: '3.5.x',
    license: 'Apache License 2.0',
    usage: 'SSH 与保险库密码学（libcrypto 静态链接）',
    homepage: 'https://www.openssl.org/'
  },
  {
    name: 'libssh2',
    version: '1.11.x',
    license: 'BSD-3-Clause',
    usage: 'SSH 协议内核（会话/认证/通道/SFTP）',
    homepage: 'https://libssh2.org/'
  },
  {
    name: 'libvterm',
    version: '0.3.x',
    license: 'MIT',
    usage: '终端仿真（VT 状态机与单元格网格）',
    homepage: 'https://www.leonerd.org.uk/code/libvterm/'
  },
  {
    name: 'libargon2 (phc-winner-argon2)',
    version: '20190702',
    license: 'Apache License 2.0 / CC0-1.0 dual',
    usage: '同步保险库 KDF（Argon2id）',
    homepage: 'https://github.com/P-H-C/phc-winner-argon2'
  },
  {
    name: 'JetBrains Mono',
    version: '随包',
    license: 'SIL Open Font License 1.1',
    usage: '终端等宽字体（ASCII）',
    homepage: 'https://www.jetbrains.com/lp/mono/'
  },
  {
    name: 'Sarasa Term SC',
    version: '随包',
    license: 'SIL Open Font License 1.1',
    usage: '终端中日韩等宽字体（与 JetBrains Mono 1:2 对齐）',
    homepage: 'https://github.com/be5invis/Sarasa-Gothic'
  },
  {
    name: 'zlib',
    version: '系统自带',
    license: 'zlib License',
    usage: 'libssh2 压缩（NDK sysroot 动态链接）',
    homepage: 'https://zlib.net/'
  }
];
