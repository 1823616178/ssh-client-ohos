/**
 * U3 native ed25519 keygen 实现 —— OpenSSL EVP_PKEY + PEM PKCS#8 + OpenSSH 公钥行。
 * 不引入 napi / hilog（桥接层在 bridge/agent_bridge.cpp）。
 */

#include "keygen.h"

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>

#include <cstring>
#include <vector>

#include "auth.h" // secureZero

namespace sshclient {
namespace ssh {

namespace {

// SSH wire：uint32 大端长度 + 字节串
void appendWireString(std::string &out, const std::string &payload)
{
    const uint32_t len = static_cast<uint32_t>(payload.size());
    out.push_back(static_cast<char>((len >> 24) & 0xff));
    out.push_back(static_cast<char>((len >> 16) & 0xff));
    out.push_back(static_cast<char>((len >> 8) & 0xff));
    out.push_back(static_cast<char>(len & 0xff));
    out.append(payload);
}

std::string bioToSecureString(BIO *bio)
{
    if (bio == nullptr) {
        return "";
    }
    char *data = nullptr;
    const long len = BIO_get_mem_data(bio, &data);
    if (len <= 0 || data == nullptr) {
        return "";
    }
    return std::string(data, static_cast<size_t>(len));
}

} // namespace

std::string formatOpensshPublicKeyLine(const std::string &keyType,
                                       const unsigned char *publicKeyBytes,
                                       size_t publicKeyLen,
                                       const std::string &comment)
{
    if (keyType.empty() || publicKeyBytes == nullptr || publicKeyLen == 0) {
        return "";
    }
    std::string wire;
    wire.reserve(4 + keyType.size() + 4 + publicKeyLen);
    appendWireString(wire, keyType);
    appendWireString(wire, std::string(reinterpret_cast<const char *>(publicKeyBytes), publicKeyLen));

    const int wireLen = static_cast<int>(wire.size());
    std::string b64(static_cast<size_t>(wireLen + 2) / 3 * 4 + 4, '\0');
    const int encoded = EVP_EncodeBlock(reinterpret_cast<unsigned char *>(&b64[0]),
                                        reinterpret_cast<const unsigned char *>(wire.data()),
                                        wireLen);
    if (encoded <= 0) {
        return "";
    }
    b64.resize(static_cast<size_t>(encoded));
    std::string line = keyType + " " + b64;
    if (!comment.empty()) {
        line += " " + comment;
    }
    return line;
}

bool generateEd25519KeyPair(const std::string &comment, const std::string &passphrase,
                            GeneratedKeyPair *out)
{
    if (out == nullptr) {
        return false;
    }

    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, nullptr);
    if (ctx == nullptr) {
        return false;
    }
    EVP_PKEY *pkey = nullptr;
    bool ok = EVP_PKEY_keygen_init(ctx) == 1 && EVP_PKEY_keygen(ctx, &pkey) == 1;
    EVP_PKEY_CTX_free(ctx);
    if (!ok || pkey == nullptr) {
        return false;
    }

    unsigned char rawPub[32] = {0};
    size_t rawPubLen = sizeof(rawPub);
    if (EVP_PKEY_get_raw_public_key(pkey, rawPub, &rawPubLen) != 1 || rawPubLen != 32) {
        OPENSSL_cleanse(rawPub, sizeof(rawPub));
        EVP_PKEY_free(pkey);
        return false;
    }

    const std::string publicKeyLine =
        formatOpensshPublicKeyLine("ssh-ed25519", rawPub, rawPubLen, comment);
    OPENSSL_cleanse(rawPub, sizeof(rawPub));
    if (publicKeyLine.empty()) {
        EVP_PKEY_free(pkey);
        return false;
    }

    BIO *bio = BIO_new(BIO_s_mem());
    if (bio == nullptr) {
        EVP_PKEY_free(pkey);
        return false;
    }
    int writeOk = 0;
    if (passphrase.empty()) {
        writeOk = PEM_write_bio_PrivateKey(bio, pkey, nullptr, nullptr, 0, nullptr, nullptr);
    } else {
        writeOk = PEM_write_bio_PrivateKey(bio, pkey, EVP_aes_256_cbc(),
                                           reinterpret_cast<unsigned char *>(const_cast<char *>(passphrase.data())),
                                           static_cast<int>(passphrase.size()), nullptr, nullptr);
    }
    EVP_PKEY_free(pkey);
    if (writeOk != 1) {
        BIO_free(bio);
        return false;
    }

    std::string pem = bioToSecureString(bio);
    BIO_free(bio);
    if (pem.find("-----BEGIN") == std::string::npos) {
        secureZero(pem);
        return false;
    }

    GeneratedKeyPair result;
    result.privateKeyPem = pem;
    result.publicKeyLine = publicKeyLine;
    result.keyType = "ssh-ed25519";
    result.comment = comment;
    secureZero(pem);
    *out = std::move(result);
    return true;
}

} // namespace ssh
} // namespace sshclient
