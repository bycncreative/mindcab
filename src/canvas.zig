//! zmind 画布视图：滚动区 + 贝塞尔连线 + 绝对定位节点框。
//! 交互：单击选中、shift+点击多选、空白框选、拖拽移动子树、
//! shift+拖放更换父节点（拖动中隐藏与旧父的连线、高亮落点目标）、双击就地编辑。
//! 只负责「画 + 交互」，数据修改走 App 的命令层。
const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const model = @import("model.zig");
const layout = @import("layout.zig");
const app_mod = @import("app.zig");

/// 连线采样点数（绘制与命中测试共用同一套几何，保证点得中）。
const edge_samples: usize = 17;

/// 连线命中容差（画布坐标，px）。
const edge_hit_slop: f32 = 6;

/// 连线标题标签的内边距与最小宽度。
const edge_label_pad_x: f32 = 5;
const edge_label_pad_y: f32 = 2;
const edge_label_min_w: f32 = 24;

/// 连线标题内联编辑框的最小宽度（外框，已含 textEntry 的 margin/border/padding）。
const edge_editor_min_w: f32 = 160;

/// 节点缩放把手的命中宽度（画布坐标，px）：右边缘 / 下边缘 / 右下角。
const resize_zone: f32 = 7;

/// 点落在节点的哪个缩放把手上（画布坐标）；左/上不可调（布局锚定，见 app.ResizeEdge）。
fn resizeZone(g: model.Geometry, px: f32, py: f32) app_mod.ResizeEdge {
    const in_right = px >= g.x + g.w - resize_zone and px <= g.x + g.w;
    const in_bottom = py >= g.y + g.h - resize_zone and py <= g.y + g.h;
    if (in_right and in_bottom) return .se;
    if (in_right) return .e;
    if (in_bottom) return .s;
    return .none;
}

/// 把图片自然尺寸「装进」边长 side 的正方形：保持纵横比，尽量铺满（允许放大）。
/// 节点缩略图的图片区是固定的正方形，直接把方形尺寸喂给 dvui.image 会把
/// 任意比例的图拉成方的（dvui 用 min_size_content 当内容尺寸渲染，不做 contain），
/// 所以这里先算出等比适配后的尺寸，再由调用方靠左上摆放。
/// 与预览窗口的区别：预览「只缩小不放大」（看细节），缩略图要「铺满」（看是什么图）。
fn fitInSquare(nat: dvui.Size, side: f32) dvui.Size {
    if (!(nat.w > 0) or !(nat.h > 0)) return .{ .w = side, .h = side };
    const s = @min(side / nat.w, side / nat.h);
    return .{ .w = @max(nat.w * s, 1), .h = @max(nat.h * s, 1) };
}

/// SDL 毫秒计时（dvui 没有时钟 API，双击判定靠它）。
fn nowMs() i64 {
    return @intCast(SDLBackend.c.SDL_GetTicks());
}

/// 绘制整个画布（连线垫底，节点在上，内联编辑框最顶）。
/// 只画当前标签的文档；每个标签有自己的滚动位置（存在 Doc.scroll_info）。
pub fn draw(app: *app_mod.App) void {
    const d = app.doc();
    const bounds = app.layoutTree();
    d.scroll_info.virtual_size = .{ .w = bounds.w, .h = bounds.h };

    var scrollArea = dvui.scrollArea(@src(), .{ .scroll_info = &d.scroll_info }, .{ .style = .content, .expand = .both });
    defer scrollArea.deinit();

    // 命令层（加节点 / 撤销 / 切标签）可能把选中节点落在视口之外——
    // 那种情况下用户看到的是「按了 Insert 却没有任何反应」。
    // 这里在取 screenRectScale 之前把视口滚到选中节点可见为止；
    // scrollArea 构造时已填好 viewport.w/h，只改 x/y（scrollToOffset 自带 clamp）。
    // 首帧 viewport 还是 0×0（尺寸在滚动区画完才写回），此时保留标志等下一帧。
    if (app.reveal_selected and revealSelected(&d.scroll_info, app)) {
        app.reveal_selected = false;
    }

    const rs = scrollArea.scroll.?.screenRectScale(.{});

    drawEdges(app, d.root, rs, 0);
    // 连线不是控件、没有自己的事件，命中测试必须手写。
    // 放在节点之前跑，并用「点是否落在节点框内」把事件让给节点框，避免抢节点的点击。
    drawEdgeEvents(app, d.root, rs);
    drawNodes(app, d.root, rs, true);
    // 框选放在节点/连线之后：它们没要的（空白处）按下才轮到框选
    handleRubberBand(app, d, &scrollArea.scroll.?, rs);
    if (app.rubber) |rb| drawRubberBand(rb, rs);
    drawInlineEditor(app);

    // 整帧画完、所有遍历都结束后，才执行挂起的重挂父（树结构变更）：
    // 松手事件在 drawNodes 递归途中触发，就地改树会让后续遍历踩到
    // 变更前的切片（同帧重复注册相同 widget id → 崩溃）。
    if (app.pending_reparent_target) |tid| {
        app.pending_reparent_target = null;
        // 先把拖拽期的视觉偏移（ox/oy）弹回：撤销快照必须拍「拖拽前」的状态，
        // 否则撤销后节点残留拖拽偏移、视觉上叠到别的节点上
        app.restoreDragOffsets();
        app.cmdReparentSelected(tid);
        app.drag_entries.clearRetainingCapacity();
    }
}

/// 把选中节点滚进可视区（只在它越出视口时移动，可见时不动）。
/// 返回「标志可以清掉了」：视口尺寸还没就绪时返回 false，下一帧再试。
fn revealSelected(si: *dvui.ScrollInfo, app: *app_mod.App) bool {
    if (si.viewport.w <= 0 or si.viewport.h <= 0) return false; // 首帧还没有视口尺寸
    const sid = app.doc().selected_id orelse return true; // 没有选中项，无事可做
    const n = model.find(app.doc().root, sid) orelse return true;
    const r = n.geom;
    if (r.x < si.viewport.x) {
        si.scrollToOffset(.horizontal, r.x);
    } else if (r.x + r.w > si.viewport.x + si.viewport.w) {
        si.scrollToOffset(.horizontal, r.x + r.w - si.viewport.w);
    }
    if (r.y < si.viewport.y) {
        si.scrollToOffset(.vertical, r.y);
    } else if (r.y + r.h > si.viewport.y + si.viewport.h) {
        si.scrollToOffset(.vertical, r.y + r.h - si.viewport.h);
    }
    return true;
}

