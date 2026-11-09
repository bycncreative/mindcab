//! 最近打开的文件（文件菜单「最近打开的文件」子菜单）。
//!
//! 持久化：`%USERPROFILE%/.mindcab/history.toml`，TOML 数组表格式：
//!
//!   [[entries]]
//!   path = 'D:\tmp\a.mcab'   （TOML 字面量字符串，反斜杠无需转义）
//!   pinned = true
//!
//! 排序约定（单列表达）：pinned 条目在前（保持钉住先后），其余按最近
//! 打开在前。打开/保存文件即 record（去重、提升到所在区顶部）；界面上
//! 可删除（免确认）与钉住/取消钉住；上限 max_entries，超出淘汰最旧的
//! 未钉住条目（钉住条目不淘汰）。本模块无 dvui 依赖，可单测。

const std = @import("std");

/// 历史条目上限（超出淘汰最旧的未钉住条目）
pub const max_entries: usize = 30;

pub const Entry = struct {
    path: []const u8, // owned（list allocator）
    pinned: bool = false,
};

pub const RecentFiles = struct {
    allocator: std.mem.Allocator,
    /// pinned 在前（钉住顺序），其余按最近打开在前
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) RecentFiles {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RecentFiles) void {
        for (self.entries.items) |e| self.allocator.free(e.path);
        self.entries.deinit(self.allocator);
    }

    fn pinnedCount(self: *const RecentFiles) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (!e.pinned) break;
            n += 1;
        }
        return n;
    }

    fn indexOf(self: *const RecentFiles, path: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            // Windows 路径大小写不敏感
            if (std.ascii.eqlIgnoreCase(e.path, path)) return i;
        }
        return null;
    }

    fn dup(self: *RecentFiles, path: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, path);
    }

    fn removeAt(self: *RecentFiles, i: usize) void {
        const e = self.entries.orderedRemove(i);
        self.allocator.free(e.path);
    }

    /// 打开/保存文件：去重后提升到所在区（pinned 区 / 未钉住区）顶部；
    /// 新条目插入未钉住区顶；超出上限淘汰最旧的未钉住条目。
    pub fn record(self: *RecentFiles, path: []const u8) !void {
        if (path.len == 0) return;
        if (self.indexOf(path)) |i| {
            const e = self.entries.items[i];
            const was_pinned = e.pinned;
            const stored = e.path;
            // remove（不 free stored），再插到目标位
            _ = self.entries.orderedRemove(i);
            const target = if (was_pinned) 0 else self.pinnedCount();
            try self.entries.insert(self.allocator, target, .{ .path = stored, .pinned = was_pinned });
        } else {
            const stored = try self.dup(path);
            errdefer self.allocator.free(stored);
            try self.entries.insert(self.allocator, self.pinnedCount(), .{ .path = stored, .pinned = false });
            self.evictOverflow();
        }
    }

    /// 界面删除某个历史（免确认）
    pub fn remove(self: *RecentFiles, path: []const u8) void {
        if (self.indexOf(path)) |i| self.removeAt(i);
    }

    /// 钉住到历史最顶端 / 取消钉住（回到未钉住区顶部）
    pub fn setPinned(self: *RecentFiles, path: []const u8, pinned: bool) void {
        const i = self.indexOf(path) orelse return;
        var e = self.entries.items[i];
        if (e.pinned == pinned) return;
        const stored = e.path;
        _ = self.entries.orderedRemove(i);
        e.pinned = pinned;
        const target = if (pinned) 0 else self.pinnedCount();
        self.entries.insert(self.allocator, target, .{ .path = stored, .pinned = pinned }) catch {
            // 插入失败（OOM）：至少保持一致——放回原位置语义已不可得，
            // 退化为直接放弃该条（与 OOM 下的整体弱化一致）
            self.allocator.free(stored);
        };
    }

    fn evictOverflow(self: *RecentFiles) void {
        while (self.entries.items.len > max_entries) {
            // 从尾部（最旧的未钉住区）向前找未钉住条目；全 pinned 则不淘汰
            var i = self.entries.items.len;
            var removed = false;
            while (i > 0) {
                i -= 1;
                if (!self.entries.items[i].pinned) {
                    self.removeAt(i);
                    removed = true;
                    break;
                }
            }
            if (!removed) break;
        }
    }

    /// 从 TOML 读取（文件不存在 / 解析失败 → 保持当前内容不变）
    pub fn loadFrom(self: *RecentFiles, io: std.Io, path: []const u8) void {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(text);
        self.parseToml(text);
    }

    fn parseToml(self: *RecentFiles, text: []const u8) void {
        // 宽松行解析：只认 [[entries]] / path = '…'|"…" / pinned = true|false
        var line_it = std.mem.splitScalar(u8, text, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "path")) {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (value.len < 2) continue;
                var p: []const u8 = undefined;
                if (value[0] == '\'' and value[value.len - 1] == '\'') {
                    p = value[1 .. value.len - 1]; // 字面量字符串：原样
                } else if (value[0] == '"' and value[value.len - 1] == '"') {
                    p = unescapeBasic(value[1 .. value.len - 1], self.allocator) catch continue;
                } else continue;
                if (p.len == 0) continue;
                // 去重（同一文件可能多行）
                if (self.indexOf(p) != null) {
                    if (value[0] == '"') self.allocator.free(p);
                } else {
                    const stored = self.dup(p) catch {
                        if (value[0] == '"') self.allocator.free(p);
                        continue;
                    };
                    self.entries.append(self.allocator, .{ .path = stored, .pinned = false }) catch {
                        self.allocator.free(stored);
                    };
                }
                if (value[0] == '"') self.allocator.free(p);
            } else if (std.mem.startsWith(u8, line, "pinned")) {
                // 归属最近一个 path 条目
                if (self.entries.items.len == 0) continue;
                if (std.mem.indexOf(u8, line, "true") != null) {
                    // 置为 pinned 并移入 pinned 区顶
                    const last = self.entries.items.len - 1;
                    const e = self.entries.items[last];
                    if (!e.pinned) {
                        const stored = e.path;
                        _ = self.entries.orderedRemove(last);
                        self.entries.insert(self.allocator, 0, .{ .path = stored, .pinned = true }) catch {
                            self.allocator.free(stored);
                        };
                    }
                }
            }
        }
    }

    fn unescapeBasic(s: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        // 只处理我们可能写出的 \\ 转义（其余原样）
        if (std.mem.indexOf(u8, s, "\\") == null) return allocator.dupe(u8, s);
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '\\') {
                try out.append(allocator, '\\');
                i += 1;
            } else {
                try out.append(allocator, s[i]);
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// 写 TOML（临时文件 + rename 原子替换；目录不存在则创建）
    pub fn flush(self: *RecentFiles, io: std.Io, path: []const u8) void {
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }

        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, "# mindcab 最近打开的文件（自动生成）\n") catch return;
        for (self.entries.items) |e| {
            buf.appendSlice(self.allocator, "[[entries]]\npath = ") catch return;
            appendTomlString(&buf, self.allocator, e.path) catch return;
            buf.appendSlice(self.allocator, if (e.pinned) "pinned = true\n\n" else "pinned = false\n\n") catch return;
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = buf.items }) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(tmp_path, cwd, path, io) catch {
            cwd.deleteFile(io, tmp_path) catch {};
        };
    }

    fn appendTomlString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        if (std.mem.indexOfScalar(u8, s, '\'') == null) {
            // 字面量字符串：反斜杠原样（Windows 路径友好）
            try buf.append(allocator, '\'');
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, "'\n");
        } else {
            // 含单引号：退化为基本字符串并转义反斜杠
            try buf.append(allocator, '"');
            for (s) |ch| {
                if (ch == '\\' or ch == '"') try buf.append(allocator, '\\');
                try buf.append(allocator, ch);
            }
            try buf.appendSlice(allocator, "\"\n");
        }
    }
};

