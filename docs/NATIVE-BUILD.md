# 原生依赖交叉编译手册（N1/N2 交付物）

> 依据：`docs/DESIGN.md` §3.4（依赖清单与版本）、§3.5（交叉编译要点）、§3.7（实测通过的配方）。
> 本文档是把该配方脚本化后的使用说明与参数解释。
> 日期：2026-08-13（OpenSSL 3.5.7 / libssh2 1.11.1 / libvterm 0.3.3 / libargon2 20190702 实测通过）

---

## 1. 环境准备

| 项 | 要求 | 本机现状 |
|---|---|---|
| 构建机 | Linux 环境（autoconf/make 需要完整 POSIX 工具链，Windows NDK 桥接不可行，见 DESIGN §3.7 注） | WSL2 `Ubuntu`，用户 home `/home/sun` |
| OHOS NDK | OpenHarmony 官方 Linux NDK（含 `llvm/bin/*-linux-ohos-clang`、`llvm-ar`、`build/cmake/ohos.toolchain.cmake`、`sysroot`） | `~/ohos-probe/ndk/native` |
| OpenSSL 源码 | 3.5.x 解压好的源码树 | `~/ohos-probe/openssl-3.5.7` |
| 系统工具 | `cmake`、`make`、`perl`、`curl`、`tar` | Ubuntu 自带 / `apt install` |
| 网络 | 下载 libssh2 / libvterm / libargon2 源码包（脚本带镜像回退；OpenSSL 用本地源码不下载） | — |

从 Windows 侧驱动的方式（本项目实际用法）：

```powershell
wsl -d Ubuntu -- bash /mnt/c/Users/lx182/DevEcoStudioProjects/ssh_client_ohos/scripts/build-openssl.sh
wsl -d Ubuntu -- bash /mnt/c/Users/lx182/DevEcoStudioProjects/ssh_client_ohos/scripts/build-deps.sh
```

## 2. 一键命令

```bash
# 在 WSL 内（两 ABI 全量，顺序无关；deps 依赖 openssl 的产物，必须先跑 N1）
bash scripts/build-openssl.sh     # N1：OpenSSL → prebuilt/<abi>/{lib,include}
bash scripts/build-deps.sh        # N2：libssh2 + libvterm + libargon2 → 同上目录，含自检

# 只构建单个 ABI：
ABIS="x86_64" bash scripts/build-openssl.sh
```

两个脚本都**幂等**：每次运行删除并重建中间构建目录（全新 Configure/解压），可任意重跑。
中间产物在 WSL home（`~/ohos-probe/build/`），**不在** Windows 挂载目录下编译——
`/mnt/c` 写文件慢且权限位有噪音，只把最终 `.a` 与头文件 cp 过去。

可调环境变量（默认值即本机约定）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `OPENSSL_SRC` | `~/ohos-probe/openssl-3.5.7` | OpenSSL 源码树 |
| `OHOS_NDK` | `~/ohos-probe/ndk/native` | NDK native 目录 |
| `ABIS` | `arm64-v8a x86_64` | 只发这两个 ABI（DESIGN D7：不发 armv7） |
| `PROJECT_ROOT` | 脚本上级目录 | 项目根（WSL 视角 `/mnt/c/...`） |
| `BUILD_ROOT` / `DOWNLOAD_DIR` | `~/ohos-probe/build/...` | 中间构建 / 源码包缓存 |
| `JOBS` | `nproc` | 并行度 |

## 3. 产物布局

```
entry/src/main/cpp/prebuilt/
├── arm64-v8a/
│   ├── lib/      libcrypto.a  libssh2.a  libvterm.a  libargon2.a
│   └── include/  openssl/*.h  libssh2.h  libssh2_sftp.h  libssh2_publickey.h
│                 vterm.h  vterm_keycodes.h  argon2.h
└── x86_64/       同上
```

> 与 DESIGN §3.5 的出入说明：§3.5 提到静态库放 `third_party/prebuilt/`、OpenSSL 放 `prebuilt/`。
> **以本手册为准**：四个库统一收在 `entry/src/main/cpp/prebuilt/<abi>/` 下——它们是同一类东西
> （预编译静态依赖），放一起 CMake 里一个变量就能指完。`third_party/` 留给将来需要随源码
> 改的第三方代码（目前为空）。
> 注意头文件**按 ABI 分开**：OpenSSL 的 `openssl/configuration.h`、BN 字长等都与架构相关，
> 不能两个 ABI 共用一份 include。
> `.a` 产物被 `.gitignore` 的 `*.a` 规则忽略，不进 git；脚本是唯一事实来源，任何人可重跑复现。

## 4. 各库参数与理由

### 4.1 OpenSSL 3.5.7（`scripts/build-openssl.sh`）

