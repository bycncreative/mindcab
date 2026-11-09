//! zmind 脑图数据模型：节点树与纯树操作。
//! 只管数据，不依赖 UI / I/O —— 序列化见 xml.zig，布局见 layout.zig。
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 视图层几何信息。
/// x/y/w/h 每帧由 layout 重新计算；ox/oy 是用户拖拽偏移，叠加在自动布局之上，
/// 会话内保持（当前不随 XML 持久化）。
pub const Geometry = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    ox: f32 = 0,
    oy: f32 = 0,
};

/// 节点自定义颜色（RGBA 各 8 位）。纯数据类型，与 UI 库无关——
/// 视图层自行转成各自的颜色表示；XML 存取走 parseHex / formatHex。
pub const Rgba = struct {
    r: u8 = 0xff,
    g: u8 = 0xff,
    b: u8 = 0xff,
    a: u8 = 0xff,

    /// 解析 "#RRGGBB" / "#RRGGBBAA"（含可选前导 # 与大小写混写）；非法输入返回 null。
    pub fn parseHex(s: []const u8) ?Rgba {
        var hex = s;
        if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
        if (hex.len != 6 and hex.len != 8) return null;
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
        const a = if (hex.len == 8) std.fmt.parseInt(u8, hex[6..8], 16) catch return null else 0xff;
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// 写成 "#RRGGBB"（不透明）或 "#RRGGBBAA"；buf 至少 9 字节。
    pub fn formatHex(self: Rgba, buf: []u8) []const u8 {
        if (self.a == 0xff) {
            return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch buf[0..0];
        }
        return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b, self.a }) catch buf[0..0];
    }
};

/// 节点属性表的一行。name/value 用 ArrayList 以便 dvui textEntry 直接绑定
/// （与 Node.text/note/link 同款模式）。
pub const Property = struct {
    name: std.ArrayList(u8) = .empty,
    value: std.ArrayList(u8) = .empty,
};

/// 文档级图片资源池的一项。
///
/// 图片数据只存一份（不再内联进 `<node>`），节点只保留 `img_ref`（= 本项 id）：
/// 同一张图片被多个节点引用时不重复存储，保存/读取都只有一份 base64。
pub const ImageAsset = struct {
    /// 资源 id：内容寻址，取图片内容的 md5 十六进制（32 位小写）。
    /// 「同一图片」= 内容相同 → md5 相同 → 复用同一 id（见 ImageStore.ensure）。
    id: std.ArrayList(u8) = .empty,
    /// 图片类型（文件后缀 jpg / png）。
    img_type: std.ArrayList(u8) = .empty,
    /// 内容 md5（十六进制，与 id 相同；单独存一份，读取/校验时可直接比对）。
    md5: std.ArrayList(u8) = .empty,
    /// 图片原始二进制（保存时才做 base64 编码）。
    data: std.ArrayList(u8) = .empty,

    fn deinit(self: *ImageAsset, gpa: Allocator) void {
        self.id.deinit(gpa);
        self.img_type.deinit(gpa);
        self.md5.deinit(gpa);
        self.data.deinit(gpa);
    }
};

/// 文档的图片池：按加入顺序保存所有被引用过的图片资源。
/// 只增不删（撤销/换图后旧资源可能被重做重新引用，删掉会让重做丢图）；
/// 保存时只写出「当前树里确实引用到的」资源（见 xml.writeImages）。
pub const ImageStore = struct {
    items: std.ArrayList(ImageAsset) = .empty,

    pub fn deinit(self: *ImageStore, gpa: Allocator) void {
        for (self.items.items) |*a| a.deinit(gpa);
        self.items.deinit(gpa);
    }

    /// 池内资源数量。
    pub fn count(self: *const ImageStore) usize {
        return self.items.items.len;
    }

    pub fn findById(self: *const ImageStore, id: []const u8) ?*ImageAsset {
        for (self.items.items) |*a| {
            if (std.mem.eql(u8, a.id.items, id)) return a;
        }
        return null;
    }

    pub fn findByMd5(self: *const ImageStore, md5: []const u8) ?*ImageAsset {
        for (self.items.items) |*a| {
            if (std.mem.eql(u8, a.md5.items, md5)) return a;
        }
        return null;
    }

    /// 直接登记一项（读取 XML 时用：id/type/md5 已由文件给出）。
    /// id 为空或已存在时按 md5 计算 id 并复用已有项。返回该资源。
    pub fn add(
        self: *ImageStore,
        gpa: Allocator,
        id: []const u8,
        img_type: []const u8,
        md5: []const u8,
        data: []const u8,
    ) !*ImageAsset {
        var a: ImageAsset = .{};
        errdefer a.deinit(gpa);
        try a.id.appendSlice(gpa, id);
        try a.img_type.appendSlice(gpa, img_type);
        try a.md5.appendSlice(gpa, md5);
        try a.data.appendSlice(gpa, data);
        try self.items.append(gpa, a);
        return &self.items.items[self.items.items.len - 1];
    }

    /// 按内容登记图片并返回其 id：md5 已存在则直接复用（不重复存数据）。
    /// 返回的切片指向资源自身的 id 缓冲，不随 items 扩容失效。
    pub fn ensure(self: *ImageStore, gpa: Allocator, img_type: []const u8, data: []const u8) ![]const u8 {
        var hexbuf: [32]u8 = undefined;
        const hex = md5Hex(data, &hexbuf);
        if (self.findByMd5(hex)) |a| return a.id.items;
        const a = try self.add(gpa, hex, img_type, hex, data);
        return a.id.items;
    }
};

