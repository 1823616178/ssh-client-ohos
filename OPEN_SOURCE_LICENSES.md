# 开源软件许可声明

本应用（HarmonyOS SSH Client）静态/动态链接或随包分发了以下开源组件。
完整许可证文本见各上游项目；字体全文另见
`entry/src/main/resources/rawfile/font/OFL-JetBrainsMono.txt` 与
`OFL-SarasaGothic.txt`。

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| OpenSSL | 3.5.x | Apache License 2.0 | libcrypto（SSH/保险库密码学） |
| libssh2 | 1.11.x | BSD-3-Clause | SSH 协议内核 |
| libvterm | 0.3.x | MIT | 终端 VT 仿真 |
| libargon2 (phc-winner-argon2) | 20190702 | Apache-2.0 / CC0-1.0 | Argon2id KDF |
| JetBrains Mono | 随包 | SIL OFL 1.1 | 终端 ASCII 等宽字体 |
| Sarasa Term SC | 随包 | SIL OFL 1.1 | 终端 CJK 等宽字体 |
| zlib | NDK 系统 | zlib License | libssh2 压缩 |

## OpenSSL（Apache-2.0）摘要

- 版权归 OpenSSL Project 贡献者。
- 再分发须保留版权与许可声明、NOTICE（若有）。
- 本应用以**静态库**形式链入 `libssh_core.so`，不修改 OpenSSL 源码接口语义。
- 许可证全文：<https://www.openssl.org/source/license-openssl-3.0.txt>

## libssh2（BSD-3-Clause）摘要

- 版权归 libssh2 项目贡献者。
- 再分发二进制须在文档/关于页保留版权声明与本声明列表。
- 许可证全文见上游 `COPYING` / `LICENSE`：<https://libssh2.org/>

## libvterm（MIT）摘要

- 版权归 Paul Evans 等贡献者。
- 可自由使用、复制、修改、合并、发布、分发、再许可及销售副本，
  须保留版权声明与许可声明。

## libargon2（Apache-2.0 / CC0 双许可）摘要

- 参考实现 phc-winner-argon2；可选择 Apache-2.0 或 CC0-1.0。
- 本项目按 Apache-2.0 条款使用，保留版权与 NOTICE。

## 字体（SIL Open Font License 1.1）

- **JetBrains Mono** 与 **Sarasa Term SC** 均以 OFL 1.1 随包分发。
- OFL 允许免费使用、研究、修改与再分发；**不得单独以字体本体销售**。
- 修改后的字体须更换 Reserved Font Name（本应用未修改字体文件）。
- 全文：`entry/src/main/resources/rawfile/font/OFL-*.txt`
  与 <https://scripts.sil.org/OFL>

## zlib（zlib License）

- 使用 HarmonyOS NDK sysroot 自带的 `libz.so` 动态链接。
- 许可证要求保留版权声明；详见 NDK 文档与 <https://zlib.net/zlib_license.html>

## 合规检查清单（P3 / P5）

- [x] 应用内「设置 → 开源许可」页展示上表摘要
- [x] 仓库根 `OPEN_SOURCE_LICENSES.md` 保留本文件
- [x] 字体 OFL 全文随 rawfile 打包
- [ ] AppGallery 提审材料附第三方开源清单（P5）
- [ ] 依赖 CVE 扫描报告（Q4）
