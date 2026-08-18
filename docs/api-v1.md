# SSH Sync 客户端 API 文档（/api/v1）

面向客户端（桌面/移动/CLI 等）集成的接口说明。仅包含 `/api/v1/*`，不包含后台管理接口 `/api/admin/*`。

## 1. 通用约定

### 1.1 Base URL

```
{SERVER_ORIGIN}/api/v1
```

### 1.2 认证

除 `POST /auth/register`、`POST /auth/login`、`POST /auth/refresh` 外，所有接口都需要：

```
Authorization: Bearer <accessToken>
```

- `accessToken` 有效期 **900 秒（15 分钟）**，过期后用 `refreshToken` 调用 `POST /auth/refresh` 换取新的一对 token。
- `refreshToken` 有效期 **30 天**，一次性使用（rotate），且带**重用检测**：同一个 refreshToken 被使用两次会导致其所在 token family 全部失效（见 3.4 节）。
- Token 与设备（device）绑定：服务端会校验 `deviceId` 对应设备是否仍处于未撤销状态、用户账号是否 `active`，否则返回 401。

### 1.3 错误响应格式

所有非 2xx 响应统一为：

```json
{
  "statusCode": 404,
  "statusMessage": "Not Found",
  "message": "云端还没有同步配置",
  "data": {
    "code": "SYNC_DOCUMENT_NOT_FOUND",
    "message": "云端还没有同步配置"
  }
}
```

客户端应基于 `data.code`（稳定的机器可读错误码）做分支处理，不要依赖 `message` 文案（中文，可能会变化）。

### 1.4 幂等性（Idempotency-Key）

以下会产生状态变更、且服务端要求防重放的接口，必须携带请求头：

```
Idempotency-Key: <uuid v4>
```

- `POST /vault`
- `PUT /sync/document`
- `POST /vault/rotate`
- `POST /sync/revisions/{revision}/restore`

规则：
- 同一个 key 在 24 小时内重复提交且请求体完全一致 → 直接返回上次成功的响应（不会重复执行）。
- 同一个 key 但请求体不同 → `409 IDEMPOTENCY_KEY_REUSED`。
- 客户端每次发起一次新的业务操作前都应生成新的 UUID。

### 1.5 乐观并发（revision / If-Match）

同步文档使用单调递增的 `revision`（无符号 64 位整数，字符串形式）做乐观锁，ETag 格式固定为：

```
"revision-<数字>"
```

写操作（`PUT /sync/document`、`POST /vault/rotate`、`DELETE /sync/revisions`、`POST /sync/revisions/{revision}/restore`）必须携带：

```
If-Match: "revision-<当前客户端已知的revision>"
```

若不携带或格式不对 → `428 SYNC_REVISION_REQUIRED`。
若服务端当前 revision 与提交的不一致 → `409 SYNC_REVISION_CONFLICT`（响应 message 中带出服务端当前值，客户端应重新拉取文档、合并后重试）。
云端还没有任何文档时，当前 revision 视为 `0`，首次上传用 `If-Match: "revision-0"`。

### 1.6 限流

以下接口有限流（基于 IP / 邮箱 / refreshToken 哈希，滑动窗口）：

| 接口 | 维度 | 限制 |
|---|---|---|
| `POST /auth/register` | 单 IP | 15 分钟 5 次 |
| `POST /auth/register` | 单邮箱 | 1 小时 3 次 |
| `POST /auth/login` | 单 IP | 15 分钟 30 次 |
| `POST /auth/login` | 单邮箱 | 15 分钟 10 次 |
| `POST /auth/refresh` | 单 IP | 1 分钟 120 次 |
| `POST /auth/refresh` | 单 refreshToken | 1 分钟 10 次 |

超限返回 `429 RATE_LIMITED`，响应头包含：

```
X-RateLimit-Limit
X-RateLimit-Remaining
X-RateLimit-Reset   (unix 秒)
Retry-After          (仅超限时出现，秒)
```

### 1.7 配额（默认值，管理员可按用户调整）

- 单账号最大设备数：`10`
- 单份同步文档最大字节数：`2 MiB`（2 * 1024 * 1024）
- 同步历史版本保留条数：`20`

---

## 2. 认证 Auth

### 2.1 `POST /auth/register` — 注册

无需 Authorization。

请求体：

```json
{
  "email": "user@example.com",
  "password": "至少10位密码",
  "inviteCode": "可选，若服务端开启邀请码注册则必填",
  "device": {
    "name": "我的 MacBook",
    "platform": "macos",
    "appVersion": "1.2.0"
  }
}
```

成功响应 `200`：

