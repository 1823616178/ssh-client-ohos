# P6 HTTPS 就绪（客户端侧）

> 对应任务 **P6** / 风险 **R-8**（`docs/TASKS.md`、`docs/DESIGN.md` §6.5.3 / D12）。
> 本文件只登记**客户端**就绪状态与切换清单；服务端仓库不在本仓改动范围内。

## 背景

同步 API 现状：

| 项 | 当前值 |
|----|--------|
| `buildProfileFields.SYNC_API_URL` | `http://123.161.179.32:46926` |
| API 基础路径 | `{SYNC_API_URL}/api/v1` |
| 明文放行 | `resources/base/profile/network_config.json` 仅放行 `123.161.179.32` |
| 风险 | 登录密码、token、key envelope 可被公网窃听（E2EE 只保护文档内容） |

## 客户端已就绪的能力

1. **`BuildConfig` 纯函数**（`entry/src/main/ets/common/constants/BuildConfig.ets`）
   - `isHttpsApiUrl(url)`：URL 是否 `https://` 开头（大小写不敏感）。
   - `shouldShowCleartextWarning(syncApiUrl)`：**非 https 时 UI 展示明文告警**；
     `SYNC_API_URL` 一旦以 `https://` 开头则返回 `false`（质量开关，纯函数，已单测）。
   - `syncApiBaseUrl(configuredUrl, preferredHttpsUrl?)`：**有可用 https 候选时优先 https**，
     否则回落构建注入地址；自动拼 `/api/v1`。
   - 类上薄封装：`BuildConfig.isSyncApiHttps()` / `shouldShowCleartextWarning()` / `syncApiBaseUrl()`。

2. **构建注入点唯一**
   - 只需改 `entry/build-profile.json5` 的 debug/release 两处 `SYNC_API_URL`。
   - HAP 可解包，地址是明文常量——HTTPS 化后同样可见域名，但传输不再明文。

3. **网络策略**
   - `network_config.json`：`base-config.cleartextTrafficPermitted = false`，
     仅 domain-config 白名单当前 IP 允许明文。
   - **运维完成 HTTPS 前不要删除该文件**（否则现网 IP 同步直接被系统拒）。
   - **切换 HTTPS 且确认不再访问明文 IP 后**，删除/收缩 cleartext 白名单
     （或移除 `app.json5` 的 `network` 配置节点——以实际模块配置为准）。

## 运维切换清单（客户端观察面）

- [ ] 服务端：域名 A/AAAA → 同步主机；Let's Encrypt（或等价）证书；HTTP/HTTPS 均监听或强制跳转。
- [ ] 证书链在设备系统信任库可校验（不要用自签；不要依赖用户装 CA）。
- [ ] 将 `entry/build-profile.json5` 两处 `SYNC_API_URL` 改为 `https://<domain>`（无尾斜杠，或带尾斜杠——客户端 `joinApiV1` 已去重 `/`）。
- [ ] 重新 `assembleHap`，确认 `BuildConfig.SYNC_API_BASE` 指向 https。
- [ ] 真机：登录 / 同步 / 设备列表；抓包确认无明文 HTTP。
- [ ] UI：明文告警不再出现（`shouldShowCleartextWarning === false`）。
- [ ] 从 `network_config.json` 移除 `123.161.179.32` 明文放行；评估删除 network 节点。
- [ ] 提审材料：更新隐私/安全说明，关闭 R-8。

## 明确不做的事（本任务范围外）

- 不改 `ssh-tool-server` 与证书签发本身。
- 不在客户端「偷偷」改写 http→https（避免半吊子 MITM/证书错误难排查）；以构建期字段为准。
- 不删除 `network_config.json`（留运维与上架阶段）。

## 测试

- `entry/src/test/I18n.test.ets`：覆盖 `t()` 键表/回落/语言解析，
  以及 `shouldShowCleartextWarning` / `syncApiBaseUrl` / `isHttpsApiUrl`（https 跳过告警、http 仍告警、https 候选优先）。
