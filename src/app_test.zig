//! zmind 单元测试：`zig build test`。
//!
//! 只测不需要真实 OS 窗口的逻辑（多文档标签的状态隔离最容易被后续改动破坏）。
//! 菜单流程测试用 dvui.testing 的无头窗口跑真实控件树（旧版注释里「不能碰
//! current_window」的限制只针对 dvui.dialog 的模态框，无头窗口本身没问题）。
//! 注意：关闭「有未保存修改」的文档会弹 dvui 模态框的路径仍要避开。
const std = @import("std");
const dvui = @import("dvui");
const app_mod = @import("app.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const canvas = @import("canvas.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
const xml = @import("xml.zig");
const docx_mod = @import("docx.zig");
const markdown_mod = @import("markdown.zig");

test "新建 / 切换 / 关闭标签：每个标签是独立文档" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.docCount());
    try app.cmdNewDoc();
    try std.testing.expectEqual(@as(usize, 2), app.docCount());
    try std.testing.expectEqual(@as(usize, 1), app.active);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("未命名2", app.doc().title(&buf));

    app.cmdSelectTab(0);
    try std.testing.expectEqual(@as(usize, 0), app.active);
    try std.testing.expectEqualStrings("未命名1", app.doc().title(&buf));

    // 文档内容彼此独立：改当前文档不影响另一个
    app.cmdAddChild();
    try std.testing.expectEqual(@as(u32, 5), app.doc().next_id);
    app.cmdSelectTab(1);
    try std.testing.expectEqual(@as(u32, 4), app.doc().next_id);

    app.docAt(0).dirty = false; // 关闭干净文档（脏文档会走确认框，需要真实窗口）
    app.cmdCloseTab(0);
    try std.testing.expectEqual(@as(usize, 1), app.docCount());
    try std.testing.expectEqualStrings("未命名2", app.doc().title(&buf));
}

test "下一个 / 上一个标签到头绕回" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.cmdNewDoc();

    app.cmdNextTab();
    try std.testing.expectEqual(@as(usize, 0), app.active);
    app.cmdNextTab();
    try std.testing.expectEqual(@as(usize, 1), app.active);
    app.cmdPrevTab();
    try std.testing.expectEqual(@as(usize, 0), app.active);
}

test "关闭最后一个标签会自动补一个新示例文档" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.cmdCloseTab(0);
    try std.testing.expectEqual(@as(usize, 1), app.docCount());
    try std.testing.expectEqual(@as(usize, 0), app.active);
}

test "已打开路径不重复开标签 + 标签标题取文件名" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.cmdNewDoc();

    try std.testing.expect(app.docAt(0).setPath("D:/tmp/a.xml"));
    try std.testing.expect(app.docAt(1).setPath("D:/tmp/a.xml"));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a.xml", app.docAt(0).title(&buf));
    try std.testing.expectEqual(@as(?usize, 0), app.indexOfPath("D:/tmp/a.xml"));
    try std.testing.expectEqual(@as(?usize, null), app.indexOfPath("D:/tmp/b.xml"));
}

test "脏标记按文档独立统计" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.cmdNewDoc();
    app.docAt(0).dirty = true;
    try std.testing.expectEqual(@as(usize, 1), app.dirtyCount());
    app.cmdAddChild(); // 改当前（第二个）文档
    try std.testing.expectEqual(@as(usize, 2), app.dirtyCount());
}

// ---------------------------------------------------------------------------
// 撤销 / 重做（镜像快照）
// ---------------------------------------------------------------------------

test "加节点可撤销、可重做" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const before = model.countNodes(app.doc().root);
    try std.testing.expect(!app.canUndo());
    try std.testing.expect(!app.canRedo());

    app.cmdAddChild();
    try std.testing.expectEqual(before + 1, model.countNodes(app.doc().root));
    try std.testing.expect(app.canUndo());

    app.cmdUndo();
    try std.testing.expectEqual(before, model.countNodes(app.doc().root));
    try std.testing.expect(app.canRedo());

    app.cmdRedo();
    try std.testing.expectEqual(before + 1, model.countNodes(app.doc().root));
    try std.testing.expect(!app.canRedo());
}

test "撤销恢复被删除的整棵子树（文本 / 连线标题 / 正文都回来）" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const before = model.countNodes(app.doc().root);
    app.doc().selectSingle(2); // 示例树里的「分支一」（带正文描述）
    // 示例树连线默认无标题：测试自建一个，验证删除后撤销能整棵恢复
    const n0 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try model.setLink(app.gpa, n0, "测试连线");
    app.cmdDeleteSelected();
    try std.testing.expectEqual(before - 1, model.countNodes(app.doc().root));
    try std.testing.expect(model.find(app.doc().root, 2) == null);

    app.cmdUndo();
    try std.testing.expectEqual(before, model.countNodes(app.doc().root));
    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expectEqualStrings("分支一", n.text.items);
    try std.testing.expectEqualStrings("带正文描述的节点", n.note.items);
    try std.testing.expectEqualStrings("测试连线", n.link.items);
}

test "新的编辑让重做栈作废" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    app.cmdAddChild();
    app.cmdUndo();
    try std.testing.expect(app.canRedo());

    app.cmdAddChild(); // 从历史中间点继续编辑
    try std.testing.expect(!app.canRedo());
}

test "撤销栈按标签独立" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try app.cmdNewDoc(); // 当前是第二个标签

    app.cmdAddChild();
    try std.testing.expect(app.canUndo());

    app.cmdSelectTab(0);
    try std.testing.expect(!app.canUndo()); // 第一个标签没有任何历史
    try std.testing.expect(!app.canRedo());
}

test "撤销恢复折叠状态与选中项" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    app.cmdSetCollapseAll(true);
    try std.testing.expect(app.doc().root.collapsed);

    app.cmdUndo();
    try std.testing.expect(!app.doc().root.collapsed);
}

// ---------------------------------------------------------------------------
// 节点背景色（Rgba 解析、命令撤销、取色器会话、XML 往返、画布渲染）
// ---------------------------------------------------------------------------

test "Rgba.parseHex / formatHex 往返与非法输入" {
    const Rgba = model.Rgba;

    try std.testing.expectEqual(Rgba{ .r = 0x12, .g = 0xab, .b = 0xcd }, Rgba.parseHex("#12abcd").?);
    try std.testing.expectEqual(@as(u8, 0xff), Rgba.parseHex("12abcd").?.a); // 6 位默认不透明
    try std.testing.expectEqual(Rgba{ .r = 0x12, .g = 0xab, .b = 0xcd, .a = 0x80 }, Rgba.parseHex("#12ABCD80").?);

    try std.testing.expectEqual(@as(?Rgba, null), Rgba.parseHex(""));
    try std.testing.expectEqual(@as(?Rgba, null), Rgba.parseHex("#"));
    try std.testing.expectEqual(@as(?Rgba, null), Rgba.parseHex("#12345"));
    try std.testing.expectEqual(@as(?Rgba, null), Rgba.parseHex("#12345g"));
    try std.testing.expectEqual(@as(?Rgba, null), Rgba.parseHex("zzzzzz"));

    var buf: [9]u8 = undefined;
    try std.testing.expectEqualStrings("#12abcd", (Rgba{ .r = 0x12, .g = 0xab, .b = 0xcd }).formatHex(&buf));
    try std.testing.expectEqualStrings("#12abcd80", (Rgba{ .r = 0x12, .g = 0xab, .b = 0xcd, .a = 0x80 }).formatHex(&buf));
}

test "节点背景色：设置 / 恢复默认可撤销重做，快照深拷贝带上 bg" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    app.doc().selectSingle(3); // 分支二（默认无背景色）
    const n = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n.bg == null);

    const yellow = model.Rgba{ .r = 0xff, .g = 0xf3, .b = 0xb0 };
    app.cmdSetNodeBg(yellow);
    try std.testing.expectEqual(yellow, n.bg.?);
    try std.testing.expect(app.canUndo());

    app.cmdUndo(); // 树被整体换回快照，旧指针失效，重新查找
    const n1 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n1.bg == null);

    app.cmdRedo();
    const n2 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(yellow, n2.bg.?);

    // 撤销别的操作不动背景色（cloneTree 必须拷贝 bg）
    app.doc().selectSingle(3);
    app.cmdAddChild();
    app.cmdUndo();
    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(yellow, n3.bg.?);

    // 恢复默认（清除）同样是一步撤销
    app.cmdSetNodeBg(null);
    const n4 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n4.bg == null);
    app.cmdUndo();
    const n5 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(yellow, n5.bg.?);
}

test "节点背景色：重复设同一色 / 已是默认时清除，不产生空撤销步" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    app.doc().selectSingle(1); // 示例树根节点自带浅黄背景
    const n = model.find(app.doc().root, 1) orelse return error.NodeMissing;
    app.cmdSetNodeBg(n.bg.?);
    try std.testing.expect(!app.canUndo());

    app.doc().selectSingle(3); // 无背景色的节点
    app.cmdSetNodeBg(null);
    try std.testing.expect(!app.canUndo());
}

test "取色器撤销会话：连续调色只算一步；开了没变色不留撤销步" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    app.doc().selectSingle(3);
    const n = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(!app.canUndo());

    // 模拟取色器会话：预备镜像后连续两次变色，仍只有一步撤销
    app.trackColorPicker(n.id);
    app.commitColorEdit();
    app.applyNodeBg(n, .{ .r = 0xff, .g = 0, .b = 0 });
    app.applyNodeBg(n, .{ .r = 0, .g = 0xff, .b = 0 });
    try std.testing.expect(app.canUndo());

    app.cmdUndo(); // 一步回到调色前
    const n1 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n1.bg == null);
    try std.testing.expect(app.canRedo());
    app.endColorSession(); // 换树后重置会话，防止旧指针镜像复活

    // 打开又关掉、一次没改：预备镜像被丢弃，不产生撤销步
    app.trackColorPicker(n1.id);
    app.endColorSession();
    try std.testing.expect(!app.canUndo());
}

test "XML 往返保留背景色；非法颜色值宽容处理" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const yellow = model.Rgba{ .r = 0xff, .g = 0xf3, .b = 0xb0 };
    const purple_alpha = model.Rgba{ .r = 0x80, .g = 0x60, .b = 0xc0, .a = 0x80 };
    // 根节点自带示例浅黄背景（buildSampleTree）；再挂一个无色节点验证「无属性往返」
    try std.testing.expectEqual(yellow, app.doc().root.bg.?);
    _ = try model.addChild(app.gpa, app.doc().root, 4, "无色节点");
    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    n2.bg = yellow;
    n3.bg = purple_alpha;

    const data = try xml.save(app.doc().root, &app.doc().images, app.gpa);
    defer app.gpa.free(data);

    const root2 = try xml.load(app.gpa, data);
    defer root2.deinit(app.gpa);
    const r2 = model.find(root2, 2) orelse return error.NodeMissing;
    const r3 = model.find(root2, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(yellow, r2.bg.?);
    try std.testing.expectEqual(purple_alpha, r3.bg.?);
    const r4 = model.find(root2, 4) orelse return error.NodeMissing;
    try std.testing.expect(r4.bg == null); // 无色节点不写属性，读回 null

    // 非法颜色值不报错：退回跟随主题
    const bad = try xml.load(app.gpa, "<mindmap version=\"1\"><node id=\"1\" text=\"x\" bg=\"nope\"/></mindmap>");
    defer bad.deinit(app.gpa);
    try std.testing.expect(bad.bg == null);
}

test "画布与导出渲染自定义背景色的节点（亮/暗两色都走一遍）" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    n2.bg = .{ .r = 0xff, .g = 0xf3, .b = 0xb0 }; // 亮色：黑字分支
    try dvui.testing.settle(Fns.frame);
    n2.bg = .{ .r = 0x1a, .g = 0x23, .b = 0x7e }; // 暗色：白字分支
    try dvui.testing.settle(Fns.frame);

    // 导出（离屏第二遍 drawNodes）也走同样的着色路径：
    // 节点框内部（避开文字与 1px 边框）应是纯背景色
    n2.bg = .{ .r = 0xff, .g = 0, .b = 0 };
    _ = app.layoutTree();
    var map = try canvas.renderMap(&app, std.testing.allocator);
    defer map.deinit(std.testing.allocator);
    const px: u32 = @intFromFloat(n2.geom.x + 3);
    const py: u32 = @intFromFloat(n2.geom.y + 3);
    const p = mapPixel(map, px, py);
    try std.testing.expect(p[3] == 255);
    try std.testing.expect(p[0] > 200); // 红
    try std.testing.expect(p[1] < 100);
    try std.testing.expect(p[2] < 100);
}