```json
{
  "accessToken": "...",
  "refreshToken": "...",
  "expiresIn": 900,
  "user": { "id": "uuid", "email": "user@example.com" },
  "device": { "id": "uuid", "name": "我的 MacBook" }
}
```

错误码：
- `400 VALIDATION_ERROR` 参数校验失败
- `403 REGISTRATION_DISABLED` 服务端未开放注册
- `403 AUTH_INVITATION_REQUIRED` / `403 AUTH_INVITATION_INVALID` 邀请码相关
- `409 AUTH_EMAIL_EXISTS` 邮箱已注册
- `429 RATE_LIMITED`

### 2.2 `POST /auth/login` — 登录

无需 Authorization。**每次登录都会新建一个 device 记录**（即使 name/platform 相同），所以客户端应在本地持久化返回的 `device.id`，同一设备重复登录前建议先判断本地是否已有有效 session，避免无限堆积设备。

请求体：

```json
{
  "email": "user@example.com",
  "password": "...",
  "device": { "name": "...", "platform": "...", "appVersion": "..." }
}
```

成功响应同 2.1。

错误码：
- `401 AUTH_INVALID_CREDENTIALS` 邮箱或密码错误（账号被禁用/已删除也走这个码，不区分，防枚举）
- `403 DEVICE_QUOTA_EXCEEDED` 已达设备数上限，需要先在 `/devices` 撤销旧设备
- `429 RATE_LIMITED`

### 2.3 `POST /auth/refresh` — 刷新令牌

无需 Authorization（用 refreshToken 本身鉴权）。

```json
{ "refreshToken": "..." }
```

成功响应同 2.1（会拿到**新的** accessToken + refreshToken，旧 refreshToken 立即失效，请求成功后客户端必须用新值覆盖本地存储）。

错误码：
- `401 AUTH_TOKEN_EXPIRED` refreshToken 不存在/已过期/已撤销/关联设备或账号已被禁用
- `401 AUTH_TOKEN_REUSED` **检测到已经被用过的 refreshToken 被再次使用**——说明 token 可能泄露，服务端会把整个 token family 全部撤销，客户端必须引导用户重新登录
- `429 RATE_LIMITED`

### 2.4 `POST /auth/logout` — 退出登录（仅当前设备）

需要 Authorization。撤销当前设备的所有 refreshToken（设备本身不撤销，仅登出）。

响应：`{ "ok": true }`

### 2.5 `POST /auth/logout-all` — 退出所有设备

需要 Authorization。撤销该账号下**所有**设备与 refreshToken（含当前设备）。

响应：

```json
{ "revokedDevices": 3, "revokedRefreshTokens": 5 }
```

### 2.6 `POST /auth/change-password` — 修改密码

需要 Authorization。

```json
{ "currentPassword": "...", "newPassword": "至少10位" }
```

成功响应：

```json
{ "ok": true, "reauthenticationRequired": true }
```

**修改成功后服务端会撤销该账号所有 refreshToken**（`reauthenticationRequired: true` 提示客户端所有设备需要重新登录，含当前设备——当前 accessToken 在过期前仍可短暂使用，但 refreshToken 已失效）。

错误码：
- `401 AUTH_CURRENT_PASSWORD_INVALID`
- `400 AUTH_PASSWORD_UNCHANGED` 新旧密码相同
- `400 VALIDATION_ERROR`

> 注意：修改密码**不会**自动重新包装（rewrap）vault 的加密密钥信封。如果 vault 密钥是用登录密码派生/包裹的，客户端修改密码后应接着调用 `PUT /vault/key-envelope` 用新密码重新包装密钥，否则旧密码包装的密钥信封会与新登录密码不一致（但不影响其可用性，因为二者是独立的密钥体系，具体取决于客户端实现）。

---

## 3. 账号 Me

### 3.1 `GET /me` — 当前用户信息

需要 Authorization。

响应：

```json
{
  "user": { "id": "uuid", "email": "user@example.com" },
  "deviceId": "uuid"
}
```

### 3.2 `DELETE /me` — 注销账号（不可恢复）

需要 Authorization。

```json
{ "currentPassword": "...", "confirmation": "DELETE" }
```

`confirmation` 字段必须是字面量字符串 `"DELETE"`。会级联删除该账号的 vault、同步文档/历史；审计记录保留但脱敏关联。

响应：

```json
{ "deleted": true, "sessionsInvalidated": true }
```

错误码：`401 AUTH_CURRENT_PASSWORD_INVALID`、`409 ACCOUNT_DELETE_CONFLICT`（并发删除冲突，可重试）。

---

## 4. 设备 Devices

