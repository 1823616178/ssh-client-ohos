# QUALITY-GATES.md —— Q2/Q3/Q4 质量门禁操作手册

> 配套：`docs/TASKS.md` M7（Q2/Q3/Q4）、`docs/DESIGN.md` §1.2 非功能需求。
> 本文只描述**如何跑、门禁卡什么、哪些必须真机**；不替代 TASKS 验收原文。

---

## 0. 一览：CI 可跑 vs 阻塞于 X0/真机

| 门禁 | 脚本 | 无设备/CI | 真机（X0 签名后） | 说明 |
|---|---|---|---|---|
| Q2 基准采集 dry-run | `scripts/bench/run-bench.sh` | ✅ 清单 + 报告骨架 | ❌ 数值需设备 | 默认离线模式 |
| Q2 基准数值采集 | 同上 + hdc 回填 | ❌ | ✅ | DESIGN §1.2：≥50fps、RSS&lt;400MB |
| Q2 门禁判定 | `scripts/bench/gate.sh` | ✅（对已有报告 JSON） | — | 可对 sample/人工 JSON 执行 |
| Q2 纯逻辑双面对拍 | `entry/src/test/BenchMetrics.test.ets` | ✅（hvigor test） | — | 与 gate.sh 阈值语义一致 |
| Q3 宿主 ASan/LSan | `scripts/bench/asan-longrun.sh`（`RUN_ASAN=1`） | ✅ WSL/Linux | — | 包装 `scripts/run-native-tests.sh` |
| Q3 8h 长稳 RSS/fd | 同上检查清单 | ❌ | ✅ | 增长 &lt;5%；fd 稳定 |
| Q3 session_bridge 竞态 | 文档跟踪 + ASan 反复开关会话 | 🟡 部分（ASan） | ✅ 长稳观察 | **仍未关闭**，见 §3 |
| Q4 日志脱敏 | `scripts/security/check-logs.sh` | ✅ | ✅ 沙箱导出后 | CI 可用 ci-logs / 人工样例 |
| Q4 HAP 解包 | `scripts/security/check-hap.sh` | ✅（有 HAP 时） | — | 无 HAP 则 dry-run 清单 |
| Q4 依赖 CVE | `scripts/security/cve-scan.sh` | 🟡 工具存在才实扫 | — | 缺工具 stub 不阻断 |
| 既有四阶段 CI | `scripts/ci-local.sh` | ✅ lint/test/native/assemble | — | 默认行为不变 |
| 抓包/链路密文核验 | 人工 | ❌ | ✅ + 代理 | R-8 HTTPS 化前为明文 HTTP（已知） |
| 沙箱导出核验 | 人工 + check-logs | ❌ | ✅ | 需签名安装 |

图例：✅ 本机/CI 可执行　🟡 视工具或深度　❌ 依赖签名真机或人工链路

---

## 1. Q2 性能门禁

### 1.1 阈值（DESIGN §1.2 / TASKS Q2）

| 指标 | 默认值 | 环境变量 |
|---|---|---|
| 平均帧率下限 | **≥ 50 fps** | `BENCH_MIN_FPS` |
| 峰值 RSS 上限 | **&lt; 400 MB** | `BENCH_MAX_RSS_MB` |
| 四场景齐全 | 门禁严格模式才强制 | `BENCH_REQUIRE_ALL=1` |

场景 ID（报告 `scenarios[].id`）：

1. `cat_5mb` — `cat` 5 MB 文本
2. `yes_burst` — `yes` 突发
3. `host_list_100` — 100 主机列表加载
4. `pane_4_concurrent` — 4 分屏并发输出

报告契约：`scripts/bench/report-schema.json`；样例：`scripts/bench/sample-report.json`。

### 1.2 怎么跑

```bash
# 1) 离线：打印四场景设备操作清单，生成 dry-run 报告
bash scripts/bench/run-bench.sh
#    → scripts/bench/last-report.json

# 2) 自检门禁（对 sample，应 PASS）
bash scripts/bench/gate.sh scripts/bench/sample-report.json

# 3) 门禁自己的 dry-run 报告（无数值时软通过；严格模式会失败）
bash scripts/bench/gate.sh scripts/bench/last-report.json
BENCH_REQUIRE_ALL=1 bash scripts/bench/gate.sh scripts/bench/last-report.json

# 4) 真机（X0 之后）：连接设备后重跑，hdc 钩子打印采样命令
DEVICE_SERIAL=<serial> bash scripts/bench/run-bench.sh
#    人工/自动化回填 fpsAvg/fpsP1/rssPeakMb 到报告 JSON
BENCH_REQUIRE_ALL=1 bash scripts/bench/gate.sh scripts/bench/last-report.json
```

