/**
 * CellGrid —— 终端单元格网格（任务 T1，DESIGN §2.2）。
 *
 * 布局硬性约定：每格 16 字节连续内存，ArkTS 侧用 DataView 直读（小端）：
 *   偏移 0  u32  Unicode 码点（0 = 空；kWideContinuation = 宽字符续格标记）
 *   偏移 4  u32  前景色 ARGB（已解析调色板/真彩）
 *   偏移 8  u32  背景色 ARGB
 *   偏移 12 u16  属性位（kAttr* 系列）
 *   偏移 14 u16  保留（链接 id / 未来扩展）
 * OHOS 目标平台（arm64/x86_64）与宿主机均为小端，结构体自然布局即上述字节序；
 * static_assert 钉死尺寸与偏移，改动会编译期报错。
 *
 * 本文件是纯逻辑实现：只依赖 C++ 标准库，禁止 include <napi/native_api.h> /
 * <hilog/log.h> / <vterm.h>。它同时被 OHOS 产物（../CMakeLists.txt 的
 * libssh_core.so）与宿主机单元测试（../tests/CMakeLists.txt）编译。
 *
 * 不变式：单元格内容写入必须经由 putCell / fillCells / copyCells，
 * 它们负责「脏行位图置位 + revision +1」；cellAt 返回的可写指针只供
 * 读路径与确知自己在做什么的写入者（写后须自行 touchCell），
 * 否则脏行位图与 revision 会与实际内容脱节。
 * 两条例外路径：bumpRevision（光标移动等非内容性视觉变化，只抬 revision）
 * 与 raiseRevisionFloor（整体重建后保 revision 单调不减），均不写单元格。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace sshclient {
namespace term {

// 宽字符续格码点标记（DESIGN §2.2）
inline constexpr uint32_t kWideContinuation = 0xFFFFFFFFu;

// 属性位（偏移 12 的 u16）。dim 位预留：libvterm 0.3.3 的屏幕层没有 dim 属性，
// 位号先占住保证布局稳定，待后续（补丁或自绘层）再接。
inline constexpr uint16_t kAttrBold      = 1u << 0;
inline constexpr uint16_t kAttrItalic    = 1u << 1;
inline constexpr uint16_t kAttrUnderline = 1u << 2;
inline constexpr uint16_t kAttrBlink     = 1u << 3;
inline constexpr uint16_t kAttrReverse   = 1u << 4;
inline constexpr uint16_t kAttrStrike    = 1u << 5;
inline constexpr uint16_t kAttrDim       = 1u << 6;
inline constexpr uint16_t kAttrWide      = 1u << 7; // 宽字符首格

struct Cell {
    uint32_t codepoint; // 偏移 0：Unicode 码点；0 = 空；kWideContinuation = 宽字符续格
    uint32_t fgArgb;    // 偏移 4：前景色 ARGB
    uint32_t bgArgb;    // 偏移 8：背景色 ARGB
    uint16_t attrs;     // 偏移 12：属性位（kAttr*）
    uint16_t reserved;  // 偏移 14：保留（链接 id / 未来扩展）
};

static_assert(sizeof(Cell) == 16, "Cell 必须恰好 16 字节（DESIGN §2.2）");
static_assert(offsetof(Cell, codepoint) == 0, "Cell 布局偏离 DESIGN §2.2");
static_assert(offsetof(Cell, fgArgb) == 4, "Cell 布局偏离 DESIGN §2.2");
static_assert(offsetof(Cell, bgArgb) == 8, "Cell 布局偏离 DESIGN §2.2");
static_assert(offsetof(Cell, attrs) == 12, "Cell 布局偏离 DESIGN §2.2");
static_assert(offsetof(Cell, reserved) == 14, "Cell 布局偏离 DESIGN §2.2");

class CellGrid {
public:
    // 默认前/背景色由上层外观系统注入（native 侧先为可配构造参数）
    CellGrid(int cols, int rows, uint32_t defaultFgArgb, uint32_t defaultBgArgb);

    int cols() const { return cols_; }
    int rows() const { return rows_; }
    uint32_t defaultFgArgb() const { return defaultFgArgb_; }
    uint32_t defaultBgArgb() const { return defaultBgArgb_; }

    // 空白格：码点 0 + 默认色 + 无属性（erase/清屏后的标准内容）
    Cell blankCell() const;

    // 越界是调用方 bug：debug 下 assert，release 下未定义（与 vector::operator[] 同级约定）
    const Cell *cellAt(int row, int col) const { return &cells_[index(row, col)]; }
    Cell *cellAt(int row, int col) { return &cells_[index(row, col)]; } // 写后须 touchCell

    // 连续内存起点与字节数（T3 零拷贝快照直接暴露这段内存）
    const uint8_t *data() const { return reinterpret_cast<const uint8_t *>(cells_.data()); }
    size_t byteSize() const { return cells_.size() * sizeof(Cell); }

    // 标准写路径：写一格 + 脏行置位 + revision +1
    void putCell(int row, int col, const Cell &cell);
    // 经 cellAt 可写指针直接写完后，手工维护脏行/revision
    void touchCell(int row, int col);

    // 用 cell 填充半开矩形 [row0,row1) × [col0,col1)（ED/EL 用；越界部分裁剪）
    void fillCells(int row0, int col0, int row1, int col1, const Cell &cell);

    // 拷贝矩形区域（矩形搬移原语；VtermBridge 滚动不镜像拷贝、走 damage 重读，
    // 见 vterm_screen.cpp onMoveRect），源/目标允许重叠（内部走临时快照）；越界部分裁剪
    void copyCells(int destRow, int destCol, int srcRow, int srcCol, int rowCount, int colCount);

    // 改尺寸：按行拷贝行列交集保留内容，新增区域填空白格；全部行标脏
    void resize(int newCols, int newRows);

    // 脏行位图（每行 1 bit，vector<uint64_t> 按 64 行一个 word）
    void setDirty(int row);
    void clearDirty(); // 全部清零（渲染帧消费完脏行后调用）
    bool isDirty(int row) const;
    const std::vector<uint64_t> &dirtyBitmap() const { return dirty_; }

    // 单调递增修订号：每次单元格内容写入 +1（ArkTS 每帧比对，无变化跳过渲染）
    uint64_t revision() const { return revision_; }

    // 非内容性视觉变化（光标移动）抬 revision：帧循环以 revision 判「是否重绘」，
    // 纯光标移动不写单元格、不抬会丢光标帧（T1 审查跟进项，T2 修）。
    // 只抬计数，不碰脏行位图——新旧光标行的标脏由调用方负责。
    void bumpRevision() { ++revision_; }

    // 把 revision 抬到至少 floor（floor 更大时生效，否则不动）。
    // 用途：setDefaultColors 这类「整体重建网格」后 revision 从 0 重计数会对外回退，
    // 调用方重建后抬回旧值，保证 revision 对外单调不减（帧循环不比小）。
    void raiseRevisionFloor(uint64_t floor)
    {
        if (revision_ < floor)
            revision_ = floor;
    }

private:
    size_t index(int row, int col) const;

    int cols_;
    int rows_;
    uint32_t defaultFgArgb_;
    uint32_t defaultBgArgb_;
    std::vector<Cell> cells_;       // cols*rows 连续内存，行优先
    std::vector<uint64_t> dirty_;   // (rows+63)/64 个 word
    uint64_t revision_ = 0;
};

} // namespace term
} // namespace sshclient