/// 离屏渲染结果：整张脑图的 RGBA 像素（行主序、已反预乘，未压缩）。
pub const MapPixels = struct {
    pixels: []u8, // 长度 = width * height * 4
    width: u32,
    height: u32,

    pub fn deinit(self: MapPixels, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// 把当前标签的脑图（连线 + 节点，不含内联编辑框、滚动条）整张画进离屏
/// 纹理并读回内存。`exportToPng` 的渲染半段，拆出来是为了让测试能直接
/// 断言像素（PNG 解码太贵，而「窗口外有没有画上」正是导出的缺陷点）。
///
/// 必须在 `dvui.Window.begin/end` 期间调用——dvui 的离屏纹理依赖当前窗口上下文。
/// 返回的内存由 allocator 分配，调用方负责释放；纹理在帧末统一销毁。
pub fn renderMap(app: *app_mod.App, allocator: std.mem.Allocator) !MapPixels {
    const d = app.doc();
    const bounds = app.layoutTree();

    // 离屏纹理 target：尺寸 = 整张脑图包围盒。layout 的坐标原点是 (margin, margin)，
    // 节点落在 [margin, bounds-margin] 内，正好在 picture 范围内（带白底边距）。
    const tex = dvui.textureCreateTarget(.{
        .width = @as(u32, @intFromFloat(@max(bounds.w, 1))),
        .height = @as(u32, @intFromFloat(@max(bounds.h, 1))),
        .interpolation = .linear,
        .format = .rgba_32,
    }) catch return error.PictureInitFailed;
    // 成功失败都要释放（destroyLater 是帧末统一释放，避免同步栈路径污染 SDL state）
    defer tex.destroyLater();

    // 切换渲染目标到离屏纹理（原本的目标会自动恢复，见 defer）。
    const target = dvui.renderTarget(.{ .texture = tex, .offset = .{ .x = 0, .y = 0 } });
    defer _ = dvui.renderTarget(target);

    // 裁剪必须放开到整张纹理。
    // Window.begin 把裁剪矩形设成了整个窗口（Window.zig：clipSet(rect_pixels)），
    // 而 dvui 的每一次绘制都会与它求交（render.zig 的 renderTriangles/renderText/…）。
    // 离屏纹理比窗口大，窗口之外的区域若不放开裁剪会被整块裁掉 —— 表现为
    // 「导出的 PNG 只有当前能看到的那一屏，滚动条滚出来的区域全是空白」。
    const prev_clip = dvui.clipGet();
    dvui.clipSet(.{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(tex.width),
        .h = @floatFromInt(tex.height),
    });
    defer dvui.clipSet(prev_clip);

    // 先用白色背景填充（不调的话 PNG 默认透明，部分看图软件渲染黑底）
    {
        var bg = dvui.box(@src(), .{}, .{
            .rect = .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h },
            .background = true,
            .style = .window,
            .margin = .{},
            .padding = .{},
        });
        defer bg.deinit();
    }

    // layout 输出的是 natural 坐标，导出场景下与 physical 1:1。
    const rs: dvui.RectScale = .{ .r = .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h }, .s = 1.0 };
    drawEdges(app, d.root, rs, 0);
    drawNodes(app, d.root, rs, false); // 第二遍：不再登记 tag，避免与正常帧撞名

    // 把离屏纹理像素读回内存。sliceToRGBA 是**原地**反预乘、返回同一块内存，
    // 所以只释放这一次（老代码两处 free 同一指针，靠 lifo 忽略 double-free 才没炸）。
    const pma_pixels = try dvui.textureReadTarget(allocator, tex);
    errdefer allocator.free(pma_pixels);
    const pixels = dvui.Color.PMA.sliceToRGBA(pma_pixels);

    return .{ .pixels = pixels, .width = tex.width, .height = tex.height };
}

/// 把当前标签的脑图渲染到离屏纹理，编码成 PNG 写入 path。
///
/// 必须在 `dvui.Window.begin/end` 期间调用——dvui 的离屏纹理依赖当前窗口上下文。
pub fn exportToPng(app: *app_mod.App, path: []const u8) !void {
    var map = try renderMap(app, app.gpa);
    defer map.deinit(app.gpa);

    // 编码 PNG 到内存 buffer。PNGEncoder 要求 writer 初始 buffer ≥ min_buffer_size
    // （pHYs 头 13 字节），Allocating.init 是 0 会触发 assert 崩溃（实测）；
    // 给 4KB 起步顺带减少编码中途扩容。
    var aw = try std.Io.Writer.Allocating.initCapacity(app.gpa, @max(4096, dvui.PNGEncoder.min_buffer_size));
    defer aw.deinit();
    try dvui.PNGEncoder.write(&aw.writer, map.pixels, map.width, map.height);
    const data = aw.writer.buffered()[0..aw.writer.end];

    // 写入文件
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = data }) catch return error.OpenWriteFailed;
}

// ---------------------------------------------------------------------------
// 连线几何：三次贝塞尔（绘制与命中测试共用）
// ---------------------------------------------------------------------------
fn edgePoints(parent: *model.Node, child: *model.Node, out: *[edge_samples]dvui.Point.Natural) void {
    const x0 = parent.geom.x + parent.geom.w;
    const y0 = parent.geom.y + parent.geom.h / 2.0;
    const x1 = child.geom.x;
    const y1 = child.geom.y + child.geom.h / 2.0;
    const dx = x1 - x0;
    for (out, 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge_samples - 1));
        const mt = 1.0 - t;
        // P0=(x0,y0) P1=(x0+dx/2,y0) P2=(x1-dx/2,y1) P3=(x1,y1)
        p.* = .{
            .x = mt * mt * mt * x0 + 3 * mt * mt * t * (x0 + dx * 0.5) + 3 * mt * t * t * (x1 - dx * 0.5) + t * t * t * x1,
            .y = mt * mt * mt * y0 + 3 * mt * mt * t * y0 + 3 * mt * t * t * y1 + t * t * t * y1,
        };
    }
}

/// 连线标题标签的外框（以贝塞尔中点为中心）；无标题返回 null。
/// 绘制、命中测试、内联编辑框三处共用，保证「看到的就是能点的」。
fn edgeLabelRect(_: *app_mod.App, parent: *model.Node, child: *model.Node) ?dvui.Rect {
    if (!child.hasLink()) return null;
    var pts: [edge_samples]dvui.Point.Natural = undefined;
    edgePoints(parent, child, &pts);
    return labelBoxAt(pts[edge_samples / 2], child.link.slice());
}

/// 以连线中点为标签尺寸算出外框（无论有没有标题都可用，编辑空标题时兜底）。
fn labelBoxAt(mid: dvui.Point.Natural, text: []const u8) dvui.Rect {
    const ts = app_mod.App.measureMultiline(app_mod.App.descFont(), text);
    const w = @max(ts.w + edge_label_pad_x * 2, edge_label_min_w);
    const h = ts.h + edge_label_pad_y * 2;
    return .{ .x = mid.x - w / 2.0, .y = mid.y - h / 2.0, .w = w, .h = h };
}

// ---------------------------------------------------------------------------
// 连线 + 连线标题
// ---------------------------------------------------------------------------
// 连线分层配色：同一层级（子节点深度，根的出边为第 1 层）的连线共用一色。
// 色相按黄金角 137.5° 铺开、起点每会话随机一次——「随机」但各层分明；
// 饱和度/明度固定在中档，浅色、深色主题下都看得清。配色不随文件保存，
// 每次启动重新随机（会话内稳定，画布与导出 PNG 走同一套）。
const edge_level_count: usize = 16;
var edge_level_colors: [edge_level_count]dvui.Color = undefined;
var edge_level_colors_ready = false;

/// 第 level 层连线的颜色；超过 16 层后循环复用前面的颜色。
pub fn edgeLevelColor(level: u32) dvui.Color {
    if (!edge_level_colors_ready) {
        var prng = std.Random.DefaultPrng.init(@intCast(SDLBackend.c.SDL_GetTicks()));
        const offset = prng.random().float(f32) * 360.0;
        // 多级路径的类型字面量（dvui.Color.HSV{...}）与「字面量后直接链方法」
        // Zig 0.17 都不支持，先取别名、再存变量
        const Hsv = dvui.Color.HSV;
        for (&edge_level_colors, 0..) |*c, i| {
            const hue = @mod(offset + @as(f32, @floatFromInt(i)) * 137.508, 360.0);
            const hsv = Hsv{ .h = hue, .s = 0.65, .v = 0.7 };
            c.* = hsv.toColor();
        }
        edge_level_colors_ready = true;
    }
    return edge_level_colors[(level - 1) % edge_level_count];
}