可选外部采集器：

```bash
HDC_BENCH_RUNNER=1 BENCH_RUNNER_CMD=./my-collector.sh \
  DEVICE_SERIAL=<serial> bash scripts/bench/run-bench.sh
```

只跑部分场景：`ALLOWED_STAGES=cat_5mb,pane_4_concurrent bash scripts/bench/run-bench.sh`

### 1.3 纯逻辑双面对拍（CI 可跑）

- 源：`entry/src/test/BenchMetrics.ets`
- 测试：`entry/src/test/BenchMetrics.test.ets`（已注册 `List.test.ets`）
- 语义必须与 `gate.sh` 一致：`>=50` 过 fps、`RSS >= 400` 不过、dry-run 软通过。
- 跑法：`hvigorw test` 或 `scripts/ci-local.sh` 阶段 2（视 Previewer 环境）。

### 1.4 阻塞说明

- **数值采集、输入延迟、静止 CPU≈0、4 实例真机观感** 依赖 X0 签名 + 真机/模拟器（TASKS 进度快照：X0 为人工阻塞项）。
- CI 侧能做的：schema/gate 脚本自检、BenchMetrics 单测、dry-run 报告产物存在性。

---

## 2. Q3 内存与句柄泄漏

```bash
# 打印清单 + 生成 longrun-report.json 骨架（默认）
bash scripts/bench/asan-longrun.sh

# WSL 内跑宿主 ASan（退出码门禁）
RUN_ASAN=1 bash scripts/bench/asan-longrun.sh

# 写骨架报告
WRITE_REPORT=1 bash scripts/bench/asan-longrun.sh
```

验收（TASKS Q3）：

- 8h 连续会话后 **RSS 增长 &lt; 5%**（`LONGRUN_HOURS` / `RSS_GROWTH_LIMIT_PCT` 可调）
- **fd 数量稳定**（不随开关会话单调上涨）
- 宿主 ASan/LSan 干净

真机采样钩子见 `asan-longrun.sh` 输出的 hdc 示例；无设备时脚本不失败，只给清单。

---

## 3. 已知跟踪项：session_bridge teardown 竞态（Q3）

**状态：代码防护已落地（TeardownGuard + 宿主 storm 测试）；长稳/真机验收仍 open**

| 项 | 内容 |
|---|---|
| 描述 | session_bridge **在途调用** vs **teardown** 的竞态 |
| 源码 | `entry/src/main/cpp/bridge/teardown_guard.h`（纯逻辑）、`session_bridge.cpp` / `internal.h` |
| 模型 | `LookupLiveCall` 取 **in-flight 租约**；`Teardown::BeginTeardown` 关入口并 **等待 inFlight==0** 再 `session.reset()`；**generation 代际** 在 teardown 时 bump，late 回调/事件一律丢弃 |
| 宿主测试 | `entry/src/main/cpp/tests/teardown_guard_test.cpp`：connect-then-teardown storm（多线程）、late drop、Raii 租约；`SANITIZE=address` 下应干净 |
| CI 侧动作 | `RUN_ASAN=1` 宿主测试；可选 `CI_DOCKER_SSHD=1` 反复 create/connect/close |
| 真机侧动作 | 8h 长稳 + 开关会话 ≥1000 次；ASan/TSan 报告归档到 Q3 结告 |
| 关闭条件 | 长稳 RSS/fd 达标 **且** 压力测试下无 UAF/泄漏报告，再在 TASKS 进度快照改状态 |

本文件与 `scripts/bench/asan-longrun.sh` 均显式打印该跟踪项，避免门禁文档漂移。

---

## 3b. T8 选择打磨残留（loupe / 气泡菜单）

