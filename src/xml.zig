//! zmind 脑图 XML 序列化与反序列化。
//! 文件格式（UTF-8）：
//! <?xml version="1.0" encoding="UTF-8"?>
//! <mindmap version="2" position="true">
//!   <images>
//!     <img id="<md5>" type="png" md5="<md5>">BASE64图片数据</img>
//!   </images>
//!   <node id="1" text="中心主题" desc="可选的正文描述" left="48" top="60">
//!     <img ref="<md5>" />
//!     <property name="权重">1</property>
//!     <node id="2" text="分支" collapsed="1"/>
//!   </node>
//! </mindmap>
//!
//! text = 标题；desc = 正文描述（可省略，省略则节点只显示标题）；
//! link = 连接线标题（本节点与父节点之间那条连线的标签，可省略）。
//! seq = 导出排序值（非负整数，可省略，省略即 0；文档导出按 seq*10^7+id 排序）。
//! left / top = 节点保存时在视图中的位置（整数，四舍五入）。
//! position = "true" 表示文档保存了各节点的视口位置：打开时按 left/top 恢复，
//! 没写 left/top 的节点退回自动布局位置；没有该标记的文档整体自动排版。
//! bg = 节点自定义背景色 "#RRGGBB" / "#RRGGBBAA"（可省略，省略则跟随主题）。
//! w / h = 用户手动调整的节点尺寸下限（整数，可省略；实际框取 max(自动, 手动)）。
//! images = 文档级图片池：所有图片数据集中放这里（一份），节点只用
//!          <img ref="..."/> 引用其 id。id 取图片内容的 md5（32 位小写十六进制），
//!          因此同一张图片（内容相同）自动复用同一 id、文件里只存一份；
//!          md5 属性是它的缓存值（与 id 相同），读取时可用来校验/复用。
//! property = 节点属性表一行（name 属性为名，正文为值，可多条按序显示）。
//! version 2 起新增 img/property 与 images 池；version 1 的文件无这些元素，
//! 天然兼容；2.0 早期把 base64 内联在节点 <img type="..."> 里的文件也能读
//! （读取时转成 images 池 + ref）。
//! 换行等控制字符以数字字符引用（&#10;）转义，保证往返一致。
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Node = model.Node;

pub const ParseError = error{
    MalformedXml,
    OutOfMemory,
    Overflow,
};

// ---------------------------------------------------------------------------
// 写出
// ---------------------------------------------------------------------------

fn escapeInto(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&apos;"),
        // 属性里的换行会被 XML 解析器规范化成空格，用数字字符引用保真
        '\n' => try out.appendSlice(gpa, "&#10;"),
        '\r' => try out.appendSlice(gpa, "&#13;"),
        '\t' => try out.appendSlice(gpa, "&#9;"),
        else => try out.append(gpa, c),
    };
}