```bash
export CC=<ndk>/llvm/bin/aarch64-unknown-linux-ohos-clang   # x86_64 ABI 换 x86_64-unknown-linux-ohos-clang
export AR=<ndk>/llvm/bin/llvm-ar  RANLIB=<ndk>/llvm/bin/llvm-ranlib  STRIP=<ndk>/llvm/bin/llvm-strip

./Configure linux-aarch64 \            # x86_64 ABI 用 linux-x86_64
  no-shared no-ssl no-tests no-apps no-docs no-legacy no-engine no-dso \
  no-comp no-ssl3 no-weak-ssl-ciphers \
  --prefix=<install> -fPIC
make -j && make install_sw
```

- `linux-aarch64` / `linux-x86_64`：Configure 不认识 ohos target，用通用 Linux target +
  ohos clang 即可（§3.7 实测 0 错误 0 补丁，**不需要** `no-asm` 或 `OPENSSL_NO_SECURE_MEMORY`）。
- `no-ssl`：只要 `libcrypto.a`（§3.4）。libssh2 的 OpenSSL 后端只用 libcrypto；砍掉 libssl 省一半构建时间。
- `no-shared`：静态链接进 `libssh_core.so`，HAP 内不多个 .so。
- `no-legacy no-engine no-dso no-comp no-ssl3 no-weak-ssl-ciphers`：裁掉 legacy provider、引擎、
  动态模块加载、压缩、SSLv3，控体积（实测 `libcrypto.a` ≈ 10 MB，链入时 `--gc-sections` 只取所用）。
- `no-tests no-apps`：OHOS 沙箱跑不了也用不上 openssl 命令行。
- **`-fPIC`（相对 §3.7 配方的新增）**：§3.7 的产物链进的是可执行文件，而本项目静态库最终要链进
  共享库 `libssh_core.so`，目标文件必须位置无关，否则链接报 `relocation R_AARCH64_ADR_PREL_PG_HI21
  against ... can not be used when making a shared object`。下同，四个库全部带 `-fPIC`。
- 头文件随 `install_sw` 按 ABI 分别安装。

### 4.2 libssh2 1.11.1（`scripts/build-deps.sh`，CMake）

```bash
cmake -DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a -DOHOS_PLATFORM=OHOS \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCRYPTO_BACKEND=OpenSSL \
  -DOPENSSL_CRYPTO_LIBRARY=<prebuilt>/<abi>/lib/libcrypto.a \
  -DOPENSSL_INCLUDE_DIR=<prebuilt>/<abi>/include \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
  -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF \
  -DENABLE_ZLIB_COMPRESSION=ON
```

- 工具链文件自带 `OHOS_ARCH` 映射到对应 ohos clang 与 sysroot，无需手工设 CC。
- `CRYPTO_BACKEND=OpenSSL`。**注意不能用 `-DOPENSSL_ROOT_DIR` 指路**：
  ohos.toolchain.cmake 设了 `CMAKE_FIND_ROOT_PATH_MODE_LIBRARY/INCLUDE ONLY`，
  `find_library`/`find_path` 只在 NDK 目录内搜索，项目目录下的 prebuilt 会被"重根"而找不到
  （实测报 `Could NOT find OpenSSL ... missing: OPENSSL_CRYPTO_LIBRARY OPENSSL_INCLUDE_DIR`）。
  解法是把 FindOpenSSL 的两个结果变量 `OPENSSL_CRYPTO_LIBRARY` / `OPENSSL_INCLUDE_DIR`
  直接写进 cache——已设置的 cache 变量会让 find 变成空操作。libssh2 只链接
  `OpenSSL::Crypto`（不碰 libssl），与 OpenSSL 侧的 `no-ssl` 裁剪正好一致。
- `ENABLE_ZLIB_COMPRESSION=ON`：zlib 用 **NDK sysroot 自带**的 `libz.so`（§3.4，不自己编）。
- 源码包镜像回退：`libssh2.org` → GitHub release。

### 4.3 libvterm 0.3.3（无 CMake，直接编译打包）

上游是依赖 `libtool` 的手写 Makefile，交叉编译桥接 libtool 不值当。源码只有 9 个 `.c`，
脚本直接对每个 `src/*.c` 调交叉编译器再 `llvm-ar` 打包，最稳：

```bash
$CC -O2 -fPIC -std=c99 -Iinclude -Isrc -c src/<每个>.c
llvm-ar rcs libvterm.a *.o && llvm-ranlib libvterm.a
```

零外部依赖，不需要任何补丁。镜像回退：`leonerd.org.uk` → launchpad。

### 4.4 libargon2 20190702（上游 Makefile + 命令行注入）

```bash
make libargon2.a CC=<ohos-clang> OPTTARGET=generic \
  CFLAGS="-std=c89 -O3 -Wall -Iinclude -Isrc -pthread -fPIC"
```

