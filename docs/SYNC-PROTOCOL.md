# 同步协议规范（schema v1）

> 任务 **S1** 交付物。配套：`docs/DESIGN.md` §6。
> 本文件是同步相关**常量、字段语义、升版规则的唯一文字出处**。
> 代码中的唯一实现出处：
>
> | 层 | 文件 |
> |---|---|
> | ArkTS | `entry/src/main/ets/common/sync/SyncProtocol.ets` |
> | native | `entry/src/main/cpp/crypto/sync_params.h`（域字符串由 `aad.hpp` 引用，不得再写字面量） |
>
> S2 / S5 及之后的模块只准 `import` / `#include` 上述文件，禁止第二处定义。
> 服务端与桌面端仓库一行不改；本应用用**独立账号 + 本 schema** 接入同一部署。

---

## 1. 范围与隔离

- 后端：复用已部署的 `ssh-tool-server` `/api/v1`（内容无关密文信封）。
- 本应用文档格式与桌面端**不互通**。同一账号只有一份云端文档——注册/登录页必须提示
  「不要用桌面端同一账号登录本应用」。
- 传输：开发期 `http://123.161.179.32:46926`（客户端自动拼 `/api/v1`）；上架前建议切 HTTPS（P6 / R-8）。
- 日志：只记同步相位与会话状态，**不记录密码、token、私钥、请求体、同步密文**。

---

## 2. 密码学参数

算法结构借鉴桌面端，**全部域字符串换成本项目自己的**（两个应用的保险库不得互解）。

| 符号 | 值 | 出处 |
|---|---|---|
| `KDF_NAME` | `argon2id` | RFC 9106，实现 libargon2 |
| `ARGON2_MEMORY_KIB` | `65536` | 64 MiB |
| `ARGON2_ITERATIONS` | `3` | |
| `ARGON2_PARALLELISM` | `1` | |
| `ARGON2_HASH_LEN` | `32` | Vault key 字节数 |
| `KDF_SALT_LEN` | `16` | Argon2id salt 字节数 |
| `AES_ALGORITHM` | `AES-256-GCM` | 信封外壳字面量，服务端校验 |
| `AES_NONCE_LEN` | `12` | 字节 |
| `AES_TAG_LEN` | `16` | 字节，拼在密文尾部 |
| `HKDF_HASH` | `SHA-256` | |
| `HKDF_SALT` | 空 | 恢复 KEK |
| `HKDF_INFO` | `ssh-port-mapper/recovery-kek/v1` | |
| `HKDF_OUT_LEN` | `32` | |
| `AAD_DOMAIN_SYNC_DOCUMENT` | `ssh-port-mapper/sync-document/v1` | |
| `AAD_DOMAIN_VAULT_KEY_PASSWORD` | `ssh-port-mapper/vault-key/password/v1` | |
| `AAD_DOMAIN_VAULT_KEY_RECOVERY` | `ssh-port-mapper/vault-key/recovery/v1` | |
| `RECOVERY_KEY_PREFIX` | `SPM1` | 与桌面端 ssh-tool 共用，两端同一保险库 |
| `RECOVERY_KEY_RAW_B64URL_LEN` | `43` | 32 字节 base64url 无填充 |
| `RECOVERY_KEY_CHECK_HEX_LEN` | `12` | `sha256("SPM1"+raw)` 前 12 位十六进制**大写** |
| `CIPHERTEXT_HASH_HEX_LEN` | `64` | 密文（含 tag）原始字节 SHA-256 **小写**十六进制 |

### 2.1 AAD 编码

每个字段编码为 `<utf8字节长度>:<值>`，字段间 `|` 连接，整体前缀 `<domain>|`。
无字段时只输出 domain，不留尾部分隔符。长度是 UTF-8 字节数，不是字符数。

| 用途 | 拼接 |
|---|---|
| 同步文档 | `<AAD_DOMAIN_SYNC_DOCUMENT>\|<len>:<vaultId>\|<len>:<schemaVersion>\|<len>:<keyVersion>` |
| 密码包裹 Vault key | `<AAD_DOMAIN_VAULT_KEY_PASSWORD>\|<len>:<keyVersion>` |
| 恢复包裹 Vault key | `<AAD_DOMAIN_VAULT_KEY_RECOVERY>\|<len>:<keyVersion>` |

