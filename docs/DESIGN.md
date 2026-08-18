# HarmonyOS SSH 客户端 设计文档

> 项目：`ssh_client_ohos`
> 目标平台：HarmonyOS NEXT（compatibleSdkVersion 6.1.0 / API 23，targetSdkVersion 6.1.1 / API 24，`runtimeOS: HarmonyOS`）
> 参考项目：`E:\code\ssh-tool`（Electron 端口映射工具）——**只借鉴其功能设计与同步协议设计，本项目独立，不与其互通，不修改该仓库**
> 服务端：`G:\code\ssh-tool-server`（Nuxt 4 + MySQL，`/api/v1`）——服务端只存不透明密文、不理解内容，本项目**按原样复用，一行不改**
> 文档日期：2026-08-13

---

## 0. 一句话定位

一个 HarmonyOS 原生 SSH 终端客户端：连接核心用 C 语言原生库（libssh2 + OpenSSL + libvterm）通过 NAPI 暴露，
界面用 ArkUI 声明式开发，配置通过一套端到端加密的云同步在用户的多台设备间同步。

**与参考项目的关系：只借鉴，不互通。** `ssh-tool` 是一个成熟的、已经踩过坑的实现，
本项目从它那里拿走的是**设计经验**——功能形态、凭据安全模型、以及那套已经跑通的端到端加密同步协议
（Argon2id 派生 + AES-256-GCM + revision 乐观锁 + 幂等重试 + 三方合并）。
本项目是**独立应用、独立账号、独立同步文档**，`E:\code\ssh-tool` 不需要做任何改动。

| | `ssh-tool`（参考对象） | 本项目（新建） |
|---|---|---|
| 形态 | Windows 桌面 Electron | HarmonyOS 原生 HAP |
| 核心能力 | SSH 隧道 / 端口映射，**无终端** | **交互式终端** + SFTP + 端口转发 |
| SSH 实现 | `ssh2`（纯 Node JS） | libssh2（C）+ OpenSSL，NAPI 封装 |
| 账号/同步 | 自建 `/api/v1` + Argon2id + AES-256-GCM | **借鉴同一套协议设计**，独立账号与独立同步文档 |
| 凭据存储 | Electron safeStorage（DPAPI） | `@ohos.security.asset`（ASSET 安全存储） |

> 之所以能「独立但不用另写后端」：`ssh-tool-server` 的同步文档接口是**内容无关**的——
> 它只存 `{nonce, ciphertext, ciphertextHash}` 密文信封，`encryptedDocumentEnvelopeSchema` 允许
> `schemaVersion` 取 1–1000，服务端从不解密也从不解析里面装的是什么。
> 所以本项目用**自己的账号 + 自己的文档格式**接同一个部署即可，服务端与桌面端都无需改动（见 §6.1）。

---

## 1. 需求分析

### 1.1 需求清单与拆解

| 编号 | 原始需求 | 拆解后的可验收目标 |
|---|---|---|
| R1 | UI 美观优雅 | 遵循 HarmonyOS 设计语言；统一 Design Token；深浅色 + 跟随系统；手机/平板/2in1 断点自适应；关键操作有转场与触感反馈；空状态、加载态、错误态均有设计稿 |
| R2 | 能否用鸿蒙 SDK 编译最新 OpenSSH 及依赖 | 见 §3，**结论：能编译，但不能这样用**；给出可落地的替代内核与完整交叉编译方案 |
| R3 | 云端配置同步 | 复用 `ssh-tool` 账号/密钥库/同步文档协议；主机、分组、转发规则、片段、外观配置、known_hosts 全量同步；密码与私钥为独立开关且默认关闭；三方合并 + 冲突 UI |
| R4 | 终端界面美观，字体/字号/颜色可配置 | 字族、字号、行高、字间距、粗体处理、连字、光标样式与闪烁、背景透明度与内边距、16 色 ANSI + 前景/背景/光标/选区共 20 个颜色位全部可改；内置主题预设 + 导入 iTerm2 / Windows Terminal 配色 |
| R5 | 仔细规划分配任务 | 见 `docs/TASKS.md` |

### 1.2 非功能需求

- **性能**：`cat` 一个 5 MB 文本时终端不掉帧（≥ 50 fps），输入到回显延迟 < 一帧（16.7 ms）+ 网络 RTT。
- **续航与后台**：息屏/切后台时会话保活由 `backgroundTaskManager` 长时任务（`dataTransfer`）承担，用户可关；长时任务被系统因低速挂起/取消时走宽限降级链（§7.5），一律优雅断开并可回前台原地重连，而不是静默失联。
- **安全**：私钥与密码永不落明文盘；仅在需要时解密进入 native，用完清零；主机指纹 TOFU；同步密文服务端不可解。
- **离线可用**：不登录账号时全部本地功能可用（与桌面端一致）。
- **可测试**：SSH 协议层与终端解析层可在 x86_64 上跑单元测试，不依赖真机。

### 1.3 明确排除的范围（首个大版本不做）

- SSH 服务端 / 反向 shell
- Mosh、Telnet、串口
- 内置代码编辑器（SFTP 只做浏览、传输、重命名、权限）
- 多用户 / 团队共享配置

---

## 2. 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│  UI 层  ArkUI / ArkTS（@Component、@ObservedV2、断点自适应）     │
│  HostListPage · TerminalPage · SftpPage · AppearancePage ...  │
└────────────────────────┬─────────────────────────────────────┘
                         │ 状态订阅（@ObservedV2 / AppStorageV2）
┌────────────────────────┴─────────────────────────────────────┐
│  服务层  ArkTS（纯逻辑，可单测）                                 │
│  SessionManager   ConfigRepository   SyncCoordinator          │
│  CredentialBroker AppearanceService  KnownHostsService        │
└────────────────────────┬─────────────────────────────────────┘
                         │ NAPI（异步 + threadsafe callback + external ArrayBuffer）
┌────────────────────────┴─────────────────────────────────────┐
│  原生层  C/C++  libssh_core.so                                │
│  ssh/      libssh2 会话状态机、通道、SFTP、direct-tcpip         │
│  term/     libvterm 终端仿真 + 单元格网格 + 回滚缓冲            │
│  crypto/   Argon2id · AES-256-GCM · HKDF-SHA256（同步保险库）   │
│  io/       非阻塞 socket + epoll 事件循环（独立线程）            │
└──────────────────────────────────────────────────────────────┘
         静态链接：OpenSSL 3.5 · libssh2 1.11 · libvterm 0.3 · libargon2 · libz(系统)
```

### 2.1 线程模型

| 线程 | 职责 |
|---|---|
| ArkTS 主线程（UI） | 渲染、事件分发、Canvas 绘制。**绝不做加解密与协议解析** |
| native I/O 线程（每 SSH 会话 1 条） | socket 读写、libssh2 状态机、libvterm 喂数据、更新单元格网格 |
| native crypto 线程池 | Argon2id 派生（64 MiB / 3 轮，约 300–800 ms，必须离开主线程） |
| ArkTS TaskPool | 同步文档 JSON 序列化/合并、SFTP 目录排序等中等开销纯计算 |

跨线程回调统一用 `napi_threadsafe_function`，native → ArkTS 只投递**轻量事件**（状态变更、`dirty` 通知），
不投递终端字节流。

### 2.2 终端数据通路（性能关键路径）

这是整个项目最容易做崩的地方，单独定死：

```
socket → libssh2_channel_read → libvterm 状态机 → native 单元格网格（连续内存）
                                                        │
                    每帧一次：displaySync 回调           │  napi_create_external_arraybuffer
                                                        ▼   （零拷贝，ArkTS 直接读 native 内存）
                                    ArkTS 读脏行位图 → Canvas 只重绘脏行