| 项 | 状态 |
|---|---|
| 长按进入选择 + 选区高亮 + 复制/全选气泡 | ✅ 已落地（TerminalCanvas） |
| 两端拖拽手柄 UI + hit 区 | ✅ 已落地；**hit 几何为纯函数**（`TerminalGestures.ets` `selectionHandleHitRects` / `selectionHandleAtPoint`） |
| 放大镜（loupe） | ❌ 未做（T8 任务书允许省略；长按定位+抬手再拖） |
| 气泡菜单「粘贴/分享」 | ❌ 归 U4（本组件仅复制/全选） |
| 回滚区选择 | ❌ 首版仅主屏（`scrollOffset>0` 不进选择） |

---

## 4. Q4 安全自查

### 4.1 日志脱敏

```bash
# 默认扫 build/ci-logs（不存在则 dry-run 清单）
bash scripts/security/check-logs.sh

# 扫指定目录（真机导出或人工样例）
bash scripts/security/check-logs.sh path/to/sample-logs
```

规则对齐 `entry/src/main/ets/common/utils/Logger.ets` 的 `sanitize()`：

- PEM/OPENSSH 私钥块
- JSON / `k=v` / `k:v` 的 password/token/privateKey/secret 等，值为 `***` 不算命中
- `Authorization` / `Bearer` 非 `***` 值

**通过标准：0 命中。** 红队样例（故意塞秘密）必须被检出。

### 4.2 HAP 解包

```bash
# 自动找 entry/build/default/outputs/default/*.hap
bash scripts/security/check-hap.sh

# 指定 HAP
bash scripts/security/check-hap.sh path/to/entry-default-unsigned.hap

# 已解包目录
HAP_DIR_ONLY=1 bash scripts/security/check-hap.sh path/to/extracted
```

检查：

1. 无私钥/明文 password/token/apiKey/SYNC 秘密（`SYNC_API_URL` 允许，D10）
2. `network_config.json`：全局 `cleartextTrafficPermitted=false`；明文域名 ⊆ `ALLOWED_SYNC_DOMAINS`（默认仅 `123.161.179.32`）
3. 无 HAP 时 dry-run 清单退出 0（X0/未构建不误伤 CI）

### 4.3 依赖 CVE

```bash
bash scripts/security/cve-scan.sh              # 无工具 → stub 指引，退出 0
CVE_STRICT=1 bash scripts/security/cve-scan.sh # 无工具 → 退出 1（全量本地门禁）
CVE_TOOL=osv|nancy|trivy bash scripts/security/cve-scan.sh
```

stub 会提示安装 `osv-scanner` / `nancy` / `trivy`，并给出 OpenSSL/libssh2 人工基线链接。  
**注意**：R-8（同步 API 明文 HTTP + 裸 IP）是传输层风险，不在 CVE 扫描关闭范围，见 P6。

### 4.4 留真机/人工的 Q4 项

- 抓包核验同步文档链路密文（S2 保险库密文；传输仍 HTTP → 仅能证明「载荷密文」）
- 沙箱导出：SharedPreferences / relationalStore / ASSET 不落明文
- 卸载后 ASSET 不可恢复（C2 系统属性）

---

## 5. 与 `scripts/ci-local.sh` 的关系

原有**四阶段**保持不变、默认全跑：

1. ArkTS lint（codelinter + 错误码对拍）
2. ArkTS 单元测试（hvigorw test + 日志判定）
3. native 单元测试（WSL gtest）
4. assembleHap（产物存在性）

**可选阶段**（默认关闭，不影响既有流水线）：

| 环境变量 | 阶段 | 动作 |
|---|---|---|
| `CI_BENCH_GATE=1` | Q2 门禁 | `gate.sh` 扫 `BENCH_REPORT`（默认 sample） |
| `CI_SECURITY_CHECK=1` | Q4 脚本 | `check-logs.sh` + `check-hap.sh`（有 HAP 才实扫） |
| `CI_CVE_SCAN=1` | Q4 CVE | `cve-scan.sh`（stub 通过） |
| `CI_ASAN_HOST=1` | Q3 宿主 ASan | `asan-longrun.sh` 且 `RUN_ASAN=1` |
| `CI_DOCKER_SSHD=1` | Q1 Docker sshd | `scripts/sshd-multi/up.sh --wait`；**无 docker → SKIP 不红** |
| `CI_DOCKER_SSHD_NATIVE=1` | Q1 + native | 上阶段后把 WSL native 测试指到 `127.0.0.1:2222` |

