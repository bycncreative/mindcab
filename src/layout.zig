//! zmind 树布局算法：测量节点尺寸、计算树形坐标、叠加拖拽偏移、求包围盒。
//! 纯几何计算，不依赖 dvui 事件系统 —— 尺寸测量通过注入的 measure 函数完成，
//! 便于日后更换布局策略（鱼骨图、放射图等）而不触碰 UI 代码。
const std = @import("std");
const model = @import("model.zig");

/// 布局参数。调间距/节点尺寸只改这里。
pub const Metrics = struct {
    level_dx: f32 = 240, // 每层水平间距
    vgap: f32 = 12, // 兄弟节点垂直间距
    pad_x: f32 = 8,
    pad_y: f32 = 6,
    node_min_w: f32 = 60, // 节点最小宽（自动布局下限，也是手动调宽的下限）
    node_min_h: f32 = 30,
    node_max_w: f32 = 220, // 自动测量的最大宽（手动调宽不受此限）
    margin: f32 = 48, // 画布四周留白
    desc_gap: f32 = 4, // 标题与正文描述之间的间距
    desc_font_delta: f32 = -2, // 正文描述相对标题的字号增减（负值 = 略小）
    img_icon: f32 = 24, // 节点图片图标尺寸（24×24，首行开头）
    img_gap: f32 = 4, // 图标与标题之间的间距
    prop_gap: f32 = 10, // 属性表格与上方文字（标题/描述）之间的间距（约半行）
    prop_row_h: f32 = 18, // 属性表格行高
    prop_name_frac: f32 = 0.4, // 属性名格占内容区宽度比例
    prop_name_min_w: f32 = 48, // 属性名格最小宽度
};

/// 属性表属性名格的宽度：按比例取，带下限，但最多占 70%
/// （小节点内容区 <48px 时下限不能把值格挤没）。
/// 测量与绘制必须走同一个函数，保证布局与渲染一致。
pub fn propNameCellW(content_w: f32) f32 {
    return @min(@max(content_w * metrics.prop_name_frac, metrics.prop_name_min_w), content_w * 0.7);
}

pub const metrics: Metrics = .{};

/// 文本种类：标题用正文字号，正文描述用略小字号。
pub const TextKind = enum { title, desc };

/// 文本测量接口：给定文本与种类返回期望宽高（由 UI 层绑定到字体）。
pub const TextMeasure = *const fn (ctx: ?*anyopaque, text: []const u8, kind: TextKind) Size;

pub const Size = struct { w: f32, h: f32 };

/// 递归测量节点尺寸，写入 geom.w/h。
/// 有正文描述时高度叠加「间距 + 描述高度」，宽度取标题与描述的较大者。
/// 用户手动尺寸（user_w/user_h）作为下限叠加：实际框取 max(自动, 手动)，
/// 文字变长仍会自动撑宽，手动拖小到内容以下时自动尺寸兜底。
pub fn measure(node: *model.Node, ctx: ?*anyopaque, tm: TextMeasure) void {
    const title = tm(ctx, node.text.items, .title);
    // 首行：有图片时标题右移（图标 + 间距），行高取标题与图标的较大者
    var w = title.w;
    var h = title.h;
    if (node.hasImg()) {
        w += metrics.img_icon + metrics.img_gap;
        h = @max(h, metrics.img_icon);
    }
    if (node.hasNote()) {
        const desc = tm(ctx, node.note.items, .desc);
        w = @max(w, desc.w);
        h += metrics.desc_gap + desc.h;
    }
    // 属性表格：先留与上方文字的间距（约半行），再逐行叠加高度
    // （表格宽 = 内容区宽，不撑宽节点）
    if (node.properties.items.len > 0) {
        h += metrics.prop_gap + @as(f32, @floatFromInt(node.properties.items.len)) * metrics.prop_row_h;
    }
    var gw = std.math.clamp(w + metrics.pad_x * 2, metrics.node_min_w, metrics.node_max_w);
    var gh = @max(h + metrics.pad_y * 2, metrics.node_min_h);
    if (node.user_w) |uw| gw = @max(gw, uw);
    if (node.user_h) |uh| gh = @max(gh, uh);
    node.geom.w = gw;
    node.geom.h = gh;
    for (node.children.items) |c| measure(c, ctx, tm);
}

