# 开源许可清单

本应用（`ssh_client_ohos`）静态或动态链接了下列第三方组件。完整许可证正文随包分发于
`entry/src/main/resources/rawfile/`（字体 OFL 文本），或见各上游项目的官方仓库。

| 组件 | 版本 | 许可证 | 链接方式 | 随包材料 |
|---|---|---|---|---|
| OpenSSL | 3.5.x | Apache License 2.0 | 静态（`libcrypto.a`） | 源码见交叉编译配方 `docs/NATIVE-BUILD.md` / DESIGN §3.7 |
| libssh2 | 1.11.x | BSD-3-Clause | 静态 | `entry/src/main/cpp/third_party` |
| libvterm | 0.3.x | BSD-2-Clause（ISC 风格） | 静态 | 同上 |
| libargon2 | 20190702 | CC0 1.0 / Apache-2.0（双许可，取 CC0） | 静态 | 同上；宿主侧见 `scripts/build-host-argon2.sh` |
| zlib | 系统 NDK | zlib License | 动态 `-lz`（OHOS sysroot） | 系统自带，不随 HAP 再分发 |
| JetBrains Mono | Regular / Bold | SIL Open Font License 1.1 | 随包 rawfile 字体 | `rawfile/font/OFL-JetBrainsMono.txt` |
| Sarasa Term SC | Regular | SIL Open Font License 1.1（基于思源等） | 随包 rawfile 字体 | `rawfile/font/OFL-SarasaGothic.txt` |

## 义务说明（上架自查）

1. **Apache-2.0（OpenSSL）**：保留 NOTICE/版权声明；若修改 OpenSSL 源码需注明。本项目按公开配方交叉编译，未改接口语义。
2. **BSD-3-Clause / BSD-2-Clause**：再分发二进制时保留版权声明与许可文本（见 `third_party` 源码树 LICENSE）。
3. **OFL-1.1 字体**：可随应用嵌入分发；不得单独售卖字体文件；许可正文已随包放入 `rawfile/font/`。
4. **隐私与合规**：应用本身不收集诊断数据；同步功能使用独立账号与端到端加密，服务端仅存密文（见 `docs/SYNC-PROTOCOL.md`）。上架材料需附隐私政策（任务 P3/P5）。

## 服务端复用声明

云同步客户端复用既有 `ssh-tool-server` 的 `/api/v1` 部署（内容无关密文信封），**不修改**服务端仓库。
同步 API 地址由构建期 `buildProfileFields.SYNC_API_URL` 注入；公网 HTTPS 化见任务 P6 与风险 R-8。

## 应用内入口

设置页 →「关于」→「开源许可」应展示本清单摘要，并可跳转/展开 rawfile 中的 OFL 全文。