fn writeNode(out: *std.ArrayList(u8), gpa: Allocator, node: *Node, depth: usize) !void {
    try out.appendNTimes(gpa, ' ', depth * 2);
    var idbuf: [16]u8 = undefined;
    const ids = try std.fmt.bufPrint(&idbuf, "{d}", .{node.id});
    try out.appendSlice(gpa, "<node id=\"");
    try out.appendSlice(gpa, ids);
    try out.appendSlice(gpa, "\" text=\"");
    try escapeInto(out, gpa, node.text.items);
    if (node.hasNote()) {
        try out.appendSlice(gpa, "\" desc=\"");
        try escapeInto(out, gpa, node.note.items);
    }
    if (node.hasLink()) {
        try out.appendSlice(gpa, "\" link=\"");
        try escapeInto(out, gpa, node.link.items);
    }
    if (node.seq != 0) {
        var seqbuf: [24]u8 = undefined;
        const seqs = std.fmt.bufPrint(&seqbuf, "{d}", .{node.seq}) catch "0";
        try out.appendSlice(gpa, "\" seq=\"");
        try out.appendSlice(gpa, seqs);
    }
    if (node.bg) |bg| {
        var hexbuf: [9]u8 = undefined;
        try out.appendSlice(gpa, "\" bg=\"");
        try out.appendSlice(gpa, bg.formatHex(&hexbuf));
    }
    if (node.user_w) |uw| {
        var numbuf: [16]u8 = undefined;
        const ws = std.fmt.bufPrint(&numbuf, "{d}", .{@as(i64, @intFromFloat(@round(uw)))}) catch "0";
        try out.appendSlice(gpa, "\" w=\"");
        try out.appendSlice(gpa, ws);
    }
    if (node.user_h) |uh| {
        var numbuf: [16]u8 = undefined;
        const hs = std.fmt.bufPrint(&numbuf, "{d}", .{@as(i64, @intFromFloat(@round(uh)))}) catch "0";
        try out.appendSlice(gpa, "\" h=\"");
        try out.appendSlice(gpa, hs);
    }
    // 视口位置：保存的是叠加拖拽偏移后的最终位置（layout 后的 geom.x/y）。
    // 还没排版过（geom 是 NaN 占位）时写 0，加载端按「未保存」退回自动布局。
    {
        const lx: f32 = if (std.math.isNan(node.geom.x)) 0 else node.geom.x;
        const ly: f32 = if (std.math.isNan(node.geom.y)) 0 else node.geom.y;
        var lxbuf: [16]u8 = undefined;
        var lybuf: [16]u8 = undefined;
        const ls = std.fmt.bufPrint(&lxbuf, "{d}", .{@as(i64, @intFromFloat(@round(lx)))}) catch "0";
        const ts = std.fmt.bufPrint(&lybuf, "{d}", .{@as(i64, @intFromFloat(@round(ly)))}) catch "0";
        try out.appendSlice(gpa, "\" left=\"");
        try out.appendSlice(gpa, ls);
        try out.appendSlice(gpa, "\" top=\"");
        try out.appendSlice(gpa, ts);
    }
    if (node.collapsed) try out.appendSlice(gpa, "\" collapsed=\"1");
    const has_extras = node.hasImg() or node.properties.items.len > 0;
    if (node.children.items.len == 0 and !has_extras) {
        try out.appendSlice(gpa, "\"/>\n");
        return;
    }
    try out.appendSlice(gpa, "\">\n");
    try writeExtras(out, gpa, node, depth);
    for (node.children.items) |c| try writeNode(out, gpa, c, depth + 1);
    try out.appendNTimes(gpa, ' ', depth * 2);
    try out.appendSlice(gpa, "</node>\n");
}

/// 写 <node> 开头标签之后的子元素：图片引用（<img ref="..." />）与属性表。
/// 缩进比节点本身再深一级（depth 传的是节点自身深度）。
fn writeExtras(out: *std.ArrayList(u8), gpa: Allocator, node: *Node, depth: usize) !void {
    const indent = (depth + 1) * 2;
    if (node.hasImg()) {
        try out.appendNTimes(gpa, ' ', indent);
        try out.appendSlice(gpa, "<img ref=\"");
        try escapeInto(out, gpa, node.img_ref.items);
        try out.appendSlice(gpa, "\" />\n");
    }
    for (node.properties.items) |p| {
        try out.appendNTimes(gpa, ' ', indent);
        try out.appendSlice(gpa, "<property name=\"");
        try escapeInto(out, gpa, p.name.items);
        try out.appendSlice(gpa, "\">");
        try escapeInto(out, gpa, p.value.items);
        try out.appendSlice(gpa, "</property>\n");
    }
}

/// 收集树里实际引用到的图片 id（撤销/换图后池里可能残留没被引用的资源，
/// 只写引用到的，避免文件越存越大）。同一 id 只收一次。
fn collectImgRefs(gpa: Allocator, node: *const Node, refs: *std.ArrayList([]const u8)) !void {
    if (node.hasImg()) {
        var dup = false;
        for (refs.items) |r| {
            if (std.mem.eql(u8, r, node.img_ref.items)) {
                dup = true;
                break;
            }
        }
        if (!dup) try refs.append(gpa, node.img_ref.items);
    }
    for (node.children.items) |c| try collectImgRefs(gpa, c, refs);
}

