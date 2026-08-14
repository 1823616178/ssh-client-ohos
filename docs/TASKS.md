# HarmonyOS SSH 客户端 任务规划

> 配套文档：`docs/DESIGN.md`
> 计量单位：**人日**（1 人日 = 1 个熟练开发者 1 个工作日）
> 总量：**221 人日**（各里程碑逐条求和的结果）。单人串行约 9.5 个月；
> 按 §5 的双轨并行（1 名原生 / 1 名 ArkTS）约 **5 个月**。
> 范围：**全部任务都在本仓库内**。不改 `E:\code\ssh-tool`，不改 `G:\code\ssh-tool-server`。

---

## 进度快照（2026-08-15 更新）

- **已完成（M0）**：X1 `b1fa2f0`、X5 `f8b604e`、X2 `a57d4e7`、X4 `dbfd13f`、N1/N2 `d8604bd`、N3 `e5e8c25`、N4 `181b00d`、X3 `79e4c49`
- **已完成（M1）**：N5 `070c6f7`、N6 `9646ecc`、N7 `caff668`、N8 `3a8e85d`、N9 `72a4b32`、N10 `6610a22`、N11 `089c617`、N12 `9db98d0`、N13 `da2428e`；C3 提前完成 `b65dd79`
- **已完成（M3）**：C1 `23a67aa`（relationalStore 六表 + planMigration 迁移框架 + RdbGateway 窄接口/内存 fake + 六 DAO，单测全覆盖；hypium 编译绿、执行欠账同 Previewer 阻塞；UNIQUE 冲突与存储故障共用 INTERNAL_ERROR 为非阻断已知瑕疵）；C2 `11fbde3`+`cf82065`（ASSET 凭据封装：别名 `host_secret:<hostId>:<kind>`、add 冲突转 update、NOT_FOUND 归 null、DEVICE_FIRST_UNLOCKED + SYNC_TYPE=NEVER、IS_PERSISTENT 用默认 false 规避权限；纯逻辑单测就绪，hdc 无明文/卸载不可恢复两条系统属性留真机待验；删主机须级联调 `removeAllSecrets`）；C4 `d2d9f4d`（SessionManager：@ObservedV2 SessionInfo、deps 注入可全 fake 单测（12 用例）、窗格双向绑定、退避倒计时 tick 链同源、sessionId 不变句柄换新、旧句柄迟到事件丢弃、EntryAbility 已接 AppDatabase.init 与 onDestroy→closeAll；dirty 唤醒通路待 U4 接到 TerminalCanvas.notifyContentDirty；8 会话真机稳定待验；非阻断观察：重连超限进 error 终态时不 close 旧句柄，留 P/Q 阶段确认 native 资源自闭）
- **已完成（M2）**：T1 `62b87c2`、T2 `0f6529b`、T3 `c49a8f9`（+回滚窗口修复 `a5d759b`）、T4 `22253f5`（帧率/CPU 验收待真机）、T5 `267991a`（字体注册与度量，Sarasa 只带 Regular）、T6 `e0c2498`（候选期 previewText 判定与应用光标模式接线待真机）、T7/T8/T9 `db3bc57`（手势/粘贴/触感与 less 翻页、捏合不抖等验收留真机）——T5 起 hypium 均只有编译绿证（Previewer 阻塞）
- **M1 剩余**：Q1 大部分已由「WSL 免 root sshd + native 测试 + ci-local.sh 门禁」覆盖，Docker 多算法 sshd 与 x86_64 模拟器用例待补
- **阻塞**：X0（签名，需人工）；N3b/T0 spike 与全部真机验收依赖 X0（含 T4 的 ≥50fps / CPU≈0 / 4 实例验收）
- **验证基线**：`scripts/run-native-tests.sh` 193/193（含真实 sshd 集成）、ASan 干净；`scripts/ci-local.sh` 阶段 1/3/4 绿，阶段 2 视 Previewer 环境
- **已知跟踪项**：session_bridge 在途调用 vs teardown 的极窄竞态（登记给 Q3）；OHOS musl 无 explicit_bzero（用 OPENSSL_cleanse，已落地）；**hvigor 本地单测经 Previewer.exe 执行，该进程在某些 Windows 会话无法启动（0xC0000142，桌面堆/会话级问题，需注销重登或重启），ci-local.sh 阶段 2 已加超时快速失败（`e2fda54`）；Previewer 恢复后需补跑 `hvigorw test` 留绿证（T5 起的新增用例只有编译绿证）**；T4 帧调度自动休眠需 U4 把会话事件接到 `notifyContentDirty()`（`FrameSchedulerCore.ets` 头注）；T4 光标/字符 blink 闪烁定时留给 A3；T8 缺口：拖拽手柄/放大镜/气泡菜单粘贴分享（改长按定位+抬手再拖，留待打磨）；T9 alt-screen keys 模式方向键未随 DECCKM 切 SS3（留待 T10）

---

## 0. 怎么读这份表