test "侧栏取色器：展开渲染整帧、收起丢弃预备镜像（不留空撤销步）" {
    // 窗口加高：取色器按钮在侧栏靠下位置，默认 600×400 的窗口里它已溢出到可视区外
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 800 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    // 展开取色器：会话预备镜像，后续帧整帧渲染取色器（含十六进制输入框）
    try dvui.testing.moveTo("side_color_pick_toggle");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.color_picker_open);
    try std.testing.expect(app.pending_color_snapshot != null);
    try std.testing.expect(app.color_picker_node_id == app.doc().selected_id.?);
    try dvui.testing.settle(Fns.frame);

    // 收起：一次都没变色，预备镜像必须被丢弃
    try dvui.testing.moveTo("side_color_pick_toggle");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(!app.color_picker_open);
    try std.testing.expect(app.pending_color_snapshot == null);
    try std.testing.expect(!app.canUndo());
}

// ---------------------------------------------------------------------------
// 节点手动尺寸（拖拽右/下边缘调整、随文件保存恢复）
// ---------------------------------------------------------------------------

test "节点手动尺寸：布局取 max(自动, 手动)，拖小到内容以下自动兜底" {
    // 布局测量走 dvui 字体（themeGet），需要无头窗口上下文
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n = model.find(app.doc().root, 3) orelse return error.NodeMissing; // 分支二
    _ = app.layoutTree();
    const auto_w = n.geom.w;
    const auto_h = n.geom.h;

    // 手动尺寸大于自动 → 生效
    n.user_w = auto_w + 80;
    n.user_h = auto_h + 40;
    _ = app.layoutTree();
    try std.testing.expectEqual(auto_w + 80, n.geom.w);
    try std.testing.expectEqual(auto_h + 40, n.geom.h);

    // 手动尺寸小于自动 → 自动兜底（不裁字）
    n.user_w = 10;
    n.user_h = 5;
    _ = app.layoutTree();
    try std.testing.expectEqual(auto_w, n.geom.w);
    try std.testing.expectEqual(auto_h, n.geom.h);

    // 清除手动尺寸 → 回到纯自动
    n.user_w = null;
    n.user_h = null;
    _ = app.layoutTree();
    try std.testing.expectEqual(auto_w, n.geom.w);
}

test "XML 往返保留节点手动尺寸；非法值忽略" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    n2.user_w = 300;
    n2.user_h = 128;
    n3.user_w = 200; // 只调了宽

    const data = try xml.save(app.doc().root, &app.doc().images, app.gpa);
    defer app.gpa.free(data);

    const root2 = try xml.load(app.gpa, data);
    defer root2.deinit(app.gpa);
    const r2 = model.find(root2, 2) orelse return error.NodeMissing;
    const r3 = model.find(root2, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(@as(f32, 300), r2.user_w.?);
    try std.testing.expectEqual(@as(f32, 128), r2.user_h.?);
    try std.testing.expectEqual(@as(f32, 200), r3.user_w.?);
    try std.testing.expect(r3.user_h == null);
    try std.testing.expect(root2.user_w == null and root2.user_h == null);

    // 非法 / 非正值忽略，退回自动布局
    const bad = try xml.load(app.gpa, "<mindmap version=\"1\"><node id=\"1\" text=\"x\" w=\"abc\" h=\"-5\"/></mindmap>");
    defer bad.deinit(app.gpa);
    try std.testing.expect(bad.user_w == null and bad.user_h == null);
}

test "节点手动尺寸：恢复自动尺寸可撤销重做" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    app.doc().selectSingle(3);
    // 没手动调过时点恢复：不动作、不产生空撤销步
    app.cmdClearNodeSize();
    try std.testing.expect(!app.canUndo());

    // 模拟画布缩放：压快照再改（与 canvas motion 里的顺序一致）
    const n = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    _ = app.pushUndo();
    n.user_w = 300;
    n.user_h = 120;
    try std.testing.expect(app.canUndo());

    // 恢复自动 = 一步撤销的清除
    app.cmdClearNodeSize();
    const n1 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n1.user_w == null and n1.user_h == null);

    app.cmdUndo();
    const n2 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(@as(f32, 300), n2.user_w.?);
    try std.testing.expectEqual(@as(f32, 120), n2.user_h.?);
}

test "画布拖拽节点右边缘调宽，撤销回退" {
    // 窗口要够宽：节点 2 的右边缘在 x≈430，600 宽减去侧栏后视口只剩 ~360，
    // 右边缘会被滚动区裁掉（事件到不了节点框）
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 800 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    _ = app.layoutTree();
    const start_w = n2.geom.w;
    try std.testing.expect(n2.user_w == null); // sanity：初始是自动尺寸

    // 按在节点右边缘把手上（tag rect 是物理像素）
    const td = dvui.tagGet("node:2") orelse return error.NoTag;
    if (!td.visible) return error.NodeNotVisible;
    const s = dvui.currentWindow().natural_scale;
    const press_x = td.rect.x + td.rect.w - 2;
    const press_y = td.rect.y + td.rect.h / 2;
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = press_x, .y = press_y } });
    _ = try cw.addEventMouseButton(.left, .press);
    // 向右拖 60 自然像素（按实际 scale 换算成物理像素），节点应变宽 60
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = press_x + 60 * s, .y = press_y } });
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(Fns.frame);

    try std.testing.expect(n2.user_w != null);
    try std.testing.expectEqual(start_w + 60, n2.geom.w);
    try std.testing.expectEqual(n2.user_w.?, n2.geom.w); // 手动 > 自动时两者相等
    try std.testing.expect(app.doc().selected_id == 2); // 按下即选中
    try std.testing.expect(app.canUndo()); // 真正改过尺寸才压快照

    app.cmdUndo();
    const n2b = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expect(n2b.user_w == null);
    _ = app.layoutTree();
    try std.testing.expectEqual(start_w, n2b.geom.w);
}

test "侧栏描述输入框：拖动把手调高度，上拖钳到下限" {
    // 窗口要够高：第一段拖拽后输入框变高，把手随之下移，600×400 会把它挤出窗口底边
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 800 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const s = dvui.currentWindow().natural_scale;
    const cw = dvui.currentWindow();
    const h0 = app.note_editor_h;

    // 先悬停一帧再按下：守住「悬停提示浮窗吞掉把手按下事件」的回归——
    // 提示若是子窗口，悬停后的 press 会被它截走，高度就不会变
    var td = dvui.tagGet("note_editor_grip") orelse return error.NoTag;
    if (!td.visible) return error.GripNotVisible;
    _ = try cw.addEventMouseMotion(.{ .pt = td.rect.center() });
    try dvui.testing.settle(Fns.frame);

    // 下拖 40 自然像素 → 输入框变高 40
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = td.rect.center().x, .y = td.rect.center().y + 40 * s } });
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(h0 + 40, app.note_editor_h);

    // 上拖远超下限 → 钳制在 note_editor_min_h（把手随框上移，重新取位置）
    td = dvui.tagGet("note_editor_grip") orelse return error.NoTag;
    _ = try cw.addEventMouseMotion(.{ .pt = td.rect.center() });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = td.rect.center().x, .y = td.rect.center().y - 5000 * s } });
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(app_mod.note_editor_min_h, app.note_editor_h);
}

test "连线分层配色：同层同色稳定、跨层异色、超层数循环复用" {
    const c1 = canvas.edgeLevelColor(1);
    try std.testing.expectEqual(c1, canvas.edgeLevelColor(1)); // 同层会话内稳定

    const c2 = canvas.edgeLevelColor(2);
    try std.testing.expect(!std.meta.eql(c1, c2)); // 相邻层色相相差黄金角，必不同色

    // 超过 16 层后循环复用（(level-1) % 16）
    try std.testing.expectEqual(c1, canvas.edgeLevelColor(17));
}

test "PNG/docx 导出：对话框初始文件名带目标后缀，拾取名自动补扩展名" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    // 从未保存过 → mindmap.<ext>
    try std.testing.expectEqualStrings("mindmap.png", app.exportDialogStartPath("png"));
    try std.testing.expectEqualStrings("mindmap.docx", app.exportDialogStartPath("docx"));
    try std.testing.expectEqualStrings("mindmap.md", app.exportDialogStartPath("md"));

    // 文档名换目标后缀（大小写混写的 .xml 也认；新后缀 .mcab 同样剥掉）
    try std.testing.expect(app.doc().setPath("D:/maps/foo.XML"));
    try std.testing.expectEqualStrings("D:/maps/foo.png", app.exportDialogStartPath("png"));
    try std.testing.expectEqualStrings("D:/maps/foo.docx", app.exportDialogStartPath("docx"));
    try std.testing.expectEqualStrings("D:/maps/foo.md", app.exportDialogStartPath("md"));
    try std.testing.expect(app.doc().setPath("D:/maps/foo.mCaB"));
    try std.testing.expectEqualStrings("D:/maps/foo.png", app.exportDialogStartPath("png"));

    // 已是目标后缀的文档路径原样用（.png 对 docx 不算，要换）
    try std.testing.expect(app.doc().setPath("D:/maps/bar.png"));
    try std.testing.expectEqualStrings("D:/maps/bar.png", app.exportDialogStartPath("png"));
    try std.testing.expectEqualStrings("D:/maps/bar.docx", app.exportDialogStartPath("docx"));
    try std.testing.expectEqualStrings("D:/maps/bar.md", app.exportDialogStartPath("md"));

    // 对话框里填的名字没有扩展名 → 补后缀；已有后缀（任意大小写）→ 原样保留
    const a = try app_mod.pathWithExt(app.gpa, "D:/out/myfile", "png");
    defer app.gpa.free(a);
    try std.testing.expectEqualStrings("D:/out/myfile.png", a);
    const b = try app_mod.pathWithExt(app.gpa, "D:/out/pic.PNG", "png");
    defer app.gpa.free(b);
    try std.testing.expectEqualStrings("D:/out/pic.PNG", b);
    const c = try app_mod.pathWithExt(app.gpa, "D:/out/doc.DOCX", "docx");
    defer app.gpa.free(c);
    try std.testing.expectEqualStrings("D:/out/doc.DOCX", c);
}

// ---------------------------------------------------------------------------
// 缺陷回归测试（test/report.md 缺陷 1/2/3/4/5/6）。
//
// 用 dvui.testing 的无头窗口跑与 main.zig 同构的完整帧（keys.beforeWidgets →
// 控件 → keys.afterWidgets），在两次 step/settle 之间注入按键 / 鼠标 / 文本
// 事件，验证全局按键分发与多行测量的最终行为。
// ---------------------------------------------------------------------------

/// 与 main.zig 的 guiFrame 同构的测试帧：去掉无头环境跑不了的
/// runPendingFileAction（文件对话框）与 runPendingExport（离屏 PNG 导出），
/// 以及会让 settle 永不收敛的 runPendingTabAction（见 frame 内注释）。
const Fns = struct {
    var app_ptr: *app_mod.App = undefined;
    /// 置 true 让下一帧调一次 cmdShowAbout（缺陷 2 需要真实模态框）。
    var show_about: bool = false;

    fn frame() !dvui.App.Result {
        const app = app_ptr;
        if (show_about) {
            show_about = false;
            app.cmdShowAbout();
        }
        app.runPendingConfirm();
        keys.beforeWidgets(app);
        {
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
            defer vbox.deinit();
            ui.drawMenuBar(app);
            ui.drawTabBar(app);
            ui.drawToolbar(app);
            {
                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
                defer hbox.deinit();
                canvas.draw(app);
                ui.drawSidePanel(app);
            }
            ui.drawStatusBar(app);
        }
        // 不跑 runPendingTabAction：它无条件 dvui.refresh（app.zig），每帧都
        // 请求重画，settle 永远等不到空闲帧。测试里的标签切换走
        // beforeWidgets 直调 cmdNextTab，不经 pending_tab_action。
        app.endTextFieldSession();
        keys.afterWidgets(app);
        return .ok;
    }
};

