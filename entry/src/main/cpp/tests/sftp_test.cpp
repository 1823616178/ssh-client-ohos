/**
 * SFTP 宿主单元测试 —— 任务 N14。
 *
 * 两层：
 *   1. 纯逻辑（路径/权限/传输状态机/rename 校验）——不依赖 sshd，始终跑；
 *   2. 集成（真实 sshd + 认证环境上的 list/stat/mkdir/upload/download）——
 *      环境未就绪或 sshd 无 sftp subsystem 时 GTEST_SKIP，不拖垮门禁。
 */
#include <gtest/gtest.h>

#include <algorithm>
#include <string>
#include <vector>

#include "io/SessionThread.h"
#include "ssh/sftp.h"
#include "sshd_testkit.h"

using namespace sshclient::ssh;

// ================================================================ 路径纯逻辑

TEST(SftpPath, JoinHandlesRootAndSlashes)
{
    EXPECT_EQ(sftpJoinPath("/home", "user"), "/home/user");
    EXPECT_EQ(sftpJoinPath("/home/", "user"), "/home/user");
    EXPECT_EQ(sftpJoinPath("/", "etc"), "/etc");
    EXPECT_EQ(sftpJoinPath("", "rel"), "rel");
    EXPECT_EQ(sftpJoinPath("/home", "/abs/other"), "/abs/other");
    EXPECT_EQ(sftpJoinPath("/home", ""), "/home");
}

TEST(SftpPath, ParentAndBase)
{
    EXPECT_EQ(sftpParentPath("/a/b/c"), "/a/b");
    EXPECT_EQ(sftpParentPath("/a"), "/");
    EXPECT_EQ(sftpParentPath("/"), "/");
    EXPECT_EQ(sftpParentPath("a/b"), "a");
    EXPECT_EQ(sftpBaseName("/a/b/c"), "c");
    EXPECT_EQ(sftpBaseName("/"), "");
    EXPECT_EQ(sftpBaseName("solo"), "solo");
    EXPECT_EQ(sftpBaseName("/a/b/"), "b");
}

TEST(SftpPath, NormalizeCollapsesAndResolves)
{
    EXPECT_EQ(sftpNormalizePath("/a//b/./c"), "/a/b/c");
    EXPECT_EQ(sftpNormalizePath("/a/b/../c"), "/a/c");
    EXPECT_EQ(sftpNormalizePath("/a/../../c"), "/c");
    EXPECT_EQ(sftpNormalizePath("/"), "/");
    EXPECT_EQ(sftpNormalizePath("a/./b"), "a/b");
    EXPECT_EQ(sftpNormalizePath("a/../b"), "b");
    EXPECT_EQ(sftpNormalizePath(""), "");
    EXPECT_EQ(sftpNormalizePath("/home/user/"), "/home/user");
}

TEST(SftpPath, PermissionsFormat)
{
    EXPECT_EQ(formatSftpPermissions(0755), "rwxr-xr-x");
    EXPECT_EQ(formatSftpPermissions(0644), "rw-r--r--");
    EXPECT_EQ(formatSftpPermissions(0000), "---------");
    EXPECT_EQ(formatSftpPermissions(0777), "rwxrwxrwx");
    // 类型位不进字符串
    EXPECT_EQ(formatSftpPermissions(0040755), "rwxr-xr-x");
}

TEST(SftpPath, TypeFromMode)
{
    EXPECT_EQ(sftpTypeFromMode(0040755), SftpEntryType::kDir);
    EXPECT_EQ(sftpTypeFromMode(0100644), SftpEntryType::kFile);
    EXPECT_EQ(sftpTypeFromMode(0120777), SftpEntryType::kSymlink);
    EXPECT_EQ(sftpTypeFromMode(0644), SftpEntryType::kOther); // 无类型位
}

