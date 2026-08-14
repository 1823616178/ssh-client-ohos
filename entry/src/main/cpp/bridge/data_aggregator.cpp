#include "data_aggregator.h"

namespace sshclient {
namespace bridge {

DataAggregator::DataAggregator() : DataAggregator(Params{}) {}

DataAggregator::DataAggregator(Params params) : params_(params) {}

bool DataAggregator::feed(const void *data, size_t len, Clock::time_point now)
{
    if (data == nullptr || len == 0) {
        return false;
    }
    if (batch_.empty()) {
        firstByteAt_ = now;
    }
    batch_.append(static_cast<const char *>(data), len);
    return batch_.size() >= params_.flushBytes;
}

std::optional<int64_t> DataAggregator::msUntilTimeFlush(Clock::time_point now) const
{
    if (batch_.empty()) {
        return std::nullopt;
    }
    const auto dueAt = firstByteAt_ + std::chrono::milliseconds(params_.flushIntervalMs);
    return std::chrono::duration_cast<std::chrono::milliseconds>(dueAt - now).count();
}

std::string DataAggregator::takeBatch()
{
    std::string out;
    out.swap(batch_); // move 赋值不保证源为空，swap 保证复位
    return out;
}

} // namespace bridge
} // namespace sshclient
