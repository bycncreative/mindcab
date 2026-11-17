//! zstring.zig — 不可变字符串 ZString（模仿 java.lang.String）+ 字符串池 StringStore。
//!
//! 动机：撤销/重做快照（docs/memo-redo-undo.md）对整棵树深拷贝，节点标题
//! `text` 与正文描述 `desc`（model.zig 里字段名是 `note`）也随节点逐字节复制。
//! 换成不可变 ZString 后，快照树与当前树可以共享同一份字节；只有真正要改文本时
//! 才构造新串——即 copyOnWrite，正对上备忘录第五节的「演进方向」。
//!
//! 与 java.lang.String 的对应关系：
//!
//! | Java                    | 这里                                        |
//! |-------------------------|---------------------------------------------|
//! | String 不可变           | bytes 是 []const u8，类型上杜绝原地改写     |
//! | 赋值/传参是引用         | ZString = 指针+长度，复制即共享底层字节     |
//! | 改值 = new String(...)  | store.create / store.intern 构造新串        |
//! | GC 回收                 | StringStore.mark-sweep（beginGc/mark/sweep）|
//!
//! 为什么用池 + GC 而不是引用计数：Java 的 `a = b` 安全是因为 GC 自动计数；Zig 的
//! 结构体赋值只是位拷贝，引用计数版 ZString 每次 `=` 都得配对 retain()，
//! 漏一处就是 double-free。「赋值即引用、且天然安全」只有池化所有权 + GC 做得到
//! ——与工程里图片池（ImageStore 不入快照）同一思路。
//!
//! ### 反复修改产生的废弃串怎么处理
//!
//! 每次「提交修改」构造一个新串，旧串只要还被撤销快照引用着就继续存活（这正是
//! COW 的意义：改一个节点不牵连整棵快照树）。快照被挤掉（undo 深度 50 溢出）、
//! redo 被清空、或文档回退换树之后，旧版本才真正无主——这些孤儿由 mark-sweep
//! GC 回收：
//!
//! ```zig
//! if (store.shouldGc()) {
//!     var g = store.beginGc();
//!     markTree(&g, doc.root);                    // 当前树
//!     for (doc.undo_stack.items) |s| markTree(&g, s.root); // 撤销栈
//!     for (doc.redo_stack.items) |s| markTree(&g, s.root); // 重做栈
//!     if (doc.pending_field_snapshot) |s| markTree(&g, s.root); // 预备快照
//!     g.sweep();
//! }
//! ```
//!
//! 不跑 GC 也不会出错，垃圾只是攒到 store.deinit（文档关闭）才释放；
//! GC 是把「长期编辑的累积」压回「活跃集大小」的手段。
//!
//! ### sweep 是延迟释放的（trash）
//!
//! GC 在帧绘制中途被触发（pushUndo → gcStrings），而 dvui 控件可能还握着
//! 「刚被替换掉的旧串」的切片（label 的 fmt args 按 id 存进 dataMap，本帧内
//! 有效）。sweep 因此**不当场 free**：死块先进 trash，等下一个**帧**的
//! freeTrashOlderThan 才真正释放——那时引用它们的控件都已在上一帧析构。
//! trash 带 epoch（帧号），同一帧内跑两轮 GC 不会提前释放本轮刚扫出的块。
//! 这把「漏标根」的后果从「当场 UAF」收窄到「最多延迟一轮」，调用方漏标的
//! 风险窗口仍然存在，集成纪律见 model.zig / app.zig 的 gcStrings。
//!
//! 配套纪律：编辑会话内用可变草稿（ArrayList）打字，**提交时才 create 一个新
//! ZString**——垃圾产生率是「每次提交一串」，不是「每个按键一串」。
//!
//! 约定：
//! - `bytes` 视作私有（Zig 无字段可见性），外部一律走 `z.slice()` 只读访问；
//! - ZString 没有 deinit：它不拥有字节，回收统一走 GC / `StringStore.deinit`
//!   （建议每个 Doc 一个 store，与 ImageStore 并列、同样不入快照）；
//! - `ZString.fromSlice` 可借用外部字节（字面量天然安全），借用串永不被 GC
//!   触碰，生命周期由调用方保证；
//! - 单线程使用（本工程 GUI 单线程）。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 不可变字符串值。复制/传参 = 共享同一份字节（引用语义）。
pub const ZString = struct {
    /// 只读字节（内部表示，勿直接使用；见文件头「约定」）。
    bytes: []const u8 = "",

    /// 空串（共享常量，零分配）——java 的 ""。
    pub const empty: ZString = .{};

    /// 借用一段已有字节，不复制。生命周期由调用方保证（字面量安全）。
    pub fn fromSlice(s: []const u8) ZString {
        return .{ .bytes = s };
    }

    /// 只读视图（渲染/序列化/`{s}` 格式化都用它）。
    pub fn slice(self: ZString) []const u8 {
        return self.bytes;
    }

    /// java: length()
    pub fn len(self: ZString) usize {
        return self.bytes.len;
    }

    /// java: isEmpty()
    pub fn isEmpty(self: ZString) bool {
        return self.bytes.len == 0;
    }

    /// java: equals()
    pub fn eql(self: ZString, other: ZString) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }

    /// 与裸切片比较（对接 []const u8 世界的 equals）。
    pub fn eqlSlice(self: ZString, s: []const u8) bool {
        return std.mem.eql(u8, self.bytes, s);
    }

    /// java: startsWith()
    pub fn startsWith(self: ZString, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.bytes, prefix);
    }

    /// java: endsWith()
    pub fn endsWith(self: ZString, suffix: []const u8) bool {
        return std.mem.endsWith(u8, self.bytes, suffix);
    }

    /// java: indexOf()（字节下标）
    pub fn indexOf(self: ZString, needle: []const u8) ?usize {
        return std.mem.indexOf(u8, self.bytes, needle);
    }

    /// java: contains()
    pub fn contains(self: ZString, needle: []const u8) bool {
        return self.indexOf(needle) != null;
    }
};