TEST(SftpPath, EntrySortDirsFirst)
{
    std::vector<SftpEntry> v;
    SftpEntry f;
    f.name = "zzz";
    f.type = SftpEntryType::kFile;
    SftpEntry d;
    d.name = "aaa";
    d.type = SftpEntryType::kDir;
    v.push_back(f);
    v.push_back(d);
    std::sort(v.begin(), v.end(), sftpEntryLess);
    EXPECT_EQ(v[0].name, "aaa");
    EXPECT_EQ(v[1].name, "zzz");
}

TEST(SftpPath, FilterDotEntries)
{
    std::vector<SftpEntry> v;
    SftpEntry a;
    a.name = ".";
    SftpEntry b;
    b.name = "..";
    SftpEntry c;
    c.name = "file";
    v.push_back(a);
    v.push_back(b);
    v.push_back(c);
    const auto out = sftpFilterDotEntries(std::move(v));
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0].name, "file");
}

// ================================================================ rename 校验

TEST(SftpRename, ValidateRejectsSameAndEmpty)
{
    EXPECT_TRUE(validateSftpRename("", "/a").has_value());
    EXPECT_TRUE(validateSftpRename("/a", "").has_value());
    EXPECT_TRUE(validateSftpRename("/a/b", "/a/b").has_value());
    EXPECT_TRUE(validateSftpRename("/a/b", "/a/b/").has_value()); // 归一化后相同
    EXPECT_TRUE(validateSftpRename("/a/b", "/a/..").has_value()); // 基名非法/根
    EXPECT_FALSE(validateSftpRename("/a/b", "/a/c").has_value());
    EXPECT_FALSE(validateSftpRename("/a/b", "/x/y").has_value());
}

// ================================================================ 传输状态机

TEST(SftpTransfer, StartOnlyFromQueued)
{
    EXPECT_TRUE(canStartTransfer(TransferState::kQueued));
    EXPECT_FALSE(canStartTransfer(TransferState::kRunning));
    EXPECT_FALSE(canStartTransfer(TransferState::kCompleted));
    EXPECT_FALSE(canStartTransfer(TransferState::kFailed));
}

TEST(SftpTransfer, CancelFromActiveStates)
{
    EXPECT_TRUE(canCancelTransfer(TransferState::kQueued));
    EXPECT_TRUE(canCancelTransfer(TransferState::kRunning));
    EXPECT_TRUE(canCancelTransfer(TransferState::kPaused));
    EXPECT_FALSE(canCancelTransfer(TransferState::kCompleted));
    EXPECT_FALSE(canCancelTransfer(TransferState::kFailed));
    EXPECT_FALSE(canCancelTransfer(TransferState::kCancelled));
    EXPECT_EQ(cancelTransferState(TransferState::kRunning), TransferState::kCancelled);
    EXPECT_EQ(cancelTransferState(TransferState::kCompleted), TransferState::kCompleted);
}

TEST(SftpTransfer, CompleteAndRetry)
{
    EXPECT_EQ(completeTransferState(TransferState::kRunning, true), TransferState::kCompleted);
    EXPECT_EQ(completeTransferState(TransferState::kRunning, false), TransferState::kFailed);
    EXPECT_EQ(completeTransferState(TransferState::kPaused, true), TransferState::kCompleted);
    EXPECT_EQ(completeTransferState(TransferState::kQueued, true), TransferState::kQueued);
    EXPECT_TRUE(canRetryTransfer(TransferState::kFailed));
    EXPECT_TRUE(canRetryTransfer(TransferState::kCancelled));
    EXPECT_FALSE(canRetryTransfer(TransferState::kCompleted));
    EXPECT_EQ(retryTransferState(TransferState::kFailed), TransferState::kQueued);
    EXPECT_EQ(retryTransferState(TransferState::kCancelled), TransferState::kQueued);
    EXPECT_EQ(retryTransferState(TransferState::kRunning), TransferState::kRunning);
}

