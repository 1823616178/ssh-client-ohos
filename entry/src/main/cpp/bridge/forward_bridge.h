/**
 * 端口转发 NAPI 桥接 —— 任务 N15/N16（DESIGN §7.3）。
 *
 * 调用模型与 N11/N14 一致：方法同步受理、事件经所属会话的 TSFN 回报：
 *   - openDirectTcpip(session, host, port) → forward 句柄；结果经 forwardOpen
 *   - forwardWrite / forwardClose：数据面（背压整次拒收）
 *   - remoteForwardListen(session, bind, port) → listen 句柄；结果经 forwardListen
 *   - remoteForwardCancel(listen)
 * 入站远程连接经 forwardAccept 上抛新数据通道句柄（与 direct-tcpip 同一数据面）。
 *
 * N16 ProxyJump：native 只提供规划纯函数与设计注记（见 ssh/forward.h）；
 * 多级会话串联尚未打通（SshSession 仅支持真实 TCP fd）。ArkTS 侧编排注释
 * 见 SessionManager 与 service/portforward/ProxyJump.ets。
 *
 * 本文件允许 include napi/hilog；纯逻辑在 cpp/ssh/forward.h。
 */
#pragma once

#include "napi/native_api.h"

namespace sshclient {
namespace bridge {

void RegisterForwardBridge(napi_env env, napi_value exports);

} // namespace bridge
} // namespace sshclient
