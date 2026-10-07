# Q1 补充：多算法 SSH 集成测试环境（可选）

> **主路径**：WSL 免 root sshd + `scripts/run-native-tests.sh` + `scripts/ci-local.sh` 阶段 3，
> 已覆盖连接/认证/shell/大数据量收发（TASKS Q1 的 CI 部分）。
>
> 本目录提供 **Docker 多算法 sshd** 的可选环境，供算法协商矩阵与私有 CI 复用。
> **无 Docker 时 SKIP，不红门禁。**

## 已知限制（x86_64 模拟器）

| 项 | 状态 |
|---|---|
| `TARGET=ohos-x86_64` 交叉编译 | ✅ 可编（`run-native-tests.sh` 看护 OHOS 工具链） |
| 在 WSL/Linux **直接执行** x86_64-linux-ohos 二进制 | ❌ **blocked**：依赖 OHOS musl 运行时 |
| x86_64 **模拟器**上跑 gtest / 集成用例 | ❌ **blocked on device/SDK**：需 hdc 投递 + 模拟器镜像内执行，当前无稳定 SDK 模拟器流水线 |
| Docker sshd 供 **宿主机** native 测试连 `127.0.0.1:2222` | ✅ 可用（本目录） |

结论：x86_64 模拟器用例在拿到可用 device/SDK 前保持 open；CI 侧以宿主机 clang gtest + 可选 Docker sshd 为准。

## 一键启停

```bash
# 启动（无 docker → SKIP 退出 0）
bash scripts/sshd-multi/up.sh

# 启动并等待端口就绪（ci-local CI_DOCKER_SSHD 使用）
bash scripts/sshd-multi/up.sh --wait

bash scripts/sshd-multi/up.sh status
bash scripts/sshd-multi/up.sh down
```

或直接 compose：

```bash
cd scripts/sshd-multi
docker compose up -d
# 宿主机 native 测试：
SSH_TEST_HOST=127.0.0.1 SSH_TEST_PORT=2222 \
  SSH_TEST_USER=test SSH_TEST_PASSWORD=testpass \
  ../../scripts/run-native-tests.sh
```

## ci-local 可选阶段

```bash
# 启用 Q1 Docker sshd 阶段（无 docker 时 SKIP 不失败）
CI_DOCKER_SSHD=1 bash scripts/ci-local.sh

# 启用后若还要把 native 测试指到 :2222（需 WSL 能连宿主 docker 端口）
CI_DOCKER_SSHD=1 CI_DOCKER_SSHD_NATIVE=1 bash scripts/ci-local.sh
```

## docker-compose

见 `docker-compose.yml`：`linuxserver/openssh-server`，挂载本地 `sshd_config`（+ 可选 `keys/`）。
镜像名可按 CI 环境替换；默认仅作本地/私有 CI 桩，不强制公网拉取。

## sshd 多算法配置要点

见 `sshd_config`：显式打开 `ssh-ed25519` / `rsa-sha2-256` / `rsa-sha2-512` /
`ecdsa-sha2-nistp256` 与 `aes256-gcm@openssh.com` 等，便于 N8/N9 认证矩阵与
算法协商失败用例。

## 备用：docker-sshd.sh（本地构建镜像）

`scripts/docker-sshd.sh up|down|status` 使用 `scripts/docker-sshd/Dockerfile` 本地构建，
无 docker 同样 SKIP 退出 0。