```

- **不做**「每来一批字节就 emit 一个 ArkTS 事件」——高吞吐时会把主线程打爆。
- native 维护 `dirtyRowBitmap` 与 `revision` 计数；ArkTS 每帧对比 `revision`，无变化直接跳过。
- 单元格二进制布局（16 字节/格，`DataView` 直读）：

  | 偏移 | 类型 | 含义 |
  |---|---|---|
  | 0 | u32 | Unicode 码点（0 = 空；宽字符续格标记 0xFFFFFFFF） |
  | 4 | u32 | 前景色 ARGB（已解析调色板/真彩） |
  | 8 | u32 | 背景色 ARGB |
  | 12 | u16 | 属性位（bold/italic/underline/blink/reverse/strike/dim/宽字符） |
  | 14 | u16 | 保留（链接 id / 未来扩展） |

- 回滚缓冲（scrollback，默认 5000 行、上限 50000）保存在 native，ArkTS 只按需请求窗口区间。

---

## 3. 需求 2 专项调研：鸿蒙 SDK 能否编译最新 OpenSSH 及其依赖

### 3.1 已实测的环境事实

在本机 `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native` 下核对：

| 项 | 结论 |
|---|---|
| 交叉编译器 | ✅ `aarch64-unknown-linux-ohos-clang(++)`、`armv7-unknown-linux-ohos-clang(++)`、`clang.exe`（x86_64 target） |
| 链接器/归档 | ✅ `ld.lld`、`llvm-ar`、`llvm-ranlib`、`llvm-strip` |
| 构建系统 | ✅ 自带 CMake（`native/build-tools/cmake`）、`native/build/cmake` 工具链文件 |
| 调试 | ✅ `lldb` + `lldb-server` |
| sysroot libc | ✅ musl 派生，`libc.so`/`libc.a`、`libpthread.a`、`libdl.a`、`librt.a`、`libutil.a` |
| POSIX 头 | ✅ `termios.h`、`pty.h`（含 `openpty`/`forkpty` 声明）、`spawn.h`、`sys/epoll.h`、`sys/select.h`、`poll.h`、`netdb.h`、`arpa/`、`netinet/` 齐全 |
| zlib | ✅ `zlib.h` + `libz.so`（**可直接用，无需自带**） |
| **OpenSSL** | ❌ **sysroot 中不存在 `openssl/` 头目录、无 `libcrypto`/`libssl`**。存在的是 `libohcrypto.so`（CryptoArchitectureKit）、`libnet_ssl.so`、`libhuks_ndk.z.so`、`libohcert_manager.z.so`，均为 OHOS 自有 C API，**与 OpenSSL 接口不兼容**，无法直接顶替 |

### 3.2 分层结论

> 以下两条结论**不是推断，是实际编译验证过的**。完整实验记录见 §3.7。

**结论一：依赖库能编译，而且毫无阻力。** OpenSSL **3.5.7** 交叉编译到 `aarch64-linux-ohos`：
`make EXIT=0`，**0 个错误，0 个源码补丁，不需要 `no-asm` 也不需要 `OPENSSL_NO_SECURE_MEMORY`**，
产出 `libcrypto.a` 9.7 MB / `libssl.a` 1.8 MB。zlib 不用编，系统自带。

**结论二：OpenSSH 源码也能编译，而且比预想的容易得多。** OpenSSH **10.5p1**（撰写时最新版）
交叉编译到 `aarch64-linux-ohos`：`make EXIT=0`，**0 个错误，0 个源码补丁**，
`ssh`/`sshd`/`scp`/`sftp`/`ssh-keygen`/`ssh-agent` 全部产出为合法的 aarch64 OHOS PIE ELF。

代价只有**两个 configure 参数**，一个源码字符都不用改：

| 问题 | 现象 | 解法 |
|---|---|---|
| `config.sub` 不认识 `ohos` | `Invalid configuration 'aarch64-linux-ohos': OS 'ohos' not recognized` | 用 `--host=aarch64-linux-musl`（OHOS libc 本就是 musl 派生，语义正确） |
| OHOS 的 musl **阉割了影子口令** | `xcrypt.c:134: error: incompatible integer to pointer conversion`（`getspnam` 未声明，隐式返回 int） | `--without-shadow` |

第二条值得单独说：OHOS sysroot 里的 `shadow.h` **只定义了 `struct spwd` 结构体，一个函数都没声明**——
华为把 `getspnam`/`getspent`/`putspent` 整套删了，因为鸿蒙根本没有 `/etc/shadow`。
而 OpenSSH 的 configure 看到 `HAVE_SHADOW_H` 就假定 `getspnam` 存在。这是整个移植过程中**唯一**的真实冲突，
而且只影响 `sshd` 的本地口令认证，与客户端无关。

> 我原先估计需要「按 Android 移植的既有 patch 套改 bsd-* 兼容层」——**实测不需要**，
> OpenSSH 自带的 `openbsd-compat/` 已经足够覆盖 OHOS musl 的缺口。这一点我此前判断偏保守。

**结论三（决定性）：编译得再顺利，也不能拿来做产品的连接内核。** 编译成功回答的是「代码能不能被 clang 接受」，
不是「这东西能不能装进 HAP 里跑起来」。三条独立的硬伤，任意一条都足以否决：

1. **OpenSSH 不是库，是可执行程序。** 实测产物 `ssh` 是一个 **7.7 MB 的 PIE 可执行文件**，不是 `.so`。
   它没有稳定的 C API，全部能力通过 `ssh` 进程 + 命令行 + 真实 tty 暴露。
   想当库用只能把 `main()` 改名后整体链进来，而 OpenSSH 内部大量使用全局状态、`atexit`、信号处理、
   `fatal()` 直接 `_exit()`——一条会话崩掉整个应用进程，多会话并发基本没法做。
2. **HarmonyOS 应用沙箱不允许 exec 自带的 ELF 可执行文件。** 应用数据目录按 `noexec` 挂载；官方唯一认可的
   原生子进程能力是 Native Child Process API（sysroot 中的 `libchild_process.so`），它**只能加载本应用内的
   `.so` 并调用约定入口符号，不能 exec 任意二进制**。同时 AppGallery 审核明确禁止动态执行外部可执行代码。
3. **OpenSSH 客户端的运行前提在手机上不成立。** 实测 `llvm-nm -u ssh` 显示它**未定义引用了 `fork` 和 `execve`**——
   这正是 ProxyCommand、ControlMaster 和启动本地命令所需要的，而这些在 HAP 沙箱里恰恰被禁。
   此外还需要真实 tty（`tcgetattr`/`SIGWINCH`）与真实 `$HOME` + `~/.ssh` 权限模型。

> 一句话回答 R2：**能编译，而且编得很顺；但不能用。**
> 「能不能编译 OpenSSH」和「能不能拿 OpenSSH 当 HAP 的 SSH 内核」是两个问题——
> 前者实测答案是 **Yes（两个 configure 参数，零源码补丁）**，后者答案仍是 **No（沙箱与架构限制）**。
> 这个实验真正的收益不是 OpenSSH，而是**顺带证明了 OpenSSL 能干净地编到 OHOS**，
> 而 OpenSSL 正是我们真正要用的 libssh2 的依赖（原风险 R-1 就此关闭）。

### 3.3 选型：连接内核用什么

| 方案 | 许可证 | 能力 | 移植成本 | 结论 |
|---|---|---|---|---|
| **libssh2 1.11.x** | BSD-3-Clause | 会话/认证/shell/exec/SFTP/direct-tcpip/forward-listen/agent/known_hosts；ed25519、ecdsa、rsa-sha2-256/512、curve25519-sha256、aes256-gcm、ETM MAC | 低。纯 C，无内部线程，天生适配非阻塞 socket，CMake 一把过 | ✅ **采用** |
| libssh 0.11.x | **LGPL-2.1** | 比 libssh2 更全：chacha20-poly1305、SSH 证书、内建 ProxyJump | 中。LGPL 要求动态链接 + 允许替换 + 公开其源码，闭源 HAP 上架需额外合规工作 | 备选（若必须支持 chacha20-poly1305 或 SSH 证书再引入） |
| OpenSSH 源码改库 | BSD | 算法最全 | 极高，且见 §3.2 结论三 | ❌ 否决 |
| 纯 ArkTS 实现（移植 `ssh2`） | — | 无原生依赖，调试舒服 | 高：需自行实现 DH/曲线运算、密钥解析、包加解密；ArkTS 无 `Buffer`，大整数运算性能差；算法覆盖与安全性靠自己背书 | ❌ 否决（安全关键代码不自造） |

**补充说明**：libssh2 不支持 `chacha20-poly1305@openssh.com`，但支持 `aes256-gcm@openssh.com`；
现代 sshd（OpenSSH 8.0+）默认算法集里 aes-gcm 始终可用，实际兼容性风险很低。
若用户遇到只开 chacha20 的加固服务器，再走备选方案 libssh。

**ProxyJump / 跳板机怎么办**：libssh2 没有内建，但支持
`libssh2_session_callback_set(LIBSSH2_CALLBACK_SEND / _RECV)` 自定义传输回调。
在跳板会话上开 `direct-tcpip` 通道，把该通道的读写函数注册为下一级会话的传输层，即可实现任意层数 ProxyJump，
不需要本机监听端口。这是 §7.3 的设计。

### 3.4 原生依赖清单（最终）

| 库 | 版本 | 链接方式 | 来源 |
|---|---|---|---|
| OpenSSL | 3.5.x（LTS） | 静态 `libcrypto.a`（`no-ssl` 只要 crypto） | 自行交叉编译 |
| libssh2 | 1.11.x | 静态 | 自行交叉编译（CMake，`CRYPTO_BACKEND=OpenSSL`） |
| libvterm | 0.3.x | 静态 | 自行交叉编译（无外部依赖） |
| libargon2 | 20190702（phc-winner-argon2） | 静态 | 自行交叉编译；用于同步保险库 KDF |
| zlib | 系统 | 动态 `-lz` | **NDK sysroot 自带** |

> 为什么 Argon2 单独引 libargon2 而不用 OpenSSL 3.2+ 的 `EVP_KDF "ARGON2ID"`：
> OpenSSL 的实现对 `lanes > 1` 需要显式配置线程支持，参数映射也多一层坑，且不同 OpenSSL 小版本间行为有过调整。
> libargon2 是 RFC 9106 的参考实现，行为稳定、无外部依赖、跨版本可复现。
> 保险库一旦解不开就等于用户数据丢失，这一处不用图省事的方案。

### 3.5 交叉编译要点（详细脚本见 `docs/NATIVE-BUILD.md`，由任务 N1 产出）

```bash
export OHOS_NDK="/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
export SYSROOT="$OHOS_NDK/sysroot"
export CC="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"