/// 写 <images> 池：每个被引用的资源一条 <img id type md5>BASE64</img>。
/// 池里找不到的 ref（文件损坏/被别处删掉）直接跳过——节点照常加载，
/// 只是画不出图标。
fn writeImages(out: *std.ArrayList(u8), gpa: Allocator, root: *const Node, images: *const model.ImageStore, depth: usize) !void {
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(gpa);
    try collectImgRefs(gpa, root, &refs);

    try out.appendNTimes(gpa, ' ', depth * 2);
    try out.appendSlice(gpa, "<images>\n");
    const Enc = std.base64.standard.Encoder;
    for (refs.items) |id| {
        const asset = images.findById(id) orelse continue;
        const enc_len = Enc.calcSize(asset.data.items.len);
        const buf = try gpa.alloc(u8, enc_len);
        defer gpa.free(buf);
        const b64 = Enc.encode(buf, asset.data.items);
        try out.appendNTimes(gpa, ' ', (depth + 1) * 2);
        try out.appendSlice(gpa, "<img id=\"");
        try escapeInto(out, gpa, asset.id.items);
        try out.appendSlice(gpa, "\" type=\"");
        try escapeInto(out, gpa, asset.img_type.items);
        try out.appendSlice(gpa, "\" md5=\"");
        try escapeInto(out, gpa, asset.md5.items);
        try out.appendSlice(gpa, "\">");
        try out.appendSlice(gpa, b64);
        try out.appendSlice(gpa, "</img>\n");
    }
    try out.appendNTimes(gpa, ' ', depth * 2);
    try out.appendSlice(gpa, "</images>\n");
}

/// 序列化为 XML 文本（调用方负责 free）。
/// mindmap 标签带 position="true"：节点属性里写了 left/top（保存时的视口位置），
/// 打开时按其恢复（见 layout.restoreSavedPositions）。
pub fn save(root: *Node, images: *const model.ImageStore, gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<mindmap version=\"2\" position=\"true\">\n");
    try writeImages(&out, gpa, root, images, 1);
    try writeNode(&out, gpa, root, 1);
    try out.appendSlice(gpa, "</mindmap>\n");
    return try out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// 读入（仅支持本格式）