- **轨道**：`X` 基座 / `N` 原生 / `T` 终端 / `C` 核心数据 / `U` 界面 / `S` 同步 / `Q` 质量 / `P` 发布
- **依赖**：必须完成才能开工的任务 ID
- 每个任务都写了**交付物**与**验收标准**。验收标准是「能被别人复核的事实」，不是「做完了」
- 🔴 = 关键路径；⚠️ = 高风险，需要预留缓冲

---

## 1. 里程碑总览

| 里程碑 | 内容 | 人日 | 出口标准（Demo 能演示什么） |
|---|---|---|---|
| **M0** 基座与技术验证 | 环境签名、工程骨架、原生依赖编译、两个高风险 spike | 20 | 真机跑通「NAPI 调 libssh2 打印版本号」；**且 N3b/T0 两个 spike 给出明确结论**（走主方案还是走兜底） |
| **M1** SSH 内核 | 连接、认证、shell 通道、事件模型 | 30 | 命令行式最小界面能连上真实服务器、执行命令、看到原始输出 |
| **M2** 终端引擎与渲染 | libvterm、单元格网格、Canvas 绘制、触摸/键盘/鼠标输入 | 38 | 能跑 `vim`、`htop`、`tmux`，中文与 emoji 正常，`cat` 大文件不掉帧 |
| **M3** 数据层与主界面 | 存储、主机管理、连接流程 UI、多标签分屏 | 36 | 完整可用的本地 SSH 客户端（无同步、无 SFTP） |
| **M4** 外观系统 | 主题、字体、配色、实时预览 | 16 | R4 全部可配置项落地，主题导入可用 |
| **M5** 云端同步 | 账号、保险库、同步引擎、冲突 UI | 35 | 手机 A 改配置 → 手机 B / 平板上看到；断网改再联网能补传；冲突可解 |
| **M6** SFTP 与端口转发 | 文件传输、`-L`/`-R`/`-D`、ProxyJump | 20 | 传文件、开隧道、跳板机连接 |
| **M7** 打磨与发布 | 性能、无障碍、合规、HTTPS 化、上架 | 26 | 通过性能门禁与安全自查，产出可上架 HAP |

---

## 2. 任务明细

### M0 — 基座与技术验证（20 人日）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| **X0** 🔴 | **开发环境与签名准备** | X | — | 1 | 华为开发者账号、`bundleName` 申请、调试证书 + Profile、`signingConfigs` 配置、真机/模拟器调试打通 | **一个空白 HAP 能装到真机并启动**。这是所有「真机验收」任务的前提 |
| X1 | 工程骨架初始化 | X | X0 | 1 | 目录结构（见 DESIGN §8）、`.gitignore`（含 `prebuilt/`、`*.a`、`.probe/`）、Git 仓库初始化、`code-linter` 规则、CLAUDE.md | `hvigor assembleHap` 通过；目录与设计文档一致 |
| X2 | Design Token 落地 | X | X1 | 2 | `color.json` / `dark/color.json` / `float.json` / `string.json`，`theme/Tokens.ets` | 深浅色切换后所有 Token 生效；组件中无硬编码颜色与尺寸 |
| N1 🔴 | OpenSSL 3.5 交叉编译 | N | X1 | 1 | `docs/NATIVE-BUILD.md`、`scripts/build-openssl.sh`、`prebuilt/{arm64-v8a,x86_64}/libcrypto.a` | 两个 ABI 均产出静态库；`llvm-nm` 能看到 `EVP_*` 符号；脚本可一键重跑 |
| N2 🔴 | libssh2 / libvterm / libargon2 交叉编译 | N | N1 | 2 | `scripts/build-deps.sh`、四个库的静态产物 | 两个 ABI 产出；libssh2 链接 OpenSSL 无未定义符号 |
| N3 🔴 | CMake 集成与 NAPI Hello World | N | N2 | 3 | `entry/src/main/cpp/CMakeLists.txt`、`napi_init.cpp`、`build-profile.json5` 的 `externalNativeOptions` | 真机调用 `getLibssh2Version()` 返回 `1.11.x`；`libssh_core.so` 出现在 HAP 内 |
| **N3b** 🔴⚠️ | **零拷贝快照可行性验证（spike）** | N | N3 | 1 | 最小 demo：native 分配一块网格内存 → `napi_create_external_arraybuffer` → ArkTS 用 `DataView` 读取并校验 | **真机上返回 `napi_ok` 且 ArkTS 读到的字节与 native 写入完全一致；finalize 回调被正常触发**。失败则立即启用兜底（见下方说明） |
| **T0** 🔴⚠️ | **终端渲染性能预研（spike）** | T/U | X1 | 3 | 最小 demo：Canvas 绘制静态 80×24 彩色字符网格，**单一 displaySync 驱动 1 个和 4 个 Canvas 实例两种场景**，模拟每帧全屏刷新 | 单实例真机稳定 ≥ 55 fps；**4 实例并发仍 ≥ 50 fps**。达不到则在 M0 阶段就切 R-2 兜底路线，而不是等到 T4（第 9 周） |
| N4 | native 单元测试框架 | N/Q | N3 | 2 | GoogleTest 接入，宿主机 clang 构建目标，`scripts/run-native-tests.sh` | `npm`/`hvigor` 之外可独立跑 native 测试；CI 可调用 |
| X3 | CI 流水线骨架 | Q | X1,N4 | 2 | GitHub Actions / 本地脚本：lint + native test + ArkTS test + assembleHap | 一条命令跑完全部门禁并输出报告 |
| X4 | 日志与错误映射基础设施 | X | X1,X5 | 1 | `common/Logger.ets`（读 `BuildProfile.LOG_*`，脱敏、5 MiB×3 轮转）、`common/SshError.ets` 中文错误码表 | 日志文件轮转生效；抽样确认无密码/token/私钥字样 |
| X5 | 构建期配置与明文 HTTP 放行 | X | X1 | 1 | `build-profile.json5` 的 `buildProfileFields`（debug/release 两套）；`AppScope/app.json5` 明文放行经实测改用 API 20+ 的 `resources/base/profile/network_config.json`（domain-config 定向放行 `123.161.179.32`，全局 cleartext 保持禁止；详见 DESIGN §6.5.2） | `import BuildProfile from 'BuildProfile'` 能读到 `SYNC_API_URL`；真机能成功请求 `http://123.161.179.32:46926/api/v1`；`cleartextTraffic` 保持 `false`；解包 HAP 确认无服务端密钥 |