/// 字符串池：ZString 字节的唯一所有者，兼 mark-sweep GC 的堆。
/// 建议每个文档（Doc）持有一个，与 ImageStore 并列、同样「不入快照」。
pub const StringStore = struct {
    gpa: Allocator,
    /// 池内全部分配（GC 全集）。每个 ZString.bytes 指向其中某一块。
    blocks: std.ArrayList([]u8) = .empty,
    /// 本轮已被判死、等待延迟释放的块（见文件头「sweep 是延迟释放的」）。
    trash: std.ArrayList([]u8) = .empty,
    /// intern() 的内容驻留表。**弱表**：不构成 GC 根，sweep 时同步清理——
    /// 否则 intern 过的旧版本会永生，恰好制造你想回收的那种垃圾。
    interned: std.StringHashMapUnmanaged(ZString) = .empty,
    /// 上一轮 GC 后的存活块数，shouldGc() 的启发式基准。
    live_after_last_gc: usize = 0,
    /// trash 里这批死块是在哪个 epoch（App 的帧号）被判死的。
    /// freeTrashOlderThan 只在 epoch 前进后才真正释放——同一帧内跑两轮 GC
    /// 时，第二轮不会把第一轮刚扫出的 trash 提前 free（那时 dvui 控件可能
    /// 还握着旧串切片）。
    trash_epoch: u64 = 0,

    pub fn init(gpa: Allocator) StringStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *StringStore) void {
        for (self.blocks.items) |b| self.gpa.free(b);
        self.blocks.deinit(self.gpa);
        for (self.trash.items) |b| self.gpa.free(b);
        self.trash.deinit(self.gpa);
        self.interned.deinit(self.gpa);
    }

    /// 当前池内块数（诊断/测试用；不含待释放的 trash）。
    pub fn blockCount(self: *const StringStore) usize {
        return self.blocks.items.len;
    }

    /// 无条件释放 trash（测试 / StringStore.deinit 前用）。
    /// App 走 freeTrashOlderThan：只在跨帧后才释放，避免帧中途的 dvui 控件
    /// 仍握着刚被判死旧串的切片。
    pub fn freeTrash(self: *StringStore) void {
        for (self.trash.items) |b| self.gpa.free(b);
        self.trash.clearRetainingCapacity();
    }

    /// 帧安全版 freeTrash：只释放「上一帧或更早」判死的块。
    /// epoch 由调用方按帧递增（App.tickFrame）；同帧内重复调用不会释放
    /// 本轮刚进 trash 的块。不跑 GC 时 trash 最终由 deinit 统一回收。
    pub fn freeTrashOlderThan(self: *StringStore, epoch: u64) void {
        if (self.trash_epoch >= epoch) return;
        self.freeTrash();
    }

    /// 启发式：块数（含待释放 trash）超过上轮 GC 存活数的 2 倍（留 64 块余量）
    /// 就值得跑一轮 GC。调用点建议放在 pushSnapshot（快照被挤掉/redo 被清空）之后。
    pub fn shouldGc(self: *const StringStore) bool {
        return self.blocks.items.len + self.trash.items.len >
            self.live_after_last_gc * 2 + 64;
    }

    /// 分配并登记进 GC 全集。
    fn allocTracked(self: *StringStore, n: usize) Allocator.Error![]u8 {
        const buf = try self.gpa.alloc(u8, n);
        errdefer self.gpa.free(buf);
        try self.blocks.append(self.gpa, buf);
        return buf;
    }

    /// 「改值」的入口之一：复制 s 进池，得到新 ZString（java: new String(s)）。
    /// 空串直接返回共享常量，零分配。旧串无需释放——仍被快照引用的继续存活，
    /// 无主的由 GC 回收。
    pub fn create(self: *StringStore, s: []const u8) Allocator.Error!ZString {
        if (s.len == 0) return .empty;
        const buf = try self.allocTracked(s.len);
        @memcpy(buf, s);
        return .{ .bytes = buf };
    }

    /// 同 create，但同内容只存一份（java: String.intern()）。
    /// 50 层快照之间对重复词（如「待办」「完成」）共享更彻底。
    /// 驻留表是弱表：无主后照常被 GC 回收，下次 intern 再建。
    pub fn intern(self: *StringStore, s: []const u8) Allocator.Error!ZString {
        if (s.len == 0) return .empty;
        if (self.interned.get(s)) |hit| return hit;
        const buf = try self.allocTracked(s.len);
        @memcpy(buf, s);
        // 驻留失败不致命：退化为普通串（块已登记，GC/deinit 照常回收）
        self.interned.put(self.gpa, buf, .{ .bytes = buf }) catch {};
        return .{ .bytes = buf };
    }

    /// 格式化出一个新 ZString（java: String.format）。
    pub fn createFmt(self: *StringStore, comptime fmt: []const u8, args: anytype) Allocator.Error!ZString {
        const buf = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(buf);
        try self.blocks.append(self.gpa, buf);
        return .{ .bytes = buf };
    }

    /// 拼接出新 ZString（java: concat）。
    pub fn concat(self: *StringStore, a: []const u8, b: []const u8) Allocator.Error!ZString {
        if (a.len == 0) return self.create(b);
        if (b.len == 0) return self.create(a);
        const buf = try self.allocTracked(a.len + b.len);
        @memcpy(buf[0..a.len], a);
        @memcpy(buf[a.len..], b);
        return .{ .bytes = buf };
    }

    /// 开启一轮 mark-sweep GC。用法见文件头。
    pub fn beginGc(self: *StringStore) Gc {
        return .{ .store = self };
    }

    /// 带 epoch 的 GC（App 用）。sweep 会把当前 epoch 记进 trash_epoch，
    /// 供 freeTrashOlderThan 判断「这批垃圾是否已经跨帧」。
    pub fn beginGcEpoch(self: *StringStore, epoch: u64) Gc {
        return .{ .store = self, .epoch = epoch };
    }

    /// mark-sweep 回收器：mark 所有存活 ZString，sweep 释放其余。
    /// 借用串（fromSlice/字面量）与空串不在 blocks 里，天然免回收。
    pub const Gc = struct {
        store: *StringStore,
        /// 本轮 GC 所属的帧号（beginGcEpoch 传入；无 epoch 时为 0）。
        epoch: u64 = 0,
        live: std.AutoHashMapUnmanaged(usize, void) = .empty,
        /// mark 阶段分配失败会置位。sweep 见此直接放弃本轮——标记不完整时
        /// 宁可整轮泄漏，绝不误释放还被引用的串。
        failed: bool = false,

        /// 标记一个仍存活的 ZString（根集合里的每一个）。
        pub fn mark(self: *Gc, z: ZString) void {
            if (z.bytes.len == 0) return;
            self.live.put(self.store.gpa, @intFromPtr(z.bytes.ptr), {}) catch {
                self.failed = true;
            };
        }

        /// 把未标记的串移进 trash（**延迟**到下轮 GC 的 freeTrash 才真正
        /// free，见结构体注释），回收 intern 弱表，结束本轮 GC。
        pub fn sweep(self: *Gc) void {
            defer self.live.deinit(self.store.gpa);
            if (self.failed) return;

            const store = self.store;
            var w: usize = 0;
            for (store.blocks.items) |b| {
                if (self.live.contains(@intFromPtr(b.ptr))) {
                    store.blocks.items[w] = b;
                    w += 1;
                } else {
                    // 弱表同步：键就是块内容，此刻仍有效，先摘项再判死。
                    // 只删「值恰好指向本块」的项——同内容的另一块可能是活的
                    // intern 项，不能误删。（块本体进 trash 延迟释放，
                    // 但弱表项必须现在摘，否则下一轮 intern 会命中
                    // 「内容相同但即将被释放」的旧键。）
                    if (store.interned.get(b)) |v| {
                        if (v.bytes.ptr == b.ptr) _ = store.interned.remove(b);
                    }
                    store.trash.append(store.gpa, b) catch store.gpa.free(b);
                }
            }
            store.blocks.shrinkRetainingCapacity(w);
            store.live_after_last_gc = w;
            store.trash_epoch = self.epoch;
        }
    };
};

