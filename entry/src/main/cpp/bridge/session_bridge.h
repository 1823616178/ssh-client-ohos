/**
 * NAPI 会话桥接 —— 任务 N11「NAPI 桥接层」。
 *
 * 对 ArkTS 暴露的统一调用模型（与 types/libssh_core/index.d.ts 一致）：
 *   - 一切方法「同步受理、立即返回」：返回 bool/number 仅表示**受理**与否
 *     （句柄无效、状态不允许、背压拒收等返回 false/0）；
 *   - 一切异步结果经**事件**回报：createSession 时注册单个 onEvent 回调，
 *     事件对象恒有 type 字段，其余字段随类型而定
 *     （stateChange/hostKey/authResult/channelOpen/channelData/channelClose/error）。
 *
 * 线程模型（DESIGN §2.1 的落地）：
 *   - ArkTS 主线程调本层方法 → post 进每会话的 SessionThread 事件循环执行；
 *   - 循环线程产生的事件经 napi_threadsafe_function（TSFN）切回 ArkTS 线程；
 *   - 每会话两条 TSFN（createSession 时创建）：
 *       stateTsfn：状态类事件（stateChange/hostKey/authResult/channelOpen/
 *                  channelClose/error）——unlimited 队列 + non-blocking 入队，
 *                  状态事件绝不丢；
 *       dataTsfn：channelData——限量队列（256 批 ≈ 4 MiB）+ non-blocking 入队 +
 *                  DataAggregator 聚合（16 KiB / 8 ms），满则丢弃并累计计数，
 *                  丢弃边沿经 stateTsfn 补发 error 事件（code=dataQueueFull）；
 *     non-blocking 保证 native 循环线程永不被 ArkTS 线程堵死。
 *   - channelData 走独立队列的已知代价：最后的 channelData 与 channelClose 之间
 *     不保证到达顺序（两条队列各自 FIFO、互相无序）。exec 类消费方应以
 *     channelClose 为结束标志、期间持续累积 channelData。T3 零拷贝网格落地后
 *     终端字节流改走快照路径，本路径仅保留给 exec/SCP 类低吞吐通道
 *     （折中依据见 data_aggregator.h 头注）。
 *
 * 生命周期：
 *   - 句柄表（handle_table.h）uint64 单调递增不复用；ArkTS 持有句柄期间
 *     SessionHandle 存活（shared_ptr 引用计数语义）；
 *   - closeSession 幂等：摘表后立即返回，实际回收在独立 teardown 线程做
 *     （关 TSFN 入口 → session->close 等终态 → 停线程 → 析构通道/会话 →
 *     释放 TSFN），不阻塞 ArkTS 主线程；
 *   - napi_env 销毁（napi_add_env_cleanup_hook）：全部会话同步优雅停掉，
 *     并等待进行中的 closeSession teardown 收尾；
 *   - TSFN 上下文（TsfnBridge）由 TSFN finalize 回调释放；inFlight 集合跟踪
 *     已入队未消费的堆事件，abort/env 销毁路径下由 finalize 统一回收，不泄漏。
 *
 * 凭据安全：密码/私钥/短语从 napi 读入 std::string 后立即交给 SshSession
 * （受理即复制并 secureZero(OPENSSL_cleanse) 调用方副本，见 auth.h）；
 * 未受理时本层自行 secureZero。边界（注释即约定）：ArkTS 运行时持有的原始
 * string/ArrayBuffer 副本不在 native 掌控内，无法清零——上层应尽量缩短
 * 其在 ArkTS 侧的驻留时间（如局部变量、用完置空）。
 *
 * 主机密钥 TOFU：bridge 层的 HostKeyCallback 按任务边界「接受并上报」——
 * 立即返回 kAccept 并将指纹信息经 hostKey 事件上报（N7 回调必须快速返回，
 * 不得阻塞循环线程等待 UI）；「首连弹窗 → 入库 → 指纹变更拒绝」的 TOFU
 * 确认编排留给上层（C4/known_hosts 方向）在拿到事件后自行实现，需要拒绝时
 * 上层 closeSession 后重连。
 *
 * N12 keepalive 与重连（任务约定：重连编排在 ArkTS 侧，native 只做三件套）：
 *   - setKeepalive(handle, intervalSec, maxMisses)：会话 keepalive 配置
 *     （须在 connect 前调用；静默黑洞判定在 ssh/session.cpp，触发后走
 *     stateChange → disconnected，errorCode=keepalive_timeout）；
 *   - stateChange 进入终态（disconnected/error/closed）时附 reconnectHint
 *     （是否值得自动重连，ssh::isAutoReconnectable）与 errorCode；
 *   - setReconnectPolicy(handle, delaysSec, maxAttempts) 设置每会话退避策略，
 *     nextReconnectDelaySec(handle, attempt) 查询第 attempt 次重连的建议延迟
 *     （-1 = 已达上限放弃）；倒计时与尝试计数由 ArkTS 侧据事件自行驱动。
 *
 * 本目录（bridge/）与 napi_init.cpp 是唯二允许 include napi/hilog 头的位置；
 * ssh/ io/ term/ crypto/ 保持纯净。napi 头经 OHOS 扩展头 napi/native_api.h
 * 引入（TSFN、env cleanup hook 等在该头声明）。
 */
#pragma once

#include "napi/native_api.h"

namespace sshclient {
namespace bridge {

// 向 exports 注册全部会话桥接方法，并挂 env 销毁清理钩子。
// 由 napi_init.cpp 的模块 Init 调用；重复注册（多 env）各自独立。
void RegisterSessionBridge(napi_env env, napi_value exports);

} // namespace bridge
} // namespace sshclient
