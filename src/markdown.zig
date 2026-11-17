//! 导出 Markdown 文本。
//!
//! 导出规则（菜单「文件 → 导出 → 导出为 Markdown」）：节点层级（根=1）≤5 的
//! 标题按层级输出 ATX 标题（# .. #####），更深的节点导出为正文段落；节点的
//! note（正文描述）按行拆成正文段落，跟在其标题/正文之后。段落之间空一行
//! （否则相邻正文行会被 Markdown 解析器并成同一段）。子节点顺序与 docx 导出
//! 一致：按导出排序键 seq * 10_000_000 + id 升序（见 model.childrenForExport）。
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

/// 层级（根节点 = 1）不超过该值的节点标题导出为 ATX 标题，更深的为正文。
const max_heading_level = 5;

/// 把 root 所在的树导出为 .md 写入 path。
pub fn exportToMarkdown(alloc: Allocator, io: std.Io, root: *model.Node, path: []const u8) !void {
    const data = try buildMarkdown(alloc, root);
    defer alloc.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return error.OpenWriteFailed;
}

/// 生成完整 Markdown 文本（调用方负责 free）。
pub fn buildMarkdown(alloc: Allocator, root: *model.Node) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer aw.deinit();
    try walkBody(alloc, &aw.writer, root, 1);
    return aw.toOwnedSlice();
}

fn walkBody(alloc: Allocator, w: *std.Io.Writer, node: *model.Node, depth: u32) !void {
    if (depth <= max_heading_level) {
        try w.splatByteAll('#', depth);
        try w.writeByte(' ');
        try w.writeAll(node.text.slice());
        try w.writeAll("\n\n");
    } else {
        try writeParagraph(w, node.text.slice());
    }
    // note（正文描述）跟在其后；按行拆成多段（Windows 换行 \r\n 去掉 \r）
    if (node.hasNote()) {
        var it = std.mem.splitScalar(u8, node.note.slice(), '\n');
        while (it.next()) |line_raw| {
            const line = if (std.mem.endsWith(u8, line_raw, "\r")) line_raw[0 .. line_raw.len - 1] else line_raw;
            if (line.len == 0) continue;
            try writeParagraph(w, line);
        }
    }
    const kids = try model.childrenForExport(alloc, node);
    defer alloc.free(kids);
    for (kids) |c| try walkBody(alloc, w, c, depth + 1);
}

/// 一个正文段落 = 一行文本 + 空行。
fn writeParagraph(w: *std.Io.Writer, line: []const u8) !void {
    try w.writeAll(line);
    try w.writeAll("\n\n");
}