/// 递归布局：x 由深度决定，y 由子树跨距居中。
pub fn layout(node: *model.Node, depth: u32, y_cursor: *f32) void {
    node.geom.x = metrics.margin + @as(f32, @floatFromInt(depth)) * metrics.level_dx;
    if (node.collapsed or node.children.items.len == 0) {
        node.geom.y = y_cursor.*;
        y_cursor.* += node.geom.h + metrics.vgap;
        return;
    }
    const y0 = y_cursor.*;
    for (node.children.items) |c| layout(c, depth + 1, y_cursor);
    const y1 = y_cursor.*;
    // 父节点垂直居中于子节点跨距
    node.geom.y = (y0 + y1 - metrics.vgap) / 2.0 - node.geom.h / 2.0;
}

/// 将拖拽偏移叠加到自动布局结果上（子节点继承父节点偏移）。
pub fn applyOffsets(node: *model.Node, parent_ox: f32, parent_oy: f32) void {
    const tx = parent_ox + node.geom.ox;
    const ty = parent_oy + node.geom.oy;
    node.geom.x += tx;
    node.geom.y += ty;
    for (node.children.items) |c| applyOffsets(c, tx, ty);
}

/// 整棵树的包围盒右下角（用于虚拟滚动尺寸）。
pub fn treeBounds(node: *model.Node, max_x: *f32, max_y: *f32) void {
    max_x.* = @max(max_x.*, node.geom.x + node.geom.w);
    max_y.* = @max(max_y.*, node.geom.y + node.geom.h);
    if (!node.collapsed) {
        for (node.children.items) |c| treeBounds(c, max_x, max_y);
    }
}

/// 一键完成 测量 → 布局 → 偏移 → 包围盒，返回虚拟画布尺寸。
pub const Bounds = struct { w: f32, h: f32 };

pub fn layoutAll(root: *model.Node, ctx: ?*anyopaque, tm: TextMeasure) Bounds {
    measure(root, ctx, tm);
    var y_cursor: f32 = metrics.margin;
    layout(root, 0, &y_cursor);
    applyOffsets(root, 0, 0);
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    treeBounds(root, &max_x, &max_y);
    return .{
        .w = max_x + metrics.margin,
        .h = @max(max_y + metrics.margin, 400),
    };
}

// ---------------------------------------------------------------------------
// 恢复保存的视口位置（XML position="true"）
// ---------------------------------------------------------------------------
/// xml.loadEx(positioned=true) 之后调用：解析时把节点属性 left/top 暂存在
/// geom.x/y（文件里没写的节点是 NaN）。这里先算出自动布局基点，再把
/// 「保存位置 − 基点」折算成每个节点的拖拽偏移 ox/oy——layoutAll 每帧
/// 重算 基点+偏移，节点停在保存时的位置；之后的拖拽/加节点仍走原有偏移机制。
pub fn restoreSavedPositions(root: *model.Node, ctx: ?*anyopaque, tm: TextMeasure) void {
    // 1) 保存位置挪到 ox/oy 暂存（下一步 layout 会覆盖 geom.x/y）
    stashSaved(root);
    // 2) 自动布局基点（不含偏移）
    measure(root, ctx, tm);
    var y_cursor: f32 = metrics.margin;
    layout(root, 0, &y_cursor);
    // 3) 差值折算成偏移，4) 立刻叠回 geom——调用返回时位置即已恢复
    restoreOffsets(root, 0, 0);
    applyOffsets(root, 0, 0);
}

/// geom.x/y（暂存的保存位置）→ geom.ox/oy，为 layout 腾出 x/y。
fn stashSaved(node: *model.Node) void {
    node.geom.ox = node.geom.x;
    node.geom.oy = node.geom.y;
    for (node.children.items) |c| stashSaved(c);
}

/// 自顶向下折算：本节点最终位置 = 基点 + 祖先偏移和(tx/ty) + 自身偏移，
/// 令其等于保存位置即得自身偏移。文件里没写 left/top（NaN）的节点偏移取 0，
/// 停在自动布局位置。折叠节点的子树没参与布局（无基点），偏移清零——
/// 展开后按自动布局出现。
fn restoreOffsets(node: *model.Node, tx: f32, ty: f32) void {
    const sx = node.geom.ox;
    const sy = node.geom.oy;
    node.geom.ox = if (std.math.isNan(sx)) 0 else sx - (node.geom.x + tx);
    node.geom.oy = if (std.math.isNan(sy)) 0 else sy - (node.geom.y + ty);
    if (node.collapsed) {
        for (node.children.items) |c| clearOffsets(c);
        return;
    }
    for (node.children.items) |c| restoreOffsets(c, tx + node.geom.ox, ty + node.geom.oy);
}

fn clearOffsets(node: *model.Node) void {
    node.geom.ox = 0;
    node.geom.oy = 0;
    for (node.children.items) |c| clearOffsets(c);
}