test "复制/粘贴节点：同级新节点、只复制自身（不含子节点）、可撤销" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    // 分支一（id 2）：加一个子节点 + 属性，验证粘贴时不带子节点、内容照搬
    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const child = try model.addChild(app.gpa, n2, 5, "子节点");
    child.parent = n2;
    try model.addProperty(app.gpa, n2, "权重", "1");
    try model.setImgRef(app.gpa, n2, "ref-x");

    app.doc().selectSingle(2);
    app.cmdCopySelected();
    try std.testing.expect(app.clipboard != null);

    const before_len = app.doc().root.children.items.len;
    app.cmdPasteNode();
    try std.testing.expectEqual(before_len + 1, app.doc().root.children.items.len);

    // 新节点：父节点与原节点相同（行内同级），紧跟在原节点之后
    const kids = app.doc().root.children.items;
    const src_idx = std.mem.indexOfScalar(*model.Node, kids, model.find(app.doc().root, 2).?).?;
    const pasted = kids[src_idx + 1];
    try std.testing.expect(pasted.id != 2);
    try std.testing.expect(pasted.parent == app.doc().root);
    // 内容照搬（标题/描述/属性/图片引用），但**不带子节点**
    const src = model.find(app.doc().root, 2).?;
    try std.testing.expectEqualStrings(src.text.items, pasted.text.items);
    try std.testing.expectEqualStrings(src.note.items, pasted.note.items);
    try std.testing.expectEqualStrings("ref-x", pasted.img_ref.items);
    try std.testing.expectEqual(@as(usize, 1), pasted.properties.items.len);
    try std.testing.expectEqualStrings("权重", pasted.properties.items[0].name.items);
    try std.testing.expectEqual(@as(usize, 0), pasted.children.items.len);
    // 粘贴后选中新节点
    try std.testing.expectEqual(pasted.id, app.doc().selected_id.?);

    // 撤销：新节点消失，原树（含原节点的子节点）不受影响
    app.cmdUndo();
    try std.testing.expectEqual(before_len, app.doc().root.children.items.len);
    const still = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expectEqual(@as(usize, 1), still.children.items.len);

    // 剪贴板可重复使用：连续粘贴两次得到两个节点
    app.cmdPasteNode();
    app.cmdPasteNode();
    try std.testing.expectEqual(before_len + 2, app.doc().root.children.items.len);
}

test "剪贴板为空 / 未选中节点时的提示，不产生节点" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const before_len = app.doc().root.children.items.len;
    app.cmdPasteNode(); // 空剪贴板
    try std.testing.expectEqual(before_len, app.doc().root.children.items.len);

    app.doc().selectionClear();
    app.cmdCopySelected(); // 没选中
    try std.testing.expect(app.clipboard == null);
}

test "Ctrl+C / Ctrl+V 按键走真实帧生效" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    app.doc().selectSingle(3); // 分支二（叶子）
    try dvui.testing.settle(Fns.frame);

    try dvui.testing.pressKey(.c, mod_ctrl);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.clipboard != null);

    const before_len = app.doc().root.children.items.len;
    try dvui.testing.pressKey(.v, mod_ctrl);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(before_len + 1, app.doc().root.children.items.len);
    // 粘贴出来的节点与源同级（挂在根下），标题相同
    const pasted = model.find(app.doc().root, app.doc().selected_id.?) orelse return error.NodeMissing;
    try std.testing.expect(pasted.parent == app.doc().root);
    try std.testing.expectEqualStrings("分支二", pasted.text.items);
}

const mod_none: dvui.enums.Mod = @fromBackingInt(@intCast(0));
const mod_ctrl: dvui.enums.Mod = @fromBackingInt(@intCast(@backingInt(dvui.enums.Mod.lcontrol)));

test "缺陷 3：多行文本测量按行累加，布局与画布走同一算法" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    // 多行高度必须明显高于单行，否则节点框会裁掉第二行（report 缺陷 3）
    const one = app_mod.App.measureText(null, "第一行正文", .desc);
    const two = app_mod.App.measureText(null, "第一行正文\n第二行正文", .desc);
    const one_t = app_mod.App.measureText(null, "标题", .title);
    const two_t = app_mod.App.measureText(null, "标题\n第二行", .title);
    try std.testing.expect(two.h > one.h + 1);
    try std.testing.expect(two_t.h > one_t.h + 1);

    // measureText 就是 measureMultiline：布局算框、画布画 rect 必须同一算法
    try std.testing.expectEqual(
        app_mod.App.measureMultiline(app_mod.App.descFont(), "第一行正文\n第二行正文").h,
        two.h,
    );
    try std.testing.expectEqual(
        app_mod.App.measureMultiline(dvui.themeGet().font_body, "标题\n第二行").h,
        two_t.h,
    );

    // 带多行正文的节点：geom 高度必须容得下 标题 + 间距 + 多行正文 + 上下内边距
    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    n.note.clearRetainingCapacity();
    try n.note.appendSlice(app.gpa, "第一行正文\n第二行正文");
    _ = app.layoutTree();
    const need = app_mod.App.measureMultiline(dvui.themeGet().font_body, n.text.items).h +
        layout.metrics.desc_gap +
        app_mod.App.measureMultiline(app_mod.App.descFont(), n.note.items).h +
        layout.metrics.pad_y * 2;
    try std.testing.expect(n.geom.h >= need - 1);
}

test "菜单：文件 → 导出 → 导出为 PNG 挂号 FileAction.export_png" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const MenuFns = struct {
        var app_ptr: *app_mod.App = undefined;
        fn frame() !dvui.App.Result {
            app_ptr.runPendingConfirm();
            ui.drawMenuBar(app_ptr);
            return .ok;
        }
    };
    MenuFns.app_ptr = &app;

    try dvui.testing.settle(MenuFns.frame);

    // 1. 点开「文件」菜单，下拉项应存在
    try dvui.testing.moveTo("menu_file");
    try dvui.testing.click(.left);
    try dvui.testing.settle(MenuFns.frame);
    try std.testing.expect(dvui.tagGet("menu_export") != null);

    // 2. 点「导出」打开次级菜单
    try dvui.testing.moveTo("menu_export");
    try dvui.testing.click(.left);
    try dvui.testing.settle(MenuFns.frame);
    try std.testing.expect(dvui.tagGet("menu_export_png") != null);

    // 3. 点「导出为 PNG」→ 挂号 export_png（对话框在真实程序里由
    //    runPendingFileAction 帧末弹出，测试帧不执行它，直接断言挂号）
    try dvui.testing.moveTo("menu_export_png");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(MenuFns.frame);
    try std.testing.expectEqual(app_mod.FileAction.export_png, app.pending_file_action);

    // 测试帧没有 runPendingFileAction，手动清掉避免 deinit 后悬挂语义
    app.pending_file_action = .none;
}

test "菜单：文件 → 导出 → 导出为 docx 挂号 FileAction.export_docx" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const MenuFns = struct {
        var app_ptr: *app_mod.App = undefined;
        fn frame() !dvui.App.Result {
            app_ptr.runPendingConfirm();
            ui.drawMenuBar(app_ptr);
            return .ok;
        }
    };
    MenuFns.app_ptr = &app;

    try dvui.testing.settle(MenuFns.frame);

    try dvui.testing.moveTo("menu_file");
    try dvui.testing.click(.left);
    try dvui.testing.settle(MenuFns.frame);
    try dvui.testing.moveTo("menu_export");
    try dvui.testing.click(.left);
    try dvui.testing.settle(MenuFns.frame);
    try std.testing.expect(dvui.tagGet("menu_export_docx") != null);

    try dvui.testing.moveTo("menu_export_docx");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(MenuFns.frame);
    try std.testing.expectEqual(app_mod.FileAction.export_docx, app.pending_file_action);

    app.pending_file_action = .none;
}

test "菜单：文件 → 导出 → 导出为 Markdown 挂号 FileAction.export_md" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const MenuFns = struct {
        var app_ptr: *app_mod.App = undefined;
        fn frame() !dvui.App.Result {
            app_ptr.runPendingConfirm();
            ui.drawMenuBar(app_ptr);
            return .ok;
        }
    };
    MenuFns.app_ptr = &app;

    try dvui.testing.settle(MenuFns.frame);

    try dvui.testing.moveTo("menu_file");
    try dvui.testing.click(.left);
    try dvui.testing.settle(MenuFns.frame);
    try dvui.testing.moveTo("menu_export");
    try dvui.testing.click(.left);
    try dvui.testing.settle(MenuFns.frame);
    try std.testing.expect(dvui.tagGet("menu_export_md") != null);

    try dvui.testing.moveTo("menu_export_md");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(MenuFns.frame);
    try std.testing.expectEqual(app_mod.FileAction.export_md, app.pending_file_action);

    app.pending_file_action = .none;
}

test "docx 导出：层级≤5 按标题、更深为正文，note 跟在其后" {
    const alloc = std.testing.allocator;

    // document.xml 必须是完整 OOXML 文档（<w:document> 根元素包住段落）：
    // 缺了这层包装 Word 解析失败，导出的文档显示为空（回归：内容丢失）
    {
        const single = try model.createNode(alloc, 1, "根");
        defer single.deinit(alloc);
        const data = try docx_mod.buildDocx(alloc, single);
        defer alloc.free(data);
        const head = std.mem.indexOf(u8, data, "<?xml").?;
        const open = std.mem.indexOfPos(u8, data, head, "<w:document").?;
        const body = std.mem.indexOfPos(u8, data, open, "<w:body>").?;
        const para = std.mem.indexOfPos(u8, data, body, "<w:p>").?;
        const close = std.mem.lastIndexOf(u8, data, "</w:body></w:document>").?;
        try std.testing.expect(head < open and open < body and body < para and para < close);
        // document.xml 条目之后才是 rels/styles 条目与中央目录
        try std.testing.expect(std.mem.indexOfPos(u8, data, close, "word/_rels/") != null);
    }

    // 中心(层1) → 一级A(2) → 二级A1(3) → 三级A1a(4) → 四级A1a1(5, 最后一个标题层)
    // → 五级正文(6, 第一个正文层)；根与一级A 各带 note
    const root = try model.createNode(alloc, 1, "中心主题");
    defer root.deinit(alloc);
    try model.setNote(alloc, root, "根节点描述");

    var parent = root;
    var id: u32 = 2;
    const names = [_][]const u8{ "一级A", "二级A1", "三级A1a", "四级A1a1" };
    for (names) |nm| {
        parent = try model.addChild(alloc, parent, id, nm);
        id += 1;
    }
    _ = try model.addChild(alloc, parent, id, "五级正文节点");

    const data = try docx_mod.buildDocx(alloc, root);
    defer alloc.free(data);

    // ZIP 结构：本地文件头魔数 + 末尾是 EOCD（22 字节：签名在倒数第 22 字节，
    // 其后还有盘号/条目数/偏移/注释长度字段，不能直接 endsWith 签名）
    try std.testing.expect(std.mem.startsWith(u8, data, "PK\x03\x04"));
    try std.testing.expect(std.mem.startsWith(u8, data[data.len - 22 ..], "PK\x05\x06"));

    // 五级层（四级A1a1）仍是 Heading5，第六层没有 Heading6
    try std.testing.expect(std.mem.indexOf(u8, data, "Heading5") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "Heading6") == null);
    // 第六层导出为正文（无样式的正文段落里能找到其文本）
    try std.testing.expect(std.mem.indexOf(u8, data, "五级正文节点") != null);
    // 根 note 在根标题（Heading1）之后、一级A 之前
    const h1 = std.mem.indexOf(u8, data, "Heading1").?;
    const note = std.mem.indexOf(u8, data, "根节点描述").?;
    const a = std.mem.indexOf(u8, data, "一级A").?;
    try std.testing.expect(h1 < note and note < a);
}