// ---------------------------------------------------------------------------

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    gpa: Allocator,
    /// 文档图片池：<images> 块解析结果（节点 <img ref> 指向其中的 id）
    images: model.ImageStore = .{},
    /// mindmap 标签带 position="true"：节点属性里的 left/top 才有意义
    ///（解析时暂存进 geom.x/y，没写的节点用 NaN 占位）。
    positioned: bool = false,

    fn peek(self: *const Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn skipWs(self: *Parser) void {
        while (self.i < self.s.len and std.ascii.isWhitespace(self.s[self.i])) : (self.i += 1) {}
    }

    fn expect(self: *Parser, lit: []const u8) ParseError!void {
        if (self.i + lit.len > self.s.len or !std.mem.eql(u8, self.s[self.i..][0..lit.len], lit)) {
            return error.MalformedXml;
        }
        self.i += lit.len;
    }

    fn eat(self: *Parser, lit: []const u8) bool {
        if (self.i + lit.len <= self.s.len and std.mem.eql(u8, self.s[self.i..][0..lit.len], lit)) {
            self.i += lit.len;
            return true;
        }
        return false;
    }

    /// 跳过 <?...?>、<!--...-->、空白
    fn skipMisc(self: *Parser) ParseError!void {
        while (true) {
            self.skipWs();
            if (self.eat("<?")) {
                while (self.i + 1 < self.s.len and !(self.s[self.i] == '?' and self.s[self.i + 1] == '>')) : (self.i += 1) {}
                try self.expect("?>");
            } else if (self.eat("<!--")) {
                while (self.i + 2 < self.s.len and !std.mem.startsWith(u8, self.s[self.i..], "-->")) : (self.i += 1) {}
                try self.expect("-->");
            } else return;
        }
    }

    const NamedEntity = struct { lit: []const u8, ch: u21 };

    fn namedEntity(rest: []const u8) ?NamedEntity {
        const table = [_]NamedEntity{
            .{ .lit = "&amp;", .ch = '&' },
            .{ .lit = "&lt;", .ch = '<' },
            .{ .lit = "&gt;", .ch = '>' },
            .{ .lit = "&quot;", .ch = '"' },
            .{ .lit = "&apos;", .ch = '\'' },
        };
        for (table) |e| {
            if (std.mem.startsWith(u8, rest, e.lit)) return e;
        }
        return null;
    }

    /// 解析 `&#10;` / `&#xA;` 形式的数字字符引用。
    fn numericEntity(rest: []const u8) ParseError!?NamedEntity {
        if (!std.mem.startsWith(u8, rest, "&#")) return null;
        var j: usize = 2;
        var radix: u8 = 10;
        if (j < rest.len and (rest[j] == 'x' or rest[j] == 'X')) {
            radix = 16;
            j += 1;
        }
        const digits_start = j;
        while (j < rest.len and rest[j] != ';') : (j += 1) {}
        if (j >= rest.len) return error.MalformedXml;
        const cp = std.fmt.parseInt(u21, rest[digits_start..j], radix) catch return error.MalformedXml;
        return .{ .lit = rest[0 .. j + 1], .ch = cp };
    }

    fn unescape(self: *Parser, raw: []const u8) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var k: usize = 0;
        while (k < raw.len) {
            if (raw[k] != '&') {
                try out.append(self.gpa, raw[k]);
                k += 1;
                continue;
            }
            const rest = raw[k..];
            const ent = (try numericEntity(rest)) orelse namedEntity(rest) orelse return error.MalformedXml;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ent.ch, &buf) catch return error.MalformedXml;
            try out.appendSlice(self.gpa, buf[0..n]);
            k += ent.lit.len;
        }
        return try out.toOwnedSlice(self.gpa);
    }

    const Attr = struct { name: []const u8, raw: []const u8 };

    /// 读下一个属性（name="value"）。遇到标签结束（'>' 或自闭合的 '/'）
    /// 返回 null（不消费该字符）；其余情况返回属性名与原始值。
    fn nextAttr(self: *Parser) ParseError!?Attr {
        self.skipWs();
        const c = self.peek() orelse return error.MalformedXml;
        if (c == '>' or c == '/') return null;
        // 读 name
        const name_start = self.i;
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_' or self.s[self.i] == '-')) : (self.i += 1) {}
        const name = self.s[name_start..self.i];
        self.skipWs();
        try self.expect("=");
        self.skipWs();
        const quote = self.peek() orelse return error.MalformedXml;
        if (quote != '"' and quote != '\'') return error.MalformedXml;
        self.i += 1;
        const val_start = self.i;
        while (self.i < self.s.len and self.s[self.i] != quote) : (self.i += 1) {}
        const raw = self.s[val_start..self.i];
        self.i += 1; // 收尾引号
        return .{ .name = name, .raw = raw };
    }

    fn parseAttrs(self: *Parser, node: *Node) ParseError!void {
        while (try self.nextAttr()) |a| {
            const name = a.name;
            const raw = a.raw;

            if (std.mem.eql(u8, name, "text")) {
                const t = try self.unescape(raw);
                node.text.deinit(self.gpa);
                node.text = .empty;
                node.text.appendSlice(self.gpa, t) catch return error.OutOfMemory;
                self.gpa.free(t);
            } else if (std.mem.eql(u8, name, "desc") or std.mem.eql(u8, name, "note")) {
                const t = try self.unescape(raw);
                node.note.deinit(self.gpa);
                node.note = .empty;
                node.note.appendSlice(self.gpa, t) catch return error.OutOfMemory;
                self.gpa.free(t);
            } else if (std.mem.eql(u8, name, "link")) {
                const t = try self.unescape(raw);
                node.link.deinit(self.gpa);
                node.link = .empty;
                node.link.appendSlice(self.gpa, t) catch return error.OutOfMemory;
                self.gpa.free(t);
            } else if (std.mem.eql(u8, name, "collapsed")) {
                node.collapsed = std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true");
            } else if (std.mem.eql(u8, name, "seq")) {
                // 导出排序值：负数 / 非法值忽略（退回默认 0，对未知来源的文件宽容）
                node.seq = std.fmt.parseInt(u64, raw, 10) catch 0;
            } else if (std.mem.eql(u8, name, "left")) {
                // 保存的视口位置：仅在 position="true" 的文档里有意义；
                // 非法值退回 NaN（恢复时按「未保存」走自动布局）
                if (self.positioned) node.geom.x = std.fmt.parseFloat(f32, raw) catch std.math.nan(f32);
            } else if (std.mem.eql(u8, name, "top")) {
                if (self.positioned) node.geom.y = std.fmt.parseFloat(f32, raw) catch std.math.nan(f32);
            } else if (std.mem.eql(u8, name, "bg")) {
                // 非法颜色值不报错，退回跟随主题（对未知来源的文件宽容）
                node.bg = model.Rgba.parseHex(raw);
            } else if (std.mem.eql(u8, name, "w") or std.mem.eql(u8, name, "h")) {
                // 手动尺寸下限：非正整数 / 非法值忽略（退回自动布局）
                if (std.fmt.parseInt(i32, raw, 10)) |v| {
                    if (v > 0) {
                        if (name[0] == 'w') node.user_w = @floatFromInt(v) else node.user_h = @floatFromInt(v);
                    }
                } else |_| {}
            } else if (std.mem.eql(u8, name, "id")) {
                node.id = std.fmt.parseInt(u32, raw, 10) catch node.id;
            }
        }
    }

    /// 读元素文本直到遇到 close_lit（不含该闭合标签本身）。
    /// title/属性值均经转义，原始文本里不会出现裸 '<'，扫描安全。
    fn readTextUntil(self: *Parser, close_lit: []const u8) ParseError![]const u8 {
        const start = self.i;
        while (self.i < self.s.len and !std.mem.startsWith(u8, self.s[self.i..], close_lit)) : (self.i += 1) {}
        if (self.i >= self.s.len) return error.MalformedXml;
        const raw = self.s[start..self.i];
        try self.expect(close_lit);
        self.skipWs();
        try self.expect(">");
        return raw;
    }

    /// 解析 <images> 池：每条 <img id="..." type="..." md5="...">BASE64</img>。
    fn parseImagesBlock(self: *Parser) ParseError!void {
        try self.expect("<images");
        if (self.eat("/>")) return;
        try self.expect(">");
        while (true) {
            self.skipWs();
            if (self.eat("</")) {
                try self.expect("images");
                self.skipWs();
                try self.expect(">");
                return;
            }
            if (!std.mem.startsWith(u8, self.s[self.i..], "<img")) {
                if (self.peek() == '<') {
                    try self.skipUnknownElement();
                    continue;
                }
                return error.MalformedXml;
            }
            try self.expect("<img");
            var id: []const u8 = "";
            var img_type: []const u8 = "img";
            var md5_attr: []const u8 = "";
            while (try self.nextAttr()) |a| {
                if (std.mem.eql(u8, a.name, "id")) {
                    id = a.raw;
                } else if (std.mem.eql(u8, a.name, "type")) {
                    img_type = a.raw;
                } else if (std.mem.eql(u8, a.name, "md5")) {
                    md5_attr = a.raw;
                }
            }
            var data_buf: ?[]u8 = null;
            defer if (data_buf) |b| self.gpa.free(b);
            if (!self.eat("/>")) {
                try self.expect(">");
                const raw = try self.readTextUntil("</img");
                data_buf = try self.decodeBase64(raw);
            }
            const data = data_buf orelse continue; // 自闭合或坏数据：跳过该项
            var hexbuf: [32]u8 = undefined;
            const hex = model.md5Hex(data, &hexbuf);
            // id 缺失时用 md5 兜底；md5 属性只作缓存/校验，以实际内容为准
            const id_use = if (id.len > 0) id else hex;
            const md5_use = if (md5_attr.len > 0) md5_attr else hex;
            // 同一内容（md5）已存在则不重复登记，保留先出现的 id
            if (self.images.findByMd5(hex)) |_| continue;
            _ = self.images.add(self.gpa, id_use, img_type, md5_use, data) catch return error.OutOfMemory;
        }
    }

    /// base64 文本 → 原始字节；坏数据返回 null（容错，不中断整份文档）。
    fn decodeBase64(self: *Parser, raw: []const u8) ParseError!?[]u8 {
        const Dec = std.base64.standard.Decoder;
        const size = Dec.calcSizeForSlice(raw) catch return null;
        const buf = self.gpa.alloc(u8, size) catch return error.OutOfMemory;
        Dec.decode(buf, raw) catch {
            self.gpa.free(buf);
            return null;
        };
        return buf;
    }

    /// 解析节点内的 <img>：新格式只带 ref（自闭合引用）；
    /// 2.0 早期的内联格式（type + base64 正文）在这里转成池内资源 + 引用。
    fn parseImg(self: *Parser, node: *Node) ParseError!void {
        try self.expect("<img");
        var ref: []const u8 = "";
        var img_type: []const u8 = "jpg";
        while (try self.nextAttr()) |a| {
            if (std.mem.eql(u8, a.name, "ref")) {
                ref = a.raw;
            } else if (std.mem.eql(u8, a.name, "type")) {
                img_type = a.raw;
            }
        }
        if (self.eat("/>")) {
            if (ref.len > 0) model.setImgRef(self.gpa, node, ref) catch return error.OutOfMemory;
            return;
        }
        try self.expect(">");
        const raw = try self.readTextUntil("</img");
        const buf = (try self.decodeBase64(raw)) orelse return;
        defer self.gpa.free(buf);
        var hexbuf: [32]u8 = undefined;
        const hex = model.md5Hex(buf, &hexbuf);
        if (self.images.findByMd5(hex) == null) {
            _ = self.images.add(self.gpa, hex, img_type, hex, buf) catch return error.OutOfMemory;
        }
        model.setImgRef(self.gpa, node, hex) catch return error.OutOfMemory;
    }

    /// 解析 <property name="权重">1</property>；name 缺省空串。
    fn parseProperty(self: *Parser, node: *Node) ParseError!void {
        try self.expect("<property");
        var pname: []const u8 = "";
        while (try self.nextAttr()) |a| {
            if (std.mem.eql(u8, a.name, "name")) pname = a.raw;
        }
        try self.expect(">");
        const raw = try self.readTextUntil("</property");
        const n = try self.unescape(pname);
        defer self.gpa.free(n);
        const v = try self.unescape(raw);
        defer self.gpa.free(v);
        model.addProperty(self.gpa, node, n, v) catch return error.OutOfMemory;
    }

    /// 跳过未知子元素（到匹配的闭合标签），对将来格式扩展保持容错。
    fn skipUnknownElement(self: *Parser) ParseError!void {
        try self.expect("<");
        const name_start = self.i;
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_' or self.s[self.i] == '-')) : (self.i += 1) {}
        const name = self.s[name_start..self.i];
        if (name.len == 0) return error.MalformedXml;
        var depth: usize = 1;
        while (self.i < self.s.len) {
            if (self.eat("</")) {
                try self.expect(name);
                self.skipWs();
                try self.expect(">");
                depth -= 1;
                if (depth == 0) return;
            } else if (self.eat("<")) {
                if (self.peek() == '/') return error.MalformedXml;
                depth += 1;
            } else {
                self.i += 1;
            }
        }
        return error.MalformedXml;
    }

    fn parseNode(self: *Parser) ParseError!*Node {
        const node = try self.gpa.create(Node);
        errdefer self.gpa.destroy(node);
        node.* = .{ .id = 0 };
        if (self.positioned) {
            // position="true" 的文档：left/top 缺省 NaN 占位（属性没写 =
            // 恢复时该节点退回自动布局位置，见 layout.restoreSavedPositions）
            node.geom.x = std.math.nan(f32);
            node.geom.y = std.math.nan(f32);
        }
        try self.expect("<node");
        try self.parseAttrs(node);
        if (self.eat("/>")) return node;
        try self.expect(">");
        while (true) {
            self.skipWs();
            if (self.eat("</")) {
                try self.expect("node");
                self.skipWs();
                try self.expect(">");
                return node;
            }
            if (std.mem.startsWith(u8, self.s[self.i..], "<img")) {
                try self.parseImg(node);
            } else if (std.mem.startsWith(u8, self.s[self.i..], "<property")) {
                try self.parseProperty(node);
            } else if (std.mem.startsWith(u8, self.s[self.i..], "<node")) {
                const child = try self.parseNode();
                child.parent = node;
                try node.children.append(self.gpa, child);
            } else if (self.peek() == '<') {
                try self.skipUnknownElement();
            } else {
                return error.MalformedXml;
            }
        }
    }
};