- `OPTTARGET=generic`：Makefile 默认 `-march=native`，交叉 clang 不认，内置探测自动回退到
  可移植实现 `ref.c`。ARM 上 upstream 本来就只有 `ref.c`；x86_64 同样走 `ref.c`，
  保证两个 ABI 的 KDF 行为逐字节一致——保险库 KDF 的正确性/可复现性优先于这点性能差
  （DESIGN §6.2 黄金向量红线）。
- 线程：OHOS musl 有完整 pthread，保留 `-pthread`，**不设** `NO_THREADS=1`。
- 命令行传入 `CFLAGS=` 会整体覆盖 Makefile 内的 `CFLAGS +=`，因此线程/PIC/头文件路径
  都在注入值里显式写全。
- Makefile 里归档器**硬编码**为 `ar`：脚本造一个 `ar → llvm-ar` 的 shim 目录放到 `PATH`
  最前，保证用 NDK 的归档器。

## 5. 验证（脚本自检 + 手工复核）

`build-deps.sh` 结尾自动做：

1. 每个 `.a` 用 `llvm-readelf -h` 确认 `Machine:` 为 `AArch64` / `Advanced Micro Devices X86-64`；
2. **链接冒烟测试**：`ohos-clang -shared -Wl,--no-undefined smoke.c libssh2.a libcrypto.a -lz`
   链出一个 `.so`。`--no-undefined` 下链接器必须解析全部符号——能链过即证明 libssh2 对
   OpenSSL 的引用无未定义符号，缺的只剩 libc/libz（动态 NEEDED）。

手工复核命令：

```bash
N=~/ohos-probe/ndk/native
$N/llvm/bin/llvm-nm prebuilt/arm64-v8a/lib/libcrypto.a | grep -c EVP_   # 实测 2839（x86_64: 2961）
$N/llvm/bin/llvm-readelf -h prebuilt/arm64-v8a/lib/libcrypto.a | grep Machine
```

2026-08-13 实测结果：两个 ABI × 四个库全部通过；链接冒烟测试产出的 smoke.so
`NEEDED` 仅 `libc.so` 与 `libz.so`（OpenSSL 已静态链入）。

## 6. 常见问题（FAQ）

**Q：`config.sub` 报 `OS 'ohos' not recognized`？**
A：那是 autoconf 系（OpenSSH 之类走 `./configure --host=` 的项目）的问题：config.sub 版本老，
不认识 `*-linux-ohos`。解法：`--host=aarch64-linux-musl`（OHOS libc 本就是 musl 派生，语义正确）。
本手册的四个库里 **libssh2/libvterm/libargon2 不用 autoconf host 三元组，OpenSSL 用自己的
Configure target**，所以都不会踩到。此条记录给将来引入 autoconf 依赖时用（DESIGN §3.2/§3.7）。

**Q：`--without-shadow` 是什么背景？**
A：同样是 OpenSSH 移植时的事，与本手册四库无关：OHOS sysroot 的 `shadow.h` 只有 `struct spwd`
结构体，`getspnam` 等函数整套被华为删了（鸿蒙没有 `/etc/shadow`），而 OpenSSH 的 configure 看到
`HAVE_SHADOW_H` 就假定函数存在。本项目的 SSH 内核是 libssh2（客户端库），不碰影子口令。
记录它是因为这是 OHOS musl 的真实缺口，将来引入任何依赖用户数据库 API 的库都要留意。

**Q：OpenSSL 报 `files missing` / `Makefile wasn't produced`？**
A：源码树里残留了旧的 in-tree 构建配置（本机 `openssl-3.5.7/` 曾被原地构建）。脚本已自动
`make distclean` 再 out-of-source 构建；手工操作时先 `make distclean`。

**Q：为什么要 `-fPIC`？**
A：见 §4.1。静态库链进共享库时目标文件必须位置无关。缺了的典型报错是
`relocation ... can not be used when making a shared object; recompile with -fPIC`。

**Q：能不能用本机 Windows 的 DevEco NDK？**
A：不能（DESIGN §3.7 注）：configure/make 需要 POSIX 环境，Windows 编译器桥接会引入路径转换
问题，失败原因无法区分。用 WSL + Linux NDK，两者 sysroot 与 clang 版本与 Windows SDK 一致。

**Q：下载失败？**
A：三个库的下载都带主站 + 镜像回退（curl 直连）。若公司网络拦了外网，手工下载源码包放到
`~/ohos-probe/build/downloads/`（文件名照脚本里的 `libssh2-1.11.1.tar.gz` /
`libvterm-0.3.3.tar.gz` / `argon2-20190702.tar.gz`），重跑脚本即走缓存。