### 4.1 `GET /devices` — 设备列表

需要 Authorization。只返回未撤销的设备，按最近活跃时间倒序。

```json
{
  "items": [
    {
      "id": "uuid",
      "name": "我的 MacBook",
      "platform": "macos",
      "appVersion": "1.2.0",
      "createdAt": "2026-01-01T00:00:00.000Z",
      "lastSeenAt": "2026-08-02T04:00:00.000Z",
      "current": true
    }
  ]
}
```

`current: true` 标识当前发起请求所用的设备。

### 4.2 `PATCH /devices/{id}` — 重命名设备

需要 Authorization。

```json
{ "name": "新名字" }
```

响应：`{ "device": { "id": "uuid", "name": "新名字" } }`

错误码：`404 DEVICE_NOT_FOUND`（不存在、不属于当前用户或已撤销）

### 4.3 `DELETE /devices/{id}` — 撤销设备

需要 Authorization。撤销指定设备及其所有 refreshToken。

限制：**不能用来撤销当前设备**（`id === 当前 deviceId` 会报错，退出当前设备请用 `POST /auth/logout`）。

响应：`{ "ok": true }`

错误码：
- `400 DEVICE_CURRENT` 试图撤销当前设备
- `404 DEVICE_NOT_FOUND`

---

## 5. 密钥库 Vault

Vault 存放"用登录密码/恢复密钥包装过的对称密钥信封"，用于客户端本地解密 `sync/document`。**信封内容（密文）服务端不可见、也不解密**，只做存取。

### 5.1 `POST /vault` — 创建密钥库（每个账号仅一次）

需要 Authorization + `Idempotency-Key`。

请求体（`keyVersion` 首次创建固定为 `1`）：

```json
{
  "keyVersion": 1,
  "passwordWrappedKey": "base64",
  "passwordWrapNonce": "base64",
  "recoveryWrappedKey": "base64",
  "recoveryWrapNonce": "base64",
  "kdfSalt": "base64",
  "kdfParameters": {
    "algorithm": "argon2id",
    "memory": 19456,
    "iterations": 2,
    "parallelism": 1
  }
}
```

响应：`{ "id": "uuid", "keyVersion": 1 }`

错误码：`409 VAULT_EXISTS`（该账号已创建过，需用 `PUT /vault/key-envelope` 或 `POST /vault/rotate` 更新）。

### 5.2 `GET /vault/key-envelope` — 获取密钥信封

需要 Authorization。

```json
{
  "id": "uuid",
  "keyVersion": 1,
  "passwordWrappedKey": "base64",
  "passwordWrapNonce": "base64",
  "recoveryWrappedKey": "base64",
  "recoveryWrapNonce": "base64",
  "kdfSalt": "base64",
  "kdfParameters": { "algorithm": "argon2id", "memory": 19456, "iterations": 2, "parallelism": 1 }
}
```

错误码：`404 VAULT_NOT_FOUND`

### 5.3 `PUT /vault/key-envelope` — 用当前密码重新包装密钥（不改 keyVersion）

需要 Authorization。适用场景：**登录密码不变**，但需要重新加密信封（比如 KDF 参数升级）；或修改密码后需要用新密码重新包装。

```json
{
  "currentPassword": "...",
  "keyVersion": 1,
  "passwordWrappedKey": "base64",
  "passwordWrapNonce": "base64",
  "recoveryWrappedKey": "base64",
  "recoveryWrapNonce": "base64",
  "kdfSalt": "base64",
  "kdfParameters": { "...": "..." }
}
```

`keyVersion` 必须与云端当前一致（否则说明本地拿到的信封已经过期）。

响应：`{ "id": "uuid", "keyVersion": 1 }`

错误码：`401 AUTH_CURRENT_PASSWORD_INVALID`、`404 VAULT_NOT_FOUND`、`409 VAULT_KEY_VERSION_MISMATCH`

### 5.4 `POST /vault/rotate` — 密钥轮换（同时更新密钥信封 + 同步文档，keyVersion + 1）

需要 Authorization + `Idempotency-Key` + `If-Match: "revision-<当前revision>"`。

用于：更换加密密钥版本（例如怀疑密钥泄露、更换加密算法）。会**原子性地**：新 keyVersion 必须等于当前 `keyVersion + 1`；同时用新 key 重新加密并上传文档（revision + 1）；**清空所有历史版本**（旧 key 的历史记录不再可用，只保留新版本）。

