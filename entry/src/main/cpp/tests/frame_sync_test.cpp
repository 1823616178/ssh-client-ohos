/**
 * FrameSync / CellGrid 存储保活单测 —— 任务 T3 验收的宿主可测部分。
 *
 * 覆盖（帧协议与所有权语义；napi 胶水路径由交叉编译 + 真机验证）：
 *   CellGrid 存储所有权（grid.h「存储所有权」）：
 *     - cellsStorage() 与当前网格共享同一存储（内容随写入更新——零拷贝前提）
 *     - resize 换入新存储后，旧 storage 副本仍存活且内容冻结（旧尺寸旧内容）
 *     - resize 后新写入只落新存储，旧 storage 不再变化
 *     - 拷贝构造/赋值为深拷贝（不共享存储，互不联动）
 *   FrameSync 发布槽：
 *     - publish 拷出 revision/几何/光标/dirty/回滚窗口的一致性
 *     - snapshot 是「发布时刻」切片：publish 后的写入更新共享网格内容
 *       （storage 同一 vector），但 dirty 位图与 revision 快照不变
 *     - endFrame：revision 一致 → 清脏并重发布（返回 true）；
 *       期间又 feed → 不一致 → 保留脏位（返回 false），下帧仍拿得到
 *     - resize 后 publish 换入新 storage；旧帧快照的 storage 仍可读
 *       （「native 释放后 ArkTS 再读不崩」的纯逻辑根据）
 */
#include <gtest/gtest.h>

#include <cstring>
#include <memory>
#include <vector>

#include "term/frame_sync.h"
#include "term/vterm_screen.h"

using sshclient::term::Cell;
using sshclient::term::CellGrid;
using sshclient::term::FrameSync;
using sshclient::term::GridFrame;
using sshclient::term::MouseMode;
using sshclient::term::VtermBridge;

namespace {

constexpr uint32_t kFg = 0xFFE5E5E5u;
constexpr uint32_t kBg = 0xFF000000u;

uint32_t codepointAt(const std::shared_ptr<const std::vector<Cell>> &storage, int cols,
                     int row, int col)
{
    return (*storage)[static_cast<size_t>(row) * static_cast<size_t>(cols) +
                      static_cast<size_t>(col)]
        .codepoint;
}

} // namespace

// ---- CellGrid 存储所有权（T3 生命周期保护的纯逻辑核心）----

TEST(GridStorageTest, CellsStorageSharesLiveVector)
{
    CellGrid g(4, 2, kFg, kBg);
    auto storage = g.cellsStorage();
    ASSERT_TRUE(storage != nullptr);
    EXPECT_EQ(storage->size(), 8u);

    // 写入经 putCell 落进同一 vector：storage 副本立刻可见（零拷贝语义）
    Cell c{};
    c.codepoint = u'A';
    g.putCell(1, 2, c);
    EXPECT_EQ(codepointAt(storage, 4, 1, 2), u'A');
    EXPECT_EQ(g.data(), reinterpret_cast<const uint8_t *>(storage->data()));
    EXPECT_EQ(g.byteSize(), storage->size() * sizeof(Cell));
}

TEST(GridStorageTest, OldStorageSurvivesResizeWithFrozenContent)
{
    CellGrid g(4, 2, kFg, kBg);
    Cell c{};
    c.codepoint = u'Z';
    g.putCell(0, 3, c);
    auto oldStorage = g.cellsStorage();

    g.resize(10, 5); // 换入新存储

    // 旧存储仍存活且内容冻结（验收「native 释放后再读不崩」的根据）
    ASSERT_EQ(oldStorage->size(), 8u);
    EXPECT_EQ(codepointAt(oldStorage, 4, 0, 3), u'Z');

    // 新网格是独立的新存储
    EXPECT_EQ(g.cellsStorage()->size(), 50u);
    EXPECT_NE(g.cellsStorage(), oldStorage);

    // 新写入只落新存储：旧存储内容不再变化
    Cell d{};
    d.codepoint = u'B';
    g.putCell(0, 0, d);
    EXPECT_EQ(codepointAt(oldStorage, 4, 0, 0), 0u); // 旧网格 (0,0) 原本为空
}

TEST(GridStorageTest, CopyIsDeepCopyNotSharingStorage)
{
    CellGrid g(4, 2, kFg, kBg);
    Cell c{};
    c.codepoint = u'Q';
    g.putCell(1, 1, c);

    CellGrid copy(g); // 拷贝构造：深拷贝
    EXPECT_NE(copy.cellsStorage(), g.cellsStorage());
    EXPECT_EQ(codepointAt(copy.cellsStorage(), 4, 1, 1), u'Q');

    Cell c2{};
    c2.codepoint = u'R';
    copy.putCell(1, 1, c2); // 改副本不影响原网格
    EXPECT_EQ(codepointAt(g.cellsStorage(), 4, 1, 1), u'Q');

    CellGrid assigned(2, 2, kFg, kBg);
    assigned = g; // 拷贝赋值：深拷贝
    EXPECT_NE(assigned.cellsStorage(), g.cellsStorage());
    EXPECT_EQ(codepointAt(assigned.cellsStorage(), 4, 1, 1), u'Q');
    EXPECT_EQ(assigned.revision(), g.revision());
}

// ---- FrameSync 发布槽 ----