test "Markdown 导出：层级≤5 按层级标题、更深为正文，note 跟在其后" {
    const alloc = std.testing.allocator;

    // 与 docx 层级测试同构的树：五级为最后一个标题层，第六层为正文
    const root = try model.createNode(alloc, 1, "中心主题");
    defer root.deinit(alloc);
    try model.setNote(alloc, root, "根节点描述");

    var parent = root;
    var id: u32 = 2;
    const names = [_][]const u8{ "一级A", "二级A1", "三级A1a", "四级A1a1" };
    for (names) |nm| {
        parent = try model.addChild(alloc, parent, id, nm);
        id += 1;
    }
    _ = try model.addChild(alloc, parent, id, "五级正文节点");

    const md = try markdown_mod.buildMarkdown(alloc, root);
    defer alloc.free(md);

    // 标题层级标记：根 #、一级 ##、四级 #####；没有 6 级标题
    try std.testing.expect(std.mem.indexOf(u8, md, "# 中心主题\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "## 一级A\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "##### 四级A1a1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "###### ") == null);
    // 第六层导出为正文（无 # 前缀）
    try std.testing.expect(std.mem.indexOf(u8, md, "\n五级正文节点\n") != null);
    // 根 note 在根标题之后、一级A 之前
    const h1 = std.mem.indexOf(u8, md, "# 中心主题").?;
    const note = std.mem.indexOf(u8, md, "根节点描述").?;
    const a = std.mem.indexOf(u8, md, "## 一级A").?;
    try std.testing.expect(h1 < note and note < a);
}

test "文档导出：子节点按 seq*10_000_000+id 升序（seq 缺省 0），树本身不动" {
    const alloc = std.testing.allocator;

    // 插入顺序 丙(30,seq2) 甲(10,seq2) 乙(20,seq5) 丁(40,无seq)。
    // 排序键：丁=40 < 甲=20_000_010 < 丙=20_000_030 < 乙=50_000_020
    const root = try model.createNode(alloc, 1, "根");
    defer root.deinit(alloc);
    const c = try model.addChild(alloc, root, 30, "丙");
    const a = try model.addChild(alloc, root, 10, "甲");
    const b = try model.addChild(alloc, root, 20, "乙");
    _ = try model.addChild(alloc, root, 40, "丁");
    c.seq = 2;
    a.seq = 2;
    b.seq = 5;

    // markdown 是纯文本，直接整串断言顺序（根 # ，子都是 ## ）
    const md = try markdown_mod.buildMarkdown(alloc, root);
    defer alloc.free(md);
    try std.testing.expectEqualStrings("# 根\n\n## 丁\n\n## 甲\n\n## 丙\n\n## 乙\n\n", md);

    // docx 用 document.xml 里的出现位置断言同样的顺序
    const data = try docx_mod.buildDocx(alloc, root);
    defer alloc.free(data);
    const ding = std.mem.indexOf(u8, data, "丁").?;
    const jia = std.mem.indexOf(u8, data, "甲").?;
    const bing = std.mem.indexOf(u8, data, "丙").?;
    const yi = std.mem.indexOf(u8, data, "乙").?;
    try std.testing.expect(ding < jia and jia < bing and bing < yi);

    // 排序只作用于导出遍历：树的子节点顺序保持插入顺序（画布布局不变）
    try std.testing.expectEqual(@as(u32, 30), root.children.items[0].id);
    try std.testing.expectEqual(@as(u32, 10), root.children.items[1].id);
    try std.testing.expectEqual(@as(u32, 20), root.children.items[2].id);
    try std.testing.expectEqual(@as(u32, 40), root.children.items[3].id);
}

test "XML：seq 属性往返持久化，缺省读回 0" {
    const alloc = std.testing.allocator;

    const root = try model.createNode(alloc, 1, "根");
    defer root.deinit(alloc);
    const a = try model.addChild(alloc, root, 2, "甲");
    a.seq = 42;
    _ = try model.addChild(alloc, root, 3, "乙"); // 无 seq → 不写属性 → 读回 0

    var images: model.ImageStore = .{};
    defer images.deinit(alloc);
    const data = try xml.save(root, &images, alloc);
    defer alloc.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "seq=\"42\"") != null);
    // 无 seq 的节点不写属性：乙的开标签（id="3" 到 text= 之间）里没有 seq
    const yi_open = std.mem.indexOf(u8, data, "id=\"3\"").?;
    const yi_text = std.mem.indexOfPos(u8, data, yi_open, "text=").?;
    try std.testing.expect(std.mem.indexOf(u8, data[yi_open..yi_text], "seq") == null);

    const back = try xml.load(alloc, data);
    defer back.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 1), back.id);
    try std.testing.expectEqual(@as(u64, 42), back.children.items[0].seq);
    try std.testing.expectEqual(@as(u64, 0), back.children.items[1].seq);
}

test "docx 导出：XML 转义与非法控制字符过滤" {
    const alloc = std.testing.allocator;

    const root = try model.createNode(alloc, 1, "a<b>&\"'z");
    defer root.deinit(alloc);
    try model.setNote(alloc, root, "含\x01控制符\x02的文本");

    const data = try docx_mod.buildDocx(alloc, root);
    defer alloc.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "a&lt;b&gt;&amp;&quot;&apos;z") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "含控制符的文本") != null);
}

test "缺陷 1：内联编辑中按 Esc 取消编辑并回滚文本" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    app.cmdBeginEditNodeTitle(n);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .node_title);

    // 进入编辑即全选：直接输入覆盖原文（sanity：文本确实进了内联输入框）
    try dvui.testing.writeText("改过的标题");
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqualStrings("改过的标题", n.text.items);

    // Esc 必须被帧首的全局分发接住——等控件画完，TextEntry 已把没消费的
    // 按键标记 handled，帧末循环就收不到（report 缺陷 1）
    try dvui.testing.pressKey(.escape, mod_none);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .none);
    try std.testing.expectEqualStrings("分支一", n.text.items);
}

test "缺陷 2：模态对话框打开期间按键不泄漏成快捷键" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    Fns.show_about = true;
    try dvui.testing.settle(Fns.frame);
    Fns.show_about = false;
    try std.testing.expect(keys.anyDialogOpen()); // sanity：门控条件确实成立

    app.doc().selectSingle(2);
    const count = model.countNodes(app.doc().root);
    const next_id = app.doc().next_id;
    const active = app.active;

    // Enter 本该只被「关于」框消费（它在 Window.end 才绘制，比帧末循环晚一拍）；
    // 若帧末循环先动手，就会泄漏成 cmdAddSibling（report 缺陷 2）
    try dvui.testing.pressKey(.enter, mod_none);
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expectEqual(next_id, app.doc().next_id);
    try std.testing.expectEqual(active, app.active);
}

test "缺陷 4：Ctrl+PageDown / Ctrl+PageUp 切换标签" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try app.cmdNewDoc();
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(usize, 1), app.active);

    // 画布滚动区处理 PageUp/PageDown 时不看 Ctrl 修饰（ScrollContainerWidget），
    // 全局分发必须在帧首抢下——否则焦点在画布时切不了标签（report 缺陷 4）
    try dvui.testing.pressKey(.page_down, mod_ctrl);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(usize, 0), app.active);

    try dvui.testing.pressKey(.page_up, mod_ctrl);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(usize, 1), app.active);

    // Ctrl+Tab 同一条路径
    try dvui.testing.pressKey(.tab, mod_ctrl);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(usize, 0), app.active);
}

test "缺陷 6：焦点在侧栏标题输入框时裸 Insert 仍插入子节点" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    app.doc().selectSingle(2);
    try dvui.testing.settle(Fns.frame);

    try dvui.testing.moveTo("side_title");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try dvui.testing.expectFocused("side_title"); // sanity：焦点确实进了文本框

    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const count = model.countNodes(app.doc().root);
    const next_id = app.doc().next_id;

    // 文本框会把它不认识的按键一律标 handled（焦点为空时甚至不做焦点过滤），
    // 帧末收不到——裸 Insert 必须在帧首抢（report 缺陷 6）
    try dvui.testing.pressKey(.insert, mod_none);
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqual(count + 1, model.countNodes(app.doc().root));
    try std.testing.expect(next_id != app.doc().next_id);
    // Insert 不是文本：输入框内容与编辑状态都不该被动过
    try std.testing.expectEqualStrings("分支一", n.text.items);
    try std.testing.expect(app.editing == .none);
}

test "缺陷 5a：编辑中点击内联框，输入只进文本（节点不再抢同一次按下）" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const orig_len = n.text.items.len;
    const count = model.countNodes(app.doc().root);
    app.doc().selectSingle(2); // 选中它再进编辑，验证点击不会把选中项带跑
    app.cmdBeginEditNodeTitle(n);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .node_title);

    // 点击内联框放光标：编辑中的节点必须跳过自己的事件循环，
    // 否则同一次按下被节点框吃掉 / 判成双击重新全选，光标落点就被全选覆盖
    //（report 缺陷 5a）
    try dvui.testing.moveTo("inline_editor");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .node_title);

    try dvui.testing.writeText("X");
    try dvui.testing.settle(Fns.frame);

    // 只是插入一个字符：既没整段替换（= 光标落点被全选覆盖），
    // 也没误触发加/删节点或切标签
    try std.testing.expectEqual(orig_len + 1, n.text.items.len);
    try std.testing.expect(!std.mem.eql(u8, n.text.items, "X"));
    try std.testing.expect(app.editing == .node_title);
    try std.testing.expectEqual(@as(u32, 2), app.editing_id);
    try std.testing.expectEqual(@as(?u32, 2), app.doc().selected_id);
    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
}

test "缺陷 5b：全选后按左箭头收缩选区，输入插到开头" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    app.cmdBeginEditNodeTitle(n); // 进入编辑即全选（edit_armed）
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .node_title);

    // 选区非空时左箭头应把光标收到选区起点并清掉选区（而不是删掉选区内容）
    try dvui.testing.pressKey(.left, mod_none);
    try dvui.testing.settle(Fns.frame);
    try dvui.testing.writeText("X");
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqualStrings("X分支一", n.text.items);
}

test "缺陷 5b：全选后按右箭头收缩选区，输入插到末尾" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    app.cmdBeginEditNodeTitle(n);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .node_title);

    try dvui.testing.pressKey(.right, mod_none);
    try dvui.testing.settle(Fns.frame);
    try dvui.testing.writeText("X");
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqualStrings("分支一X", n.text.items);
}

// ---------------------------------------------------------------------------
// 用户后续报的三个缺陷（口述，未进 report.md）：
//   A. 节点被选中时 Insert 仍然插不进子节点
//   B. 选中根节点往上拖之后，滚动条再也够不到被拖出去的内容
//   C. 导出 PNG 只有当前可见那一屏，滚动隐藏的区域是空白
// ---------------------------------------------------------------------------

/// 取 RGBA 图中某个像素（行主序、每像素 4 字节）。
fn mapPixel(map: canvas.MapPixels, x: u32, y: u32) *const [4]u8 {
    const off = @as(usize, y) * map.width + x;
    return map.pixels[off * 4 ..][0..4];
}

/// 第一个 y 超过 limit 的可见节点（用于找「窗口之外」的内容）。
fn firstNodeBelow(node: *model.Node, limit: f32) ?*model.Node {
    if (node.collapsed) return null;
    if (node.geom.y > limit) return node;
    for (node.children.items) |c| {
        if (firstNodeBelow(c, limit)) |n| return n;
    }
    return null;
}

/// 所有可见节点是否都落在虚拟画布 [0, bounds] 之内。
fn allNodesInBounds(node: *model.Node, bounds: layout.Bounds) bool {
    if (node.geom.x < -0.5 or node.geom.y < -0.5) return false;
    if (node.geom.x + node.geom.w > bounds.w + 0.5) return false;
    if (node.geom.y + node.geom.h > bounds.h + 0.5) return false;
    if (node.collapsed) return true;
    for (node.children.items) |c| {
        if (!allNodesInBounds(c, bounds)) return false;
    }
    return true;
}

test "缺陷 A：单击选中节点后按 Insert 插入子节点" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    // 走一遍用户的真实路径：先选根，再**用鼠标单击**别的节点，
    // 最后按 Insert（不是直接改 selected_id —— 点击路径本身要被覆盖到）。
    app.doc().selectSingle(1);
    try dvui.testing.settle(Fns.frame);
    try dvui.testing.moveTo("node:2");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(?u32, 2), app.doc().selected_id);
    try std.testing.expect(app.editing == .none); // sanity：单击不该进编辑态

    const count = model.countNodes(app.doc().root);
    const next_id = app.doc().next_id;
    try dvui.testing.pressKey(.insert, mod_none);
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqual(count + 1, model.countNodes(app.doc().root));
    try std.testing.expect(next_id != app.doc().next_id);
    try std.testing.expect(app.editing == .none);
    // 新节点必须被选中且可见（父节点不能是折叠态，否则插入了也看不见）
    const added = app.selectedNode() orelse return error.NoSelection;
    try std.testing.expect(added.parent != null);
    if (added.parent) |p| try std.testing.expect(!p.collapsed);
}

test "缺陷 A-2：内联编辑中按 Insert 会给出状态栏提示（不再是无声无息）" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    app.cmdBeginEditNodeTitle(n);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(app.editing == .node_title);

    const count = model.countNodes(app.doc().root);
    app.setStatus("占位");
    try dvui.testing.pressKey(.insert, mod_none);
    try dvui.testing.settle(Fns.frame);

    // 编辑期间 Insert 归文本框（README 约定），但必须让用户看得出去向
    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expect(app.editing == .node_title);
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "正在编辑标题") != null);
}

test "缺陷 A-3：新节点落在视口之外时，画布把它滚进视野" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;

    // 造一棵比视口高的树，然后把视口拨回顶部
    app.doc().selectSingle(1);
    for (0..30) |_| app.cmdAddSibling();
    try dvui.testing.settle(Fns.frame);
    const si = &app.doc().scroll_info;
    try std.testing.expect(si.viewport.h > 0); // sanity：视口尺寸已由 scrollArea 填好
    si.scrollToOffset(.vertical, 0);

    // 追加在 root 子列表末尾 = 树的最底部，此时完全在视口之外。
    // 不滚动的话用户看到的就是「按了 Insert 什么都没发生」。
    app.doc().selectSingle(1);
    app.cmdAddChild();
    try dvui.testing.settle(Fns.frame);

    const n = app.selectedNode() orelse return error.NoSelection;
    try std.testing.expect(si.viewport.y > 0);
    try std.testing.expect(n.geom.y >= si.viewport.y - 0.5);
    try std.testing.expect(n.geom.y + n.geom.h <= si.viewport.y + si.viewport.h + 0.5);
}