> **N1 原本是全项目最大的不确定点，现已实测排除。** OpenSSL 3.5.7 交叉编译到 `aarch64-linux-ohos`
> 零错误零补丁通过，可复现配方见 DESIGN §3.7。本任务从 3 人日降为 1 人日（照配方脚本化 + 补 x86_64 ABI）。
> mbedTLS 备选方案（原方案 B）不再需要预留。
>
> **N3b 与 T0 是新增的两个前置 spike，共 4 人日，别跳过。**
> 它们各自验证一个「错了就要推翻架构」的假设，而原计划要到第 9–10 周才会撞上：
>
> - **N3b**：`napi_create_external_arraybuffer` 在 OHOS 的 `js_native_api.h` 里有声明，
>   官方文档也**没有**像 `async_hook` 系列那样标注 "not supported"（我已核对 NDK 文档）。
>   但「头文件有声明」不等于「ArkTS 运行时真的支持」，必须在真机上跑一次才算数。
>   **兜底**：若不可用，改为 native 侧维护常驻 `napi_create_arraybuffer`（运行时持有的普通 ArrayBuffer），
>   每帧只 `memcpy` 脏行区间进去。80×24×16 字节 = 30 KB 满屏，单帧拷贝成本可忽略，
>   代价是多一次拷贝而非零拷贝——**架构不用推翻，但 T3 要改写，早知道早改**。
> - **T0**：R-2（Canvas 帧率）是 R-1 关闭后剩下的最大风险，而首日要做分屏后它还叠加了 R-10（多窗格并发渲染）。
>   花 3 天先画静态字符网格测帧率，**并且直接测 1 实例与 4 实例两种场景**，
>   比写完 T1/T2/T3（11 人日）再加 U4b（5 人日）之后才发现画不动要划算得多。
>   4 实例场景是新增的——它验证 D14「全应用单一帧调度器」这条架构约束是否真的够用。

---

### M1 — SSH 内核（30 人日）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| N5 🔴 | 非阻塞 I/O 事件循环 | N | N3 | 3 | `cpp/io/`：epoll 循环、每会话线程、唤醒管道、超时管理 | 单测：1000 次连接/断开无 fd 泄漏、无线程泄漏（valgrind/ASan 干净） |
| N6 🔴 | 会话生命周期与状态机 | N | N5 | 4 | `cpp/ssh/session.cpp`：握手、算法协商、连接超时、优雅关闭 | 能连通真实 sshd；断网后 30 s 内进入 `disconnected` 而非卡死 |
| N7 🔴 | 主机密钥与 TOFU | N | N6 | 2 | `libssh2_knownhost_*` 封装、SHA256 指纹、randomart 生成 | 首连返回指纹；指纹变更时返回 `HOST_KEY_MISMATCH` 且**不继续握手** |
| N8 🔴 | 认证：密码 / 公钥 / keyboard-interactive | N | N6 | 4 | `cpp/ssh/auth.cpp`；私钥从内存加载（`libssh2_userauth_publickey_frommemory`） | 四种方式各自连通真实 sshd；错误密码返回明确错误码；私钥缓冲区用完 `explicit_bzero` |
| N9 | 应用内 SSH Agent | N | N8 | 2 | 内存密钥托管，多会话复用，超时自动清除 | 解锁一次后第二个会话免密；配置的超时到期后内存中无密钥残留 |
| N10 🔴 | shell 通道与 PTY | N | N8 | 3 | 通道打开、`request_pty`、`resize`、`exec`、EOF/exit-status | 能开 shell；`stty size` 与设置的 cols/rows 一致；resize 后 `SIGWINCH` 生效 |
| N11 🔴 | NAPI 桥接层 | N | N10 | 5 | `cpp/bridge/`：异步方法、`napi_threadsafe_function` 事件流、句柄表、引用计数 | ArkTS 侧能完成「创建→连接→认证→开 shell→写→收事件→关闭」全流程；反复 100 次无内存增长 |
| N12 | keepalive 与自动重连策略 | N | N11 | 2 | keepalive 配置、退避 1/2/5/10/20/30 s、尝试计数 | 拔网线后按退避重连；重连事件带倒计时；上限可配 |
| N13 | 错误码体系 | N | N11 | 2 | 统一 `SshErrorCode` 枚举，覆盖 DNS/超时/拒绝/认证失败/算法不匹配/主机密钥变更等 | 每个错误码在 X4 的中文表里有对应文案；无「未知错误」兜底占比 > 5% |
| Q1 | SSH 集成测试环境 | Q | N11,X3 | 3 | Docker `sshd`（多算法配置）、x86_64 模拟器测试用例 | CI 中自动跑通连接/认证/shell/大数据量收发 |