fn drawEdges(app: *app_mod.App, node: *model.Node, rs: dvui.RectScale, depth: u32) void {
    if (node.collapsed) return;
    for (node.children.items) |c| {
        // shift 重挂父拖拽中：被拖节点与旧父的连线（含标题标签）暂不绘出，
        // 子树自己的连线照画——视觉上表达「它正在离开这个父节点」。
        if (app.reparent_drag and app.dragEntryHas(c.id)) {
            drawEdges(app, c, rs, depth + 1);
            continue;
        }
        var natural: [edge_samples]dvui.Point.Natural = undefined;
        edgePoints(node, c, &natural);
        var pts: [edge_samples]dvui.Point.Physical = undefined;
        for (&natural, &pts) |p, *q| q.* = rs.pointToPhysical(.{ .x = p.x, .y = p.y });

        const is_selected = (app.doc().selected_edge_id orelse 0) == c.id;
        dvui.Path.stroke(.{ .points = &pts }, .{
            .thickness = (if (is_selected) @as(f32, 3) else @as(f32, 2)) * rs.s,
            .color = .{ .color = if (is_selected) dvui.themeGet().focus else edgeLevelColor(depth + 1) },
        });

        // 正在编辑这条线的标题时，输入框代替标签
        const editing_this = app.editing == .edge_title and app.editing_id == c.id;
        if (!editing_this) {
            if (edgeLabelRect(app, node, c)) |rect| {
                dvui.label(@src(), "{s}", .{c.link.slice()}, .{
                    .id_extra = c.id,
                    .rect = rect,
                    .font = app_mod.App.descFont(),
                    .padding = .{ .h = edge_label_pad_y, .w = edge_label_pad_x, .x = edge_label_pad_x, .y = edge_label_pad_y },
                    .background = true,
                    .style = .content,
                    .corners = dvui.CornerRect.round(4),
                });
            }
        }

        drawEdges(app, c, rs, depth + 1);
    }
}

// ---------------------------------------------------------------------------
// 连线命中测试：单击选中、双击编辑连线标题
// ---------------------------------------------------------------------------
fn drawEdgeEvents(app: *app_mod.App, node: *model.Node, rs: dvui.RectScale) void {
    if (node.collapsed) return;
    for (node.children.items) |c| {
        handleEdgeEvents(app, node, c, rs);
        drawEdgeEvents(app, c, rs);
    }
}

fn handleEdgeEvents(app: *app_mod.App, parent: *model.Node, child: *model.Node, rs: dvui.RectScale) void {
    var pts: [edge_samples]dvui.Point.Natural = undefined;
    edgePoints(parent, child, &pts);
    const label_rect = edgeLabelRect(app, parent, child);

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        const me = switch (e.evt) {
            .mouse => |m| m,
            else => continue,
        };
        const mp = rs.pointFromPhysical(me.p);
        const p: dvui.Point.Natural = .{ .x = mp.x, .y = mp.y };

        switch (me.action) {
            .position => if (!pointInAnyNode(app.doc().root, p) and edgeHit(&pts, label_rect, p)) {
                dvui.cursorSet(.hand);
            },
            .press => {
                if (!me.button.pointer()) continue;
                // 正在就地编辑这条连线的标题：按下交给内联输入框（放光标），
                // 这里再走一遍会触发 clickIsDouble 重新全选（缺陷 5a 同款）
                if (app.editing == .edge_title and app.editing_id == child.id) continue;
                // 节点框优先：点进节点框的按下事件让给 drawNodes
                if (pointInAnyNode(app.doc().root, p)) continue;
                if (!edgeHit(&pts, label_rect, p)) continue;

                e.handled = true; // 连线不是控件，没有 WidgetData 可传给 handle()
                app.doc().selectSingle(child.id);
                app.doc().selected_edge_id = child.id;
                if (app.clickIsDouble(.edge_title, child.id, p.x, p.y, nowMs())) {
                    app.cmdBeginEditEdgeTitle(child);
                } else {
                    app.setStatus("已选中连接线，双击可编辑连线标题");
                }
                dvui.refresh(null, @src(), null);
            },
            else => {},
        }
    }
}

/// 点是否落在任一可见节点框内（画布坐标）。
fn pointInAnyNode(node: *model.Node, p: dvui.Point.Natural) bool {
    const g = node.geom;
    if (p.x >= g.x and p.x <= g.x + g.w and p.y >= g.y and p.y <= g.y + g.h) return true;
    if (node.collapsed) return false;
    for (node.children.items) |c| {
        if (pointInAnyNode(c, p)) return true;
    }
    return false;
}

fn distToSegment2(p: dvui.Point.Natural, a: dvui.Point.Natural, b: dvui.Point.Natural) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = p.x - a.x;
    const wy = p.y - a.y;
    const len2 = vx * vx + vy * vy;
    const t = if (len2 == 0) 0 else std.math.clamp((wx * vx + wy * vy) / len2, 0, 1);
    const dx = wx - t * vx;
    const dy = wy - t * vy;
    return dx * dx + dy * dy;
}

