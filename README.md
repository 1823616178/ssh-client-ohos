# HarmonyOS NEXT 原生 SSH 终端客户端 (ssh-client-ohos)

<p align="center">
  <img src="AppScope/resources/base/media/foreground.png" width="128" height="128" alt="Logo" />
</p>

<p align="center">
  <strong>专为 HarmonyOS NEXT 打造的高性能、端到端加密、原生 SSH 终端客户端</strong>
</p>

<p align="center">
  <a href="#-核心特性">核心特性</a> •
  <a href="#-系统架构">系统架构</a> •
  <a href="#-模块结构">模块结构</a> •
  <a href="#-构建与运行">构建与运行</a> •
  <a href="#-安全与隐私">安全与隐私</a> •
  <a href="#-开源协议">开源协议</a>
</p>

---

## 📖 项目简介

`ssh-client-ohos` 是一款面向 **HarmonyOS NEXT**（API 12+）的原生 SSH 终端与远程管理客户端。

项目采用 **ArkTS / ArkUI 声明式界面** 结合 **C/C++ 原生内核**（libssh2 + OpenSSL + libvterm + libargon2，静态链接编译为 `libssh_core.so`），通过高效的 **NAPI 异步桥接** 提供媲美桌面级终端的流畅体验与极低延迟。同时，支持多设备端到端加密云端配置同步。

---

## ✨ 核心特性

- 🖥️ **高性能交互式终端**
  - 基于 C 原生库 `libvterm` 的状态机解析与单元格网格管理。
  - 单一帧调度器（FrameSchedulerCore）驱动脏行局部刷新，高吞吐（如 `cat` 大文件）保持稳定高帧率（≥ 50 fps）且静止时 CPU 占用趋近于 0。
  - 支持 24-bit TrueColor 与 16 色 ANSI 标准色域。
  - 内置精选等宽字体（JetBrains Mono、更纱黑体 Sarasa Term SC），支持自适应字号、行高与字间距调节。
  - 完整的软硬键盘支持：底部常用控制键栏（KeyBar）、物理键盘全套修饰键与快捷键、IME 输入法缓冲拦截与批量退格适配。
  - 便捷的手势与文本交互：长按定点选区、滑动扩展、双击选词、单击 URL 识别、平滑惯性滚动。

- 📁 **SFTP 文件管理器**
  - 图形化远程文件浏览与管理（路径切换、排序、新建、重命名、权限修改、删除）。
  - 后台传输队列（TransferQueue），支持断点续传、大文件异步上传/下载与状态监控。

- 🔀 **端口转发与网络代理**
  - 本地端口转发（Local Forward）：将远端服务映射至本机。
  - 远程端口转发（Remote Forward）：将本机端口暴露至远端主机。
  - 动态转发（Dynamic SOCKS5）：一键建立本地 SOCKS5 代理隧道。
  - 多跳跳板机（ProxyJump）链式连接支持。

- 🔐 **企业级凭据安全**
  - 深度集成 HarmonyOS `@ohos.security.asset`（ASSET 关键资产存储），密码、私钥与 Passphrase 经硬件级安全芯片隔离保护，绝不落地明文盘。
  - 支持密码、公私钥对（Ed25519 / RSA）、SSH-Agent 认证。
  - 主机指纹 TOFU（Trust On First Use）模型校验，直观展示 SHA256 指纹与 OpenSSH randomart 图形化校验码。

- ☁️ **端到端加密配置云同步**
  - 主机列表、分组、端口转发规则、脚本片段与外观配置跨设备双向同步。
  - 零知识证明加密架构（Zero-Knowledge）：基于 Argon2id 密钥派生 + AES-256-GCM 本地加密信封，远端服务器仅存储不可读密文。
  - 支持离线队列、乐观锁（revision）版本控制与三方智能合并。

- 🎨 **自由外观与多端自适应**
  - 内置多种主流配色预设（Default Dark/Light, One Dark, Solarized, Dracula, Nord 等），支持导入 iTerm2 / Windows Terminal 配色方案。
  - 手机、折叠屏、平板、2in1 桌面多形态断点自适应（AdaptiveLayout），平板与折叠屏展开态支持侧边栏折叠与分屏会话协同。

- 🔋 **后台保活与网络恢复**
  - 集成 `backgroundTaskManager` 申请 `dataTransfer` 长时任务，息屏与切后台保持会话不掉线。
  - Wi-Fi ⇄ 蜂窝移动网络热切换自动探活与透明重连机制。