---

### M2 — 终端引擎与渲染（38 人日）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| T1 🔴 | libvterm 封装与单元格网格 | T/N | N10 | 5 | `cpp/term/`：VTermScreen 回调、连续内存网格、16 字节单元格布局、脏行位图、`revision` | 单测：VT 序列语料（SGR/光标/滚动区/alt-screen/DECSET）全部断言通过 |
| T2 🔴 | 回滚缓冲 | T/N | T1 | 3 | 环形缓冲，默认 5000 行、上限 50000，按窗口区间查询 | 输出 100000 行后内存稳定；任意窗口查询 O(1) 定位 |
| T3 🔴 | 零拷贝快照 NAPI | T/N | T1,N11 | 3 | `napi_create_external_arraybuffer` 暴露网格与脏行位图，含生命周期保护 | ArkTS 读到的字节与 native 一致；native 释放后 ArkTS 再读不崩（有保护） |
| T4 🔴⚠️ | TerminalCanvas 渲染组件 | T/U | T3,X2 | 7 | `view/TerminalCanvas.ets`：**全应用单一 displaySync 帧调度器**（DESIGN §4.3.1/D14）、多实例复用、脏行重绘、OffscreenCanvas 滚动、光标绘制 | `cat` 5 MB 文件全程 ≥ 50 fps；静止时 CPU 占用 ≈ 0；**4 个 Canvas 实例共用一条帧循环，不可见标签页零绘制** |
| T5 | 字体注册与度量 | T/U | T4 | 2 | JetBrains Mono + Sarasa Term SC 随包、`font.registerFont`、字宽缓存 | 中英混排严格对齐；改字号后一帧内重排完成 |
| T6 🔴 | 键盘输入与 IME | T/U | T4,N11 | 5 | 隐藏 TextInput 承接 IME、按键→VT 序列映射表、粘滞修饰键、**按聚焦窗格路由输入** | 中文输入法候选期间不发送；Ctrl+C/Ctrl+D/方向键/Home/End/F1-F12 全部正确；分屏下只有聚焦窗格收到输入 |
| T7 | 移动端功能键条 | U | T6 | 3 | 可横滑键条、Ctrl/Alt 粘滞与长按锁定、自定义键位 | 单手可完成 `Ctrl+C`、`Ctrl+Z`、`Esc`、`Tab` 补全 |
| T8 | 选择、复制、粘贴 | T/U | T4 | 3 | 长按选择模式、拖拽手柄、放大镜、气泡菜单、bracketed paste 提示 | 跨行选择正确含换行；宽字符边界不切半个字 |
| T9 | 滚动与缩放手势 | T/U | T4,T2 | 3 | 回滚滑动、alt-screen 下的滚轮序列切换、双指捏合改字号 | 在 `less` 中滑动能翻页；捏合缩放实时且不抖 |
| **T10** ⚠️ | **物理键盘支持（2in1）** | T/U | T6 | 2 | `onKeyEvent` 通路（不弹软键盘）、完整修饰键组合、F1–F12/Home/End/PgUp/PgDn、可自定义快捷键表 | 接外接键盘时软键盘不弹出；`Ctrl+C`/`Ctrl+D`/`Alt+B`/`Alt+F`/方向键/功能键全部正确送达远端；快捷键可改 |
| **T11** ⚠️ | **鼠标 / 触控板与终端鼠标上报** | T/U | T4,T8 | 2 | 拖拽选择、双击选词、三击选行、滚轮回滚、右键菜单、I-beam 指针；SGR 鼠标模式（`DECSET 1006`）转发 | 触控板拖选与桌面终端一致；`vim`/`tmux`/`htop` 能响应鼠标点击与滚轮 |

---