TEST(FrameSyncTest, PublishCopiesConsistentSnapshot)
{
    VtermBridge b(10, 3);
    b.feed("abc\r\nxy");
    FrameSync sync;
    sync.publish(b);

    const GridFrame f = sync.snapshot();
    ASSERT_TRUE(f.storage != nullptr);
    EXPECT_EQ(f.storage->size(), 30u);
    EXPECT_EQ(f.revision, b.grid().revision());
    EXPECT_EQ(f.cols, 10);
    EXPECT_EQ(f.rows, 3);
    EXPECT_EQ(f.cursorRow, b.cursorRow());
    EXPECT_EQ(f.cursorCol, b.cursorCol());
    EXPECT_TRUE(f.cursorVisible);
    EXPECT_FALSE(f.altScreen);
    EXPECT_EQ(f.mouseMode, MouseMode::kNone);
    EXPECT_EQ(f.bellCount, 0u);
    EXPECT_EQ(f.dirty.size(), b.grid().dirtyBitmap().size());
    // 内容经 storage 可见（零拷贝语义）
    EXPECT_EQ(codepointAt(f.storage, 10, 0, 0), u'a');
    EXPECT_EQ(codepointAt(f.storage, 10, 1, 0), u'x');
    // 已发布 revision 镜像
    EXPECT_EQ(sync.publishedRevision(), b.grid().revision());
}

TEST(FrameSyncTest, SnapshotIsPublishTimeSlice)
{
    VtermBridge b(10, 3);
    b.feed("ab");
    FrameSync sync;
    sync.publish(b);
    const GridFrame before = sync.snapshot();
    const uint64_t revBefore = before.revision;
    const std::vector<uint64_t> dirtyBefore = before.dirty;

    b.feed("cd"); // publish 后的写入：网格共享存储内容更新，但快照标量不动

    EXPECT_EQ(before.revision, revBefore);
    EXPECT_EQ(before.dirty, dirtyBefore); // dirty 是拷出的 vector，不随后续写入变化
    // 网格内容共享同一 storage：新写入对持有旧快照的读者可见（帧内并发读的
    // 既定语义——帧有效性由 endFrame 的 revision 比对兜底，见 frame_sync.h）
    EXPECT_EQ(codepointAt(before.storage, 10, 0, 2), u'c');
    // 重新发布后快照才前进
    sync.publish(b);
    EXPECT_EQ(sync.snapshot().revision, b.grid().revision());
    EXPECT_EQ(sync.publishedRevision(), b.grid().revision());
}

TEST(FrameSyncTest, EndFrameClearsDirtyOnlyWhenRevisionMatches)
{
    VtermBridge b(10, 3);
    FrameSync sync;
    b.feed("ab");
    sync.publish(b);
    const uint64_t rev1 = sync.snapshot().revision;

    // 一致：清脏并重发布
    EXPECT_TRUE(sync.endFrame(b, rev1));
    EXPECT_EQ(sync.snapshot().revision, rev1);
    for (uint64_t w : sync.snapshot().dirty) {
        EXPECT_EQ(w, 0u);
    }

    // 帧内又有写入：不清，脏位保留（自愈路径）
    b.feed("\r\nQ");
    sync.publish(b);
    const uint64_t rev2 = sync.snapshot().revision;
    ASSERT_NE(rev2, rev1);
    EXPECT_FALSE(sync.endFrame(b, rev1)); // 过期 revision：拒绝清脏
    bool anyDirty = false;
    for (uint64_t w : sync.snapshot().dirty) {
        anyDirty = anyDirty || (w != 0u);
    }
    EXPECT_TRUE(anyDirty);

    // 用新 revision 重试：清脏成功
    EXPECT_TRUE(sync.endFrame(b, rev2));
}

TEST(FrameSyncTest, OldFrameStorageSurvivesResize)
{
    VtermBridge b(10, 3);
    b.feed("hello");
    FrameSync sync;
    sync.publish(b);
    const GridFrame oldFrame = sync.snapshot();
    ASSERT_EQ(oldFrame.cols, 10);

    b.resize(20, 5); // 网格换入新存储
    sync.publish(b);

    // 旧帧快照的 storage 仍存活、内容冻结为旧尺寸（ArkTS 持有旧 external
    // buffer 的对应场景：以旧帧的 cols/rows 解释，读到旧内容，不崩）
    EXPECT_EQ(codepointAt(oldFrame.storage, 10, 0, 0), u'h');
    EXPECT_EQ(oldFrame.storage->size(), 30u);

    const GridFrame newFrame = sync.snapshot();
    EXPECT_EQ(newFrame.cols, 20);
    EXPECT_EQ(newFrame.rows, 5);
    EXPECT_EQ(newFrame.storage->size(), 100u);
    EXPECT_NE(newFrame.storage, oldFrame.storage);
}

TEST(FrameSyncTest, ScrollbackWindowPublishedInSnapshot)
{
    VtermBridge b(10, 3);
    // 4 行输出挤 3 行屏：第 1 行顶出进回滚
    b.feed("L0\nL1\nL2\nL3");
    FrameSync sync;
    sync.publish(b);
    const GridFrame f = sync.snapshot();
    EXPECT_EQ(f.scrollbackTotal, b.scrollback().totalPushed());
    EXPECT_EQ(f.scrollbackOldest, b.scrollback().oldestIndex());
    EXPECT_GT(f.scrollbackTotal, 0u); // 确有行被顶出
}

TEST(FrameSyncTest, MouseModeAndBellReflectedInSnapshot)
{
    VtermBridge b(10, 3);
    b.feed("\x1b[?1000h"); // DECSET 1000：鼠标点击上报
    b.feed("\x07");        // bell
    FrameSync sync;
    sync.publish(b);
    const GridFrame f = sync.snapshot();
    EXPECT_EQ(f.mouseMode, MouseMode::kClick);
    EXPECT_EQ(f.bellCount, 1u);
}