`schemaVersion`、`keyVersion` 按十进制字符串传入（如 `"1"`）。

### 2.2 恢复密钥格式

```
SPM1-<base64url 43 字符>-<校验 12 位大写十六进制>
```

校验 = `SHA-256( ASCII("SPM1") || raw32 )` 的十六进制小写再取前 12 位并转大写。
编解码任一段被改必须拒绝。S2 须覆盖 10000 次随机往返（DESIGN §9）。

### 2.3 信封外壳（服务端校验，内容自由）

`vaultKeyEnvelopeSchema` / `encryptedDocumentEnvelopeSchema` 必须满足：

- `algorithm` 字面量精确为 `AES-256-GCM`
- `nonce` / `ciphertext` 为标准 base64，长度在服务端允许区间
- `ciphertextHash` 为 64 位小写十六进制
- Argon2 参数落在服务端允许区间（本客户端固定写上表默认值）
- `schemaVersion` 允许 1–1000（服务端不解析明文）

`ciphertext` = `AES-256-GCM(plaintext)` 的密文 \|\| 16B tag。
`ciphertextHash` = `hex_lower(sha256(ciphertext_with_tag))`。

---

## 3. 文档 schema v1

明文 JSON，UTF-8，无 BOM。序列化前所有数组按 `id` 字典序稳定排序，
对象键按本规范列出的顺序写出（S5 `SyncSerializer`），保证同一配置字节一致。

```jsonc
{
  "schemaVersion": 1,
  "updatedAt": "2026-08-15T00:00:00.000Z",
  "preferences": {
    "syncPasswords": false,
    "syncPrivateKeys": false
  },
  "hosts": [],
  "groups": [],
  "appearance": [],
  "snippets": [],
  "forwards": [],
  "knownHosts": []
}
```

| 字段 | 语义 |
|---|---|
| `schemaVersion` | 文档格式版本，v1 = `1`。只升不降。 |
| `updatedAt` | 本机写出时刻，ISO-8601 UTC，带毫秒与 `Z`。 |
| `preferences.syncPasswords` | 是否把主机密码/短语放进 `hosts[].secrets`。默认 `false`。 |
| `preferences.syncPrivateKeys` | 是否把私钥放进 `hosts[].secrets.privateKey`。默认 `false`。 |
| `hosts` | `HostProfile` + 可选 `secrets`（仅当对应开关为 true） |
| `groups` | `HostGroup` |
| `appearance` | `AppearanceProfile`（20 色位 + 字体度量） |
| `snippets` | `Snippet` |
| `forwards` | `PortForwardRule` |
| `knownHosts` | `KnownHostEntry` |

实体字段与 `entry/src/main/ets/common/model/models.ets` 一致。每个实体必须有稳定 `id`（UUID v4）；改名不改 id。

`hosts[].secrets`（可选，缺省表示本机不上传）：

| 字段 | 何时出现 |
|---|---|
| `password` | `syncPasswords === true` 且认证方式为密码 |
| `passphrase` | `syncPasswords === true` 且密钥带短语 |
| `privateKey` | `syncPrivateKeys === true` |

关闭任一敏感开关时：S7 轮换 Vault key、生成新恢复密钥、原子清空云端历史。旧恢复密钥立即失效。

---

## 4. 体积与拦截（客户端提前拦，勿等服务端 413）

| 符号 | 值 |
|---|---|
| `DOCUMENT_MAX_BYTES` | `2097152`（2 MiB，服务端上限） |
| `PRIVATE_KEY_MAX_BYTES` | `262144`（256 KiB / 条） |
| `HOST_COUNT_MAX` | `5000` |

超限：不发起 PUT，向用户提示哪一项超限。

---

## 5. 升版与降级

- 本客户端当前读写 `SCHEMA_VERSION = 1`。
- 读到 `schemaVersion > SCHEMA_VERSION`：**只读不写**，UI 提示升级应用。禁止把低版本文档覆盖云端。
- 读到 `schemaVersion < SCHEMA_VERSION`：在内存中升到当前版本再参与合并；写出用当前版本。
- 未来加字段：升 `schemaVersion`，老字段保持兼容。不得复用已删除字段名。
- 未知字段：升版路径保留（S5 合并时按「本机 schema 认识的键」处理，其余随远端原样带回，避免丢失）。