/// 计算内容的 md5，写成 32 位小写十六进制（out 至少 32 字节）。
pub fn md5Hex(data: []const u8, out: *[32]u8) []const u8 {
    const Md5 = std.crypto.hash.Md5;
    const digest = Md5.hashResult(data);
    for (digest, 0..) |b, i| {
        const pair = std.fmt.bytesToHex(@as([1]u8, @splat(b)), .lower);
        out[i * 2] = pair[0];
        out[i * 2 + 1] = pair[1];
    }
    return out[0..32];
}

pub const Node = struct {
    id: u32,
    /// 导出排序值：文档导出（docx/markdown）时子节点按 seq * 10_000_000 + id
    /// 升序排列（u64）。没有 seq 的节点取默认值 0。随 XML 持久化。
    seq: u64 = 0,
    /// 标题（必显示）
    text: std.ArrayList(u8) = .empty,
    /// 正文描述（可选；为空时节点只渲染标题，非空时以略小字体显示在标题下方）
    note: std.ArrayList(u8) = .empty,
    /// 连接线标题（可选）：本节点与父节点之间那条连线的标签，如「依赖」「包含」。
    /// 存在子节点自己身上（边的另一端就是父节点），根节点没有父连线故此字段无意义。
    link: std.ArrayList(u8) = .empty,
    /// 自定义背景色（可选；null = 跟随主题默认）。
    bg: ?Rgba = null,
    /// 用户手动调整的节点尺寸（拖拽右/下边缘得到；null = 跟随自动布局）。
    /// 语义是「下限」：实际框取 max(自动尺寸, 手动尺寸)——文字变长时框仍会
    /// 自动变宽，手动拖小到内容以下时自动尺寸兜底（不裁字）。随 XML 持久化。
    user_w: ?f32 = null,
    user_h: ?f32 = null,
    collapsed: bool = false,
    /// 节点图片引用：指向文档图片池（ImageStore）里某项的 id；空 = 无图片。
    /// 图片数据不在节点里（同一张图可被多个节点共享），保存时写
    /// `<images><img id="...">…</img></images>` + 节点内 `<img ref="..." />`。
    img_ref: std.ArrayList(u8) = .empty,
    /// 属性表：有序（name, value）对，保存时写 <property name="...">value</property>。
    properties: std.ArrayList(Property) = .empty,
    children: std.ArrayList(*Node) = .empty,
    parent: ?*Node = null,
    geom: Geometry = .{},

    pub fn deinit(self: *Node, gpa: Allocator) void {
        for (self.children.items) |c| c.deinit(gpa);
        self.children.deinit(gpa);
        self.text.deinit(gpa);
        self.note.deinit(gpa);
        self.link.deinit(gpa);
        self.img_ref.deinit(gpa);
        for (self.properties.items) |*p| {
            p.name.deinit(gpa);
            p.value.deinit(gpa);
        }
        self.properties.deinit(gpa);
        gpa.destroy(self);
    }

    /// 是否引用了节点图片（决定布局是否预留图标位、画布是否渲染图标）。
    pub fn hasImg(self: *const Node) bool {
        return self.img_ref.items.len > 0;
    }

    /// 是否有正文描述（决定布局是否预留第二行、画布是否渲染描述）。
    pub fn hasNote(self: *const Node) bool {
        return self.note.items.len > 0;
    }

    /// 是否有连接线标题（决定画布是否在连线中点渲染标签）。
    pub fn hasLink(self: *const Node) bool {
        return self.link.items.len > 0;
    }
};

/// 覆盖式写入标题。
pub fn setText(gpa: Allocator, node: *Node, s: []const u8) !void {
    node.text.clearRetainingCapacity();
    try node.text.appendSlice(gpa, s);
}

/// 覆盖式写入正文描述（传空串即清除描述，节点退回只显示标题）。
pub fn setNote(gpa: Allocator, node: *Node, s: []const u8) !void {
    node.note.clearRetainingCapacity();
    try node.note.appendSlice(gpa, s);
}