const testing = std.testing;

test "create 复制字节：源缓冲改动不影响 ZString" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    var src: [5]u8 = "hello".*;
    const z = try store.create(&src);
    src[0] = 'H';
    try testing.expectEqualStrings("hello", z.slice());
}

test "赋值 = 引用共享：复制 ZString 只共享字节" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const a = try store.create("中心主题");
    const b = a; // 位拷贝 = 共享同一份字节
    try testing.expect(a.slice().ptr == b.slice().ptr);
    try testing.expect(b.eql(a));
}

test "改值 = 构造新串，旧串不受影响（copyOnWrite）" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const snap = try store.create("旧标题"); // 撤销快照持有的旧值
    var cur = snap; // 当前树先与快照共享同一份字节
    cur = try store.create("新标题"); // 改值 → 只构造新串

    try testing.expectEqualStrings("旧标题", snap.slice()); // 快照完好
    try testing.expectEqualStrings("新标题", cur.slice());
    try testing.expect(snap.slice().ptr != cur.slice().ptr);
}

test "intern 同内容共享同一份字节" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const a = try store.intern("确定");
    const b = try store.intern("确定");
    const c = try store.intern("取消");
    try testing.expect(a.slice().ptr == b.slice().ptr);
    try testing.expect(a.slice().ptr != c.slice().ptr);
    try testing.expect(c.eqlSlice("取消"));
}