/// 历史文件默认路径：%USERPROFILE%/.mindcab/history.toml。
/// USERPROFILE 取不到（异常环境）返回 null。
pub fn defaultPath(buf: []u8) ?[]const u8 {
    const home = userProfile() orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\.mindcab\\history.toml", .{home}) catch null;
}

/// %USERPROFILE%（UTF-8；直接读 Windows 块环境，中文用户名不乱码）。
/// 返回值指向模块级静态缓冲（下次调用失效）。
fn userProfile() ?[]const u8 {
    const env_block = GetEnvironmentStringsW() orelse return null;
    defer _ = FreeEnvironmentStringsW(env_block);

    var p = env_block;
    while (p[0] != 0) {
        const entry = std.mem.span(p);
        if (entry.len > 12 and entry[11] == '=' and eqW(entry[0..11], "USERPROFILE")) {
            const value16 = entry[12..];
            const n = std.unicode.utf16LeToUtf8(&user_profile_buf, value16) catch return null;
            return user_profile_buf[0..n];
        }
        p += entry.len + 1;
    }
    return null;
}

var user_profile_buf: [std.fs.max_path_bytes]u8 = undefined;

fn eqW(a: []const u16, ascii: []const u8) bool {
    if (a.len != ascii.len) return false;
    for (a, ascii) |u, c| {
        if (u != c) return false;
    }
    return true;
}