# OpenSSL（只要 libcrypto，砍掉一切用不上的东西以控体积）
./Configure linux-aarch64 \
  no-shared no-tests no-apps no-docs no-legacy no-engine no-dso \
  no-comp no-ssl3 no-weak-ssl-ciphers \
  --prefix="$OUT/arm64-v8a" --with-zlib-include="$SYSROOT/usr/include" \
  CC="$CC" AR="$OHOS_NDK/llvm/bin/llvm-ar" RANLIB="$OHOS_NDK/llvm/bin/llvm-ranlib"

# libssh2
cmake -DCMAKE_TOOLCHAIN_FILE="$OHOS_NDK/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a -DOHOS_PLATFORM=OHOS \
  -DCRYPTO_BACKEND=OpenSSL -DOPENSSL_ROOT_DIR="$OUT/arm64-v8a" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
  -DENABLE_ZLIB_COMPRESSION=ON
```

产物按 ABI 归档到 `entry/src/main/cpp/prebuilt/{arm64-v8a,x86_64}/`（lib/ 与 include/，最终只产出一个 `libssh_core.so`，详见 `docs/NATIVE-BUILD.md`）。ABI 只发 **arm64-v8a**（真机）与 **x86_64**（模拟器/CI 单测），不发 armv7。

`entry/build-profile.json5` 接入：

```json5
"buildOption": {
  "externalNativeOptions": {
    "path": "./src/main/cpp/CMakeLists.txt",
    "arguments": "-DOHOS_STL=c++_shared",
    "cppFlags": "-std=c++17 -fvisibility=hidden -ffunction-sections -fdata-sections",
    "abiFilters": ["arm64-v8a", "x86_64"]
  }
}
```

### 3.6 风险与兜底

| 风险 | 概率 | 兜底 |
|---|---|---|
| ~~OpenSSL 在 musl/ohos target 上编译报错~~ | **已排除** | §3.7 实测：OpenSSL 3.5.7 零错误零补丁通过，无需任何降级选项 |
| libssh2 与 OpenSSL 3.5 的 provider/低层 API 弃用告警 | 低 | libssh2 1.11 已适配 OpenSSL 3.x |
| 上架审核要求提供第三方开源清单 | 高（必然） | 任务 P3 产出 `OPEN_SOURCE_LICENSES.md` 与应用内「开源许可」页 |
| 产物体积 | 中 | 实测 `libcrypto.a` 9.7 MB（静态库含全部目标文件，实际链入只取用到的部分）；配合 `-ffunction-sections -Wl,--gc-sections` 与 `no-*` 裁剪，只发两个 ABI |

---

### 3.7 实验记录：实际编译验证

**结论摘要**

| 被测对象 | 版本 | 目标 | 结果 |
|---|---|---|---|
| OpenSSL | 3.5.7 | `aarch64-linux-ohos` | ✅ `make EXIT=0`，0 错误，0 补丁 |
| OpenSSH | 10.5p1 | `aarch64-linux-ohos` | ✅ `make EXIT=0`，0 错误，0 源码补丁，2 个 configure 参数 |

**环境**：WSL2 Ubuntu + OpenHarmony 官方 Linux NDK
`native-linux-x64-6.1.0.31-Release`（取自 `ohos-sdk-windows_linux-public.tar.gz`，
与本机 DevEco Studio 的 Windows SDK 同版本），clang 15.0.4，`-target aarch64-linux-ohos -D__MUSL__`。

> 为什么用 Linux NDK 而不是本机的 Windows NDK：autoconf 的 `configure` 需要 `make` 与大量 POSIX 工具，
> 用 Windows 编译器桥接会引入路径转换问题，失败原因将无法区分是「OHOS 不兼容」还是「桥接没弄好」。
> 用原生 Linux NDK 才能得到可信结论。两套 NDK 的 sysroot 与 clang 版本一致。

**可复现步骤**

```bash
N=<ndk>/native
export CC="$N/llvm/bin/aarch64-unknown-linux-ohos-clang"
export AR="$N/llvm/bin/llvm-ar" RANLIB="$N/llvm/bin/llvm-ranlib" STRIP="$N/llvm/bin/llvm-strip"

# ---- OpenSSL 3.5.7 ----
./Configure linux-aarch64 no-shared no-tests no-apps no-docs no-legacy no-engine no-dso \
            no-comp no-ssl3 no-weak-ssl-ciphers --prefix=$OUT
make -j12 && make install_sw
# → libcrypto.a 9.7 MB, libssl.a 1.8 MB