---

## 6. 同步边界

| 同步 | 不同步（设备本地） |
|---|---|
| 主机、分组、转发、片段 | 打开的会话、标签、窗格树 |
| 外观配置 | 字体文件（随包） |
| known_hosts | 后台保活、触感、键条布局、快捷键表 |
| 密码 / 私钥（独立开关，默认关） | 日志、账号 token、`device.id` |

---

## 7. 相位（`SyncPhase`）

```
signed_out → disabled → locked → idle ⇄ syncing → synced
                                   ↓        ↓
                                offline   conflict / error / auth_error
```

触发：登录后、切前台、保存后防抖 `SAVE_DEBOUNCE_MS = 3000`、手动、网络恢复、轮询
`POLL_INTERVAL_MINUTES`（C3 默认 15，可关）。

冲突：三方合并（base / local / remote）。解不开的字段进 U7，选项「保留本机 / 使用云端」。
敏感字段只显示「有变更」，不显示值。

---

## 8. HTTP API（客户端必须实现，S3）

Base：`{SYNC_API_URL}/api/v1`。除 register / login / refresh 外带
`Authorization: Bearer <accessToken>`。

| 类 | 端点 |
|---|---|
| 账号 | `POST /auth/register` `POST /auth/login` `POST /auth/refresh` `POST /auth/logout` `POST /auth/logout-all` `POST /auth/change-password` `DELETE /me` |
| 设备 | `GET /devices` `PATCH /devices/{id}` `DELETE /devices/{id}` |
| Vault | `POST /vault` `GET /vault/key-envelope` `PUT /vault/key-envelope` `POST /vault/rotate` `DELETE /vault` |
| 文档 | `HEAD /sync/document` `GET /sync/document` `PUT /sync/document` |
| 历史 | `GET /sync/revisions` `DELETE /sync/revisions` `POST /sync/revisions/{revision}/restore` |

纪律（服务端已实现，客户端必须遵守）：

- 写操作要 `Idempotency-Key: <uuid v4>`（vault 创建、文档 PUT、rotate、restore）。
- 文档写要 `If-Match: "revision-<n>"`；云端无文档时 `"revision-0"`。
- 401 `AUTH_TOKEN_EXPIRED`：refresh 后重放原请求。
- 401 `AUTH_TOKEN_REUSED`：清本地 token，强制重新登录。
- 404 `SYNC_DOCUMENT_NOT_FOUND` 与 `VAULT_NOT_FOUND` 必须分支处理，不得当成同一种「没有数据」。
- 409 `SYNC_REVISION_CONFLICT`：拉远端、三方合并、换新 Idempotency-Key 再 PUT。
- 429：按 `Retry-After` 退避。
- **login 会新建设备**，配额 10。`device.id` 必须本地持久化并在后续 login 复用。

错误只看响应 `data.code`，不依赖中文 `message`。

---

## 9. S2 黄金向量（登记后永不修改）

S2 用固定输入跑 Argon2id → AES-256-GCM → `ciphertextHash`，断言与登记值逐字节相等。
向量表放在 `entry/src/main/cpp/tests/vault_golden_vectors.h`（S2 产出），本规范只规定：

- 输入：同步密码、salt、KDF 四参数、明文、nonce 全部写死。
- 输出：密文（含 tag）十六进制、`ciphertextHash`。
- 一旦合入主线，**禁止改登记值**；算法实现只能改到继续命中旧向量。
- 已冻结文件：`entry/src/main/cpp/tests/vault_golden_vectors.h`
  （`kCiphertextHash` = `c74d2505b3edc90e2734059eaeed058bdb13c5c9f770962df8f20e0b2c064274`）。

---

## 10. 常量清单（与代码符号一一对应）

见 `SyncProtocol.ets` 与 `sync_params.h` 同名符号。新增常量必须：先改本文件，再改那两个头，S1 单测核对三处一致。