### M3 — 数据层与主界面（36 人日）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| C1 🔴 | relationalStore 数据层 | C | X1 | 4 | 建表 SQL、DAO、版本迁移框架（hosts/groups/appearance/snippets/known_hosts/forwards） | 迁移可从 v1 升到 vN；单测覆盖全部 DAO |
| C2 🔴 | ASSET 凭据存储 | C | X1 | 3 | `repository/CredentialStore.ets`：密码、密码短语、私钥的存取与删除 | `hdc` 导出沙箱确认无明文；卸载应用后凭据不可恢复 |
| C3 | Preferences 与应用设置 | C | X1 | 1 | 轻量 KV 封装 + 默认值 | 首次启动写入默认值；读写有类型约束 |
| C4 🔴 | SessionManager | C | N11,C1,C2 | 5 | 多会话生命周期、状态广播（`@ObservedV2`）、与 native 句柄一一对应、**会话↔窗格绑定与解绑** | 同时 8 个会话稳定；关闭窗格能正确释放对应会话；应用退出时全部优雅关闭 |
| U1 🔴 | HostListPage | U | C1,X2 | 4 | 分组列表、搜索、状态点、滑动菜单、快速连接、空状态 | 100 台主机列表滚动 ≥ 55 fps；分组折叠状态持久化 |
| U2 🔴 | HostEditPage | U | C1,C2 | 4 | 四段式表单（连接/认证/终端/转发）、校验、测试连接 | 必填校验完整；「测试连接」凭据不经过 UI 层长期驻留 |
| U3 | KeyManagerPage | U | C2,N8 | 3 | 私钥导入（文件/粘贴）、生成密钥对、指纹展示、导出公钥、删除 | 导入 OpenSSH 与 PEM 均成功；生成的 ed25519 公钥能被真实服务器接受 |
| U4 🔴 | TerminalPage 整合（单窗格） | U | T4,T6,T7,C4 | 4 | 沉浸式顶栏、连接中/失败/重连态、侧滑抽屉、会话切换 | 从主机列表点击到出现 shell 提示符全程无白屏、无跳变 |
| **U4b** 🔴⚠️ | **多标签与分屏容器** | U | U4 | 5 | 窗格二叉树模型（DESIGN §4.3.1）、标签栏、拖拽分隔条、焦点管理与输入路由、关闭时兄弟节点上提、断点降级时窗格树保活 | 4 窗格同时输出互不串扰；拖分隔条后**每个窗格各自**向远端发对了 `request_pty_size`（远端 `stty size` 逐一核对）；`lg→sm→lg` 往返后窗格树与会话完好 |
| U5 | 自适应布局 | U | U1,U4b | 3 | `sm/md/lg` 断点、`SideBarContainer` 三栏（主机树 / 终端 / 右侧面板）、横竖屏与折叠态 | 手机竖屏/横屏/平板/2in1 四种形态截图评审通过 |

---

### M4 — 外观系统（16 人日，R4 专项）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| A1 🔴 | AppearanceProfile 模型与仓库 | C | C1 | 2 | 实体、DAO、默认 profile、与主机的引用关系 | 删除被引用的 profile 时有保护；主机可各自绑定不同外观 |
| A2 🔴 | 内置主题预设 | U | A1 | 2 | Harmony Dark/Light、One Dark Pro、Dracula、Nord、Solarized ×2、Tokyo Night、GitHub Light | 9 套主题的 20 个色位齐全；与官方配色比对无偏差 |
| A3 🔴 | AppearancePage 与实时预览 | U | A1,T4 | 5 | 字族/字号/行高/字间距/字重/连字/bold-as-bright/光标样式与闪烁/背景透明度/内边距 + 20 色取色器 | 每一项改动在预览区 100 ms 内可见；退出不保存则完全还原 |
| A4 | 配色导入 | U | A2 | 3 | iTerm2 `.itermcolors`（plist XML）与 Windows Terminal JSON 解析器 | 各导入 5 个真实主题文件成功；非法文件有明确报错不崩溃 |
| A5 | 背景图与模糊 | U | A3,T4 | 2 | 背景图选择、模糊度、不透明度 | 开启背景图后仍满足 T4 的帧率门禁 |
| A6 | 应用整体主题 | U | X2 | 2 | 深色/浅色/跟随系统，全局生效与持久化 | 系统切换深浅色时应用即时跟随，无闪白 |

---

### M5 — 云端同步（35 人日）