示例：

```bash
CI_BENCH_GATE=1 BENCH_REPORT=scripts/bench/sample-report.json \
  CI_SECURITY_CHECK=1 CI_CVE_SCAN=1 \
  bash scripts/ci-local.sh

# Q1 Docker 多算法 sshd（本机无 docker 时自动 SKIP）
CI_DOCKER_SSHD=1 bash scripts/ci-local.sh
```

阶段 1–4 失败仍快速失败；可选阶段挂在四阶段之后。

**x86_64 模拟器说明（Q1 残留）**：`TARGET=ohos-x86_64` 仅交叉编译看护；OHOS musl 二进制
不能在 WSL/Linux 直接执行。x86_64 模拟器上的 gtest/集成用例 **仍 blocked on device/SDK**
（需 hdc + 模拟器镜像），CI 以宿主机 clang gtest + 可选 Docker sshd 为准。
详见 `scripts/sshd-multi/README.md` 与 `docs/NATIVE-BUILD.md` §7.4。

---

## 6. Windows Git Bash / WSL 注意事项

- 全部脚本 `#!/usr/bin/env bash`，避免 bash 4+ 专用语法；路径用 `PROJECT_ROOT` 拼接，兼容 `/c/...` 与 `/mnt/c/...`。
- JSON：优先 `python3`/`python`，回退 `node`；不强制 `jq`。
- `hdc` 仅在 PATH 可用时启用设备钩子；否则自动 dry-run。
- ASan：Windows 侧通过 `wsl -d $WSL_DISTRO` 调 `scripts/run-native-tests.sh`；已在 Linux 内则直接本地跑。
- HAP 解包依赖 `unzip` 或 Python `zipfile`。
- 不要在脚本里写死签名材料；`build-profile.json5` 的 keyPassword 仅存在于开发机，HAP 扫描目标是**包内资源**。

---

## 7. 发布前检查清单（P5 自提检）

- [ ] `bash scripts/ci-local.sh` 四阶段绿
- [ ] `bash scripts/bench/gate.sh <实测报告>` 且 `BENCH_REQUIRE_ALL=1`
- [ ] `RUN_ASAN=1 bash scripts/bench/asan-longrun.sh` 绿；8h 长稳数据齐全
- [ ] TASKS 中 session_bridge 竞态有结论（开/关）且证据入 Q3 报告
- [ ] `bash scripts/security/check-logs.sh <导出日志目录>` 0 命中
- [ ] `bash scripts/security/check-hap.sh <release HAP>` 通过
- [ ] `CVE_STRICT=1 bash scripts/security/cve-scan.sh`（装好工具后）通过
- [ ] 真机：抓包/沙箱/四场景性能签字（依赖 X0）

---

## 8. 文件索引

| 路径 | 用途 |
|---|---|
| `scripts/bench/run-bench.sh` | Q2 采集/dry-run |
| `scripts/bench/gate.sh` | Q2 报告门禁入口 |
| `scripts/bench/gate_check.py` | Q2 门禁判定（与 BenchMetrics.ets 对齐） |
| `scripts/bench/report-schema.json` | 报告 JSON Schema |
| `scripts/bench/sample-report.json` | 过线样例（gate 自检） |
| `scripts/bench/asan-longrun.sh` | Q3 ASan + 长稳清单 |
| `scripts/security/check-logs.sh` | Q4 日志脱敏扫描入口 |
| `scripts/security/check_logs_scan.py` | 日志扫描判定 |
| `scripts/security/check-hap.sh` | Q4 HAP 解包扫描入口 |
| `scripts/security/check_hap_scan.py` | HAP 扫描判定 |
| `scripts/security/cve-scan.sh` | Q4 CVE（osv/nancy/trivy / stub） |
| `entry/src/test/BenchMetrics.ets` | Q2 纯指标 helper |
| `entry/src/test/BenchMetrics.test.ets` | helper 单测（List.test 注册） |
| `scripts/ci-local.sh` | 既有四阶段 + 可选质量阶段（含 `CI_DOCKER_SSHD`） |
| `scripts/sshd-multi/up.sh` | Q1 Docker 多算法 sshd 启动/探活（无 docker SKIP） |
| `scripts/sshd-multi/README.md` | Q1 用法 + x86_64 模拟器 blocked 说明 |