# ---- OpenSSH 10.5p1 ----
./configure --host=aarch64-linux-musl \        # config.sub 不认 ohos
            --with-ssl-dir=$OUT \
            --without-shadow \                 # OHOS musl 无 getspnam
            --without-pam --without-selinux \
            --disable-utmp --disable-wtmp --disable-lastlog \
            --with-zlib="$N/sysroot/usr" --prefix=/data/ssh
make -j12
```

**产物核验**

```
$ file ssh
ssh: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV),
     dynamically linked, interpreter /lib/ld-musl-aarch64.so.1

$ llvm-readelf -d ssh | grep NEEDED
  NEEDED  libz.so          # 系统自带
  NEEDED  libc.so          # OpenSSL 已静态链入，无 libcrypto.so 依赖

$ llvm-nm ssh | grep -cE " [Tt] (EVP_|OPENSSL_)"
977                        # OpenSSL 符号确实在里面

$ strings ssh | grep -E "^OpenSSH_10|^OpenSSL 3"
OpenSSL 3.5.7 9 Jun 2026
OpenSSH_10.5p1

$ llvm-nm -u ssh | grep -E "fork|execve"
U execve                   # ← 这正是 HAP 沙箱里跑不起来的原因
U fork
```

产物尺寸：`ssh` 7.7 MB、`sshd` 6.7 MB、`ssh-keygen` 6.6 MB、`sftp` 616 KB、`scp` 600 KB（未 strip，含调试信息）。

**这个实验对项目的实际价值**

1. **风险 R-1（OpenSSL 编译不过）直接关闭。** 这原本是任务 N1 的最大不确定点，
   现在有了可复现的成功配置，N1 从「⚠️ 高风险 3 人日」降为「照抄配方 1 人日」。
2. **确认了 OHOS musl 的一个真实缺口**：无影子口令函数。这提示后续引入任何依赖
   `getspnam`/`getpwnam_r` 之外用户数据库 API 的库时要留意。
3. **§3.3 的选型结论不变。** OpenSSH 编译顺利不改变「它是可执行程序、沙箱禁 exec」这个架构事实，
   libssh2 仍是唯一可落地的内核选择。

---

## 4. 需求 1 与 4：视觉与交互设计

### 4.1 设计基调

**克制的深色专业工具风 + HarmonyOS 的呼吸感。** 不做花哨渐变，靠层次、留白、圆角与克制的强调色支撑质感。
从桌面端 `styles.css` 沿用色彩逻辑（深色为主、单一强调色、语义色四件套），换成 HarmonyOS 尺度。

### 4.2 Design Token（`entry/src/main/resources/base/element/color.json` + `dark/element/color.json`）

| Token | 深色 | 浅色 | 用途 |
|---|---|---|---|
| `app_bg` | `#0E131D` | `#F2F5FB` | 页面底 |
| `app_surface` | `#151C2A` | `#FFFFFF` | 卡片 |
| `app_surface_hover` | `#1E2839` | `#F5F8FF` | 按压/悬浮 |
| `app_border` | `#26314A` | `#E0E6F2` | 分隔线 |
| `app_text` | `#E8EEFB` | `#1A2233` | 主文字 |
| `app_text_dim` | `#9AA7C0` | `#5D6B85` | 次要文字 |
| `app_text_faint` | `#6B7891` | `#8A97AE` | 占位/提示 |
| `app_accent` | `#4D8DFF` | `#2F6FE4` | 强调 |
| `app_success` / `warn` / `danger` | `#34C77B` / `#F5A524` / `#F4605F` | `#16A765` / `#C9800C` / `#DC3F43` | 状态 |

尺度：圆角 `xs 8 / sm 12 / md 16 / lg 24`；间距 `4 / 8 / 12 / 16 / 24 / 32`；
字号 `caption 12 / body 14 / title 16 / headline 20 / display 28`。全部落到 `float.json`，组件里禁止写魔法数字。

### 4.3 页面结构与自适应

| 断点 | 宽度 | 布局 |
|---|---|---|
| `sm`（手机竖屏） | < 600vp | 单栏；底部 Tab（主机 / 会话 / 我的）；终端全屏沉浸，**单窗格**，会话间用横滑切换 |
| `md`（手机横屏 / 小平板） | 600–840vp | 主机列表 + 内容双栏（`SideBarContainer`）；标签栏出现，**最多 2 窗格** |
| `lg`（平板 / 2in1） | > 840vp | 左侧主机树 + 中间**多标签 + 任意分屏**终端 + 右侧可折叠面板（SFTP / 转发 / 片段） |

#### 4.3.1 多标签与分屏（首日需求，v1.0 范围内）

**模型**：一棵窗格树，和 tmux / iTerm2 同构。

```
TabSet
 └─ Tab（每个标签一棵独立的窗格树）
     └─ PaneNode
         ├─ Leaf   → 绑定一个 SSH 会话 + 一个 TerminalCanvas
         └─ Split  → { direction: 'row' | 'column', ratio: number, children: [PaneNode, PaneNode] }
```

- 分屏用二叉树递归表达，任意层级嵌套；拖动分隔条改 `ratio`
- 关闭一个 Leaf 时，其兄弟节点上提替换父 Split（保持树紧凑）
- 每个 Leaf 独立持有 native 会话句柄；**尺寸变化必须各自向远端发 `request_pty_size`**——
  这是分屏最容易漏的一点：拖分隔条要对受影响的每个窗格重算 cols/rows 并单独通知远端
- 断点降级：从 `lg` 切到 `sm`（旋转/折叠屏合起）时窗格树**不销毁**，只渲染当前聚焦的 Leaf，
  切回来原样恢复。会话不能因为转屏就断

**焦点与输入路由**：全局单一「聚焦窗格」，键盘、粘贴、片段发送只投递给它。
聚焦窗格边框用 `app_accent` 高亮；点击 / Tab 键 / `Ctrl+Alt+方向键` 切换焦点。

**⚠️ 渲染架构的关键约束：全局单一帧调度器。**
一个窗格一个 `displaySync` 回调是错的——4 个分屏就是 4 条独立帧循环，互相错拍，
在 120 Hz 设备上会打满 CPU。正确做法是**整个应用只有一个 `displaySync` 回调**，
每帧遍历「当前可见的 Leaf」列表，对各自 native `revision` 有变化的窗格才重绘。
不可见的标签页完全不绘制（但 native 侧照常收数据、照常更新网格，切回来即是最新状态）。

这条直接影响 T4 的实现方式，必须在写 `TerminalCanvas` 之前定下来。

#### 4.3.2 2in1 形态带来的额外输入需求

2in1 意味着**外接键盘与鼠标/触控板是主要输入方式**，而 §4.4 的移动端交互全是为触摸设计的。
这两块必须单独做，否则 2in1 上的终端基本不可用：

| 输入 | 需求 |
|---|---|
| 物理键盘 | 真实按键事件（`onKeyEvent`）而非 IME；完整修饰键组合（Ctrl/Alt/Shift/Meta）；Ctrl+C/Z/D、Alt+B/F、F1–F12、Home/End/PgUp/PgDn；**不弹软键盘** |
| 键盘快捷键 | 新建标签、关闭标签、切换标签、横/纵向分屏、切换焦点窗格、复制粘贴，全部可自定义 |
| 鼠标 / 触控板 | 拖拽选择文本、双击选词、三击选行、滚轮滚动回滚缓冲、右键菜单（复制/粘贴）、悬停时指针变 I-beam |
| 终端鼠标上报 | SGR 鼠标模式（`DECSET 1006`）转发给远端，让 vim / tmux / htop 能响应鼠标 |

页面清单：