> 后端策略：复用 `ssh-tool-server` 已有部署 + **独立账号**，服务端与桌面端均零改动（见 DESIGN §6.1）。
> 本里程碑全部工作都在本仓库内。

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| S1 | 同步协议规范 | S | — | 2 | `docs/SYNC-PROTOCOL.md`：文档 schema v1、字段语义、密码学参数与域字符串、升版与降级规则 | 规范中每个常量都能在 S2/S5 的代码里找到唯一出处，无第二处定义 |
| S2 🔴⚠️ | native 保险库密码学 | N/S | N3 | 5 | `cpp/crypto/`：Argon2id、AES-256-GCM、HKDF-SHA256、AAD 构造、恢复密钥编解码 | **黄金向量测试通过**：固定输入产出的密文与 `ciphertextHash` 逐字节等于登记值；向量入库后永不修改（DESIGN §9） |
| S3 🔴 | API 客户端 | S | X4,X5 | 5 | `service/sync/ApiClient.ets`：全部 `/api/v1` 端点、`If-Match`、`Idempotency-Key`、401 自动 refresh、429 退避、错误码分支 | 对着真实服务端跑通 api-v1.md 第 8 章的四个典型流程；`SYNC_DOCUMENT_NOT_FOUND` 与 `VAULT_NOT_FOUND` 正确区分 |
| S4 🔴 | 会话与设备管理 | S | S3,C2 | 3 | 注册/登录/登出/全部登出/改密/注销；device.id 持久化复用；设备列表/重命名/撤销 | 重复登录**不会**新建设备（否则 10 台配额很快耗尽）；改密后按 `reauthenticationRequired` 正确处理 |
| S5 🔴 | 序列化与三方合并 | S | S1,C1 | 5 | `SyncSerializer.ets`（稳定排序、体积上限拦截）、`SyncMerge.ets`（三方合并，借鉴桌面端 `sync-merge.ts` 的语义） | 单测覆盖 field / add-add / delete-modify 三类冲突；同一配置重复序列化字节一致 |
| S6 🔴 | 同步协调器状态机 | S | S2,S3,S5 | 6 | 相位机、触发时机（登录/前台/保存防抖/手动/网络恢复/轮询）、离线队列、乐观锁重试 | 断网改配置 → 联网自动补传；两台设备并发写入触发 409 后能自动合并重试成功 |
| S7 | 敏感同步开关与密钥轮换 | S | S6 | 3 | 「同步密码」「同步私钥」独立开关（默认关）；关闭时轮换 Vault key + 新恢复密钥 + 清空云端历史 | 关闭开关后云端历史条数为 0；旧恢复密钥失效；新恢复密钥只显示一次 |
| U6 | AccountSyncPage | U | S4,S6 | 4 | 登录注册表单、同步状态卡、设备管理、历史版本与回滚、恢复密钥展示 | 状态卡实时反映 `SyncPhase`；恢复密钥有「已抄写」二次确认 |
| U7 | 冲突解决 UI | U | S6 | 2 | 冲突列表（实体/字段/敏感标记）、保留本机 / 使用云端 | 敏感字段只显示「有变更」不显示值；解决后同步立即恢复 |

---

### M6 — SFTP 与端口转发（20 人日）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| N14 | SFTP native 层 | N | N10 | 4 | `libssh2_sftp_*` 封装：目录、stat、读写、rename、mkdir、rm、chmod、symlink | 1 GB 文件上传下载校验和一致；中断后可续传 |
| U8 | SftpPage | U | N14,U4 | 5 | 双栏/单栏文件浏览、传输队列与进度、文件选择器打通、通知栏进度 | 传输中切后台不中断；失败可重试 |
| N15 | 本地/远程/动态转发 | N/C | N10 | 4 | `direct-tcpip`、`forward_listen`、SOCKS5 握手（移植桌面端 `socks5.ts`） | 三种转发各自打通真实场景；流量与连接数统计正确 |
| U9 | PortForwardPage | U | N15,C1 | 3 | 规则增删改、启停、状态与流量展示、迷你速率曲线 | 规则随云同步；三种转发类型的表单校验各自正确 |
| N16 | ProxyJump 多级跳板 | N | N15 | 3 | `LIBSSH2_CALLBACK_SEND/RECV` 传输层重定向，支持多级串联 | 两级跳板连通；中间任一级断开时下级正确报错而非挂死 |
| U10 | 命令片段 | U | C1,U4 | 1 | 片段列表、一键发送、`${host}`/`${user}` 变量替换 | 片段随云同步；发送前有变量预览 |

---

### M7 — 打磨与发布（26 人日）