---

## 🏗️ 系统架构

```
┌──────────────────────────────────────────────────────────────────┐
│              ArkUI 声明式层（ArkTS / @ObservedV2）               │
│  HostListPage · TerminalPage · SftpPage · PortForwardPage ...    │
├──────────────────────────────────────────────────────────────────┤
│           ViewModel 与业务调度层 (SessionManager / Sync)          │
│  TerminalViewModel · HostEditViewModel · SftpViewModel ...      │
├──────────────────────────────────────────────────────────────────┤
│                   NAPI 桥接层 (C++ Bridge)                       │
│  session_bridge · terminal_bridge · sftp_bridge · forward_bridge │
├──────────────────────────────────────────────────────────────────┤
│                    原生核心库 (libssh_core.so)                   │
│  ├── libssh2   : SSH-2 协议、会话握手、信道多路复用              │
│  ├── OpenSSL   : 加密套件、密钥交换、Ed25519 / RSA / AES-GCM     │
│  ├── libvterm  : 终端控制序列解析、VT100/Xterm 仿真与字符网格     │
│  └── libargon2 : 密码哈希派生、端到端加密密钥生成                │
└──────────────────────────────────────────────────────────────────┘
```

---

## 📂 模块结构

```text
├── AppScope/                      # 全局应用配置与图标资源
├── entry/
│   ├── src/main/cpp/              # C/C++ 原生核心与 NAPI 桥接
│   │   ├── bridge/                # NAPI 接口绑定与线程安全函数
│   │   ├── crypto/                # 本地保险库与 Argon2id / AES-GCM 加密实现
│   │   ├── ssh/                   # libssh2 封装（会话、认证、SFTP、转发）
│   │   ├── term/                  # libvterm 终端模拟封装与单元格位图
│   │   └── tests/                 # 原生宿主单元测试套件
│   ├── src/main/ets/              # ArkTS 应用源码
│   │   ├── common/                # 通用常量、国际化、Token 与工具类
│   │   ├── napi/                  # NAPI 声明与 TS 封装接口
│   │   ├── pages/                 # 主机列表、终端、SFTP、端口转发、设置等页面
│   │   ├── repository/            # RelationalStore 与 ASSET 存储层
│   │   ├── service/               # 会话管理、后台保活、同步引擎
│   │   ├── theme/                 # 主题样式与色彩 Token
│   │   ├── view/                  # 可复用组件（TerminalCanvas、KeyBar 等）
│   │   └── viewmodel/             # 视图模型（状态驱动）
│   ├── src/main/resources/        # 多语言字符串、字体与色彩配置
│   └── src/test/                  # ArkTS 单元测试用例
├── docs/                          # 设计规范、任务规划与协议文档
└── scripts/                       # 自动化测试、CI 门禁与环境脚本
```

---

## 🛠️ 构建与运行

### 1. 环境依赖
- **DevEco Studio**：5.0+ (Release)
- **HarmonyOS SDK**：API 12+ / compatibleSdkVersion 6.1.0 (API 23+)
- **CMake**：3.10.2+
- **Node.js**：18.x+ / 20.x+
- **hvigor**：配套 DevEco Studio 构建工具

### 2. 构建工程
可以使用 DevEco Studio 直接打开工程进行同步与构建，或通过命令行：

```bash
# 1. 安装依赖包
ohpm install

# 2. 构建 HAP 包
hvigorw assembleHap --mode module -p product=default
```

### 3. 运行测试套件
```bash
# 运行 ArkTS 单元测试
hvigorw test
```

---

## 🔒 安全与隐私

1. **零明文留存**：连接密码与私钥口令仅存于内存中的受控安全擦除区（`OPENSSL_cleanse`），使用完毕即刻清理；
2. **硬件级凭据保险**：借助 HarmonyOS ASSET 机制，私钥数据受系统级设备锁屏凭据防护；
3. **日志脱敏保证**：控制台与持久化日志已严格实施参数脱敏，严禁打印私钥、明文密码与网络传输密文；
4. **端到端加密**：同步服务只作为密文管道转发，即便服务器数据受损也不会泄漏配置内容。

---

## 📄 开源协议

本项目依照 [MIT License](LICENSE) 授权许可开源。  
项目使用的第三方开源组件与相关授权声明详见 [OPEN_SOURCE_LICENSES.md](OPEN_SOURCE_LICENSES.md)。