test "缺陷 A-4：对话框打开时按 Insert，状态栏说明它被挡住了" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    Fns.show_about = true;
    try dvui.testing.settle(Fns.frame);
    Fns.show_about = false;
    try std.testing.expect(keys.anyDialogOpen()); // sanity：门控条件确实成立

    const count = model.countNodes(app.doc().root);
    app.setStatus("占位");
    try dvui.testing.pressKey(.insert, mod_none);
    try dvui.testing.settle(Fns.frame);

    // 对话框挡下 Insert 是既定语义（缺陷 2 的代价），但不能一声不吭——
    // 「按了没反应」和「被明确告知为什么」是两回事
    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "对话框") != null);
}

test "缺陷 A-5：没人要的键由状态栏点名；小键盘 0 兜底成 Insert（用户实测键码）" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    // (1) 没有任何绑定的功能键：状态栏必须点名收到的是哪个键码，
    //     否则「收到的键码不对」和「SDL 根本没收到按键」在用户眼里一模一样。
    const count = model.countNodes(app.doc().root);
    app.setStatus("占位");
    try dvui.testing.pressKey(.f5, mod_none);
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "f5") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "未处理") != null);

    // (2) 用户实测的 Insert：以扫描码 0x52（无 E0）到达 → SDL 归成 kp_0。
    //     没人消费它，就兜底成插入子节点；状态栏必须回到正常语义。
    app.setStatus("占位");
    try dvui.testing.pressKey(.kp_0, mod_none);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(count + 1, model.countNodes(app.doc().root));
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "已添加子节点") != null);

    // 对照组：真正的 .insert 不该被诊断语句抢走状态栏
    app.setStatus("占位");
    try dvui.testing.pressKey(.insert, mod_none);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(count + 2, model.countNodes(app.doc().root));
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "已添加子节点") != null);

    // 帧末自己处理的键同样不许被诊断覆盖（端到端实验抓到过：
    // Delete 先写「已删除节点」，随后的诊断又把它盖成「按键 delete 未处理」）
    app.setStatus("占位");
    try dvui.testing.pressKey(.delete, mod_none);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "已删除节点") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.statusSlice(), "未处理") == null);
}

test "缺陷 A-6：焦点在文本框里时小键盘 0 仍然只是输入，不插入节点" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    try dvui.testing.moveTo("side_title");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try dvui.testing.expectFocused("side_title"); // sanity：焦点确实进了文本框

    // kp_0 的 Insert 兜底放在帧末，靠的正是「TextEntry 先收下」这一层——
    // 焦点在输入框里时，小键盘 0 必须还是打字用的 0，绝不能变成加节点。
    const count = model.countNodes(app.doc().root);
    try dvui.testing.pressKey(.kp_0, mod_none);
    try dvui.testing.settle(Fns.frame);

    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expect(app.editing == .none);
}

test "缺陷 B：把根节点往上拖，内容不会被拖出滚动条可达范围" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;

    // 造一棵比视口高的树（滚动条才有意义）
    for (0..20) |_| app.cmdAddSibling();
    app.reveal_selected = false; // 本测试只考核「拖拽钳制」，不依赖 reveal
    try dvui.testing.settle(Fns.frame);
    // 根节点被布局居中在整棵子树中间（layout 的父节点居中规则），树一高就
    // 落到视口外了：手动把视口拨到根节点处，好让鼠标按得到它
    const root_geom = app.doc().root.geom;
    app.doc().scroll_info.scrollToOffset(.vertical, @max(0, root_geom.y - 8));
    try dvui.testing.settle(Fns.frame);
    {
        const td = dvui.tagGet("node:1") orelse return error.NoTag;
        if (!td.visible) return error.RootNotVisible;
    }

    // 根节点按下 → 拖到窗口左上角 → 松开（treeBounds 只统计右下角，
    // 若不夹住，内容会被拖到 y<0，而滚动条的偏移永远 ≥0，那段内容就此失联）
    try dvui.testing.moveTo("node:1");
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 1, .y = 1 } });
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(Fns.frame);

    const bounds = app.layoutTree();
    try std.testing.expect(allNodesInBounds(app.doc().root, bounds));
}

test "缺陷 C：导出纹理覆盖整张脑图，窗口之外的区域也画上了" {
    var t = try dvui.testing.init(.{}); // 测试窗口 600×400
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;

    // 造一棵比窗口高的树：越出 400px 的部分在窗口里根本看不到
    app.doc().selectSingle(1);
    for (0..30) |_| app.cmdAddSibling();
    try dvui.testing.settle(Fns.frame);

    const bounds = app.layoutTree();
    try std.testing.expect(bounds.h > 500); // sanity：确实超出窗口
    const far = firstNodeBelow(app.doc().root, 420) orelse return error.NoFarNode;

    var map = try canvas.renderMap(&app, std.testing.allocator);
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, @intFromFloat(bounds.w)), map.width);
    try std.testing.expectEqual(@as(u32, @intFromFloat(bounds.h)), map.height);

    // 1) 窗口之外的白底必须真的画上去。Window.begin 把裁剪矩形设成整个窗口，
    //    不放开的话这里会是未画过的空白（alpha=0）——正是「只导出可见区域」。
    const bottom_bg = mapPixel(map, 2, map.height - 5);
    try std.testing.expect(bottom_bg[3] == 255);
    try std.testing.expect(bottom_bg[0] >= 200 and bottom_bg[1] >= 200 and bottom_bg[2] >= 200);

    // 2) 窗口之外的节点内容（文字/边框是深色不透明像素）必须在图里
    const x0: u32 = @intFromFloat(@max(far.geom.x, 0));
    const y0: u32 = @intFromFloat(@max(far.geom.y, 0));
    const x1: u32 = @min(map.width, @as(u32, @intFromFloat(far.geom.x + far.geom.w)));
    const y1: u32 = @min(map.height, @as(u32, @intFromFloat(far.geom.y + far.geom.h)));
    var dark: usize = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const p = mapPixel(map, x, y);
            if (p[3] == 255 and p[0] < 160) dark += 1;
        }
    }
    try std.testing.expect(dark > 0);
}

test "缺陷 C-2：exportToPng 写出的文件尺寸 = 整张脑图" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;

    app.doc().selectSingle(1);
    for (0..30) |_| app.cmdAddSibling();
    try dvui.testing.settle(Fns.frame);
    const bounds = app.layoutTree();

    const path = "zmind_test_export_tmp.png";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try canvas.exportToPng(&app, path);

    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(64 << 20),
    );
    defer std.testing.allocator.free(data);

    try std.testing.expect(data.len > 24);
    try std.testing.expectEqual(@as(u8, 0x89), data[0]); // PNG 魔数 \x89PNG
    try std.testing.expectEqualSlices(u8, "PNG", data[1..4]);
    try std.testing.expectEqualSlices(u8, "IHDR", data[12..16]);
    try std.testing.expectEqual(@as(u32, @intFromFloat(bounds.w)), std.mem.readInt(u32, data[16..20], .big));
    try std.testing.expectEqual(@as(u32, @intFromFloat(bounds.h)), std.mem.readInt(u32, data[20..24], .big));
}

// ---------------------------------------------------------------------------
// 节点重挂父（shift+拖放）与多选（框选 / shift+点击）
// ---------------------------------------------------------------------------

test "重挂父：把节点挂到目标节点下，撤销还原父子关系" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    // 示例树：1(根) → 2(分支一), 3(分支二)；给 2 挂个子节点 4
    _ = try model.addChild(app.gpa, model.find(app.doc().root, 2) orelse return error.NodeMissing, 4, "孙节点");
    const before = model.countNodes(app.doc().root);

    // 把 3（分支二）重挂到 2（分支一）下
    app.doc().selectSingle(3);
    app.drag_entries.append(app.gpa, .{ .id = 3, .ox0 = 0, .oy0 = 0 }) catch unreachable;
    app.cmdReparentSelected(2);

    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n3.parent == model.find(app.doc().root, 2));
    // 重挂后用户偏移清零：节点落到新父的自动布局位置
    try std.testing.expectEqual(@as(f32, 0), n3.geom.ox);
    try std.testing.expectEqual(@as(f32, 0), n3.geom.oy);
    try std.testing.expectEqual(before, model.countNodes(app.doc().root)); // 只动结构，不增减节点
    try std.testing.expect(app.canUndo());

    app.cmdUndo();
    const n3b = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expect(n3b.parent == app.doc().root);
}

test "重挂父：目标是自身/后代/现父 → 全部跳过并弹回原位，不留撤销步" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    _ = try model.addChild(app.gpa, model.find(app.doc().root, 2) orelse return error.NodeMissing, 4, "孙节点");
    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    app.doc().selectSingle(3);
    // 模拟拖拽中已经挪动了偏移
    n3.geom.ox = 37;
    n3.geom.oy = -11;
    app.drag_entries.append(app.gpa, .{ .id = 3, .ox0 = 0, .oy0 = 0 }) catch unreachable;

    // 1) 拖到根节点下：3 本来就是根的子节点，无变化 → 跳过
    app.cmdReparentSelected(1);
    try std.testing.expect(!app.canUndo());
    try std.testing.expect(n3.parent == app.doc().root);
    // 2) 拖到自己上：跳过
    app.cmdReparentSelected(3);
    try std.testing.expect(!app.canUndo());

    // 3) 拖到自己的后代（4 是 2 的子节点，把 2 拖到 4 下会成环）：跳过并弹回原位
    app.drag_entries.clearRetainingCapacity();
    app.doc().selectSingle(2);
    app.drag_entries.append(app.gpa, .{ .id = 2, .ox0 = 3, .oy0 = 5 }) catch unreachable;
    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    n2.geom.ox = 100; // 模拟拖拽中挪动
    app.cmdReparentSelected(4);
    try std.testing.expect(!app.canUndo());
    try std.testing.expect(n2.parent == app.doc().root); // 结构没动
    try std.testing.expectEqual(@as(f32, 3), n2.geom.ox); // 偏移弹回拖拽前
    try std.testing.expectEqual(@as(f32, 5), n2.geom.oy);
}

test "重挂父：多选两个节点一次挂到新父下，一步撤销全还原" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    // 新建节点 4 当落点目标
    _ = try model.addChild(app.gpa, app.doc().root, 4, "目标节点");
    const before = model.countNodes(app.doc().root);

    // 多选 2 和 3，一起拖到 4 下
    app.doc().selectSingle(2);
    app.doc().selectAdd(3);
    app.drag_entries.append(app.gpa, .{ .id = 2, .ox0 = 0, .oy0 = 0 }) catch unreachable;
    app.drag_entries.append(app.gpa, .{ .id = 3, .ox0 = 0, .oy0 = 0 }) catch unreachable;
    app.cmdReparentSelected(4);

    const n4 = model.find(app.doc().root, 4) orelse return error.NodeMissing;
    try std.testing.expect(n4.children.items.len == 2);
    try std.testing.expect(model.find(app.doc().root, 2).?.parent == n4);
    try std.testing.expect(model.find(app.doc().root, 3).?.parent == n4);
    try std.testing.expectEqual(before, model.countNodes(app.doc().root));

    // 一步撤销：两个节点一起回来（撤销替换整棵树，指针要重新 find）
    app.cmdUndo();
    const r = app.doc().root;
    try std.testing.expect(model.find(r, 2).?.parent == r);
    try std.testing.expect(model.find(r, 3).?.parent == r);
    try std.testing.expect(model.find(r, 4).?.children.items.len == 0);
}

test "多选：selectAdd/selectRemove 与主选中回退" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const d = app.doc();

    d.selectSingle(2);
    try std.testing.expect(d.isSelected(2));
    try std.testing.expectEqual(@as(usize, 1), d.selected_ids.items.len);
    try std.testing.expectEqual(@as(?u32, 2), d.selected_id);

    d.selectAdd(3);
    try std.testing.expect(d.isSelected(2) and d.isSelected(3));
    try std.testing.expectEqual(@as(usize, 2), d.selected_ids.items.len);
    try std.testing.expectEqual(@as(?u32, 2), d.selected_id); // 主选中不动

    d.selectAdd(3); // 重复加入是空操作
    try std.testing.expectEqual(@as(usize, 2), d.selected_ids.items.len);

    // 移除主选中：主选中回退到集合剩余的最后一个
    d.selectRemove(2);
    try std.testing.expect(!d.isSelected(2));
    try std.testing.expectEqual(@as(?u32, 3), d.selected_id);

    // 清空
    d.selectRemove(3);
    try std.testing.expect(d.selected_ids.items.len == 0);
    try std.testing.expect(d.selected_id == null);
}