```
pages/
  HostListPage.ets       主机列表：分组、搜索、状态点、滑动菜单、快速连接卡
  TerminalPage.ets       终端主界面
  HostEditPage.ets       主机编辑（连接 / 认证 / 终端 / 转发 四个分段）
  KeyManagerPage.ets     私钥管理：导入、生成、查看指纹、导出公钥
  SftpPage.ets           SFTP 文件浏览与传输
  PortForwardPage.ets    端口转发规则
  SnippetPage.ets        命令片段
  AppearancePage.ets     外观设置（实时预览）
  AccountSyncPage.ets    账号与云同步
  SettingsPage.ets       通用设置 / 关于 / 开源许可
```

### 4.4 终端界面（R4 核心）

**版面**

```
┌────────────────────────────────────────┐
│ ← host-name        ● 已连接    ⋮       │  沉浸式顶栏，滚动时自动淡出
├────────────────────────────────────────┤
│                                        │
│            Canvas 终端区                │  背景可设透明度 / 图片
│                                        │
├────────────────────────────────────────┤
│ Esc Tab Ctrl Alt ↑ ↓ ← → ⌘ / : - | ~   │  可横滑的功能键条，支持自定义
└────────────────────────────────────────┘
```

**渲染实现**

- ArkUI `Canvas` + `CanvasRenderingContext2D({ antialias: true })`
- 帧驱动用 `@ohos.graphics.displaySync` 对齐屏幕刷新率（120 Hz 设备自动跟随），
  每帧检查 native `revision`，无变化不绘制
- 只重绘脏行；整屏滚动用 `OffscreenCanvas` 位块搬移，只画新进入的那一行
- 字符宽度只在字体/字号变化时用 `measureText('W')` 测一次并缓存；宽字符占 2 格（宽度由 libvterm 判定）

**字体**

- 内置随包：**JetBrains Mono**（OFL，ASCII）+ **Sarasa Term SC**（OFL，CJK 等宽，与 JetBrains Mono 严格 1:2 对齐）
- 启动时 `font.registerFont()` 注册；可选 Nerd Font 变体供 powerlevel10k / starship 用户
- 可配置：字族、字号（8–32）、行高倍数（1.0–2.0）、字间距、字重、**连字开关**、粗体是否用亮色（bold-as-bright）

**颜色**

- 完整 20 个颜色位：ANSI 0–7、bright 8–15、前景、背景、光标、选区背景
- 内置主题：Harmony Dark（默认）、Harmony Light、One Dark Pro、Dracula、Nord、Solarized Dark/Light、Tokyo Night、GitHub Light
- 支持导入 **iTerm2 `.itermcolors`**（plist XML）与 **Windows Terminal 配色 JSON**
- 主题为独立实体，可被多个主机 profile 引用；同步到云端
- 真彩（24-bit SGR）与 256 色调色板由 libvterm 解析后直接给出 ARGB

**其他外观项**：光标样式（块/竖线/下划线）+ 闪烁开关、背景不透明度、背景图与模糊度、
终端四周内边距、滚动条显隐、URL 自动识别与下划线。

**移动端专属交互**（决定这个终端好不好用的关键）

| 交互 | 设计 |
|---|---|
| 输入法 | 隐藏 `TextInput` 承接 IME，`onChange` 取增量提交给通道；中文候选期间不发送 |
| 修饰键 | 功能键条上的 Ctrl/Alt 为「粘滞」：点一下高亮，下一个按键带该修饰，再点取消；长按锁定 |
| 选择复制 | 长按进入选择模式，双指或拖拽手柄调整范围，气泡菜单「复制 / 粘贴 / 全选 / 分享」，带放大镜 |
| 滚动 | 单指滑动 = 回滚缓冲；在 alt-screen（vim/less）下改为发送方向键或鼠标滚轮序列（可配置） |
| 缩放 | 双指捏合实时改字号，松手落库 |
| 粘贴 | 从 `@ohos.pasteboard` 读取，含换行时提示「检测到多行，是否使用括号粘贴（bracketed paste）」 |
| 触感 | 连接成功 / 断开 / 复制 / 粘滞键切换用 `@ohos.vibrator` 轻震 |
| 横竖屏 | 旋转后按新尺寸重算 cols/rows 并发 `SIGWINCH`（`libssh2_channel_request_pty_size`） |

---

## 5. 数据模型与本地存储

### 5.1 存储介质分工

| 数据 | 介质 | 理由 |
|---|---|---|
| 主机、分组、转发规则、片段、外观主题、known_hosts | `@ohos.data.relationalStore`（SQLite） | 结构化、要查询与排序 |
| 轻量偏好（主题模式、默认字号、后台策略、上次会话） | `@ohos.data.preferences` | KV 足够 |
| **密码、密钥密码短语、私钥内容、账号 token、Vault key 缓存** | `@ohos.security.asset` | OHOS 官方安全存储，等价桌面端 safeStorage；支持 `Accessibility` 与生物识别门禁 |
| 同步基线文档（base）、待发队列 | 文件 + ASSET 加密 | 与桌面端 `sync-*.json` 对应 |
| 日志 | 应用 files 目录，轮转 5 MiB × 3 | 与桌面端一致；**不记录密码/token/私钥/密文** |

### 5.2 核心实体（ArkTS 类型，`common/model/`）

```ts
interface HostProfile {
  id: string
  name: string
  host: string
  port: number
  username: string
  authType: 'password' | 'key' | 'agent'
  hostFingerprint: string      // TOFU
  keepalive: number
  groupId: string | null
  appearanceId: string | null  // 引用 AppearanceProfile
  jumpHostId: string | null    // ProxyJump
  initCommands: string[]       // 连接后自动执行
  envVars: Record<string, string>
  termType: string             // 默认 xterm-256color
}

interface AppearanceProfile {
  id: string
  name: string
  fontFamily: string
  fontSize: number             // 8–32
  lineHeight: number           // 1.0–2.0
  letterSpacing: number
  fontWeight: number
  ligatures: boolean
  boldAsBright: boolean
  cursorStyle: 'block' | 'bar' | 'underline'
  cursorBlink: boolean
  backgroundOpacity: number    // 0–1
  padding: number
  palette: string[]            // 16 个 #RRGGBB
  foreground: string
  background: string
  cursorColor: string
  selectionColor: string
}

interface Snippet { id: string; name: string; content: string; groupId: string | null }
interface KnownHostEntry { id: string; host: string; port: number; keyType: string; fingerprint: string; addedAt: string }
```

---

## 6. 需求 3：云端配置同步

### 6.1 后端策略：复用部署，独立账号

同步需要一个后端。`ssh-tool-server` 已经具备账号、设备、密钥库、同步文档、历史版本、
密钥轮换、限流、幂等和乐观锁的完整实现，且**对文档内容完全不感知**（只存密文信封）。
因此本项目**直接复用这个后端的部署，不写新后端、不改服务端代码**。

隔离方式（三选一，推荐 A）：

| | 方式 | 隔离强度 | 工作量 |
|---|---|---|---|
| **A（推荐）** | 复用同一部署，SSH 客户端用**独立账号**注册 | 账号级隔离。一个账号一份同步文档，不同账号互不可见，天然不会与桌面端冲突 | 0 |
| B | 再起一个 server 实例 + 独立数据库 | 部署级隔离 | 半天运维 |
| C | 复用同一部署，但在服务端加 `appId` 维度 | — | 需改服务端，**与「不改外部仓库」相悖，不采用** |

> 唯一需要注意的是：**不要用同一个账号同时登录桌面端和本应用**。
> 同一账号只有一份同步文档，两个格式不同的客户端会互相覆盖。
> 这一点在 `AccountSyncPage` 的注册/登录页做文案提示即可，不需要任何代码层面的跨仓库协调。

