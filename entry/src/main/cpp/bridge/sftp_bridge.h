/**
 * SFTP NAPI 桥接 —— 任务 N14（DESIGN §7.4）。
 *
 * 调用模型与 N11 一致：方法同步受理、事件经所属会话的 stateTsfn 回报
 * （类型 sftpOpen / sftpList / sftpStat / sftpOpDone / sftpProgress /
 * sftpTransferDone，字段见 types/libssh_core/index.d.ts）。
 *
 * 本文件允许 include napi/hilog；纯逻辑在 cpp/ssh/sftp.h。
 */
#pragma once

#include "napi/native_api.h"

namespace sshclient {
namespace bridge {

void RegisterSftpBridge(napi_env env, napi_value exports);

} // namespace bridge
} // namespace sshclient