test "框选：与矩形相交的节点入选，主选中是第一个命中；add 追加不清原选择" {
    var t = try dvui.testing.init(.{}); // layoutTree 的字体测量要无头窗口
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    _ = app.layoutTree(); // 算出各节点 geom
    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    const r = dvui.Rect{
        .x = @min(n2.geom.x, n3.geom.x) + 1,
        .y = @min(n2.geom.y, n3.geom.y) + 1,
        .w = @max(n2.geom.x + n2.geom.w, n3.geom.x + n3.geom.w) - @min(n2.geom.x, n3.geom.x) - 2,
        .h = @max(n2.geom.y + n2.geom.h, n3.geom.y + n3.geom.h) - @min(n2.geom.y, n3.geom.y) - 2,
    };

    app.selectNodesInRect(r, false);
    try std.testing.expect(app.doc().isSelected(2));
    try std.testing.expect(app.doc().isSelected(3));
    try std.testing.expect(!app.doc().isSelected(1)); // 框没碰到根节点
    try std.testing.expectEqual(@as(?u32, 2), app.doc().selected_id); // 先序第一个命中

    // add 模式：不清空原选择，主选中保持
    app.doc().selectSingle(1);
    app.selectNodesInRect(r, true);
    try std.testing.expect(app.doc().isSelected(1));
    try std.testing.expect(app.doc().isSelected(2));
    try std.testing.expectEqual(@as(?u32, 1), app.doc().selected_id);
}

test "多选删除：一次删两个节点，一步撤销整组还原" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const before = model.countNodes(app.doc().root);
    app.doc().selectSingle(2);
    app.doc().selectAdd(3);
    app.cmdDeleteSelected();

    try std.testing.expectEqual(before - 2, model.countNodes(app.doc().root));
    try std.testing.expect(model.find(app.doc().root, 2) == null);
    try std.testing.expect(model.find(app.doc().root, 3) == null);
    try std.testing.expect(app.canUndo());

    app.cmdUndo();
    try std.testing.expectEqual(before, model.countNodes(app.doc().root));
    try std.testing.expect(model.find(app.doc().root, 2) != null);
    try std.testing.expect(model.find(app.doc().root, 3) != null);
}

// ---------------------------------------------------------------------------
// 视口位置持久化：保存 left/top + mindmap position="true"，打开时恢复
// ---------------------------------------------------------------------------

test "XML：保存 left/top 与 position 标记，loadEx 读回" {
    const alloc = std.testing.allocator;
    const root = try model.createNode(alloc, 1, "根");
    defer root.deinit(alloc);
    _ = try model.addChild(alloc, root, 2, "甲");
    // 模拟排版后的位置（保存的是四舍五入后的整数）
    root.geom.x = 123.4;
    root.geom.y = 55.6;
    root.children.items[0].geom.x = 300;
    root.children.items[0].geom.y = 88;

    var images: model.ImageStore = .{};
    defer images.deinit(alloc);
    const data = try xml.save(root, &images, alloc);
    defer alloc.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "position=\"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "left=\"123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "top=\"56\"") != null);

    var res = try xml.loadEx(alloc, data);
    defer res.deinit(alloc);
    try std.testing.expect(res.positioned);
    try std.testing.expectApproxEqAbs(@as(f32, 123), res.root.geom.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 56), res.root.geom.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), res.root.children.items[0].geom.x, 0.01);
}

test "XML：旧格式（无 position 标记）不解析 left/top，整体自动排版" {
    const alloc = std.testing.allocator;
    var res = try xml.loadEx(alloc,
        \\<mindmap version="1"><node id="1" text="根" left="999" top="888"/></mindmap>
    );
    defer res.deinit(alloc);
    try std.testing.expect(!res.positioned);
    // 没有标记时 left/top 被忽略：geom 保持 0，走自动布局
    try std.testing.expectEqual(@as(f32, 0), res.root.geom.x);
    try std.testing.expectEqual(@as(f32, 0), res.root.geom.y);
}

test "恢复视口位置：保存的 left/top 精确还原，缺 left/top 的节点退回自动布局" {
    var t = try dvui.testing.init(.{}); // 基点布局的字体测量要无头窗口
    defer t.deinit();
    const alloc = std.testing.allocator;

    // 节点 3 故意不写 left/top：应停在自动布局位置（偏移 0）
    var res = try xml.loadEx(alloc,
        \\<mindmap version="1" position="true">
        \\  <node id="1" text="根" left="100" top="80">
        \\    <node id="2" text="甲" left="340" top="30"/>
        \\    <node id="3" text="乙"/>
        \\  </node>
        \\</mindmap>
    );
    defer res.deinit(alloc);
    try std.testing.expect(res.positioned);

    layout.restoreSavedPositions(res.root, null, app_mod.App.measureText);
    const n1 = res.root;
    const n2 = n1.children.items[0];
    const n3 = n1.children.items[1];
    // 保存过的节点恢复到保存时的位置（浮点误差 0.01 内）
    try std.testing.expectApproxEqAbs(@as(f32, 100), n1.geom.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), n1.geom.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 340), n2.geom.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), n2.geom.y, 0.01);
    // 没写 left/top 的节点：偏移 0 = 停在自动布局基点
    try std.testing.expectEqual(@as(f32, 0), n3.geom.ox);
    try std.testing.expectEqual(@as(f32, 0), n3.geom.oy);
}

test "恢复视口位置：折叠节点的子树偏移清零，展开后走自动布局" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const alloc = std.testing.allocator;

    var res = try xml.loadEx(alloc,
        \\<mindmap version="1" position="true">
        \\  <node id="1" text="根" left="100" top="80" collapsed="1">
        \\    <node id="2" text="甲" left="340" top="30"/>
        \\  </node>
        \\</mindmap>
    );
    defer res.deinit(alloc);

    layout.restoreSavedPositions(res.root, null, app_mod.App.measureText);
    // 折叠子树没参与布局：子节点偏移清零（展开时按自动布局出现），不残留文件里的旧值
    const n2 = res.root.children.items[0];
    try std.testing.expectEqual(@as(f32, 0), n2.geom.ox);
    try std.testing.expectEqual(@as(f32, 0), n2.geom.oy);
    // 折叠节点本身照常恢复
    try std.testing.expectApproxEqAbs(@as(f32, 100), res.root.geom.x, 0.01);
}

// ---------------------------------------------------------------------------
// 正文描述输入框：最大宽度（视图宽度的 20%）+ 超宽自动折行
// ---------------------------------------------------------------------------

test "正文描述输入框：break_lines 在最大宽度处自动折行" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const WrapFns = struct {
        var buf: [1200]u8 = undefined;
        var scale: f32 = 1;
        var plain_w: f32 = 0;
        var plain_h: f32 = 0;
        var wrap_w: f32 = 0;
        var wrap_h: f32 = 0;
        fn frame() !dvui.App.Result {
            scale = dvui.windowRectScale().s;
            // 固定宽度的容器：不折行的长行不会被测试窗口宽度钳住
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .rect = .{ .x = 0, .y = 0, .w = 3000, .h = 600 } });
            defer box.deinit();
            var te1 = dvui.textEntry(@src(), .{
                .multiline = true,
                .text = .{ .buffer = buf[0..] },
            }, .{ .tag = "wrap_plain" });
            defer te1.deinit();
            var te2 = dvui.textEntry(@src(), .{
                .multiline = true,
                .break_lines = true,
                .text = .{ .buffer = buf[0..] },
            }, .{ .tag = "wrap_on", .max_size_content = .width(120) });
            defer te2.deinit();
            if (dvui.tagGet("wrap_plain")) |td| {
                plain_w = td.rect.w / scale;
                plain_h = td.rect.h / scale;
            }
            if (dvui.tagGet("wrap_on")) |td| {
                wrap_w = td.rect.w / scale;
                wrap_h = td.rect.h / scale;
            }
            return .ok;
        }
    };
    // 无换行的长行：1200 字节 = "ab " 重复 400 次
    var fi: usize = 0;
    while (fi < WrapFns.buf.len) : (fi += 3) {
        @memcpy(WrapFns.buf[fi .. fi + 3], "ab ");
    }

    try dvui.testing.settle(WrapFns.frame);
    // 不折行：整行自然宽度远超最大宽度
    try std.testing.expect(WrapFns.plain_w > 400);
    // 折行：宽度被最大值钳住（max_size 钳的是内容尺寸，外框还有
    // margin/border/padding 共 22px），高度按折行行数变高
    try std.testing.expect(WrapFns.wrap_w <= 121 + 22);
    try std.testing.expect(WrapFns.wrap_h > WrapFns.plain_h);
}

test "正文描述输入框：最大宽度 = 视图宽度 × 20%" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const RatioFns = struct {
        var view_w: f32 = 0;
        var max_w: f32 = 0;
        fn frame() !dvui.App.Result {
            view_w = dvui.windowRect().w;
            max_w = ui.noteEditorMaxWidth();
            return .ok;
        }
    };
    _ = try dvui.testing.step(RatioFns.frame);
    try std.testing.expect(RatioFns.max_w > 0);
    try std.testing.expectApproxEqAbs(RatioFns.view_w * app_mod.note_editor_max_w_frac, RatioFns.max_w, 0.01);
}

test "正文描述输入框：侧栏输入框宽度不超过最大宽度" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;

    app.doc().selectSingle(2);
    const n = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    // 远超最大宽度的长行（600 字节）
    try model.setNote(app.gpa, n, "ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab ab");

    try dvui.testing.settle(Fns.frame);

    // 测试窗口 600 宽 → 上限 120 自然像素；输入框（物理像素）换算后不得超出
    const entry = dvui.tagGet("side_note") orelse return error.TestUnexpectedResult;
    const s = dvui.windowRectScale().s;
    try std.testing.expect(entry.rect.w / s <= ui.noteEditorMaxWidth() + 0.6);
    // 上限确实钳住了面板宽度（面板 240，上限 120），否则这条测试没有意义
    try std.testing.expect(entry.rect.w / s < 224);
}

// ---------------------------------------------------------------------------
// 工具栏：保存/撤销/重做图标的可用状态（置灰 = 点击不触发）
// ---------------------------------------------------------------------------

test "工具栏：新文档保存/撤销置灰，点击不触发；变脏/入栈后恢复可用" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const count = model.countNodes(app.doc().root);

    // 新文档不脏：点保存不挂号（对话框只在真实程序帧末弹出，测试帧只断言挂号）
    try dvui.testing.moveTo("tb_save");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(Fns.frame);
    try std.testing.expect(app.pending_file_action == .none);

    // 撤销栈空：点撤销不产生任何变化
    try dvui.testing.moveTo("tb_undo");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(Fns.frame);
    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expect(!app.canUndo());

    // 文档变脏：保存按钮恢复可用，点击挂号 .save
    app.doc().dirty = true;
    _ = try dvui.testing.step(Fns.frame);
    try dvui.testing.moveTo("tb_save");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(Fns.frame);
    try std.testing.expectEqual(app_mod.FileAction.save, app.pending_file_action);
    app.pending_file_action = .none; // 测试帧不执行它，手动清掉

    // 加一个子节点（压撤销步 + 变脏）：撤销恢复可用，点击撤销生效
    app.doc().selectSingle(2);
    app.cmdAddChild();
    try std.testing.expect(app.canUndo() and app.doc().dirty);
    try dvui.testing.moveTo("tb_undo");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(Fns.frame);
    try std.testing.expectEqual(count, model.countNodes(app.doc().root));
    try std.testing.expect(!app.canUndo());

    // 撤销之后重做栈非空：重做按钮可用，点击重做生效
    try dvui.testing.moveTo("tb_redo");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(Fns.frame);
    try std.testing.expectEqual(count + 1, model.countNodes(app.doc().root));
    try std.testing.expect(!app.canRedo());
}

// ---------------------------------------------------------------------------
// 「下一级节点」列表：拖动换位写 seq=下标，调节导出顺序
// ---------------------------------------------------------------------------

