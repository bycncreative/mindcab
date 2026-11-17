//! 导出 .docx（Word 的 OOXML 文档格式）。
//!
//! .docx 本体是一个 ZIP 包；std.zip 只有读，这里手写 store（不压缩）方式的
//! ZIP 写入——Word / WPS / LibreOffice 均接受不压缩条目，CRC32 用 std.hash.Crc32。
//! 条目少、文件名全 ASCII、总长远小于 4GB，ZIP64 无需考虑。包内是最小 OOXML 骨架：
//!   [Content_Types].xml           部件类型声明
//!   _rels/.rels                   包关系 → word/document.xml
//!   word/document.xml             正文（按节点层级生成标题/正文段落）
//!   word/_rels/document.xml.rels  document → styles
//!   word/styles.xml               Normal + Heading1..5（带 outlineLvl，导航窗格可用）
//!
//! 导出规则（菜单「文件 → 导出 → 导出为 docx」）：节点层级（根=1）≤5 的
//! 标题导出为对应级别的 Word 标题（Heading1..Heading5），更深的节点导出为
//! 正文段落；节点的 note（正文描述）导出在其标题/正文之后的正文段落。
//! 子节点顺序：按导出排序键 seq * 10_000_000 + id 升序（见 model.childrenForExport），
//! markdown 导出用同一顺序。
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

/// 层级（根节点 = 1）不超过该值的节点标题导出为 Word 标题样式，更深的为正文。
const max_heading_level = 5;

/// 把 root 所在的树导出为 .docx 写入 path。
pub fn exportToDocx(alloc: Allocator, io: std.Io, root: *model.Node, path: []const u8) !void {
    const data = try buildDocx(alloc, root);
    defer alloc.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch return error.OpenWriteFailed;
}

/// 生成完整 .docx 字节（ZIP 容器）。调用方负责 free 返回的内存。
pub fn buildDocx(alloc: Allocator, root: *model.Node) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer aw.deinit();

    // document.xml 必须有 OOXML 根元素：<w:document ...><w:body> 段落们
    // </w:body></w:document>。少了这层包装 Word 解析失败，文档显示为空
    // （markdown 是纯文本拼接没有这个问题）。
    try aw.writer.writeAll(document_head);
    try walkBody(alloc, &aw.writer, root, 1);
    try aw.writer.writeAll(document_tail);
    const doc_xml = try aw.toOwnedSlice();
    defer alloc.free(doc_xml);

    // [Content_Types].xml 按惯例放第一个条目
    const entries = [_]Entry{
        .{ .name = "[Content_Types].xml", .data = content_types_xml },
        .{ .name = "_rels/.rels", .data = root_rels_xml },
        .{ .name = "word/document.xml", .data = doc_xml },
        .{ .name = "word/_rels/document.xml.rels", .data = document_rels_xml },
        .{ .name = "word/styles.xml", .data = styles_xml },
    };
    return writeZip(alloc, &entries);
}

// ---------------------------------------------------------------------------
// document.xml：树的先序遍历 → 段落序列
// ---------------------------------------------------------------------------

fn walkBody(alloc: Allocator, w: *std.Io.Writer, node: *model.Node, depth: u32) !void {
    // 标题文本：层级 ≤5 → HeadingN，更深 → 正文段落（level 0）
    try writeParagraph(w, node.text.slice(), if (depth <= max_heading_level) depth else 0);
    // note（正文描述）跟在其后；按行拆成多段（Windows 换行 \r\n 去掉 \r）
    if (node.hasNote()) {
        var it = std.mem.splitScalar(u8, node.note.slice(), '\n');
        while (it.next()) |line_raw| {
            const line = if (std.mem.endsWith(u8, line_raw, "\r")) line_raw[0 .. line_raw.len - 1] else line_raw;
            if (line.len == 0) continue;
            try writeParagraph(w, line, 0);
        }
    }
    const kids = try model.childrenForExport(alloc, node);
    defer alloc.free(kids);
    for (kids) |c| try walkBody(alloc, w, c, depth + 1);
}

/// level 1..max_heading_level → HeadingN 样式；0 → 正文（无样式段落）。
fn writeParagraph(w: *std.Io.Writer, text: []const u8, level: u32) !void {
    if (level > 0) {
        try w.print("<w:p><w:pPr><w:pStyle w:val=\"Heading{d}\"/></w:pPr><w:r><w:t xml:space=\"preserve\">", .{level});
    } else {
        try w.writeAll("<w:p><w:r><w:t xml:space=\"preserve\">");
    }
    try writeEscapedXmlText(w, text);
    try w.writeAll("</w:t></w:r></w:p>");
}