按 `E:\code\ssh-tool\docs\api-v1.md` 实现客户端。需要在 HarmonyOS 侧完整实现：

- 注册 / 登录 / 刷新 / 登出 / 全部登出 / 改密 / 注销账号
- 设备列表 / 重命名 / 撤销（**注意：每次 login 都会新建 device，配额 10，必须本地持久化 `device.id` 并优先复用已有 session**）
- Vault 创建 / 获取信封 / 重包装 / 轮换 / 删除
- 同步文档 `HEAD` / `GET` / `PUT`（`If-Match: "revision-N"` + `Idempotency-Key`）
- 历史版本列表 / 清空 / 回滚
- 401 `AUTH_TOKEN_EXPIRED` 自动 refresh 重放；`AUTH_TOKEN_REUSED` 清本地并强制重登
- 429 按 `Retry-After` 退避；离线队列与幂等重试

### 6.2 密码学参数（借鉴桌面端方案，使用本项目自己的域字符串）

算法与结构照搬桌面端已验证的设计，但**所有域分隔字符串换成本项目自己的**——
两个应用的保险库本来就不该能互相解开，域分离是密码学卫生，不是可选项。

| 项 | 值 |
|---|---|
| KDF | Argon2id（libargon2，RFC 9106），默认 `memory=65536 KiB, iterations=3, parallelism=1, hashLength=32` |
| 文档加密 | AES-256-GCM，nonce 12B，tag 16B 拼在密文尾部 |
| 文档 AAD | `"ssh-port-mapper/sync-document/v1" + "|" + len:vaultId + "|" + len:schemaVersion + "|" + len:keyVersion` |
| 密码包裹 AAD | `"ssh-port-mapper/vault-key/password/v1" + "|" + len:keyVersion` |
| 恢复包裹 AAD | `"ssh-port-mapper/vault-key/recovery/v1" + "|" + len:keyVersion` |
| 恢复 KEK 派生 | HKDF-SHA256，salt 空，info `"ssh-port-mapper/recovery-kek/v1"`，32B |
| 恢复密钥格式 | `SPM1-<base64url 43 字符>-<sha256("SPM1"+raw) 前 12 位十六进制大写>` |
| `ciphertextHash` | 密文（含 tag）原始字节的 sha256 小写十六进制 |

> AAD 字段编码规则（沿用 `crypto-vault.ts` 的 `aad()` 思路）：每个字段编码为 `<utf8字节长度>:<值>`，
> 字段间用 `|` 连接，整体前缀 `<domain>|`。长度前缀是为了防止字段边界歧义，不能省。

**唯一的外部兼容约束**是 `vaultKeyEnvelopeSchema` 与 `encryptedDocumentEnvelopeSchema`——
这两个结构服务端要校验（base64 长度范围、`algorithm: "AES-256-GCM"` 字面量、
`ciphertextHash` 必须是 64 位小写十六进制、Argon2 参数取值区间）。信封**外壳**必须符合，
信封**内容**完全自由。

实现位置：**全部放 native（`crypto/` 目录，OpenSSL + libargon2）**，不用 `@ohos.security.cryptoFramework`。
理由是 native 已经链了 OpenSSL，且 Argon2id（64 MiB / 3 轮）必须离开 UI 线程。

### 6.3 同步文档 schema

本项目的文档格式由自己定义，`schemaVersion` 从 1 起算，按 SSH 客户端的实际需要来设计，
不受任何外部 schema 约束：

```jsonc
{
  "schemaVersion": 1,
  "updatedAt": "2026-08-13T...",
  "preferences": { "syncPasswords": false, "syncPrivateKeys": false },
  "hosts":      [ /* HostProfile + 可选 secrets（密码/短语/私钥） */ ],
  "groups":     [ /* HostGroup */ ],
  "appearance": [ /* AppearanceProfile：字体、字号、20 色调色板等 */ ],
  "snippets":   [ /* Snippet */ ],
  "forwards":   [ /* PortForwardRule */ ],
  "knownHosts": [ /* KnownHostEntry */ ]
}
```

设计约定：

- 所有数组按 `id` 字典序排序后再序列化，保证同样的配置产出同样的字节（利于 `ciphertextHash` 与去重判断）
- 每个实体都有稳定 `id`（UUID v4），改名不改 id，这是三方合并的前提
- 服务端限制单份文档 **2 MiB**：私钥单条上限 256 KiB，主机数上限 5000，超限在客户端提前拦截并提示
- 未来加字段直接升 `schemaVersion`，老版本客户端读到更高版本时**只读不写**并提示升级（避免降级覆盖）

### 6.4 同步状态机

沿用桌面端设计（`SyncPhase`）：

```
signed_out → disabled → locked → idle ⇄ syncing → synced
                                   ↓        ↓
                                offline   conflict / error / auth_error
```

触发时机：登录后、应用切前台、保存配置后防抖 3 s、手动下拉、网络恢复（`@ohos.net.connection` 监听）、
定时轮询（默认 15 min，可关）。

冲突处理沿用三方合并（base / local / remote），冲突项弹 `SyncConflictDialog`：
逐条展示「实体 / 字段 / 敏感与否」，提供「保留本机 / 使用云端」，敏感字段（密码、私钥）值不显示只显示「有变更」。

### 6.5 客户端构建配置与明文传输（**上线前必须处理**）

**后端地址（已确定）**

```
生产 / 开发：http://123.161.179.32:46926
客户端自动追加 /api/v1  →  http://123.161.179.32:46926/api/v1
```

#### 6.5.1 鸿蒙没有 `.env`，用 `buildProfileFields`

桌面端靠 `.env` + electron-vite 在构建期把公开配置写进主进程 bundle。
HarmonyOS 的等价机制是 hvigor 的 `buildProfileFields`——在 `entry/build-profile.json5` 里声明，
构建时生成 `BuildProfile.ets`，代码里 `import BuildProfile from 'BuildProfile'` 直接读：

```json5
// entry/build-profile.json5
"buildOptionSet": [
  {
    "name": "debug",
    "arkOptions": {
      "buildProfileFields": {
        "SYNC_API_URL": "http://123.161.179.32:46926",
        "LOG_LEVEL": "debug",
        "LOG_TO_FILE": true,
        "LOG_MAX_BYTES": 5242880,
        "LOG_MAX_FILES": 3
      }
    }
  },
  {
    "name": "release",
    "arkOptions": {
      "buildProfileFields": {
        "SYNC_API_URL": "http://123.161.179.32:46926",
        "LOG_LEVEL": "info",
        "LOG_TO_FILE": true,
        "LOG_MAX_BYTES": 5242880,
        "LOG_MAX_FILES": 3
      }
    }
  }
]
```

与桌面端一致的纪律：**只有这几个非敏感项能进客户端包**。
数据库口令、JWT 密钥、MFA 配置这类服务端变量绝不能出现在 HAP 里——HAP 是可解包的 zip，
`buildProfileFields` 的值在产物里就是明文常量。

日志行为对齐桌面端：输出到控制台 + 应用 files 目录，5 MiB 轮转保留 3 个文件，
**只记录启动、同步状态、会话状态，不记录密码、token、私钥、请求体、同步密文**。

#### 6.5.2 ⚠️ HarmonyOS 默认禁止明文 HTTP，必须显式声明

