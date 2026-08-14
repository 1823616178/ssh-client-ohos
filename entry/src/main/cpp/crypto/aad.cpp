#include "aad.hpp"

namespace sshclient {
namespace crypto {

std::string EncodeAad(std::string_view domain, const std::vector<std::string_view> &fields)
{
    // 预估容量：domain + 每字段 "|" + 至多 20 位长度 + ":" + 值
    size_t capacity = domain.size();
    for (const auto field : fields) {
        capacity += field.size() + 22;
    }

    std::string out;
    out.reserve(capacity);
    out.append(domain);
    for (const auto field : fields) {
        out.push_back('|');
        // string_view::size 即 UTF-8 字节数，正是 §6.2 要求的长度语义
        out.append(std::to_string(field.size()));
        out.push_back(':');
        out.append(field);
    }
    return out;
}

std::string SyncDocumentAad(std::string_view vaultId, std::string_view schemaVersion,
                            std::string_view keyVersion)
{
    return EncodeAad(kAadDomainSyncDocument, {vaultId, schemaVersion, keyVersion});
}

std::string VaultKeyPasswordAad(std::string_view keyVersion)
{
    return EncodeAad(kAadDomainVaultKeyPassword, {keyVersion});
}

std::string VaultKeyRecoveryAad(std::string_view keyVersion)
{
    return EncodeAad(kAadDomainVaultKeyRecovery, {keyVersion});
}

} // namespace crypto
} // namespace sshclient