/// 覆盖式写入连接线标题（传空串即清除标签，连线恢复为无标题）。
pub fn setLink(gpa: Allocator, node: *Node, s: []const u8) !void {
    node.link.clearRetainingCapacity();
    try node.link.appendSlice(gpa, s);
}

/// 覆盖式写入节点图片引用（传空串即清除引用；资源本身留在文档图片池里）。
pub fn setImgRef(gpa: Allocator, node: *Node, id: []const u8) !void {
    node.img_ref.clearRetainingCapacity();
    try node.img_ref.appendSlice(gpa, id);
}

/// 清除节点图片引用。
pub fn clearImgRef(node: *Node) void {
    node.img_ref.clearRetainingCapacity();
}

/// 追加一条属性（name/value 深拷贝进列表）。
pub fn addProperty(gpa: Allocator, node: *Node, name: []const u8, value: []const u8) !void {
    var p: Property = .{};
    errdefer {
        p.name.deinit(gpa);
        p.value.deinit(gpa);
    }
    try p.name.appendSlice(gpa, name);
    try p.value.appendSlice(gpa, value);
    try node.properties.append(gpa, p);
}

/// 覆盖式写入某条属性的 name（idx 越界时无操作）。
pub fn setPropertyName(gpa: Allocator, node: *Node, idx: usize, s: []const u8) !void {
    if (idx >= node.properties.items.len) return;
    node.properties.items[idx].name.clearRetainingCapacity();
    try node.properties.items[idx].name.appendSlice(gpa, s);
}

/// 覆盖式写入某条属性的 value（idx 越界时无操作）。
pub fn setPropertyValue(gpa: Allocator, node: *Node, idx: usize, s: []const u8) !void {
    if (idx >= node.properties.items.len) return;
    node.properties.items[idx].value.clearRetainingCapacity();
    try node.properties.items[idx].value.appendSlice(gpa, s);
}

/// 删除某条属性（idx 越界时无操作）。
pub fn removeProperty(gpa: Allocator, node: *Node, idx: usize) void {
    if (idx >= node.properties.items.len) return;
    var p = node.properties.orderedRemove(idx);
    p.name.deinit(gpa);
    p.value.deinit(gpa);
}

pub fn createNode(gpa: Allocator, id: u32, text: []const u8) !*Node {
    const n = try gpa.create(Node);
    errdefer gpa.destroy(n);
    n.* = .{ .id = id };
    try n.text.appendSlice(gpa, text);
    return n;
}

/// 在 parent 下追加子节点，并自动展开 parent。
pub fn addChild(gpa: Allocator, parent: *Node, id: u32, text: []const u8) !*Node {
    const n = try createNode(gpa, id, text);
    errdefer n.deinit(gpa);
    try parent.children.append(gpa, n);
    n.parent = parent;
    parent.collapsed = false;
    return n;
}

/// 在 node 后插入同级节点；root 无同级，退化为添加子节点。
pub fn addSibling(gpa: Allocator, node: *Node, id: u32, text: []const u8) !*Node {
    const parent = node.parent orelse return addChild(gpa, node, id, text);
    const n = try createNode(gpa, id, text);
    errdefer n.deinit(gpa);
    const idx = std.mem.indexOfScalar(*Node, parent.children.items, node) orelse return error.NotFound;
    try parent.children.insert(gpa, idx + 1, n);
    n.parent = parent;
    return n;
}

/// 删除节点（连同子树）。root 不可删。
pub fn remove(gpa: Allocator, node: *Node) void {
    const parent = node.parent orelse return;
    const idx = std.mem.indexOfScalar(*Node, parent.children.items, node) orelse return;
    _ = parent.children.orderedRemove(idx);
    node.deinit(gpa);
}

/// 把 node 从当前父节点的 children 摘下但不销毁（重挂父用）：parent 置 null，
/// node 的子树原样保留。root（无父）原样返回。
pub fn detach(node: *Node) void {
    const parent = node.parent orelse return;
    if (std.mem.indexOfScalar(*Node, parent.children.items, node)) |idx| {
        _ = parent.children.orderedRemove(idx);
    }
    node.parent = null;
}

/// anc 是否是 node 的祖先（或就是 node 自身）。
pub fn isAncestor(anc: *const Node, node: *const Node) bool {
    var cur: ?*const Node = node;
    while (cur) |c| {
        if (c == anc) return true;
        cur = c.parent;
    }
    return false;
}

pub fn find(root: *Node, id: u32) ?*Node {
    if (root.id == id) return root;
    for (root.children.items) |c| {
        if (find(c, id)) |hit| return hit;
    }
    return null;
}