/// XML 文本转义（&<>"'），并丢弃 XML 1.0 不允许的控制字符
///（C0 中仅保留 \t \n \r）——用户输入里混进控制符会让 Word 拒绝打开文档。
fn writeEscapedXmlText(w: *std.Io.Writer, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (entityOf(c)) |ent| {
            try w.writeAll(s[start..i]);
            try w.writeAll(ent);
            start = i + 1;
        } else if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') {
            try w.writeAll(s[start..i]);
            start = i + 1;
        }
    }
    try w.writeAll(s[start..]);
}

fn entityOf(c: u8) ?[]const u8 {
    return switch (c) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&apos;",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// ZIP 写入（全部 store 不压缩）
// ---------------------------------------------------------------------------

const Entry = struct {
    name: []const u8,
    data: []const u8,
};

fn writeZip(alloc: Allocator, entries: []const Entry) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(alloc, 4096);
    defer aw.deinit();
    const w = &aw.writer;

    // 各条目 local header 的起始偏移（中央目录要用）
    var offsets: [8]u32 = undefined;
    std.debug.assert(entries.len <= offsets.len);

    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(w.end);
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x03\x04"); // local file header 签名
        try writeU16(w, 20); // 解压所需版本
        try writeU16(w, 0); // 通用标志位（文件名全 ASCII，无需 UTF-8 位）
        try writeU16(w, 0); // 压缩方法：store
        try writeU16(w, 0); // 修改时间（1980-01-01，导出场景无意义）
        try writeU16(w, 0); // 修改日期
        try writeU32(w, crc);
        try writeU32(w, @intCast(e.data.len)); // 压缩后大小
        try writeU32(w, @intCast(e.data.len)); // 原始大小
        try writeU16(w, @intCast(e.name.len));
        try writeU16(w, 0); // extra 字段长度
        try w.writeAll(e.name);
        try w.writeAll(e.data);
    }

    const cd_offset: u32 = @intCast(w.end);
    for (entries, 0..) |e, i| {
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x01\x02"); // central directory header 签名
        try writeU16(w, 20); // 打包所用版本
        try writeU16(w, 20); // 解压所需版本
        try writeU16(w, 0); // 通用标志位
        try writeU16(w, 0); // 压缩方法
        try writeU16(w, 0); // 修改时间
        try writeU16(w, 0); // 修改日期
        try writeU32(w, crc);
        try writeU32(w, @intCast(e.data.len));
        try writeU32(w, @intCast(e.data.len));
        try writeU16(w, @intCast(e.name.len));
        try writeU16(w, 0); // extra 长度
        try writeU16(w, 0); // 注释长度
        try writeU16(w, 0); // 起始盘号
        try writeU16(w, 0); // 内部属性
        try writeU32(w, 0); // 外部属性
        try writeU32(w, offsets[i]);
        try w.writeAll(e.name);
    }
    const cd_size: u32 = @intCast(w.end - cd_offset);

    try w.writeAll("PK\x05\x06"); // end of central directory 签名
    try writeU16(w, 0); // 本盘号
    try writeU16(w, 0); // 中央目录所在盘
    try writeU16(w, @intCast(entries.len)); // 本盘条目数
    try writeU16(w, @intCast(entries.len)); // 总条目数
    try writeU32(w, cd_size);
    try writeU32(w, cd_offset);
    try writeU16(w, 0); // 注释长度

    return aw.toOwnedSlice();
}

fn writeU16(w: *std.Io.Writer, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try w.writeAll(&b);
}

fn writeU32(w: *std.Io.Writer, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}

// ---------------------------------------------------------------------------
// 静态 XML 部件（除 document.xml 外全部是固定内容）
// ---------------------------------------------------------------------------

const content_types_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    \\<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    \\<Default Extension="xml" ContentType="application/xml"/>
    \\<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    \\<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    \\</Types>
;

const root_rels_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    \\</Relationships>
;

const document_rels_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    \\</Relationships>
;

/// A4 页面 + 常规页边距；样式用 Word 内置标题的默认观感
/// （蓝色、逐级缩小、H4 斜体），outlineLvl 让 Word 导航窗格 / 目录识别层级。
const styles_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Times New Roman"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    \\<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    \\<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="60"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>
    \\<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="180" w:after="40"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>
    \\<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="40"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\<w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="120" w:after="40"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:i/><w:color w:val="2E74B5"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\<w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="120" w:after="40"/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:color w:val="2E74B5"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\</w:styles>
;

const document_head =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
;

const document_tail =
    \\<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800" w:header="851" w:footer="992" w:gutter="0"/><w:cols w:space="720"/></w:sectPr>
    \\</w:body></w:document>
;