test "空串零分配" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const a = try store.create("");
    const b = try store.intern("");
    try testing.expect(a.isEmpty());
    try testing.expect(b.isEmpty());
    try testing.expect(a.eql(b));
    try testing.expect(a.eqlSlice(""));
}

test "fromSlice 借用与只读查询" {
    // "分支一" 3 个汉字 × 3 字节，"-" 在字节下标 9
    const z = ZString.fromSlice("分支一-依赖");
    try testing.expectEqual(@as(usize, 16), z.len());
    try testing.expect(z.startsWith("分支"));
    try testing.expect(z.endsWith("依赖"));
    try testing.expect(z.contains("-"));
    try testing.expectEqual(@as(?usize, 9), z.indexOf("-"));
}

test "createFmt 与 concat" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const a = try store.createFmt("{s}-副本", .{"节点"});
    try testing.expectEqualStrings("节点-副本", a.slice());

    const b = try store.concat("未命名", "2");
    try testing.expectEqualStrings("未命名2", b.slice());

    const c = try store.concat("", "2");
    try testing.expectEqualStrings("2", c.slice());
}

test "GC 回收无主串，保留快照引用的串" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const snap = try store.create("旧标题"); // 被撤销快照引用
    const cur = try store.create("新标题"); // 当前树引用
    _ = try store.create("改废的中间版"); // 无主垃圾
    try testing.expectEqual(@as(usize, 3), store.blockCount());

    var g = store.beginGc();
    g.mark(snap);
    g.mark(cur);
    g.sweep();

    try testing.expectEqual(@as(usize, 2), store.blockCount());
    try testing.expectEqualStrings("旧标题", snap.slice());
    try testing.expectEqualStrings("新标题", cur.slice());
}