| ID | 任务 | 轨道 | 依赖 | 人日 | 交付物 | 验收标准 |
|---|---|---|---|---|---|---|
| P1 🔴 | 后台保活与网络切换 | C | C4 | 3 | `backgroundTaskManager` 长时任务、`net.connection` 监听、息屏策略设置 | 切后台 30 min 会话存活；WiFi↔蜂窝切换 5 s 内触发重连 |
| Q2 🔴 | 性能优化与基准门禁 | Q | T4,U4b,U1 | 6 | 基准脚本（`cat` 5 MB / `yes` / vim 滚动 / 100 主机列表 / **4 分屏并发输出**）、火焰图分析、CI 门禁 | 全部场景达 DESIGN §1.2 指标；4 分屏并发下仍 ≥ 50 fps；内存峰值 < 400 MB |
| Q3 🔴 | 内存与句柄泄漏治理 | Q | N11,C4 | 3 | ASan/LSan 跑通、长稳测试（8 h 连续会话） | 8 h 后 RSS 增长 < 5%；fd 数量稳定 |
| Q4 🔴 | 安全自查 | Q | C2,S2,X5 | 3 | 抓包核验、沙箱导出核验、日志脱敏核验、HAP 解包核验、依赖 CVE 扫描 | 无明文凭据落盘；同步文档在链路上为密文；日志无敏感字段；解包 HAP 无服务端密钥；依赖无高危 CVE |
| P6 ⚠️ | 同步服务 HTTPS 化 | P | — | 1 | 服务端挂域名 + Let's Encrypt；客户端 `SYNC_API_URL` 切 `https://`，删除 `app.json5` 的 `network` 节点 | 客户端全链路 HTTPS；证书链校验通过；风险 R-8 关闭 |
| P2 | 无障碍与国际化 | U | U1–U10 | 3 | 无障碍标签、动态字体、简体中文 + 英文 | 读屏可完成主流程；英文界面无截断 |
| P3 | 合规与开源许可 | P | N2 | 2 | `OPEN_SOURCE_LICENSES.md`、应用内开源许可页、隐私政策 | 覆盖 OpenSSL / libssh2 / libvterm / libargon2 / 字体的全部许可要求 |
| P4 | 应用图标、启动页、商店素材 | P | X2 | 2 | 分层图标、启动动画、商店截图与文案 | 图标在深浅色与各尺寸下清晰 |
| P5 | 签名、打包与上架 | P | P1–P4,P6,Q2–Q4 | 3 | 签名配置、release 构建、AppGallery 提审材料 | 产出可安装的 release HAP；提审自检清单全绿 |

---

## 3. 关键路径

```
X0 → X1 → N1 → N2 → N3 → N5 → N6 → N8 → N10 → N11 → T1 → T3 → T4 → T6 → U4 → U4b → Q2 → P5
                     ↘ S2 ──────────────────────────────→ S6 → U6 ↗
                        S1 → S5 ↗          S3 → S4 ↗
```

关键路径长度 **65 人日**。压缩它的唯一有效手段是把 N1/N2（原生依赖编译）提前独立开工，
以及在 N11 完成后立刻并行拆出终端轨与 UI 轨。

---

## 4. 风险登记

| # | 风险 | 影响 | 概率 | 应对 | 触发条件 |
|---|---|---|---|---|---|
| ~~R-1~~ | ~~OpenSSL 无法在 ohos target 编译~~ | — | **已关闭** | 实测 OpenSSL 3.5.7 零错误零补丁通过（DESIGN §3.7） | — |
| R-2 ⚠️ | Canvas 渲染达不到帧率（T4） | 终端体验不可接受，R4 落空 | 中 | **M0 阶段用 T0 spike 提前暴露**；兜底依次尝试：只重绘脏行 → OffscreenCanvas 分块 → `@ohos.arkui.node` 自绘节点 → NDK 侧 `native_drawing` 直接上屏 | T0 静态网格 < 55 fps，或 T4 实测 `cat` 5 MB < 40 fps |
| R-9 | `napi_create_external_arraybuffer` 在 ArkTS 运行时不可用 | T3 零拷贝方案失效 | 低 | **N3b spike 第一周就验**；兜底改为常驻 ArrayBuffer + 每帧 `memcpy` 脏行（满屏仅 30 KB，成本可忽略） | N3b 返回非 `napi_ok`，或 ArkTS 读到的字节不一致 |
| R-10 ⚠️ | 多窗格并发渲染掉帧 | 分屏在 2in1 上卡顿，首日需求达不成 | 中 | 架构上先定死「全应用单一帧调度器」（D14）；**T0 spike 直接测 4 实例**；兜底：非聚焦窗格降到 30 fps 刷新、失焦窗格只在 `revision` 变化时重绘 | T0 的 4 实例场景 < 50 fps |
| R-3 | 用户用同一账号同时登录桌面端与本应用 | 两份格式不同的文档互相覆盖，配置丢失 | 低 | 注册/登录页文案提示；本应用读到无法解析的文档时**只报错不覆盖**，绝不静默上传本地版本 | 用户反馈配置消失 |
| R-4 ⚠️ | 保险库互解不通（S2） | 同步功能整体不可用 | 中 | S2 第一天先做黄金测试向量，用最小 demo 验证，不要等整个模块写完 | 黄金测试任一向量失败 |
| R-5 | 后台保活被系统回收（P1） | 会话频繁掉线 | 中 | 优雅降级：保存会话状态，回前台自动重连并提示 | 真机实测后台 < 10 min 被杀 |
| R-6 | AppGallery 审核对 SSH 类应用的额外要求 | 上架延期 | 低 | P3 提前准备隐私政策与数据出境说明；P5 预留 2 周审核缓冲 | 提审被拒 |
| R-7 | libssh2 不支持 chacha20-poly1305 | 少数加固服务器连不上 | 低 | 保留 libssh（LGPL）作为备选后端，接口层已抽象 | 用户实际反馈连不上 |
| R-8 ⚠️ | 同步 API 走公网**明文 HTTP + 裸 IP** | 登录密码、token、key envelope 可被窃听；AppGallery 审核高概率被问 | **高** | 给服务端挂域名 + Let's Encrypt，客户端切 `https://` 并删除 `network` 节点（约半天运维）。在此之前：登录页提示、token 短时效、不做「记住密码」自动登录 | 提审前未切 HTTPS |