```json
{
  "currentPassword": "...",
  "keyEnvelope": {
    "keyVersion": 2,
    "passwordWrappedKey": "base64",
    "...": "..."
  },
  "document": {
    "schemaVersion": 1,
    "keyVersion": 2,
    "algorithm": "AES-256-GCM",
    "nonce": "base64",
    "ciphertext": "base64",
    "ciphertextHash": "sha256 hex(64位)"
  }
}
```

约束：`document.keyVersion` 必须等于 `keyEnvelope.keyVersion`；`ciphertextHash` 必须是 `ciphertext` 原始字节的 sha256 十六进制摘要。

响应：`{ "id": "uuid", "keyVersion": 2, "revision": "1", "updatedAt": "ISO时间" }`

错误码：
- `401 AUTH_CURRENT_PASSWORD_INVALID`
- `404 VAULT_NOT_FOUND`
- `409 SYNC_REVISION_CONFLICT` / `409 SYNC_REVISION_LIMIT_REACHED`
- `409 VAULT_KEY_VERSION_MISMATCH`（新版本不是 当前+1，或 document/keyEnvelope 版本不一致）
- `413 SYNC_DOCUMENT_TOO_LARGE`
- `400 SYNC_DOCUMENT_INVALID`（哈希不匹配）
- `428 SYNC_REVISION_REQUIRED`

### 5.5 `DELETE /vault` — 删除密钥库（含全部同步数据）

需要 Authorization。

```json
{ "currentPassword": "..." }
```

响应：`{ "deleted": true, "vaultId": "uuid" }`

错误码：`401 AUTH_CURRENT_PASSWORD_INVALID`、`404 VAULT_NOT_FOUND`

---

## 6. 同步文档 Sync Document

一个账号只有一份"当前同步文档"（加密的完整配置快照），配合历史版本（见第 7 节）做回滚。

### 6.1 `HEAD /sync/document` — 探测云端是否有文档 / 拿 revision

需要 Authorization。无响应体，靠响应头判断：

```
ETag: "revision-3"
X-Sync-Revision: 3
X-Key-Version: 1
Last-Modified: <HTTP日期>
```

- `404 SYNC_DOCUMENT_NOT_FOUND`：**云端还没有任何同步文档**（新建 vault 后的正常状态），客户端应据此走"首次上传"流程：直接调用 `PUT /sync/document`，`If-Match: "revision-0"`。
- `404 VAULT_NOT_FOUND`：连 vault 都没建，需要先走 `POST /vault`。

这两个 404 语义不同，客户端务必用 `data.code` 区分，不要笼统地把 404 当错误弹给用户。

### 6.2 `GET /sync/document` — 拉取完整同步文档

需要 Authorization。

```json
{
  "revision": "3",
  "schemaVersion": 1,
  "keyVersion": 1,
  "algorithm": "AES-256-GCM",
  "nonce": "base64",
  "ciphertext": "base64",
  "ciphertextHash": "sha256 hex",
  "updatedByDeviceId": "uuid",
  "updatedAt": "2026-08-02T04:00:00.000Z"
}
```

同时带 `ETag` / `X-Sync-Revision` / `X-Key-Version` 响应头。

错误码：`404 VAULT_NOT_FOUND`、`404 SYNC_DOCUMENT_NOT_FOUND`

### 6.3 `PUT /sync/document` — 上传新版本文档

需要 Authorization + `Idempotency-Key` + `If-Match: "revision-<baseRevision>"`。

```json
{
  "schemaVersion": 1,
  "keyVersion": 1,
  "algorithm": "AES-256-GCM",
  "nonce": "base64",
  "ciphertext": "base64",
  "ciphertextHash": "sha256 hex(64位)"
}
```

- `keyVersion` 必须与云端 vault 当前 `keyVersion` 一致（否则说明本地密钥信封过期，需先 `GET /vault/key-envelope` 刷新）。
- `baseRevision`（从 `If-Match` 解析）必须等于云端当前 revision，否则 `409 SYNC_REVISION_CONFLICT`——客户端应重新 `GET` 最新文档、本地合并/解决冲突后再重试上传。
- 成功后旧版本会被写入历史（见第 7 节），超出保留条数（默认 20，管理员可调）的最旧历史会被清理。

响应：`{ "revision": "4", "updatedAt": "ISO时间" }`

错误码：
- `404 VAULT_NOT_FOUND`
- `400 SYNC_DOCUMENT_INVALID`（`ciphertextHash` 与 `ciphertext` 不匹配）
- `409 VAULT_KEY_VERSION_MISMATCH`
- `409 SYNC_REVISION_CONFLICT`
- `413 SYNC_DOCUMENT_TOO_LARGE`
- `428 SYNC_REVISION_REQUIRED`
- `400 IDEMPOTENCY_KEY_REQUIRED` / `409 IDEMPOTENCY_KEY_REUSED`
- `503 MAINTENANCE_MODE`