test "反复修改 title：快照释放后旧版本被 GC 回收" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    // 模拟 5 次提交：5 个版本各占一块
    var v: [5]ZString = undefined;
    for (&v, 0..) |*slot, i| {
        slot.* = try store.createFmt("标题-{d}", .{i});
    }
    try testing.expectEqual(@as(usize, 5), store.blockCount());

    // 一份撤销快照还引用第 2 版，当前树用第 4 版；其余是无主垃圾
    const snap = v[2];
    const cur = v[4];
    var g = store.beginGc();
    g.mark(snap);
    g.mark(cur);
    g.sweep();
    try testing.expectEqual(@as(usize, 2), store.blockCount());

    // 快照被挤掉（undo 深度溢出）后再回收，只剩当前版本
    var g2 = store.beginGc();
    g2.mark(cur);
    g2.sweep();
    try testing.expectEqual(@as(usize, 1), store.blockCount());
    try testing.expectEqualStrings("标题-4", cur.slice());
}

test "GC 同步清理 intern 弱表" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    _ = try store.intern("确定");
    try testing.expectEqual(@as(u32, 1), store.interned.count());

    // 无任何引用 → 串与弱表项一起回收
    var g = store.beginGc();
    g.sweep();
    try testing.expectEqual(@as(usize, 0), store.blockCount());
    try testing.expectEqual(@as(u32, 0), store.interned.count());

    // 再 intern 照常工作
    const again = try store.intern("确定");
    try testing.expectEqualStrings("确定", again.slice());

    // 被引用的 intern 串不回收，且仍维持同内容共享
    var g2 = store.beginGc();
    g2.mark(again);
    g2.sweep();
    try testing.expectEqual(@as(u32, 1), store.interned.count());
    const shared = try store.intern("确定");
    try testing.expect(shared.slice().ptr == again.slice().ptr);
}

test "GC 不误删同内容的 intern 项" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const shared = try store.intern("重复"); // intern 项指向的块
    const dup = try store.create("重复"); // 同内容的普通块
    try testing.expect(shared.slice().ptr != dup.slice().ptr);

    // 只标记 intern 那块：dup 无主被回收，但 intern 项必须保留
    var g = store.beginGc();
    g.mark(shared);
    g.sweep();
    try testing.expectEqual(@as(usize, 1), store.blockCount());
    try testing.expectEqual(@as(u32, 1), store.interned.count());

    const again = try store.intern("重复");
    try testing.expect(again.slice().ptr == shared.slice().ptr);
}

test "GC 天然放过借用串与空串" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const borrowed = ZString.fromSlice("字面量借用");
    _ = try store.create("池内串");

    var g = store.beginGc();
    g.mark(borrowed); // 标了也没事：借用串不在 blocks 里
    g.mark(.empty);
    g.sweep();

    try testing.expectEqual(@as(usize, 0), store.blockCount()); // 池内串无主被回收
    try testing.expectEqualStrings("字面量借用", borrowed.slice()); // 借用串原样
}

test "mark 失败时 sweep 保守放弃：只泄漏不误释放" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const keep = try store.create("保留");
    _ = try store.create("本该回收");

    var g = store.beginGc();
    g.mark(keep);
    g.failed = true; // 模拟 mark 阶段 OOM
    g.sweep();

    // 一块都没释放（宁可泄漏），keep 仍有效
    try testing.expectEqual(@as(usize, 2), store.blockCount());
    try testing.expectEqualStrings("保留", keep.slice());
}

test "sweep 延迟释放：判死的块进 trash，freeTrash 才回收" {
    var store = StringStore.init(testing.allocator);
    defer store.deinit();

    const keep = try store.create("保留");
    _ = try store.create("垃圾");

    var g = store.beginGc();
    g.mark(keep);
    g.sweep();
    // blocks 里已摘除，但块本体还在 trash 里等延迟释放
    try testing.expectEqual(@as(usize, 1), store.blockCount());
    try testing.expectEqual(@as(usize, 1), store.trash.items.len);

    // 释放窗口内新 intern 不会命中 trashed 旧键（同内容各造新块）
    const fresh = try store.intern("垃圾");
    try testing.expectEqual(@as(usize, 2), store.blockCount());

    store.freeTrash();
    try testing.expectEqual(@as(usize, 0), store.trash.items.len);
    try testing.expectEqualStrings("保留", keep.slice());
    try testing.expectEqualStrings("垃圾", fresh.slice());
}