这是桌面端不存在、鸿蒙特有的一道坎。**机制更正（X5 实施时实测修正）**：
最初核实的 `app.json5` 的 `app.network` 节点在本机 hvigor 6.1.1（SDK 6.1.1 / API 24）的构建期 schema
（`toolchains/modulecheck/app.json`）中并不存在，写入会在 PreBuild 阶段直接报 Schema 校验错误；
`configcheck/configSchema_rich.json` 里的 `network` 实际挂在 FA 模型遗留的 `deviceConfig` 下，与 Stage 模型无关。
本项目目标平台（API 23/24）的正确机制是 **API 20+ 引入的 `network_config.json`**
（见官方《使用HTTP访问网络》「明文HTTP访问权限配置说明」，优先级：component-config > domain-config > base-config）。

**不要用 `base-config.cleartextTrafficPermitted: true` 全局放开**——那等于给整个应用开明文，包括将来任何第三方 SDK。
用 `domain-config` 只对这一个地址开口子：

```json
// entry/src/main/resources/base/profile/network_config.json（固定路径，自动生效，无需在 module.json5 引用）
{
  "network-security-config": {
    "base-config": {
      "cleartextTrafficPermitted": false
    },
    "domain-config": [
      {
        "domains": [
          { "include-subdomains": false, "name": "123.161.179.32" }
        ],
        "cleartextTrafficPermitted": true
      }
    ]
  }
}
```

> 注意：SSH 连接本身走 `@ohos.net.socket` 的原始 TCP，**不受这个配置约束**（它管的是 HTTP 栈）。
> 这里放开的只是同步 API 那一条 HTTP 通道。

#### 6.5.3 明文 HTTP 的实际风险边界

端到端加密保护的是**同步文档的内容**，不保护**传输通道本身**。走公网明文 HTTP 时：

| 项 | 是否被 E2EE 保护 | 明文 HTTP 下的暴露情况 |
|---|---|---|
| 主机、密码、私钥等文档内容 | ✅ AES-256-GCM，服务端也解不开 | 中间人看到的是密文，**安全** |
| **登录邮箱与密码** | ❌ 明文 JSON body | **可被完整窃听** |
| **accessToken / refreshToken** | ❌ | **可被窃取并冒用账号** |
| **Vault key envelope**（`GET /vault/key-envelope`） | 被同步密码包裹 | 信封本身泄露；攻击者可离线暴力破解同步密码（Argon2id 64 MiB/3 轮，弱密码有风险） |
| 请求可被篡改 | ❌ | 可注入伪造响应，诱导客户端进入错误状态 |

`api-v1.md` 原文也写了这一点：可信局域网或本机可以直接用 HTTP，**公网仍建议 HTTPS**。
而 `123.161.179.32:46926` 是公网 IP。

**建议（不阻塞开发，但建议在 v1.0 上架前解决）**：给服务端挂一个域名 + Let's Encrypt 证书，
客户端切到 `https://`，然后把 `network` 节点整个删掉。成本约半天运维，收益是消除上面整张表的风险。

**额外的现实约束**：AppGallery 审核对「明文 HTTP + 裸 IP + 账号登录」这个组合是高概率会问的，
需要在 P5 的提审材料里准备说明，或者干脆在提审前切 HTTPS 一次性绕开。这一点已登记为风险 R-8。

### 6.6 同步与不同步的边界

| 同步 | 不同步（设备本地） |
|---|---|
| 主机、分组、转发规则、片段 | 当前打开的会话与标签 |
| 外观主题与字体配置 | 字体文件本身（随包） |
| known_hosts 指纹 | 后台保活策略、触感开关 |
| 密码 / 密码短语（**独立开关，默认关**） | 屏幕方向锁定、功能键条布局 |
| 私钥内容（**独立开关，默认关**） | 日志、账号 token、设备 id |

关闭敏感同步时，与桌面端行为一致：**轮换 Vault key + 生成新恢复密钥 + 原子清除云端历史**。

---

## 7. 功能设计细节

### 7.1 连接与认证

- 认证方式：密码、公钥（OpenSSH / PEM，支持带密码短语）、keyboard-interactive（含 2FA 验证码输入）、agent（HarmonyOS 无系统 agent，做**应用内 agent**：解锁后在内存持有密钥，供多会话与转发复用）
- 主机指纹 TOFU：首连展示 `SHA256:xxx` 与指纹随机艺术图（randomart），用户确认后入库；不匹配时**拒绝连接**并给出对比视图
- 连接超时、认证失败、算法协商失败等错误全部映射成中文可读提示（照搬桌面端的错误文案思路）
- 自动重连：退避 1→2→5→10→20→30 s（上限可配），界面显示倒计时与尝试次数
- Keepalive：`libssh2_keepalive_config`，默认 30 s；连续 3 个周期无入站活动判静默黑洞。
  另有主动探测 `probeNow()`：网络切换时强发一拍并只开 5 s 判定窗口（§7.5），不必干等 90 s

### 7.2 终端会话

- 多会话并存，每会话一条 native I/O 线程；平板/2in1 支持多标签与分屏
- `xterm-256color`，真彩支持
- 断线后终端内容保留并置灰，支持「重连并恢复」（重连是新 shell，历史输出保留在回滚缓冲里）
- 命令片段：一键发送，支持 `${host}` `${user}` 变量替换
- 输出搜索（回滚缓冲内正则/纯文本查找，高亮跳转）

### 7.3 端口转发与跳板

- 本地转发（`-L`）：ArkTS 侧用 `@ohos.net.socket` 的 `TCPSocketServer` 监听，收到连接后交给 native 开 `direct-tcpip` 通道
- 远程转发（`-R`）：`libssh2_channel_forward_listen_ex`
- 动态转发（`-D`，SOCKS5）：ArkTS 实现 SOCKS5 握手（可直接移植桌面端 `socks5.ts` 逻辑），后端接 `direct-tcpip`
- **ProxyJump**：见 §3.3，用 `LIBSSH2_CALLBACK_SEND/RECV` 把上级通道当作下级会话的传输层，支持多级串联

### 7.4 SFTP

- `libssh2_sftp_*`；目录浏览、上传下载（带进度与断点续传）、新建/重命名/删除、chmod、软链接识别
- 与 HarmonyOS 文件选择器（`@ohos.file.picker`）打通
- 大文件传输走长时任务，通知栏显示进度

### 7.5 后台保活

实现落在 `service/background/`（策略机 `BackgroundPolicy` 纯逻辑 + 外壳 `BackgroundKeepAlive`
接系统 API），会话侧口子在 `SessionManager`（`activeSessionCount` / `setQuiet` /
`notifyNetworkChanged` / `suspendAllForPolicy` / `resumeAllSuspended`）。

**长时任务不是「申请到就一劳永逸」**：SDK 明确有
`ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED` 与
`ContinuousTaskSuspendReason.SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED`——`dataTransfer`
长时任务在低速时会被系统挂起甚至取消，而空闲 SSH 会话恰恰就是低速。因此保活是一条**降级链**：

| 阶段 | 行为 |
|---|---|
| 切后台且有活跃会话 | 申请 `dataTransfer` 长时任务（`ohos.permission.KEEP_BACKGROUND_RUNNING` + ability 的 `backgroundModes`），同时进入静默模式（抑制 dirty 唤醒，事件照收、数据不丢） |
| 被系统挂起（低速） | **不断连接**，等 `continuousTaskActive` 回来 |
| 被取消 / 申请失败 | 用短时任务 `requestSuspendDelay` 换一个宽限窗口（≤ 8 s） |
| 宽限到期 | **优雅断开**：只断连接，保留会话面孔与窗格绑定，`SessionInfo.errorMessage` 写明原因与出路 |
| 回前台 | 释放长时任务、解除静默、原地重连被挂起的会话（sessionId 不变、句柄换新）；没挂起过则做一次切网收敛 |
| 后台会话数归零 | 立刻释放长时任务（不白占资源） |

