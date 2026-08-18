# CLAUDE.md

本文件为 AI 编码助手提供项目上下文。修改代码前先读关键文档。

## 项目定位

HarmonyOS NEXT 原生 SSH 终端客户端：ArkTS/ArkUI 声明式界面 + C 原生核心（libssh2 + OpenSSL + libvterm + libargon2，静态链接为单个 `libssh_core.so`），通过 NAPI 桥接；配置经端到端加密的云同步在多设备间同步（Argon2id + AES-256-GCM）。

## 关键文档

- `docs/DESIGN.md` — 总体设计：架构与线程模型、终端数据通路（§2.2）、原生依赖选型与交叉编译（§3）、Design Token（§4.2）、数据模型（§5）、同步协议与密码学参数（§6）、目录结构（§8）、关键决策（§10）
- `docs/TASKS.md` — 任务规划：里程碑、任务依赖、交付物与验收标准

## 目录结构摘要

```
entry/src/main/cpp/            原生核心（C/C++）
  ├── bridge/                  NAPI 绑定、threadsafe function、external ArrayBuffer
  ├── ssh/                     libssh2 会话、认证、通道、SFTP、转发
  ├── term/                    libvterm 封装、单元格网格、回滚缓冲、脏行位图
  ├── crypto/                  Argon2id / AES-256-GCM / HKDF / 恢复密钥
  ├── io/                      非阻塞 socket + epoll 事件循环
  ├── third_party/             libssh2 / libvterm / libargon2 源码
  └── prebuilt/                OpenSSL 等静态库（按 ABI，不入库）
entry/src/main/ets/            ArkTS 层
  ├── entryability/  pages/    入口与页面
  ├── view/                    可复用组件（TerminalCanvas、HostCard…）
  ├── viewmodel/               页面状态（@ObservedV2）
  ├── service/                 SessionManager / SyncCoordinator / CredentialBroker…
  ├── repository/              relationalStore / preferences / asset 封装
  ├── napi/                    libssh_core.d.ts 与薄封装
  ├── common/                  model / constants / utils / 错误映射
  └── theme/                   Design Token 与主题预设
entry/src/main/resources/      base/element、dark/element、rawfile/font/（终端字体）
scripts/                       交叉编译、native 单测、CI 门禁脚本
```

## 构建命令

- 构建 HAP：`hvigorw assembleHap --mode module -p product=default`
  （本机可直接 `node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" assembleHap --mode module -p product=default`）
- 测试：`hvigorw test`

## 硬性约束

- **不改外部仓库**：`E:\code\ssh-tool` 与 `G:\code\ssh-tool-server` 一行不改；同步后端按原样复用。
- **与桌面端共用同步格式**：保险库与同步文档跟桌面端 ssh-tool 完全互通（同账号双向同步），
  故 AAD 域用 `ssh-port-mapper/*`、恢复密钥前缀 `SPM1`，文档必须严格产出桌面端的 `SyncDocumentV1`
  （`E:\code\ssh-tool\src\shared\sync-schemas.ts` 是 `z.strictObject`，多一个键对端会整份拒绝）。
  只同步「主机基础字段 / 端口转发 / 分组」交集；外观、片段、known_hosts、跳板、初始命令、
  环境变量、终端类型等为本机专有，不上云，且**下行时不得被覆盖清空**。
- **禁止硬编码颜色/尺寸**：组件中不得出现魔法数字，一律使用 Design Token（`resources` 的 `color.json` / `float.json` 与 `theme/` 封装）。
- **日志脱敏**：不记录密码、token、私钥、请求体与同步密文。