extern "kernel32" fn GetEnvironmentStringsW() ?[*:0]u16;
extern "kernel32" fn FreeEnvironmentStringsW(penv: [*:0]u16) i32;

// ---------------------------------------------------------------------------
// 单测（`zig build test`）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "recent record 去重与 MRU 顺序" {
    var r = RecentFiles.init(testing.allocator);
    defer r.deinit();
    try r.record("a.mcab");
    try r.record("b.mcab");
    try r.record("a.mcab"); // 重复：提到未钉住区顶
    try testing.expectEqual(@as(usize, 2), r.entries.items.len);
    try testing.expectEqualStrings("a.mcab", r.entries.items[0].path);
    try testing.expectEqualStrings("b.mcab", r.entries.items[1].path);
}

test "recent pin 到顶与取消" {
    var r = RecentFiles.init(testing.allocator);
    defer r.deinit();
    try r.record("a");
    try r.record("b");
    try r.record("c");
    r.setPinned("c", true); // pinned 区顶
    try testing.expectEqualStrings("c", r.entries.items[0].path);
    try testing.expect(r.entries.items[0].pinned);
    try r.record("b"); // 未钉住区顶（pinned 之后）
    try testing.expectEqualStrings("b", r.entries.items[1].path);
    r.setPinned("c", false); // 取消：回到未钉住区顶（b 之前）
    try testing.expectEqualStrings("c", r.entries.items[0].path);
    try testing.expect(!r.entries.items[0].pinned);
}

test "recent remove 免确认删除" {
    var r = RecentFiles.init(testing.allocator);
    defer r.deinit();
    try r.record("a");
    try r.record("b");
    r.remove("a");
    try testing.expectEqual(@as(usize, 1), r.entries.items.len);
    try testing.expectEqualStrings("b", r.entries.items[0].path);
    r.remove("不存在的"); // 无副作用
    try testing.expectEqual(@as(usize, 1), r.entries.items.len);
}

test "recent 上限淘汰最旧未钉住条目（钉住不淘汰）" {
    var r = RecentFiles.init(testing.allocator);
    defer r.deinit();
    try r.record("pinned-old");
    r.setPinned("pinned-old", true);
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        var buf: [32]u8 = undefined;
        try r.record(try std.fmt.bufPrint(&buf, "f{d}", .{i}));
    }
    // 淘汰在每次 record 时即时发生：pinned-old + f1..f29（f0 已被挤掉）
    try testing.expectEqual(max_entries, r.entries.items.len);
    var found_pinned = false;
    var found_f0 = false;
    for (r.entries.items) |e| {
        if (std.mem.eql(u8, e.path, "pinned-old")) found_pinned = true;
        if (std.mem.eql(u8, e.path, "f0")) found_f0 = true;
    }
    try testing.expect(found_pinned);
    try testing.expect(!found_f0);
    // 再加一条：挤掉当前最旧的未钉住 f1
    try r.record("new");
    try testing.expectEqual(max_entries, r.entries.items.len);
    var found_f1 = false;
    var found_new = false;
    for (r.entries.items) |e| {
        if (std.mem.eql(u8, e.path, "f1")) found_f1 = true;
        if (std.mem.eql(u8, e.path, "new")) found_new = true;
    }
    try testing.expect(!found_f1);
    try testing.expect(found_new);
}

test "recent TOML round-trip（含中文与反斜杠路径）" {
    var r = RecentFiles.init(testing.allocator);
    defer r.deinit();
    try r.record("D:\\tmp\\设计\\文 档.mcab");
    try r.record("C:\\其它.mcab");
    r.setPinned("C:\\其它.mcab", true);

    const path = ".mindcab-test-history.toml";
    r.flush(testing.io, path);
    defer {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
    }

    var r2 = RecentFiles.init(testing.allocator);
    defer r2.deinit();
    r2.loadFrom(testing.io, path);
    try testing.expectEqual(@as(usize, 2), r2.entries.items.len);
    try testing.expect(r2.entries.items[0].pinned); // pinned 区在前
    try testing.expectEqualStrings("C:\\其它.mcab", r2.entries.items[0].path);
    try testing.expectEqualStrings("D:\\tmp\\设计\\文 档.mcab", r2.entries.items[1].path);
}