---

## 5. 双人并行排期建议

| 周 | 原生轨（A：C/C++ 为主） | 应用轨（B：ArkTS 为主） |
|---|---|---|
| 1–2 | **X0** N1 N2 N3 **N3b** N4 | X1 X5 X2 X4 **T0** C3 |
| 3–4 | N5 N6 N7 | C1 C2 U1 A6 |
| 5–6 | N8 N9 N10 | U2 U3 A1 A2 X3 |
| 7–8 | N11 N13 Q1 | C4 A3 A4 |
| 9–10 | T1 T2 T3 | T4 T5（B 主导，A 支持快照接口） |
| 11–12 | S2 N12 | T6 T7 T8 T9 |
| 13–14 | N14 N15 | **U4 U4b** |
| 15–16 | N16 Q3 | **T10 T11** U5 A5 |
| 17–18 | Q4（native 侧） | S1 S3 S4 |
| 19–20 | U8/U9 的 native 支撑 | S5 S6 |
| 21–22 | Q2 性能优化（native 侧） | U6 U7 S7 U10 |
| 23–24 | Q2/Q3 收尾 | U8 U9 P1 P2 |
| 25–26 | 缓冲 / 缺陷收敛 | P3 P4 P6 P5 |

双轨 26 周 × 2 人 = 260 人日产能，需求 220 人日，留约 15% 缓冲——考虑到 U4b 与 2in1 输入是新增的高不确定项，这个缓冲不宜再压缩。

若只有 1 人，按 M0→M7 顺序串行；可先发**手机版首版**（U4b/T10/T11/U5 共 13 人日 + M6 的 20 人日后置），省 33 人日。

---

## 6. 首版（v1.0）与后续版本的取舍建议

| 版本 | 包含 | 理由 |
|---|---|---|
| **v1.0** | M0–M5（含云同步、**多标签分屏、2in1 键鼠**）+ P 系列 | 「好用的终端 + 配置跟着人走」是核心价值主张；平板/2in1 形态按需求列为首日范围 |
| v1.1 | M6（SFTP、端口转发、ProxyJump） | 高价值但非首日必需 |
| v1.2 | 窗格布局预设与会话恢复、`.ssh/config` 导入、Zmodem、鸿蒙分布式流转（手机↔平板接续会话） | 差异化能力，鸿蒙特有的流转是最值得做的一个 |

---

## 7. 开工前待确认

1. ~~同步后端地址~~ ✅ 已确定：`http://123.161.179.32:46926`，本应用注册独立账号接入。
   落到 `buildProfileFields`（任务 X5），明文放行方式见 DESIGN §6.5.2。
   **遗留**：是否在上架前切 HTTPS（任务 P6 / 风险 R-8）——建议切，成本半天。
2. ~~目标设备形态~~ ✅ 已确定：**首日支持平板 / 2in1 的多标签分屏**，已纳入 v1.0 范围。
   相应新增 U4b（多标签与分屏容器）、T10（物理键盘）、T11（鼠标与终端鼠标上报），
   并上调 T4 / T6 / C4 / Q2 / T0。架构设计见 DESIGN §4.3.1 与 §4.3.2、决策 D13–D15。

---

## 8. Day 1 检查清单

按顺序做，前三项是硬阻塞——没有它们后面所有「真机验收」都无法执行。

- [ ] **X0**：华为开发者账号 → 申请 `bundleName`（建议 `com.jekaku.sshclient`）→ 生成调试证书与 Profile
      → `build-profile.json5` 填 `signingConfigs` → **空白 HAP 装进真机并启动成功**
- [ ] **X1**：`git init`（当前目录还不是 git 仓库）；按 DESIGN §8 建目录；
      `.gitignore` 必须包含 `prebuilt/`、`*.a`、`oh_modules/`、`.hvigor/`、`build/`
- [ ] **N1**：把 DESIGN §3.7 的 OpenSSL 配方脚本化，补 `x86_64` ABI
- [ ] **N3b / T0**：两个 spike 出结论，决定 T3 与 T4 走主方案还是兜底
- [ ] 保留 WSL 里的 `~/ohos-probe/ndk`（N1/N2 还要用它编 libssh2/libvterm/libargon2）；
      `~/ohos-probe/sdk.tar.gz`（2.4 GB）可以删

**先别做**：`docs/NATIVE-BUILD.md` 与 `docs/SYNC-PROTOCOL.md` 是 N1 与 S1 的交付物，
在动手写代码时顺带产出，现在不用先写。