/// 深拷贝整棵子树，返回独立的镜像树（撤销/重做快照用）。
/// 复制 id / seq / 文本 / 折叠状态 / geom（含拖拽偏移 ox/oy，否则撤销会把用户
/// 手动挪过的节点弹回自动布局位置）；parent 指针在拷贝内部重建。
pub fn cloneTree(gpa: Allocator, node: *const Node) !*Node {
    const n = try gpa.create(Node);
    n.* = .{
        .id = node.id,
        .seq = node.seq,
        .collapsed = node.collapsed,
        .bg = node.bg,
        .user_w = node.user_w,
        .user_h = node.user_h,
        .geom = node.geom,
    };
    errdefer n.deinit(gpa);
    try n.text.appendSlice(gpa, node.text.items);
    try n.note.appendSlice(gpa, node.note.items);
    try n.link.appendSlice(gpa, node.link.items);
    try n.img_ref.appendSlice(gpa, node.img_ref.items);
    try n.properties.ensureTotalCapacity(gpa, node.properties.items.len);
    for (node.properties.items) |p| {
        var cp: Property = .{};
        errdefer {
            cp.name.deinit(gpa);
            cp.value.deinit(gpa);
        }
        try cp.name.appendSlice(gpa, p.name.items);
        try cp.value.appendSlice(gpa, p.value.items);
        n.properties.appendAssumeCapacity(cp);
    }
    // 先备足容量：后面 appendAssumeCapacity 就不会在「子节点已分配、还没挂上」
    // 的半成品状态里失败（那种状态下 deinit 会漏掉刚克隆的子树）
    try n.children.ensureTotalCapacity(gpa, node.children.items.len);
    for (node.children.items) |c| {
        const cc = try cloneTree(gpa, c);
        n.children.appendAssumeCapacity(cc);
        cc.parent = n;
    }
    return n;
}

/// 浅拷贝：只复制节点自身的内容（标题/描述/连线标题/颜色/尺寸/属性/图片引用），
/// **不含子节点**，parent 置 null。剪贴板（Ctrl+C）用它。
/// geom 与 collapsed 属于视图状态，不复制：粘贴出来的新节点按自动布局落位、
/// 保持展开，否则会带着原节点的拖拽偏移叠在原节点上。
pub fn cloneShallow(gpa: Allocator, node: *const Node) !*Node {
    const n = try gpa.create(Node);
    n.* = .{
        .id = node.id,
        .seq = node.seq,
        .bg = node.bg,
        .user_w = node.user_w,
        .user_h = node.user_h,
    };
    errdefer n.deinit(gpa);
    try n.text.appendSlice(gpa, node.text.items);
    try n.note.appendSlice(gpa, node.note.items);
    try n.link.appendSlice(gpa, node.link.items);
    try n.img_ref.appendSlice(gpa, node.img_ref.items);
    try n.properties.ensureTotalCapacity(gpa, node.properties.items.len);
    for (node.properties.items) |p| {
        var cp: Property = .{};
        errdefer {
            cp.name.deinit(gpa);
            cp.value.deinit(gpa);
        }
        try cp.name.appendSlice(gpa, p.name.items);
        try cp.value.appendSlice(gpa, p.value.items);
        n.properties.appendAssumeCapacity(cp);
    }
    return n;
}

pub fn countNodes(root: *Node) usize {
    var n: usize = 1;
    for (root.children.items) |c| n += countNodes(c);
    return n;
}

/// 子树内最大 id（打开文件后用于分配下一个 id）。
pub fn maxId(node: *Node) u32 {
    var m = node.id;
    for (node.children.items) |c| m = @max(m, maxId(c));
    return m;
}

/// 折叠/展开整个子树（调用方自行决定 root 是否保持展开）。
pub fn setCollapseAll(node: *Node, collapsed: bool) void {
    node.collapsed = collapsed;
    for (node.children.items) |c| setCollapseAll(c, collapsed);
}

/// 文档导出（docx/markdown）的子节点排序键：seq * 10_000_000 + id。
/// seq 缺省 0；乘加用回绕运算，seq 极大时也不 panic。
pub fn exportSortKey(node: *const Node) u64 {
    return node.seq *% 10_000_000 +% node.id;
}

/// 按导出排序键升序（稳定）排好的子节点切片副本，调用方负责 free。
/// 返回副本而不是就地排序：树本身（画布布局、撤销快照）的子节点顺序
/// 不应被一次文档导出改变。
pub fn childrenForExport(alloc: Allocator, node: *const Node) ![]*Node {
    const copy = try alloc.dupe(*Node, node.children.items);
    std.sort.insertion(*Node, copy, {}, struct {
        fn lessThan(_: void, a: *Node, b: *Node) bool {
            return exportSortKey(a) < exportSortKey(b);
        }
    }.lessThan);
    return copy;
}