/// 连线命中：先测标题标签矩形，再测到折线的最小距离。
fn edgeHit(pts: *const [edge_samples]dvui.Point.Natural, label_rect: ?dvui.Rect, p: dvui.Point.Natural) bool {
    if (label_rect) |r| {
        if (p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h) return true;
    }
    // 逐段比较并立即返回：min_d2 不能用阈值做初值，
    // 否则「min_d2 <= 阈值」恒真，任何点击都会命中遍历到的第一条连线。
    const slop2 = edge_hit_slop * edge_hit_slop;
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        if (distToSegment2(p, a, b) <= slop2) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 折叠徽章：折叠节点右侧的圆形「+」，点击展开该节点
// ---------------------------------------------------------------------------
/// 画在节点框右边缘外侧（不重叠），所以点击不会与节点框的选中/拖拽冲突。
/// id_extra 必须用 node.id：递归里所有徽章共用同一行 @src()，不区分会撞 id。
fn drawCollapseBadge(app: *app_mod.App, node: *model.Node) void {
    if (!node.collapsed or node.children.items.len == 0) return; // 叶子节点不显示

    const size: f32 = 18;
    if (dvui.buttonIcon(
        @src(),
        "expand_node",
        dvui.entypo.plus,
        .{},
        .{},
        .{
            .id_extra = node.id,
            .rect = .{
                .x = node.geom.x + node.geom.w + 4,
                .y = node.geom.y + node.geom.h / 2.0 - size / 2.0,
                .w = size,
                .h = size,
            },
            .padding = .{ .h = 3, .w = 3, .x = 3, .y = 3 },
            .min_size_content = .{ .w = 12, .h = 12 },
            .margin = .{},
            .corners = dvui.CornerRect.round(size / 2.0),
            .style = .control,
            .background = true,
            .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
            .color_border = .{ .color = dvui.themeGet().color(.control, .border) },
        },
    )) {
        app.cmdToggleCollapse(node);
        dvui.refresh(null, @src(), null);
    }
}

// ---------------------------------------------------------------------------
// 节点框：选中高亮 + 点击选中 + 双击改标题 + 拖拽移动子树
// ---------------------------------------------------------------------------
fn drawNodes(app: *app_mod.App, node: *model.Node, rs: dvui.RectScale, with_tags: bool) void {
    const is_selected = app.doc().isSelected(node.id);
    // shift 重挂父拖拽中：光标下的合法目标节点描粗边框，提示松手会挂到这里
    const drop_target = app.reparent_drag and app.reparent_moved and
        isValidReparentTarget(app, node, app.reparent_mx, app.reparent_my);
    // 自定义背景色：框填充用节点色；文字按背景亮度自动选黑/白保证可读
    // （亮黄底配白字、深蓝底配黑字都看不清，主题默认文字色只对默认背景合适）。
    const custom_bg: ?dvui.Color = if (node.bg) |bg| app_mod.App.dvuiColor(bg) else null;
    const text_color: ?dvui.ColorOrGradient = if (custom_bg) |c| .{ .color = if (c.brightness() < 0.5) dvui.Color.white else dvui.Color.black } else null;
    // 测试用的定位 tag（"node:<id>"）：dvui.testing.moveTo/click 靠它点到节点。
    // 只在正常绘制那一遍登记——导出会再画一遍，同帧撞名 dvui 会报 duplicate tag。
    var tag_buf: [24]u8 = undefined;
    const tag_name: ?[]const u8 = if (with_tags)
        (std.fmt.bufPrint(&tag_buf, "node:{d}", .{node.id}) catch null)
    else
        null;
    {
        const bw: f32 = if (drop_target) 2 else 1;
        var b = dvui.box(@src(), .{}, .{
            .id_extra = node.id,
            .tag = tag_name,
            .rect = .{ .x = node.geom.x, .y = node.geom.y },
            // min_size_content 是「内容」尺寸，不含 padding；减掉才能让
            // 实际外框正好等于 layout 算出的 geom.w/h（否则节点会互相压住）
            .min_size_content = .{
                .w = @max(node.geom.w - layout.metrics.pad_x * 2, 1),
                .h = @max(node.geom.h - layout.metrics.pad_y * 2, 1),
            },
            .padding = .{ .h = layout.metrics.pad_y, .w = layout.metrics.pad_x, .x = layout.metrics.pad_x, .y = layout.metrics.pad_y },
            .background = true,
            .style = .window,
            .color_fill = if (custom_bg) |c| .{ .color = c } else null,
            .border = .{ .h = bw, .w = bw, .x = bw, .y = bw },
            .corners = dvui.CornerRect.round(6),
            .color_border = if (drop_target or is_selected) .{ .color = dvui.themeGet().focus } else null,
        });
        defer b.deinit();

        // 节点内容：可选图片区（左侧正方形，最小 128×128）+ 标题 + 可选正文描述
        // （有图时都在图片右侧；无图时正文通栏）+ 可选属性表格（灰名格 / 浅绿值格，
        // 逐行贴在内容底部）。
        // 标签用显式 rect（相对节点内容区），不靠嵌套 box 布局——
        // 导出 PNG 的离屏 second pass 里 expand 布局标签不渲染（实测），
        // 显式 rect 与连线标题同款路径，两条路径都验证过。
        // 图片命中区边长带出内层块：事件循环里判「点在图片上 = 打开预览」用
        var img_side_e: f32 = 0;
        var img_has_asset = false;
        {
            const cw = @max(node.geom.w - layout.metrics.pad_x * 2, 1);
            const title_font = dvui.themeGet().font_body;
            // 高度按多行测量（与 layout → measureMultiline 同一算法）：
            // 写死单行 textHeight() 会把第二行裁掉（report 缺陷 3）
            const title_h = app_mod.App.measureMultiline(title_font, node.text.slice()).h;
            const has_img = node.hasImg();
            // 有图节点 = 左右两列：左列正方形图片区（layout.imgSide：最小 128，
            // 随右列撑高，图片保持纵横比），右列 = 标题 + 正文描述；
            // 无图节点维持原布局（标题一行，正文在下方通栏）。
            const desc_h: f32 = if (node.hasNote())
                app_mod.App.measureMultiline(app_mod.App.descFont(), node.note.slice()).h
            else
                0;
            const right_h = title_h + if (node.hasNote()) layout.metrics.desc_gap + desc_h else 0;
            const img_side: f32 = if (has_img) layout.imgSide(right_h) else 0;
            img_side_e = img_side;
            // 池里真有这份图才可点（找不到的坏引用照旧不画、不可点）
            img_has_asset = has_img and app.imageAsset(node) != null;
            // 右列文字的左缘（相对节点内容区）
            const text_x: f32 = if (has_img) img_side + layout.metrics.img_gap else 0;
            // 文字块总高（属性表格 y 的基准）：有图 = max(图片区, 右列)；
            // 无图 = 标题行 + 间距 + 正文
            const text_block_h = if (has_img)
                @max(img_side, right_h)
            else
                right_h;

            // 属性表格底色：用 Path 直接画矩形，**不要**用嵌套 dvui.box——
            // BoxWidget.init 会把自身设为当前父级，循环里第二个单元格就变成
            // 第一个单元格的子控件（rect 相对它定位），表现为值格向右下错位、
            // 后续文字标签也挂到错的父级。Path 用画布绝对坐标，不参与布局。
            const table_y = text_block_h + if (node.properties.items.len > 0) layout.metrics.prop_gap else 0;
            if (node.properties.items.len > 0) {
                // 节点内容区左上角（画布坐标）：geom + 边框 + padding
                const cx = node.geom.x + bw + layout.metrics.pad_x;
                const cy = node.geom.y + bw + layout.metrics.pad_y;
                const name_w = layout.propNameCellW(cw);
                const table_top = cy + table_y;
                const table_h = @as(f32, @floatFromInt(node.properties.items.len)) * layout.metrics.prop_row_h;
                const cell_border: dvui.Color = .{ .r = 153, .g = 153, .b = 153 };

                // 1) 底色（不含边框，边框统一最后画 1px，避免相邻格互相叠成粗线）
                for (node.properties.items, 0..) |_, i| {
                    const ry = table_top + @as(f32, @floatFromInt(i)) * layout.metrics.prop_row_h;
                    fillCanvasRect(rs, .{ .x = cx, .y = ry, .w = name_w, .h = layout.metrics.prop_row_h }, .{ .r = 217, .g = 217, .b = 217 });
                    fillCanvasRect(rs, .{
                        .x = cx + name_w,
                        .y = ry,
                        .w = @max(cw - name_w, 1),
                        .h = layout.metrics.prop_row_h,
                    }, .{ .r = 209, .g = 237, .b = 209 });
                }
                // 2) 外框 + 竖分隔线 + 行分隔线，全部 1 物理像素
                strokeCanvasLine(rs, cx, table_top, cx + cw, table_top, cell_border);
                strokeCanvasLine(rs, cx, table_top + table_h, cx + cw, table_top + table_h, cell_border);
                strokeCanvasLine(rs, cx, table_top, cx, table_top + table_h, cell_border);
                strokeCanvasLine(rs, cx + cw, table_top, cx + cw, table_top + table_h, cell_border);
                strokeCanvasLine(rs, cx + name_w, table_top, cx + name_w, table_top + table_h, cell_border);
                var ri: usize = 1;
                while (ri < node.properties.items.len) : (ri += 1) {
                    const ry = table_top + @as(f32, @floatFromInt(ri)) * layout.metrics.prop_row_h;
                    strokeCanvasLine(rs, cx, ry, cx + cw, ry, cell_border);
                }
            }

            // 图片区：内容区左上角正方形（显式 rect，离屏导出同样生效）。
            // 图片在正方形内**等比铺满**（contain）并**靠左上对齐**：短边方向
            // 的留白落在右侧/下方，不居中、绝不改比例。
            // 注意不能把正方形直接当 min_size_content——dvui 的 image 把这个尺寸
            // 当内容尺寸去渲染，方形尺寸会把任意比例的图拉伸。
            // 数据来自文档图片池（节点只存 ref）；池里找不到就不画（布局位照留）。
            if (has_img) {
                if (app.imageAsset(node)) |asset| {
                    const source: dvui.ImageSource = .{ .imageFile = .{
                        .bytes = asset.data.items,
                        .name = asset.img_type.items,
                        // 撤销/重载会换内存地址，按字节内容识别变更更稳妥
                        .invalidation = .bytes,
                    } };
                    const nat = dvui.imageSize(source) catch dvui.Size{ .w = img_side, .h = img_side };
                    const fit = fitInSquare(nat, img_side);
                    _ = dvui.image(@src(), .{
                        .source = source,
                        .shrink = .ratio,
                    }, .{
                        .id_extra = node.id,
                        // 在正方形图片区内**靠左上**（只留白，不裁切）：
                        // 短边方向的留白全部落在右侧/下方，视觉上与节点文字同基线
                        .rect = .{
                            .x = 0,
                            .y = 0,
                            .w = fit.w,
                            .h = fit.h,
                        },
                        .min_size_content = .{ .w = fit.w, .h = fit.h },
                        .label = .{ .text = "节点图片" },
                    });
                }
            }

            // 正在双击编辑这个节点的标题时，标题让位给画布上的输入框
            if (!(app.editing == .node_title and app.editing_id == node.id)) {
                dvui.label(@src(), "{s}", .{node.text.slice()}, .{
                    .id_extra = node.id,
                    .rect = .{ .x = text_x, .y = 0, .w = @max(cw - text_x, 1), .h = title_h },
                    // dvui 标签默认 padding 6，会把节点撑高（布局按文本尺寸算）
                    .padding = .{},
                    .color_text = text_color,
                });
            }

            if (node.hasNote()) {
                // 正文在标题下方（有图时与标题同列，都排在图片右侧）
                dvui.label(@src(), "{s}", .{node.note.slice()}, .{
                    .id_extra = node.id,
                    .rect = .{
                        .x = text_x,
                        .y = title_h + layout.metrics.desc_gap,
                        .w = @max(cw - text_x, 1),
                        .h = desc_h,
                    },
                    .font = app_mod.App.descFont(),
                    .padding = .{},
                    .color_text = text_color,
                });
            }

            // 属性表格文字：底色已画，这里叠字（格底浅色，统一用深色文字）
            if (node.properties.items.len > 0) {
                const name_w = layout.propNameCellW(cw);
                const cell_text: dvui.ColorOrGradient = .{ .color = .{ .r = 38, .g = 38, .b = 38 } };
                for (node.properties.items, 0..) |p, i| {
                    const ry = table_y + @as(f32, @floatFromInt(i)) * layout.metrics.prop_row_h;
                    // 单元格内上下居中：标签框高度取文本高，y 取行高与文本高的差的一半
                    const name_h = app_mod.App.measureMultiline(app_mod.App.descFont(), p.name.items).h;
                    const value_h = app_mod.App.measureMultiline(app_mod.App.descFont(), p.value.items).h;
                    dvui.label(@src(), "{s}", .{p.name.items}, .{
                        .id_extra = @as(usize, node.id) * 4096 + i * 2 + 2048,
                        .rect = .{
                            .x = 3,
                            .y = ry + @max((layout.metrics.prop_row_h - name_h) / 2.0, 0),
                            .w = @max(name_w - 6, 1),
                            .h = name_h,
                        },
                        .font = app_mod.App.descFont(),
                        .padding = .{},
                        .color_text = cell_text,
                    });
                    dvui.label(@src(), "{s}", .{p.value.items}, .{
                        .id_extra = @as(usize, node.id) * 4096 + i * 2 + 2049,
                        .rect = .{
                            .x = name_w + 3,
                            .y = ry + @max((layout.metrics.prop_row_h - value_h) / 2.0, 0),
                            .w = @max(cw - name_w - 6, 1),
                            .h = value_h,
                        },
                        .font = app_mod.App.descFont(),
                        .padding = .{},
                        .color_text = cell_text,
                    });
                }
            }
        }

        // 缺陷 5a：正在就地编辑这个节点的标题时，跳过它的事件循环——
        // 否则同一次按下既落进内联 TextEntry（放光标），又被这里判成
        // 双击重新全选（clickIsDouble），光标落点就被全选覆盖了。
        const editing_this = (app.editing == .node_title and app.editing_id == node.id);
        if (!editing_this) {
            for (dvui.events()) |*e| {
                if (!b.matchEvent(e)) continue;
                switch (e.evt) {
                    .mouse => |me| switch (me.action) {
                        .press => if (me.button.pointer()) {
                            e.handle(@src(), b.data());
                            const mp = rs.pointFromPhysical(me.p);
                            // 是否点在图片区（内容区 = geom + 边框 + padding 的
                            // 左上角 img_side²）。图片区**不**另起一套手势：按下
                            // 照常选中 + 预备拖拽，只在松手时判断「没拖动过」才算
                            // 点击，进而打开预览（见 .release 分支）。
                            const zone = resizeZone(node.geom, mp.x, mp.y);
                            const img_lx = mp.x - (node.geom.x + bw + layout.metrics.pad_x);
                            const img_ly = mp.y - (node.geom.y + bw + layout.metrics.pad_y);
                            const on_img = img_has_asset and !me.mod.shift() and
                                zone == .none and
                                img_lx >= 0 and img_ly >= 0 and
                                img_lx < img_side_e and img_ly < img_side_e;
                            app.image_press_id = if (on_img) node.id else 0;
                            if (me.mod.shift()) {
                                // shift+按下：多选与重挂父共用入口。
                                // 不在多选里就先加入（主选中跟手）；原本就在的，
                                // 等松手没拖动时移出（shift+点击 = 切换多选）。
                                app.doc().selected_edge_id = null;
                                const was = app.doc().isSelected(node.id);
                                if (!was) {
                                    app.doc().selectAdd(node.id);
                                    app.doc().selected_id = node.id;
                                }
                                dvui.captureMouse(b.data(), e.num);
                                dvui.dragPreStart(me.button, me.p, .{ .name = "node_reparent" });
                                app.reparent_drag = true;
                                app.reparent_moved = false;
                                app.reparent_was_selected = was;
                                app.drag_mouse_x = mp.x;
                                app.drag_mouse_y = mp.y;
                                // 拖拽集合 = 多选里的顶层节点（没有选中祖先的那些），
                                // 拖动时整体平移；记录初始偏移，落空时按它弹回
                                app.drag_entries.clearRetainingCapacity();
                                for (app.doc().selected_ids.items) |id| {
                                    const n = model.find(app.doc().root, id) orelse continue;
                                    if (hasSelectedAncestor(app, n)) continue;
                                    app.drag_entries.append(app.gpa, .{ .id = id, .ox0 = n.geom.ox, .oy0 = n.geom.oy }) catch {};
                                }
                                if (app.drag_entries.items.len == 0) {
                                    app.drag_entries.append(app.gpa, .{ .id = node.id, .ox0 = node.geom.ox, .oy0 = node.geom.oy }) catch {};
                                }
                                app.setStatus("shift+拖放到目标节点 = 更换父节点");
                                dvui.refresh(null, @src(), null);
                            } else if (zone != .none) {
                                // 右/下边缘或右下角：进入缩放，不与拖拽移动/双击编辑混用
                                app.doc().selectSingle(node.id);
                                dvui.captureMouse(b.data(), e.num);
                                dvui.dragPreStart(me.button, me.p, .{ .name = "node_resize" });
                                app.resize_node_id = node.id;
                                app.resize_edge = zone;
                                app.resize_start_w = node.geom.w;
                                app.resize_start_h = node.geom.h;
                                app.resize_start_mx = mp.x;
                                app.resize_start_my = mp.y;
                                app.resize_snapshot_pushed = false;
                            } else if (app.clickIsDouble(.node_title, node.id, mp.x, mp.y, nowMs()) and !on_img) {
                                app.doc().selectSingle(node.id);
                                // 双击：放弃这次拖拽预备，直接进入标题编辑。
                                // 图片区不参与（双击图片 = 连开两次预览），
                                // clickIsDouble 仍要调用以刷新点击记录。
                                app.cmdBeginEditNodeTitle(node);
                            } else {
                                app.doc().selectSingle(node.id);
                                // 捕获鼠标并预备拖拽（阈值内松开 = 普通点击）
                                dvui.captureMouse(b.data(), e.num);
                                dvui.dragPreStart(me.button, me.p, .{ .name = "node_drag" });
                                app.drag_entries.clearRetainingCapacity();
                                app.drag_entries.append(app.gpa, .{ .id = node.id, .ox0 = node.geom.ox, .oy0 = node.geom.oy }) catch {};
                                app.drag_mouse_x = mp.x;
                                app.drag_mouse_y = mp.y;
                                app.setStatus(if (on_img) "已选中节点，松手查看图片" else "已选中节点，双击可改标题");
                            }
                        },
                        .motion => {
                            if (dvui.captured(b.data().id)) {
                                if (app.resize_node_id == node.id) {
                                    if (dvui.dragging(me, "node_resize")) |_| {
                                        e.handle(@src(), b.data());
                                        // 第一次真正改变尺寸时压一份镜像（与移动拖拽同款：
                                        // 按下时还分不清点击还是缩放，避免单击留空撤销步）
                                        if (!app.resize_snapshot_pushed) {
                                            app.resize_snapshot_pushed = true;
                                            _ = app.pushUndo();
                                        }
                                        const cur = rs.pointFromPhysical(me.p);
                                        var nw = app.resize_start_w + (cur.x - app.resize_start_mx);
                                        var nh = app.resize_start_h + (cur.y - app.resize_start_my);
                                        switch (app.resize_edge) {
                                            .e => nh = app.resize_start_h,
                                            .s => nw = app.resize_start_w,
                                            else => {},
                                        }
                                        // 下限由 layout.measure 的 max(自动, 手动) 兜底，
                                        // 这里只卡住绝对最小值
                                        node.user_w = @max(nw, layout.metrics.node_min_w);
                                        node.user_h = @max(nh, layout.metrics.node_min_h);
                                        app.doc().dirty = true;
                                        app.setStatus("调整节点大小中…");
                                        dvui.refresh(null, @src(), null);
                                    }
                                } else if (app.reparent_drag) {
                                    if (dvui.dragging(me, "node_reparent")) |_| {
                                        e.handle(@src(), b.data());
                                        app.reparent_moved = true;
                                        const cur = rs.pointFromPhysical(me.p);
                                        const dx = cur.x - app.drag_mouse_x;
                                        const dy = cur.y - app.drag_mouse_y;
                                        // 多选拖拽整体平移；不压快照不置 dirty——
                                        // 松手落空会按 drag_entries 弹回原位
                                        for (app.drag_entries.items) |en| {
                                            const n = model.find(app.doc().root, en.id) orelse continue;
                                            var min_dx: f32 = 0;
                                            var min_dy: f32 = 0;
                                            subtreeMinDelta(n, n.geom.x, n.geom.y, &min_dx, &min_dy);
                                            const base_x = n.geom.x - n.geom.ox;
                                            const base_y = n.geom.y - n.geom.oy;
                                            n.geom.ox = @max(en.ox0 + dx, -min_dx - base_x);
                                            n.geom.oy = @max(en.oy0 + dy, -min_dy - base_y);
                                        }
                                        app.reparent_mx = cur.x;
                                        app.reparent_my = cur.y;
                                        app.setStatus("松手：把选中节点挂到目标节点下");
                                        dvui.refresh(null, @src(), null);
                                    }
                                } else if (dvui.dragging(me, "node_drag")) |_| {
                                    e.handle(@src(), b.data());
                                    // 第一次真正拖动时压一份镜像（按下时还分不清
                                    // 用户是单击还是拖动，避免单击也留空撤销步）
                                    if (!app.drag_snapshot_pushed) {
                                        app.drag_snapshot_pushed = true;
                                        _ = app.pushUndo();
                                    }
                                    const cur = rs.pointFromPhysical(me.p);
                                    const dx = cur.x - app.drag_mouse_x;
                                    const dy = cur.y - app.drag_mouse_y;
                                    for (app.drag_entries.items) |en| {
                                        const n = model.find(app.doc().root, en.id) orelse continue;
                                        // 子树不能被拖出虚拟画布的左/上边缘：
                                        // layout.treeBounds 只统计右下角，落到 0 以外的
                                        // 区域滚动条永远滚不到（=「把根节点往上拖之后
                                        // 滚动条不起作用、内容再也看不见」）。
                                        // 子树各节点相对本节点的位移与拖拽偏移无关
                                        // （geom 相减时偏移互相抵消），可直接量当前 geom。
                                        var min_dx: f32 = 0;
                                        var min_dy: f32 = 0;
                                        subtreeMinDelta(n, n.geom.x, n.geom.y, &min_dx, &min_dy);
                                        const base_x = n.geom.x - n.geom.ox;
                                        const base_y = n.geom.y - n.geom.oy;
                                        n.geom.ox = @max(en.ox0 + dx, -min_dx - base_x);
                                        n.geom.oy = @max(en.oy0 + dy, -min_dy - base_y);
                                    }
                                    app.doc().dirty = true;
                                    app.setStatus("拖拽中…");
                                    dvui.refresh(null, @src(), null);
                                }
                            }
                        },
                        .release => if (me.button.pointer()) {
                            if (dvui.captured(b.data().id)) {
                                e.handle(@src(), b.data());
                                dvui.captureMouse(null, e.num);
                                dvui.dragEnd(me.button);
                                if (app.resize_node_id == node.id) {
                                    app.resize_node_id = 0; // 下一次缩放重新开始
                                    app.resize_snapshot_pushed = false;
                                    app.setStatus("已调整节点大小");
                                } else if (app.reparent_drag) {
                                    app.reparent_drag = false;
                                    if (app.reparent_moved) {
                                        // 真的拖动过：落到哪个节点上就挂到它下面
                                        const cur = rs.pointFromPhysical(me.p);
                                        const p: dvui.Point.Natural = .{ .x = cur.x, .y = cur.y };
                                        if (dropTargetAt(app, app.doc().root, p)) |t| {
                                            // 树结构变更推迟到整帧画完（draw 结束统一执行）：
                                            // 此刻 drawNodes 还在遍历 children.items，就地改树
                                            // 会让后续递归踩到失效切片（同帧重复注册 widget 崩溃）
                                            app.pending_reparent_target = t.id;
                                        } else {
                                            app.restoreDragOffsets();
                                            app.setStatus("未落在节点上，已取消");
                                        }
                                    } else if (app.reparent_was_selected) {
                                        // 没拖动 = shift+点击切换多选：原本就在 → 移出
                                        app.doc().selectRemove(node.id);
                                        app.setStatus("已从多选中移除");
                                    } else {
                                        app.setStatus("已加入多选");
                                    }
                                    if (!app.reparent_moved) {
                                        // 没有挂起重挂父时才清：挂起的要等帧尾
                                        // cmdReparentSelected 消费完 entries 再清
                                        app.drag_entries.clearRetainingCapacity();
                                    }
                                } else if (app.image_press_id == node.id and !app.drag_snapshot_pushed) {
                                    // 图片区按下、**没拖动**就松手 = 一次点击 → 打开预览。
                                    // 拖动过的走下面的「已移动子树」：图片上按下和别处一样
                                    // 能拖节点，只有「没挪动」才当点击（drag_snapshot_pushed
                                    // 在第一次真正拖动时才置位）。
                                    app.image_press_id = 0;
                                    const cur = rs.pointFromPhysical(me.p);
                                    const lx = cur.x - (node.geom.x + bw + layout.metrics.pad_x);
                                    const ly = cur.y - (node.geom.y + bw + layout.metrics.pad_y);
                                    if (lx >= 0 and ly >= 0 and lx < img_side_e and ly < img_side_e) {
                                        app.cmdShowImagePreview(node);
                                    } else {
                                        // 拖出图片区但没到拖拽阈值（阈内的微小位移）
                                        app.setStatus("已选中节点");
                                    }
                                } else {
                                    app.drag_snapshot_pushed = false; // 下一次拖拽重新压快照
                                    app.image_press_id = 0; // 拖过了就不算点图片
                                    app.setStatus("已移动子树");
                                }
                                dvui.refresh(null, @src(), null);
                            }
                        },
                        .position => {
                            const mp = rs.pointFromPhysical(me.p);
                            switch (resizeZone(node.geom, mp.x, mp.y)) {
                                .e => dvui.cursorSet(.arrow_w_e),
                                .s => dvui.cursorSet(.arrow_n_s),
                                .se => dvui.cursorSet(.arrow_nw_se),
                                .none => dvui.cursorSet(.hand),
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        } // if (!editing_this)
    }
    // 徽章画在节点框之后 = 最上层；位置在框外，不抢节点框的鼠标事件
    drawCollapseBadge(app, node);
    if (!node.collapsed) {
        for (node.children.items) |c| drawNodes(app, c, rs, with_tags);
    }
}

/// 以 (ox, oy) 为原点，求子树内 geom 相对原点的最小位移（含原点自身，故 ≤ 0）。
/// 折叠节点的子树不可见、且 layout 不再刷新它们的 geom，与 treeBounds 一致跳过。
fn subtreeMinDelta(node: *model.Node, ox: f32, oy: f32, min_x: *f32, min_y: *f32) void {
    min_x.* = @min(min_x.*, node.geom.x - ox);
    min_y.* = @min(min_y.*, node.geom.y - oy);
    if (node.collapsed) return;
    for (node.children.items) |c| subtreeMinDelta(c, ox, oy, min_x, min_y);
}

/// 拖拽点（画布坐标）命中的第一个可见节点（先序遍历，父先于子；
/// 重叠时先画在上面的后命中——与绘制顺序一致即可接受）。
fn nodeAt(root: *model.Node, p: dvui.Point.Natural) ?*model.Node {
    const g = root.geom;
    if (p.x >= g.x and p.x <= g.x + g.w and p.y >= g.y and p.y <= g.y + g.h) return root;
    if (root.collapsed) return null;
    for (root.children.items) |c| {
        if (nodeAt(c, p)) |hit| return hit;
    }
    return null;
}

/// n 的某个祖先是否在多选集合里（重挂父拖拽集合只收「顶层选中节点」用）。
fn hasSelectedAncestor(app: *app_mod.App, n: *model.Node) bool {
    var cur = n.parent;
    while (cur) |p| : (cur = p.parent) {
        if (app.doc().isSelected(p.id)) return true;
    }
    return false;
}

/// 松手点下的第一个「合法重挂父」目标（先序遍历）。不用 nodeAt：被拖节点
/// 跟着指针走，松手时指针几乎总是压在它自己身上，必须跳过被拖节点及其
/// 子树（它们都是非法目标），才能找到压在下面的真正落点。
fn dropTargetAt(app: *app_mod.App, node: *model.Node, p: dvui.Point.Natural) ?*model.Node {
    if (isValidReparentTarget(app, node, p.x, p.y)) return node;
    if (node.collapsed) return null;
    for (node.children.items) |c| {
        if (dropTargetAt(app, c, p)) |hit| return hit;
    }
    return null;
}

/// (mx, my) 落在 n 的框内，且 n 是合法的重挂父目标——与 cmdReparentSelected
/// 的校验保持一致：不能是 root、拖拽集合成员、被拖节点的祖先或后代，
/// 也不能已经挂着拖拽集合里某个节点当父（松手无变化）。
fn isValidReparentTarget(app: *app_mod.App, n: *model.Node, mx: f32, my: f32) bool {
    const d = app.doc();
    const g = n.geom;
    if (mx < g.x or mx > g.x + g.w or my < g.y or my > g.y + g.h) return false;
    if (n == d.root) return false;
    if (app.dragEntryHas(n.id)) return false;
    for (app.drag_entries.items) |e| {
        const dragged = model.find(d.root, e.id) orelse continue;
        if (model.isAncestor(dragged, n)) return false; // n 是被拖节点的后代 → 成环
        if (n.parent) |par| {
            if (par == dragged) return false; // 已经是它的子节点，松手无变化
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// 空白处框选：按下拖出矩形，松手选中与矩形相交的可见节点
// ---------------------------------------------------------------------------
/// 节点/连线的按下事件已各自处理并标记 handled，这里只接住剩下的空白按下。
/// 普通按下拖出矩形 = 重新框选；shift+按下拖出 = 在原选择上追加。
/// 没拖动就松开 = 空白单击，清空全部选中。
fn handleRubberBand(app: *app_mod.App, d: *app_mod.Doc, sc: *dvui.ScrollContainerWidget, rs: dvui.RectScale) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (!sc.matchEvent(e)) continue;
        const me = switch (e.evt) {
            .mouse => |m| m,
            else => continue,
        };
        const mp = rs.pointFromPhysical(me.p);
        switch (me.action) {
            .press => if (me.button.pointer() and !me.button.touch()) {
                // 内联编辑进行中：按下要交给焦点机制（点空白 = 提交编辑），
                // 框选不掺和；编辑框在框选之后才画，这里若抢走按下事件，
                // 输入框就拿不到焦点了
                if (app.editing != .none) continue;
                e.handled = true;
                dvui.captureMouse(sc.data(), e.num);
                dvui.dragPreStart(me.button, me.p, .{ .name = "rubber_band" });
                app.rubber = .{
                    .x0 = mp.x,
                    .y0 = mp.y,
                    .x1 = mp.x,
                    .y1 = mp.y,
                    .add = me.mod.shift(),
                };
                dvui.refresh(null, @src(), null);
            },
            .motion => {
                if (dvui.captured(sc.data().id)) {
                    if (dvui.dragging(me, "rubber_band")) |_| {
                        e.handled = true;
                        if (app.rubber) |*rb| {
                            rb.x1 = mp.x;
                            rb.y1 = mp.y;
                        }
                        dvui.refresh(null, @src(), null);
                    }
                }
            },
            .release => if (me.button.pointer()) {
                if (dvui.captured(sc.data().id)) {
                    e.handled = true;
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd(me.button);
                    if (app.rubber) |rb| {
                        const r = normalizeRect(rb);
                        // 拖出过有效面积才算框选；否则是空白单击 = 清空选择
                        const dragged = r.w > 2 or r.h > 2;
                        if (dragged) {
                            app.selectNodesInRect(r, rb.add);
                            const n = app.doc().selected_ids.items.len;
                            // 消息格式化到局部缓冲再 setStatus：直接写 status_buf
                            // 再 setStatus 会 memcpy 自身（源目标重叠 panic）
                            var cnt_buf: [48]u8 = undefined;
                            const cnt_msg = std.fmt.bufPrint(&cnt_buf, "已选中 {d} 个节点", .{n}) catch "已选中节点";
                            app.setStatus(if (rb.add) "已追加选择" else cnt_msg);
                        } else if (!rb.add) {
                            d.selectionClear();
                        }
                    }
                    app.rubber = null;
                    dvui.refresh(null, @src(), null);
                }
            },
            else => {},
        }
    }
}

/// 框选矩形的两角归一化成 x/y 为左上角、w/h 为正的矩形。
fn normalizeRect(rb: app_mod.RubberBand) dvui.Rect {
    return .{
        .x = @min(rb.x0, rb.x1),
        .y = @min(rb.y0, rb.y1),
        .w = @abs(rb.x1 - rb.x0),
        .h = @abs(rb.y1 - rb.y0),
    };
}

/// 在画布坐标 rect 处填充纯色矩形。
/// 直接走 Path，不创建控件——控件（尤其 dvui.box）会改动父级与流式布局，
/// 属性表格单元格若用嵌套 box 会互相成为父子导致错位。
/// 边框由调用方用 strokeCanvasLine 统一画 1px（相邻格不会叠成粗线）。
fn fillCanvasRect(rs: dvui.RectScale, r: dvui.Rect, fill: dvui.Color) void {
    const corners = [_]dvui.Point.Natural{
        .{ .x = r.x, .y = r.y },
        .{ .x = r.x + r.w, .y = r.y },
        .{ .x = r.x + r.w, .y = r.y + r.h },
        .{ .x = r.x, .y = r.y + r.h },
    };
    var pts: [4]dvui.Point.Physical = undefined;
    // 逐个用匿名字面量转换（array 元素是 Natural，不能直接喂给 pointToPhysical）
    for (corners, 0..) |c, i| pts[i] = rs.pointToPhysical(.{ .x = c.x, .y = c.y });
    dvui.Path.fillConvex(.{ .points = pts[0..4] }, .{ .color = .{ .color = fill } });
}

/// 画布坐标下画一条 1 物理像素宽的线（表格框线）。
/// thickness 用 1 而不是 rs.s：高 DPI 下 1.25 等小数会让线看起来变粗、发虚，
/// 1px 框线按物理像素画最清晰。
fn strokeCanvasLine(rs: dvui.RectScale, x0: f32, y0: f32, x1: f32, y1: f32, color: dvui.Color) void {
    var pts: [2]dvui.Point.Physical = .{
        rs.pointToPhysical(.{ .x = x0, .y = y0 }),
        rs.pointToPhysical(.{ .x = x1, .y = y1 }),
    };
    dvui.Path.stroke(.{ .points = pts[0..2] }, .{ .thickness = 1, .color = .{ .color = color } });
}

/// 把框选矩形画出来（主题 focus 色的半透明填充 + 实线边框）。
fn drawRubberBand(rb: app_mod.RubberBand, rs: dvui.RectScale) void {
    const r = normalizeRect(rb);
    var pts: [5]dvui.Point.Physical = undefined;
    const corners = [_]dvui.Point.Natural{
        .{ .x = r.x, .y = r.y },
        .{ .x = r.x + r.w, .y = r.y },
        .{ .x = r.x + r.w, .y = r.y + r.h },
        .{ .x = r.x, .y = r.y + r.h },
    };
    for (corners, 0..) |c, i| pts[i] = rs.pointToPhysical(.{ .x = c.x, .y = c.y });
    pts[4] = pts[0];
    const focus = dvui.themeGet().focus;
    dvui.Path.fillConvex(.{ .points = pts[0..4] }, .{ .color = .{ .color = dvui.Color.opacity(focus, 0.15) } });
    dvui.Path.stroke(.{ .points = pts[0..5] }, .{ .thickness = 1 * rs.s, .color = .{ .color = focus } });
}

// ---------------------------------------------------------------------------
// 内联编辑框：双击节点标题 / 双击连线标题后就地编辑
// ---------------------------------------------------------------------------
/// 撑成 textEntry 能用的外框：dvui 在显式传入 rect 时不会再拿 min_size_content
/// 把框撑大，而 textEntry 默认 margin 4 + border 1 + padding 6 每边吃掉 11px。
/// 直接拿标签框 / 节点框当 rect，内容区会被挤成负数（表现为编辑框太小、文字被裁）。
fn fitEditorRect(visual: dvui.Rect, min_w: f32) dvui.Rect {
    const chrome: f32 = (4 + 1 + 6) * 2; // margin + border + padding，左右/上下各一份
    const w = @max(visual.w, min_w);
    const h = @max(visual.h, dvui.themeGet().font_body.lineHeight() + chrome);
    // 放大时保持中心不变（连线标签以连线中点为中心）
    return .{
        .x = visual.x + (visual.w - w) / 2.0,
        .y = visual.y + (visual.h - h) / 2.0,
        .w = w,
        .h = h,
    };
}

/// 输入框绑定到 app.edit_draft（草稿缓冲）：node.text/link 已是不可变
/// ZString，打字先落草稿，Enter / 失焦由 app.cmdCommitEdit 构造新串提交，
/// Esc 由 cmdCancelEdit 回滚到进入编辑前的文本。
fn drawInlineEditor(app: *app_mod.App) void {
    if (app.editing == .none) return;
    const node = app.editingNode() orelse {
        app.editing = .none; // 目标节点已消失（删除/新建/打开文件）
        return;
    };

    const rect = switch (app.editing) {
        .node_title => blk: {
            const g = node.geom;
            break :blk fitEditorRect(dvui.Rect{ .x = g.x, .y = g.y, .w = g.w, .h = g.h }, g.w);
        },
        .edge_title => blk: {
            const parent = node.parent orelse {
                app.editing = .none;
                return;
            };
            // 还没有标题时，按最小宽度给一个框，位置同样落在连线中点上
            const visual = edgeLabelRect(app, parent, node) orelse blk2: {
                var pts: [edge_samples]dvui.Point.Natural = undefined;
                edgePoints(parent, node, &pts);
                break :blk2 labelBoxAt(pts[edge_samples / 2], "");
            };
            // 标签用 descFont（小字号），输入框用正文字号：宽度按正文重算
            const ts = dvui.themeGet().font_body.textSize(node.link.slice());
            break :blk fitEditorRect(visual, @max(ts.w + 30, edge_editor_min_w));
        },
        .none => unreachable,
    };

    var te = dvui.textEntry(@src(), .{
        .text = .{ .array_list = .{ .backing = &app.edit_draft, .allocator = app.gpa } },
        .placeholder = switch (app.editing) {
            .node_title => "节点标题",
            .edge_title => "连线标题",
            .none => unreachable,
        },
        .multiline = false,
    }, .{
        .id_extra = node.id,
        .rect = rect,
        .tag = "inline_editor",
        .background = true,
        .style = .content,
        .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
        .color_border = .{ .color = dvui.themeGet().focus },
        .min_size_content = .{ .w = @max(rect.w, 140), .h = @max(rect.h, 24) },
    });
    defer te.deinit();

    const armed = app.edit_armed;
    if (armed) {
        // 进入编辑的第一帧：聚焦 + 全选，直接输入即覆盖原文
        app.edit_armed = false;
        dvui.focusWidget(te.data().id, null, null);
        te.textSet(app.edit_draft.items, true);
    }

    if (te.text_changed) app.doc().dirty = true;
    if (te.enter_pressed) {
        app.cmdCommitEdit();
    } else if (!armed and dvui.focusedWidgetIdInCurrentSubwindow() != te.data().id) {
        app.cmdCommitEdit(); // 点到别处失焦 = 确认保存
    }
}