- 设置项：「后台保持连接」（默认开）/「息屏 N 分钟后断开」（默认关）。前者关掉即走上表的宽限窗口；
  后者到期同样是策略性断开而非静默失联
- 系统回收前：模块级 `AbilityStage.onMemoryLevel` 收到 `CRITICAL` 即优雅断开（UIAbility 没有这个回调）
- 网络切换（WiFi ⇄ 蜂窝）：`NetworkWatcher` 监听默认网，以 **netId 或承载类型变化**为判据
  （同一张网的 capability 抖动不算）。切网后**主动收敛**而不是干等超时——退避倒计时中的会话
  立刻重连；`established` 的会话调 native `probeNow()` 强发一拍 keepalive 并开 5 s 短判定窗口，
  窗口内无入站即判黑洞进 `disconnected`，走既有重连链（周期 keepalive 是 30 s × 3 = 90 s，切网场景太慢）

### 7.6 权限清单（`module.json5`）

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | SSH（原始 TCP）/ 同步 API（HTTP） |
| `ohos.permission.GET_NETWORK_INFO` | 网络切换感知 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 后台保活 |
| `ohos.permission.VIBRATE` | 触感反馈 |
| `ohos.permission.STORE_PERSISTENT_DATA`（如需） | SFTP 落盘 |

---

## 8. 目录结构

```
ssh_client_ohos/
├── docs/
│   ├── DESIGN.md              本文档
│   ├── TASKS.md               任务规划
│   ├── NATIVE-BUILD.md        原生依赖交叉编译手册（任务 N1 产出）
│   └── SYNC-PROTOCOL.md       同步文档格式与密码学参数规范（任务 S1 产出）
├── entry/src/main/
│   ├── cpp/
│   │   ├── CMakeLists.txt
│   │   ├── napi_init.cpp
│   │   ├── bridge/            NAPI 绑定、threadsafe function、external ArrayBuffer
│   │   ├── ssh/               会话、认证、通道、SFTP、转发
│   │   ├── term/              libvterm 封装、单元格网格、回滚缓冲、脏行位图
│   │   ├── crypto/            Argon2id / AES-GCM / HKDF / 恢复密钥
│   │   ├── io/                非阻塞 socket + epoll 事件循环
│   │   ├── third_party/       libssh2 / libvterm / libargon2 源码
│   │   └── prebuilt/          OpenSSL 静态库（按 ABI）
│   ├── ets/
│   │   ├── entryability/
│   │   ├── pages/             见 §4.3
│   │   ├── view/              可复用组件（TerminalCanvas、HostCard、KeyPad…）
│   │   ├── viewmodel/         页面状态（@ObservedV2）
│   │   ├── service/           SessionManager / SyncCoordinator / CredentialBroker…
│   │   ├── repository/        relationalStore / preferences / asset 封装
│   │   ├── napi/              libssh_core.d.ts 与薄封装
│   │   ├── common/            model、constants、utils、错误映射
│   │   └── theme/             Design Token 与主题预设
│   └── resources/
│       ├── base/element/      color.json / float.json / string.json
│       ├── dark/element/
│       └── rawfile/font/      JetBrainsMono、SarasaTermSC
└── entry/src/ohosTest/        真机/模拟器集成测试
```

---

## 9. 测试策略

| 层 | 手段 |
|---|---|
| native 单元测试 | GoogleTest，编到 x86_64-linux-ohos 或宿主机 clang；覆盖 VT 解析、单元格网格、AAD 构造、Argon2/AES 向量 |
| **保险库黄金向量测试** | 固定 `(同步密码, salt, KDF 参数, 明文, nonce)` → 断言产出的密文与 `ciphertextHash` 逐字节等于登记的期望值。向量一旦入库**永不修改**，它保证任何一次重构都不会让老用户的保险库解不开。**这是同步功能的验收红线** |
| 恢复密钥往返测试 | 随机生成 10000 个恢复密钥，校验和格式、编解码往返、篡改任一字符必须被拒 |
| SSH 协议集成测试 | CI 起一个真实 `sshd`（docker），x86_64 模拟器跑通连接/认证/shell/SFTP/转发 |
| ArkTS 单元测试 | `@ohos.hypium`；覆盖三方合并、状态机、配置仓库、错误映射 |
| UI 测试 | `ohosTest` + UiTest；覆盖主流程（新建主机 → 连接 → 输入 → 断开） |
| 性能基准 | `cat` 5 MB 文件、`yes` 持续输出、vim 滚动；采集帧率与内存，纳入 CI 门禁 |
| 安全自查 | 抓包确认无明文凭据；`hdc file recv` 导出沙箱确认无明文私钥；日志脱敏检查 |

---

## 10. 关键决策一览

| # | 决策 | 结论 | 理由 |
|---|---|---|---|
| D1 | SSH 内核 | **libssh2 1.11 + OpenSSL 3.5** | OpenSSH 不是库且沙箱禁 exec（§3.2）；libssh2 BSD 许可、纯 C、非阻塞友好 |
| D2 | 终端仿真器 | **libvterm（native）** | 完整 VT220/xterm、真彩、宽字符、alt-screen；自己写至少多花 4 周还不一定对 |
| D3 | 终端渲染 | Canvas + external ArrayBuffer 零拷贝 + 脏行重绘 + displaySync | 唯一能在高吞吐下不掉帧的方案 |
| D4 | 同步保险库密码学位置 | native（OpenSSL + libargon2） | Argon2id 必须离开 UI 线程；native 已链 OpenSSL，不再多引一套加密实现 |
| D5 | 同步后端 | **复用 `ssh-tool-server` 部署 + 独立账号**，服务端与桌面端均零改动 | 该后端对文档内容不感知，只存密文信封；账号级隔离已足够（§6.1） |
| D9 | 同步文档格式 | 自定义 v1，按 SSH 客户端需要设计 | 本项目独立，不与桌面端互通，无需迁就其 schema |
| D10 | 客户端构建期配置 | hvigor `buildProfileFields` → `import BuildProfile from 'BuildProfile'` | 鸿蒙没有 `.env`；这是官方等价机制。只放非敏感项，HAP 可解包（§6.5.1） |
| D11 | 明文 HTTP 放行方式 | `app.network.securityConfig.domainSettings` **只对同步服务器这一个地址**放行，不用全局 `cleartextTraffic: true` | 全局放开等于给所有第三方 SDK 开明文口子（§6.5.2） |
| D12 | 传输层安全 | 开发期接受 HTTP，**上架前建议切 HTTPS** | E2EE 保护文档内容，但不保护登录密码与 token；公网明文可被完整窃听（§6.5.3） |
| D13 | 多标签分屏 | **首日支持**（v1.0）。窗格用二叉树表达，断点降级时窗格树不销毁 | 平板 / 2in1 是首日目标形态（§4.3.1） |
| D14 | 帧调度 | **全应用单一 `displaySync` 回调**，每帧遍历可见 Leaf 按 `revision` 决定是否重绘 | 每窗格一条帧循环会互相错拍并打满 CPU；这条约束 T4 的写法（§4.3.1） |
| D15 | 2in1 输入 | 物理键盘走 `onKeyEvent`（不弹软键盘），独立于移动端 IME 路径；鼠标含 SGR 鼠标上报 | 触摸交互无法覆盖 2in1 的主要输入方式（§4.3.2） |
| D6 | 凭据存储 | `@ohos.security.asset` | OHOS 官方安全存储，对位桌面端 safeStorage |
| D7 | 发布 ABI | arm64-v8a + x86_64 | 真机 + 模拟器/CI；不发 armv7 省体积 |
| D8 | Argon2 实现 | libargon2 而非 OpenSSL EVP_KDF | 与 `hash-wasm` 同为 RFC 9106 参考实现，互解风险最小 |