test "下一级节点列表：拖动换位写 seq=下标，导出顺序跟随，一步撤销还原" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    // 示例树根下加第三个子节点 4：children 顺序 [2,3,4]，seq 全 0
    _ = try model.addChild(app.gpa, app.doc().root, 4, "分支三");
    const parent = app.doc().root;
    const kids = try model.childrenForExport(app.gpa, parent);
    defer app.gpa.free(kids);
    try std.testing.expectEqual(@as(usize, 3), kids.len);

    // 把下标 2（节点 4）拖到 0
    app.cmdMoveChildSeq(kids, 2, 0);
    try std.testing.expectEqual(@as(u64, 0), model.find(parent, 4).?.seq);
    try std.testing.expectEqual(@as(u64, 1), model.find(parent, 2).?.seq);
    try std.testing.expectEqual(@as(u64, 2), model.find(parent, 3).?.seq);

    // 导出顺序跟随新 seq：4,2,3
    const kids2 = try model.childrenForExport(app.gpa, parent);
    defer app.gpa.free(kids2);
    try std.testing.expectEqual(@as(u32, 4), kids2[0].id);
    try std.testing.expectEqual(@as(u32, 2), kids2[1].id);
    try std.testing.expectEqual(@as(u32, 3), kids2[2].id);
    try std.testing.expect(app.canUndo() and app.doc().dirty);

    // 同一手势内的第二次换位不再压撤销步
    const pushed = app.seq_drag_pushed;
    app.cmdMoveChildSeq(kids2, 0, 1);
    try std.testing.expectEqual(pushed, app.seq_drag_pushed);

    // 一步撤销：seq 全回 0，导出顺序回 2,3,4
    app.cmdUndo();
    // 撤销替换整棵树，指针要重新走 app.doc().root
    const root2 = app.doc().root;
    try std.testing.expectEqual(@as(u64, 0), model.find(root2, 4).?.seq);
    const kids3 = try model.childrenForExport(app.gpa, root2);
    defer app.gpa.free(kids3);
    try std.testing.expectEqual(@as(u32, 2), kids3[0].id);
    try std.testing.expectEqual(@as(u32, 3), kids3[1].id);
    try std.testing.expectEqual(@as(u32, 4), kids3[2].id);
}

test "下一级节点列表：无头拖拽列表项，seq 实时更新" {
    // 窗口加高：侧栏列表完整可见（不用滚动就能拖）
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 1000 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;

    _ = try model.addChild(app.gpa, app.doc().root, 4, "分支三");
    app.doc().selectSingle(1);
    try dvui.testing.settle(Fns.frame);

    // 列表三行按导出顺序 2,3,4；把最后一行（节点 4）拖到第一行
    const cw = dvui.currentWindow();
    const r_last = dvui.tagGet("child_item_4") orelse return error.TestUnexpectedResult;
    _ = try cw.addEventMouseMotion(.{ .pt = r_last.rect.center() });
    _ = try cw.addEventMouseButton(.left, .press);
    const r_first = dvui.tagGet("child_item_2") orelse return error.TestUnexpectedResult;
    _ = try cw.addEventMouseMotion(.{ .pt = r_first.rect.center() });
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(Fns.frame);

    // seq 按新列表下标写入；导出顺序 4,2,3；树本身顺序不动
    try std.testing.expectEqual(@as(u64, 0), model.find(app.doc().root, 4).?.seq);
    try std.testing.expectEqual(@as(u64, 1), model.find(app.doc().root, 2).?.seq);
    try std.testing.expectEqual(@as(u64, 2), model.find(app.doc().root, 3).?.seq);
    const parent = app.doc().root;
    try std.testing.expectEqual(@as(u32, 2), parent.children.items[0].id);
    try std.testing.expectEqual(@as(u32, 3), parent.children.items[1].id);
    try std.testing.expectEqual(@as(u32, 4), parent.children.items[2].id);
    try std.testing.expect(app.canUndo());

    // 一步撤销还原
    app.cmdUndo();
    try std.testing.expectEqual(@as(u64, 0), model.find(app.doc().root, 4).?.seq);
}

test "关于对话框：公众号二维码已编入 exe 资源" {
    // @embedFile 的字节以 JPEG 签名开头；替换 assets/wxqrcode.jpg 为真实
    // 二维码后重新构建，此测试仍然有效（只校验格式不校验内容）
    try std.testing.expect(app_mod.wxqrcode_jpg.len > 4);
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff", app_mod.wxqrcode_jpg[0..3]);
}

test "回归：shift 多选与重挂父（真实事件流）不崩溃" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 1000 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const cw = dvui.currentWindow();
    cw.modifiers = dvui.enums.Mod.lshift;

    // ---- 单选重挂：shift+按下 节点2 拖到 节点3 上释放 → 2 挂到 3 下 ----
    app.doc().selectSingle(2);
    {
        const r2 = dvui.tagGet("node:2") orelse return error.TestUnexpectedResult;
        _ = try cw.addEventMouseMotion(.{ .pt = r2.rect.center() });
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try dvui.testing.step(Fns.frame);
        const r3 = dvui.tagGet("node:3") orelse return error.TestUnexpectedResult;
        _ = try cw.addEventMouseMotion(.{ .pt = r3.rect.center() });
        _ = try dvui.testing.step(Fns.frame);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(Fns.frame);
    }
    // 被拖动的节点 2 跟着指针走，松手时指针压在它身上——目标查找必须
    // 跳过它，找到压在下面的节点 3
    {
        const moved = model.find(app.doc().root, 2) orelse return error.NodeMissing;
        try std.testing.expect(moved.parent == model.find(app.doc().root, 3));
        try std.testing.expectEqual(@as(usize, 1), app.doc().root.children.items.len);
        try std.testing.expect(app.canUndo());
        app.cmdUndo(); // 还原，给下一段用
        try std.testing.expectEqual(@as(usize, 2), app.doc().root.children.items.len);
    }

    // ---- 多选重挂：多选 {2,3}，一起拖到未选中的节点 4 上 ----
    _ = try model.addChild(app.gpa, app.doc().root, 4, "分支三");
    app.doc().selectSingle(2);
    {
        const r3 = dvui.tagGet("node:3") orelse return error.TestUnexpectedResult;
        _ = try cw.addEventMouseMotion(.{ .pt = r3.rect.center() });
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(Fns.frame);
    }
    try std.testing.expect(app.doc().isSelected(2));
    try std.testing.expect(app.doc().isSelected(3));

    {
        const r2 = dvui.tagGet("node:2") orelse return error.TestUnexpectedResult;
        _ = try cw.addEventMouseMotion(.{ .pt = r2.rect.center() });
        _ = try cw.addEventMouseButton(.left, .press);
        _ = try dvui.testing.step(Fns.frame);
        const r4 = dvui.tagGet("node:4") orelse return error.TestUnexpectedResult;
        _ = try cw.addEventMouseMotion(.{ .pt = r4.rect.center() });
        _ = try dvui.testing.step(Fns.frame);
        _ = try cw.addEventMouseButton(.left, .release);
        _ = try dvui.testing.step(Fns.frame);
    }
    // 两个选中的节点一起挂到未选中的节点 4 下
    try std.testing.expect(model.find(app.doc().root, 2).?.parent == model.find(app.doc().root, 4));
    try std.testing.expect(model.find(app.doc().root, 3).?.parent == model.find(app.doc().root, 4));
    try std.testing.expectEqual(@as(usize, 1), app.doc().root.children.items.len);
}
test "回归：空白框选（左键拖拽多选）不崩溃" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 1000 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);

    const cw = dvui.currentWindow();
    const r2 = dvui.tagGet("node:2") orelse return error.TestUnexpectedResult;

    // 空白处起点（node2 右侧 100px、顶缘上方 10px——不在任何节点上）
    const start_pt: dvui.Point.Physical = .{ .x = r2.rect.x + r2.rect.w + 100, .y = r2.rect.y - 10 };
    _ = try cw.addEventMouseMotion(.{ .pt = start_pt });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(Fns.frame);

    // 拖到 node3 中心（框过节点），松开
    const r3 = dvui.tagGet("node:3") orelse return error.TestUnexpectedResult;
    _ = try cw.addEventMouseMotion(.{ .pt = r3.rect.center() });
    _ = try dvui.testing.step(Fns.frame);
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(Fns.frame);

    try std.testing.expect(app.doc().isSelected(2));
    try std.testing.expect(app.doc().isSelected(3));
}

test "App 持有 recent 历史：record 去重提升，deinit 释放不泄漏" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 0), app.recent.entries.items.len);

    try app.recent.record("D:\\tmp\\a.mcab");
    try app.recent.record("D:\\tmp\\b.mcab");
    try app.recent.record("D:\\tmp\\a.mcab"); // 重复：提到未钉住区顶
    try std.testing.expectEqual(@as(usize, 2), app.recent.entries.items.len);
    try std.testing.expectEqualStrings("D:\\tmp\\a.mcab", app.recent.entries.items[0].path);

    app.recent.remove("D:\\tmp\\b.mcab"); // 不走 recentRemove：那会落盘真实历史文件
    try std.testing.expectEqual(@as(usize, 1), app.recent.entries.items.len);
    // entries 的内存由 defer app.deinit() 里的 recent.deinit 释放（testing.allocator 查泄漏）
}

// ---------------------------------------------------------------------------
// 2.0：节点图片（img）与属性表（property）
// ---------------------------------------------------------------------------

test "XML version=2：images 池 + node 内 img ref 往返持久化" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    // 一段最小 JPEG 风格字节（内容不参与解码，只验证 base64 往返）
    const img_bytes = "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\xff\xd9";
    try app.cmdSetNodeImg(n2, "jpg", img_bytes);
    try model.addProperty(app.gpa, n2, "权重", "1");
    try model.addProperty(app.gpa, n2, "材质", "橡胶<&\"");

    const data = try xml.save(app.doc().root, &app.doc().images, app.gpa);
    defer app.gpa.free(data);

    // 保存产物断言：version=2；图片数据集中在 <images> 池里；
    // 节点内只写引用 <img ref="..." />；属性照旧
    try std.testing.expect(std.mem.indexOf(u8, data, "<mindmap version=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "<images>") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "<img id=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "type=\"jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "md5=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "<img ref=\"") != null);
    // 节点内不再内联 base64：<img> 只剩 ref 一个属性
    try std.testing.expect(std.mem.indexOf(u8, data, "<img type=\"jpg\">") == null);
    try std.testing.expect(std.mem.indexOf(u8, data, "<property name=\"权重\">1</property>") != null);
    // 转义：值里的 < & " 不能破坏 XML 结构
    try std.testing.expect(std.mem.indexOf(u8, data, "<property name=\"材质\">橡胶&lt;&amp;&quot;</property>") != null);

    // 往返：图片池里取回同一份字节，节点 ref 指向它
    var res = try xml.loadEx(app.gpa, data);
    defer res.deinit(app.gpa);
    const r2 = model.find(res.root, 2) orelse return error.NodeMissing;
    try std.testing.expect(r2.hasImg());
    const asset = res.images.findById(r2.img_ref.items) orelse return error.ImageMissing;
    try std.testing.expectEqualStrings("jpg", asset.img_type.items);
    try std.testing.expectEqualStrings(img_bytes, asset.data.items);
    try std.testing.expectEqual(@as(usize, 1), res.images.count());
    // id 就是内容 md5；md5 属性与 id 一致
    var hexbuf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(model.md5Hex(img_bytes, &hexbuf), asset.id.items);
    try std.testing.expectEqualStrings(asset.id.items, asset.md5.items);
    try std.testing.expectEqual(@as(usize, 2), r2.properties.items.len);
    try std.testing.expectEqualStrings("权重", r2.properties.items[0].name.items);
    try std.testing.expectEqualStrings("1", r2.properties.items[0].value.items);
    try std.testing.expectEqualStrings("材质", r2.properties.items[1].name.items);
    try std.testing.expectEqualStrings("橡胶<&\"", r2.properties.items[1].value.items);

    // version=1 旧文件照常加载（无 images/img/property 天然兼容）
    var old = try xml.load(app.gpa, "<mindmap version=\"1\"><node id=\"1\" text=\"旧\"/></mindmap>");
    defer old.deinit(app.gpa);
    try std.testing.expect(!old.hasImg());
    try std.testing.expectEqual(@as(usize, 0), old.properties.items.len);

    // 坏 base64 不致命：丢弃该项，节点照常加载（ref 保留但不指向任何资源）
    var bad = try xml.loadEx(app.gpa, "<mindmap version=\"2\"><images><img id=\"x\" type=\"jpg\">!!!bad!!!</img></images><node id=\"1\" text=\"x\"><img ref=\"x\" /></node></mindmap>");
    defer bad.deinit(app.gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.images.count());
    const b1 = model.find(bad.root, 1) orelse return error.NodeMissing;
    try std.testing.expect(b1.hasImg()); // 引用还在
    try std.testing.expect(bad.images.findById(b1.img_ref.items) == null); // 但资源缺失
}

