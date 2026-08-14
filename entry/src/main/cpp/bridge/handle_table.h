/**
 * 句柄表 —— 任务 N11「NAPI 桥接层」的纯逻辑部分（宿主可测）。
 *
 * ArkTS 侧持有 uint64 句柄期间，对应原生对象存活；句柄语义：
 *   - 从 1 开始单调递增，**永不复用**（0 保留为「无效句柄」哨兵）；
 *     uint64 回绕需要 2^64 次会话，实际不可达，不额外处理；
 *   - 对象以 shared_ptr 存储：lookup 返回副本，延长对象寿命到调用方用完，
 *     擦除（erase）后正在使用旧句柄的调用方仍能安全收尾（引用计数语义）；
 *   - erase 幂等：重复关闭同一句柄返回 nullptr；
 *   - erase 只「摘除」不「销毁」：对象的实际回收顺序（先停线程再释放，
 *     见 SessionHandle 析构）由调用方在拿到 shared_ptr 后自行控制，
 *     表本身不关心 T 的析构语义。
 *
 * 线程安全：全部方法内部持锁，可任意线程并发调用。
 *
 * 纯逻辑代码：只依赖 C++ 标准库，禁止 include <napi/native_api.h> / <hilog/log.h>
 * （本目录仅 session_bridge 允许碰 napi；header-only 模板，无对应 .cpp）。
 */
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace sshclient {
namespace bridge {

template <typename T>
class HandleTable {
public:
    HandleTable() = default;
    ~HandleTable() = default;

    HandleTable(const HandleTable &) = delete;
    HandleTable &operator=(const HandleTable &) = delete;

    // 插入对象并返回新句柄（单调递增、不复用）
    uint64_t insert(std::shared_ptr<T> obj)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t handle = next_++;
        map_.emplace(handle, std::move(obj));
        return handle;
    }

    // 按句柄查找；不存在返回 nullptr。返回的 shared_ptr 副本保活到调用方释放
    std::shared_ptr<T> lookup(uint64_t handle) const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = map_.find(handle);
        return (it != map_.end()) ? it->second : nullptr;
    }

    // 摘除句柄并返回对象（调用方决定销毁时机与线程）；句柄不存在返回 nullptr
    std::shared_ptr<T> erase(uint64_t handle)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::shared_ptr<T> obj;
        auto it = map_.find(handle);
        if (it != map_.end()) {
            obj = std::move(it->second);
            map_.erase(it);
        }
        return obj;
    }

    // 摘除全部句柄（env 销毁/模块卸载时关闭所有会话）；
    // 返回顺序不保证，调用方负责逐个按正确顺序回收
    std::vector<std::shared_ptr<T>> eraseAll()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::shared_ptr<T>> out;
        out.reserve(map_.size());
        for (auto &kv : map_) {
            out.push_back(std::move(kv.second));
        }
        map_.clear();
        return out;
    }

    size_t size() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return map_.size();
    }

    bool contains(uint64_t handle) const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return map_.find(handle) != map_.end();
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<uint64_t, std::shared_ptr<T>> map_;
    uint64_t next_ = 1; // 句柄从 1 开始，0 作无效哨兵
};

} // namespace bridge
} // namespace sshclient