---

## 7. 同步历史 Sync Revisions

### 7.1 `GET /sync/revisions` — 历史版本列表（游标分页）

需要 Authorization。

查询参数：
- `limit`（可选，1~100，默认 20）
- `beforeRevision`（可选，游标，取上一页 `pagination.nextBeforeRevision`）

```json
{
  "items": [
    {
      "revision": "3",
      "schemaVersion": 1,
      "keyVersion": 1,
      "algorithm": "AES-256-GCM",
      "ciphertextHash": "sha256 hex",
      "createdByDevice": { "id": "uuid", "name": "MacBook", "platform": "macos", "appVersion": "1.2.0" },
      "createdAt": "2026-08-01T00:00:00.000Z"
    }
  ],
  "pagination": { "limit": 20, "hasMore": true, "nextBeforeRevision": "1" }
}
```

注意：列表项**不包含** `nonce` / `ciphertext`（需要具体内容需通过 restore 或另外的接口按需拉取，本仓库当前未提供"获取单条历史内容"的只读接口）。

### 7.2 `DELETE /sync/revisions` — 清空历史（保留当前文档）

需要 Authorization + `If-Match: "revision-<当前revision>"`。**不会**删除当前同步文档，只清空历史版本记录。

响应：`{ "ok": true, "currentRevision": "3", "deletedRevisions": 12 }`

错误码：`404 VAULT_NOT_FOUND`、`409 SYNC_REVISION_CONFLICT`、`428 SYNC_REVISION_REQUIRED`、`503 MAINTENANCE_MODE`

### 7.3 `POST /sync/revisions/{revision}/restore` — 回滚到指定历史版本

需要 Authorization + `Idempotency-Key` + `If-Match: "revision-<当前revision>"`。路径参数 `revision` 为目标历史版本号（字符串数字）。

行为：把目标历史版本的内容**作为新的一次提交**追加（revision + 1），不是简单地把 revision 指针指回去。回滚后目标版本必须使用与当前 vault 一致的 `keyVersion`（如果之后又做过密钥轮换，旧版本历史会失效）。

响应：`{ "revision": "5", "restoredFromRevision": "2", "updatedAt": "ISO时间" }`

错误码：
- `400 VALIDATION_ERROR`（`revision` 参数格式非法）
- `404 VAULT_NOT_FOUND`
- `404 SYNC_REVISION_NOT_FOUND`（目标历史版本不存在）
- `409 VAULT_KEY_VERSION_MISMATCH`（目标版本的 keyVersion 与当前不一致）
- `409 SYNC_REVISION_CONFLICT`
- `413 SYNC_DOCUMENT_TOO_LARGE`
- `428 SYNC_REVISION_REQUIRED`
- `503 MAINTENANCE_MODE`

---

## 8. 典型客户端流程

### 8.1 首次注册 + 建库 + 首次上传

1. `POST /auth/register` → 拿到 accessToken/refreshToken
2. 本地生成密钥、用密码派生 KDF 包装 → `POST /vault`（`Idempotency-Key: uuid1`）
3. 加密本地配置 → `PUT /sync/document`，`If-Match: "revision-0"`，`Idempotency-Key: uuid2`

### 8.2 老设备登录后同步

1. `POST /auth/login`
2. `HEAD /sync/document` 拿 `X-Sync-Revision`
   - 若 404 `VAULT_NOT_FOUND` → 提示用户还没建库，或走恢复流程
   - 若 404 `SYNC_DOCUMENT_NOT_FOUND` → 云端库已建但无文档，按"首次上传"处理
   - 否则对比本地 revision，不一致则 `GET /sync/document` 拉全量、解密合并
3. 有更新则 `PUT /sync/document` 携带最新 `If-Match`

### 8.3 accessToken 过期

拦截 401 且 `data.code === 'AUTH_TOKEN_EXPIRED'` → 用 refreshToken 调 `POST /auth/refresh` → 重试原请求。若 refresh 也返回 401（`AUTH_TOKEN_REUSED` / `AUTH_TOKEN_EXPIRED`）→ 清除本地 token，引导重新登录。

### 8.4 冲突处理（409 SYNC_REVISION_CONFLICT）

`PUT /sync/document`、`POST /vault/rotate`、`DELETE /sync/revisions`、`POST /sync/revisions/{revision}/restore` 都可能因为其他设备并发写入而冲突。客户端应：重新 `GET /sync/document` 拿最新内容和 revision → 本地合并 → 用新 revision 重试写操作。