test "XML：2.0 早期内联 <img type> 格式读取时转成池内资源 + ref" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    const legacy =
        \\<mindmap version="2"><node id="1" text="旧内联"><img type="png">aGVsbG8=</img></node></mindmap>
    ;
    var res = try xml.loadEx(app.gpa, legacy);
    defer res.deinit(app.gpa);
    const n1 = model.find(res.root, 1) orelse return error.NodeMissing;
    try std.testing.expect(n1.hasImg());
    try std.testing.expectEqual(@as(usize, 1), res.images.count());
    const asset = res.images.findById(n1.img_ref.items) orelse return error.ImageMissing;
    try std.testing.expectEqualStrings("hello", asset.data.items);
    try std.testing.expectEqualStrings("png", asset.img_type.items);
}

test "图片去重：同一张图（md5 相同）只存一份、复用同一 id" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try app.cmdSetNodeImg(n2, "png", "same-bytes");
    try app.cmdSetNodeImg(n3, "png", "same-bytes");

    try std.testing.expectEqual(@as(usize, 1), app.doc().images.count());
    try std.testing.expectEqualStrings(n2.img_ref.items, n3.img_ref.items);
    // 再设一次不同内容 → 池里多一项，引用不同
    try app.cmdSetNodeImg(n2, "png", "other-bytes");
    try std.testing.expectEqual(@as(usize, 2), app.doc().images.count());
    try std.testing.expect(!std.mem.eql(u8, n2.img_ref.items, n3.img_ref.items));
    // 保存只写被引用到的资源（两棵树都还引用着 → 两项都在）
    const data = try xml.save(app.doc().root, &app.doc().images, app.gpa);
    defer app.gpa.free(data);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, data, "<img id=\""));
}

test "cloneTree 深拷贝 img ref/property：改原件不影响克隆（撤销镜像）" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try model.setImgRef(app.gpa, n2, "ref-1");
    try model.addProperty(app.gpa, n2, "权重", "1");

    const snap = try model.cloneTree(app.gpa, app.doc().root);
    defer snap.deinit(app.gpa);

    // 改原件（换引用 + 改值 + 删属性），克隆体必须原样
    try model.setImgRef(app.gpa, n2, "ref-2");
    try model.setPropertyValue(app.gpa, n2, 0, "99");
    model.removeProperty(app.gpa, n2, 0);

    const c2 = model.find(snap, 2) orelse return error.NodeMissing;
    try std.testing.expectEqualStrings("ref-1", c2.img_ref.items);
    try std.testing.expectEqual(@as(usize, 1), c2.properties.items.len);
    try std.testing.expectEqualStrings("1", c2.properties.items[0].value.items);
}

test "节点图片：设置可撤销、移除可撤销（资源留在池里，重做仍可恢复）" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.doc().selectSingle(2);

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try app.cmdSetNodeImg(n2, "jpg", "bytes-a");
    try std.testing.expect(n2.hasImg());
    try std.testing.expect(app.doc().dirty);
    const ref_a = try app.gpa.dupe(u8, n2.img_ref.items);
    defer app.gpa.free(ref_a);

    // undo/redo 是整树换镜像：旧指针随旧树进了栈，必须重新 find
    app.cmdUndo();
    const undone = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expect(!undone.hasImg());

    app.cmdRedo();
    const r2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expectEqualStrings(ref_a, r2.img_ref.items);
    try std.testing.expect(app.imageAsset(r2) != null); // 池里的数据仍在

    app.cmdClearNodeImg();
    const c2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expect(!c2.hasImg());
    app.cmdUndo();
    const restored = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expectEqualStrings(ref_a, restored.img_ref.items);
    try std.testing.expect(app.imageAsset(restored) != null);
}

test "属性命令：添加 / 删除 / 改名改值，一步撤销还原一组" {
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.doc().selectSingle(2);

    const n2 = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    app.cmdAddProperty();
    app.cmdAddProperty();
    try std.testing.expectEqual(@as(usize, 2), n2.properties.items.len);

    try model.setPropertyValue(app.gpa, n2, 0, "1");
    try model.setPropertyName(app.gpa, n2, 0, "权重");

    app.cmdRemoveProperty(0);
    const after = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expectEqual(@as(usize, 1), after.properties.items.len);

    app.cmdUndo();
    const restored = model.find(app.doc().root, 2) orelse return error.NodeMissing;
    try std.testing.expectEqual(@as(usize, 2), restored.properties.items.len);
    try std.testing.expectEqualStrings("权重", restored.properties.items[0].name.items);
    try std.testing.expectEqualStrings("1", restored.properties.items[0].value.items);
}

test "侧栏属性区：添加按钮加一行、删除按钮移除、输入框直绑可编辑" {
    // 侧栏内容多，窗口加高保证「添加属性」按钮在视口内
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 900 } });
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    Fns.app_ptr = &app;
    app.doc().selectSingle(3);
    try dvui.testing.settle(Fns.frame);

    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    try std.testing.expectEqual(@as(usize, 0), n3.properties.items.len);

    try dvui.testing.moveTo("side_prop_add");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(usize, 1), n3.properties.items.len);

    // 属性名输入框直绑 p.name：键入即写入模型（撤销由文本框会话负责）
    try dvui.testing.moveTo("side_prop_name:0");
    try dvui.testing.click(.left);
    try dvui.testing.writeText("权重");
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqualStrings("权重", n3.properties.items[0].name.items);
    try std.testing.expect(app.doc().dirty);

    // 编辑框高度必须与常规单行输入框（标题）一致——只给宽度会让 textEntry
    // 缩成一条细缝（用户反馈「上下太小」）
    {
        const title_r = (try dvui.testing.tagGet("side_title")).rect;
        const name_r = (try dvui.testing.tagGet("side_prop_name:0")).rect;
        try std.testing.expect(@abs(title_r.h - name_r.h) <= 3);
        try std.testing.expect(name_r.h > title_r.h * 0.8);
    }

    try dvui.testing.moveTo("side_prop_del:0");
    try dvui.testing.click(.left);
    try dvui.testing.settle(Fns.frame);
    try std.testing.expectEqual(@as(usize, 0), n3.properties.items.len);
}

test "布局：img 首行撑高、property 逐行叠加高度" {
    // 布局测量走 dvui 字体（themeGet），需要无头窗口上下文
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    _ = app.layoutTree();
    const base_h = n3.geom.h;
    const base_w = n3.geom.w;
    // 无属性时高度可能被 node_min_h 撑起，期望值必须按内容高度算（排除钳制）
    var content_h = app_mod.App.measureMultiline(dvui.themeGet().font_body, n3.text.items).h;
    if (n3.hasNote()) {
        content_h += layout.metrics.desc_gap + app_mod.App.measureMultiline(app_mod.App.descFont(), n3.note.items).h;
    }

    // 加 2 条属性：内容高度 + 与上方文字的半行间距 + 2×18，宽度不被表格撑动
    try model.addProperty(app.gpa, n3, "权重", "1");
    try model.addProperty(app.gpa, n3, "材质", "橡胶");
    _ = app.layoutTree();
    try std.testing.expectEqual(
        content_h + layout.metrics.prop_gap + 2 * layout.metrics.prop_row_h + layout.metrics.pad_y * 2,
        n3.geom.h,
    );
    try std.testing.expectEqual(base_w, n3.geom.w);
    try std.testing.expect(base_h <= n3.geom.h);

    // 加图片：首行高度 ≥ 图标 24（无图时标题行可能小于 24）
    model.removeProperty(app.gpa, n3, 1);
    model.removeProperty(app.gpa, n3, 0);
    try app.cmdSetNodeImg(n3, "jpg", "fake-jpeg-bytes");
    _ = app.layoutTree();
    try std.testing.expect(n3.geom.h >= layout.metrics.img_icon + layout.metrics.pad_y * 2);
    try std.testing.expect(n3.geom.w >= layout.metrics.img_icon + layout.metrics.img_gap + layout.metrics.pad_x * 2);
}

test "导出渲染：属性表格画在节点框内，名格与值格同一行并排" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    var app = try app_mod.App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();

    const n3 = model.find(app.doc().root, 3) orelse return error.NodeMissing;
    // 撑宽节点：值格才有足够宽度，取样避开左对齐文字
    try n3.text.appendSlice(app.gpa, " 留足取样宽度");
    try model.addProperty(app.gpa, n3, "权重", "1");
    _ = app.layoutTree();
    // renderMap 注册 widget id：两次离屏渲染必须隔帧，否则同帧撞 id（dvui 报 duplicate id）
    Fns.app_ptr = &app;
    try dvui.testing.settle(Fns.frame);
    var map = try canvas.renderMap(&app, std.testing.allocator);
    defer map.deinit(std.testing.allocator);

    // 名格（灰 217…）、值格（浅绿 209/237/209）都必须画在节点框内，
    // 且**同一行并排**——嵌套控件导致的「值格向右下错位」会在这里露馅。
    const gray = colorBBox(map, n3.geom, .{ .r = 217, .g = 217, .b = 217 }, 6);
    const green = colorBBox(map, n3.geom, .{ .r = 209, .g = 237, .b = 209 }, 6);
    try std.testing.expect(gray != null);
    try std.testing.expect(green != null);
    const g1 = gray.?;
    const g2 = green.?;
    // 同一行（上下边界差 ≤ 2px）
    try std.testing.expect(@abs(g1.y0 - g2.y0) <= 2 and @abs(g1.y1 - g2.y1) <= 2);
    // 并排：值格紧跟名格右边界（中间只隔两格的 1px 边框与抗锯齿）
    try std.testing.expect(g2.x0 > g1.x1 and g2.x0 - g1.x1 <= 6);
    // 行高≈prop_row_h（只统计内部像素，四周各让出边框+抗锯齿 2px）
    const row_h: i32 = @intFromFloat(layout.metrics.prop_row_h);
    try std.testing.expect(g1.y1 - g1.y0 <= row_h and g1.y1 - g1.y0 >= row_h - 6);

    // 移除属性 → 节点框内不再有浅绿
    model.removeProperty(app.gpa, n3, 0);
    _ = app.layoutTree();
    try dvui.testing.settle(Fns.frame); // 隔帧，避免与上一次 renderMap 撞 widget id
    var map2 = try canvas.renderMap(&app, std.testing.allocator);
    defer map2.deinit(std.testing.allocator);
    try std.testing.expect(colorBBox(map2, n3.geom, .{ .r = 209, .g = 237, .b = 209 }, 6) == null);
}

/// 像素颜色比较用的 RGB 三元组（测试辅助）。
const Rgb = struct { r: u8, g: u8, b: u8 };

/// (x, y) 处像素是否接近 c（容差 tol）。
fn pixelNear(map: canvas.MapPixels, x: i32, y: i32, c: Rgb, tol: i32) bool {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(map.width)) or y >= @as(i32, @intCast(map.height))) return false;
    const p = mapPixel(map, @intCast(x), @intCast(y));
    return @abs(@as(i32, p[0]) - c.r) <= tol and @abs(@as(i32, p[1]) - c.g) <= tol and @abs(@as(i32, p[2]) - c.b) <= tol;
}

/// 在 geom 范围内找指定颜色像素的包围盒（容差 tol，抗锯齿/主题混色）。
/// 只统计「4 邻域同色」的内部像素——节点圆角描边的抗锯齿会把外围像素
/// 混成接近目标的灰，不做这一步包围盒会被整个节点框污染。
/// 找不到返回 null。
fn colorBBox(map: canvas.MapPixels, geom: model.Geometry, rgb: Rgb, tol: i32) ?struct { x0: i32, y0: i32, x1: i32, y1: i32 } {
    var y: i32 = @intFromFloat(geom.y);
    var x0: i32 = -1;
    var y0: i32 = -1;
    var x1: i32 = -1;
    var y1: i32 = -1;
    while (y < @as(i32, @intFromFloat(geom.y + geom.h))) : (y += 1) {
        var x: i32 = @intFromFloat(geom.x);
        while (x < @as(i32, @intFromFloat(geom.x + geom.w))) : (x += 1) {
            if (!pixelNear(map, x, y, rgb, tol)) continue;
            if (!pixelNear(map, x - 1, y, rgb, tol) or !pixelNear(map, x + 1, y, rgb, tol)) continue;
            if (!pixelNear(map, x, y - 1, rgb, tol) or !pixelNear(map, x, y + 1, rgb, tol)) continue;
            if (x0 < 0 or x < x0) x0 = x;
            if (y0 < 0 or y < y0) y0 = y;
            if (x > x1) x1 = x;
            if (y > y1) y1 = y;
        }
    }
    if (x0 < 0) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}