/// load 的完整版：同时返回文档是否保存了视口位置（position="true"）
/// 与文档图片池（调用方负责 deinit root 与 images）。
/// positioned = true 时，各节点 geom.x/y 暂存了保存时的位置（没写的节点是
/// NaN），调用方用 layout.restoreSavedPositions 折算成拖拽偏移完成恢复。
pub const LoadResult = struct {
    root: *Node,
    positioned: bool,
    images: model.ImageStore,

    pub fn deinit(self: *LoadResult, gpa: Allocator) void {
        self.root.deinit(gpa);
        self.images.deinit(gpa);
        self.* = undefined;
    }
};

pub fn loadEx(gpa: Allocator, data: []const u8) !LoadResult {
    var p = Parser{ .s = data, .gpa = gpa };
    errdefer p.images.deinit(gpa);
    try p.skipMisc();
    try p.expect("<mindmap");
    // mindmap 标签属性：version 忽略；position="true" 表示按 left/top 恢复位置
    while (try p.nextAttr()) |a| {
        if (std.mem.eql(u8, a.name, "position")) {
            p.positioned = std.mem.eql(u8, a.raw, "true");
        }
    }
    if ((p.peek() orelse return error.MalformedXml) == '/') return error.MalformedXml;
    p.i += 1; // 收掉 '>'
    try p.skipMisc(); // 跳过 <mindmap> 与 <images>/根 <node> 之间的空白
    // 图片池在根节点之前；老文件没有这个块，直接进节点解析
    if (std.mem.startsWith(u8, p.s[p.i..], "<images")) {
        try p.parseImagesBlock();
        try p.skipMisc();
    }
    const root = try p.parseNode();
    try p.skipMisc();
    try p.expect("</mindmap");
    return .{ .root = root, .positioned = p.positioned, .images = p.images };
}

/// 解析整份文档，返回 root 节点（调用方负责 deinit）。
/// 不关心 position 标记 / 图片的调用方用这个；要恢复视口位置用 loadEx、
/// 要用节点图片用 loadEx（这里的图片池会随返回值释放）。
pub fn load(gpa: Allocator, data: []const u8) !*Node {
    var res = try loadEx(gpa, data);
    res.images.deinit(gpa);
    return res.root;
}