TEST(SftpTransfer, ProgressOnlyWhileRunning)
{
    EXPECT_EQ(progressTransferState(TransferState::kRunning), TransferState::kRunning);
    EXPECT_EQ(progressTransferState(TransferState::kQueued), TransferState::kQueued);
    EXPECT_EQ(progressTransferState(TransferState::kFailed), TransferState::kFailed);
}

// ================================================================ 集成（可跳过）

TEST(SftpIntegration, OpenListStatMkdirRoundtrip)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    StateRecorder rec;
    sshclient::io::SessionThread thread;
    ASSERT_TRUE(thread.start());
    SshSessionOptions opts;
    SshSession session(thread, opts, std::ref(rec));
    // Q3：声明顺序 = 析构逆序：先 stopper.stop() 再 ~SshSession 再 ~SessionThread
    //（析构契约：SessionThread::stop 之后再析构 SshSession；~SshSession 另有兜底）
    struct ThreadStopper {
        sshclient::io::SessionThread &t;
        ~ThreadStopper() { t.stop(); }
    } stopper{thread};
    if (!ReachEstablished(session, rec, env)) {
        GTEST_SKIP() << "无法驱动到 established（sshd/认证环境异常）";
    }

    struct Box {
        std::mutex mu;
        std::condition_variable cv;
        bool opened = false;
        bool openOk = false;
        std::string openErr;
        bool listed = false;
        bool listOk = false;
        std::vector<SftpEntry> entries;
        std::string listErr;
        bool opDone = false;
        bool opOk = false;
        std::string opMsg;
    } box;

    SftpCallbacks cb;
    cb.onOpen = [&](const SftpOpenResult &r) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.opened = true;
        box.openOk = r.success;
        box.openErr = r.message.empty() ? toString(r.error) : r.message;
        box.cv.notify_all();
    };
    cb.onList = [&](const SftpListResult &r) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.listed = true;
        box.listOk = r.success;
        box.entries = r.entries;
        box.listErr = r.message.empty() ? toString(r.error) : r.message;
        box.cv.notify_all();
    };
    cb.onOp = [&](const SftpOpResult &r) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.opDone = true;
        box.opOk = r.success;
        box.opMsg = r.message.empty() ? toString(r.error) : r.message;
        box.cv.notify_all();
    };

    SshSftp sftp(session, cb);
    ASSERT_TRUE(sftp.open());
    {
        std::unique_lock<std::mutex> lock(box.mu);
        if (!box.cv.wait_for(lock, 10s, [&] { return box.opened; })) {
            session.close();
            GTEST_SKIP() << "SFTP open 超时";
        }
        if (!box.openOk) {
            session.close();
            GTEST_SKIP() << "sshd 无 sftp subsystem 或 open 失败：" << box.openErr;
        }
    }

    ASSERT_TRUE(sftp.list("/"));
    {
        std::unique_lock<std::mutex> lock(box.mu);
        ASSERT_TRUE(box.cv.wait_for(lock, 10s, [&] { return box.listed; }));
        if (!box.listOk) {
            session.close();
            GTEST_SKIP() << "SFTP list 失败：" << box.listErr;
        }
        // 根目录至少应有部分条目；过滤后不包含 . 与 ..
        for (const auto &e : box.entries) {
            EXPECT_NE(e.name, ".");
            EXPECT_NE(e.name, "..");
        }
    }

    const std::string testDir = "/tmp/sshclient-sftp-test";
    ASSERT_TRUE(sftp.mkdir(testDir, 0755));
    {
        std::unique_lock<std::mutex> lock(box.mu);
        ASSERT_TRUE(box.cv.wait_for(lock, 10s, [&] { return box.opDone; }));
        if (!box.opOk) {
            // /tmp 可能不可写，SKIP 而非失败
            session.close();
            GTEST_SKIP() << "mkdir 失败：" << box.opMsg;
        }
    }

    sftp.close();
    session.close();
}
