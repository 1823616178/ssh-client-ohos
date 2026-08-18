/**
 * 保险库 NAPI（S2 高层操作的桥）。密钥只留在 native 句柄表，ArkTS 不持有 vault key。
 */
#pragma once

#include "napi/native_api.h"

namespace sshclient {
namespace bridge {

void RegisterVaultBridge(napi_env env, napi_value exports);

} // namespace bridge
} // namespace sshclient
