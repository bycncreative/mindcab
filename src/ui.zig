//! zmind 标准控件区：菜单栏、工具栏、侧栏属性面板、状态栏。
//! 画布视图见 canvas.zig。
const std = @import("std");
const dvui = @import("dvui");
const model = @import("model.zig");
const app_mod = @import("app.zig");

// ---------------------------------------------------------------------------
// 菜单栏
// ---------------------------------------------------------------------------
pub fn drawMenuBar(app: *app_mod.App) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
    defer hbox.deinit();

    {
        var m = dvui.menu(@src(), .horizontal, .{});
        defer m.deinit();
        if (dvui.menuItemLabel(@src(), "文件", .{ .submenu = true }, .{ .tag = "menu_file" })) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            // dvui 菜单项激活后不会自动收起菜单（官方 Examples/menus.zig 同款），
            // 每个菜单项被点击时都必须显式 fw.close() 沿链关闭并交还焦点。
            if (dvui.menuItemLabel(@src(), "新建", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdNewDoc() catch app.setStatus("新建失败：内存不足");
            }
            if (dvui.menuItemLabel(@src(), "打开", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                // 对话框阻塞：只挂号，帧末再弹
                app.pending_file_action = .open;
            }
            if (dvui.menuItemLabel(@src(), "保存", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.pending_file_action = .save;
            }
            if (dvui.menuItemLabel(@src(), "另存为", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.pending_file_action = .save_as;
            }
            if (dvui.menuItemLabel(@src(), "关闭标签页", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdCloseTab(app.active);
            }
            // 「最近打开的文件」动态子菜单：历史存于 %USERPROFILE%/.mindcab/history.toml
            drawRecentMenu(app, fw);
            // 「导出」次级菜单：与文件操作同级，挂在「关闭标签页」与「退出」之间。
            // dvui 菜单激活后不会自动收起（官方示例同款），子菜单项也需 fw.close()。
            // 桌面惯例：顶栏的「文件」不加箭头，下拉里的嵌套项（导出）要加，
            // 提示还有子菜单。menuItemLabel 不支持图标，按其内部写法手动组
            // menuItem + label + icon，箭头颜色跟菜单文字走（深浅色主题都可见）。
            // menuItem 不是盒子、不做顺序排布，多子控件须用 hbox 装起来（官方
            // widgetpedia 同款）；label 撑满剩余宽度，把箭头推到菜单项右缘。
            var export_item = dvui.menuItem(@src(), .{ .submenu = true }, .{ .expand = .horizontal, .tag = "menu_export" });
            const subrect: ?dvui.Rect.Natural = export_item.activeRect();
            {
                const arrow_color = export_item.style().color(.text);
                const label_opts = export_item.style().strip().override(.{ .label = .{ .for_id = export_item.data().id }, .expand = .horizontal });
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
                defer row.deinit();
                dvui.labelNoFmt(@src(), "导出", .{}, label_opts);
                dvui.icon(@src(), "submenu_arrow", dvui.entypo.chevron_right, .{ .fill_color = arrow_color, .stroke_color = arrow_color }, .{ .gravity_y = 0.5, .role = .none });
            }
            export_item.deinit();
            if (subrect) |sub_r| {
                var sub = dvui.floatingMenu(@src(), .{ .from = sub_r }, .{});
                defer sub.deinit();
                if (dvui.menuItemLabel(@src(), "导出为 PNG", .{}, .{ .expand = .horizontal, .tag = "menu_export_png" }) != null) {
                    sub.close();
                    fw.close();
                    // 系统对话框是阻塞的，只挂号让帧末统一执行（见 app.zig 注释）
                    app.pending_file_action = .export_png;
                }
                if (dvui.menuItemLabel(@src(), "导出为 docx", .{}, .{ .expand = .horizontal, .tag = "menu_export_docx" }) != null) {
                    sub.close();
                    fw.close();
                    app.pending_file_action = .export_docx;
                }
                if (dvui.menuItemLabel(@src(), "导出为 Markdown", .{}, .{ .expand = .horizontal, .tag = "menu_export_md" }) != null) {
                    sub.close();
                    fw.close();
                    app.pending_file_action = .export_md;
                }
            }
            if (dvui.menuItemLabel(@src(), "退出", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdRequestQuit();
            }
        }
    }
    {
        var m = dvui.menu(@src(), .horizontal, .{ .id_extra = 1 });
        defer m.deinit();
        if (dvui.menuItemLabel(@src(), "编辑", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            // 撤销/重做放最前（最常用）。栈空时不置灰——dvui 菜单项没有 disabled，
            // 点了给一句状态栏提示即可。
            const undo_label = if (app.canUndo()) "撤销    Ctrl+Z" else "撤销（无可撤销的操作）";
            if (dvui.menuItemLabel(@src(), undo_label, .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdUndo();
            }
            const redo_label = if (app.canRedo()) "重做    Ctrl+Y" else "重做（无可重做的操作）";
            if (dvui.menuItemLabel(@src(), redo_label, .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdRedo();
            }
            if (dvui.menuItemLabel(@src(), "添加子节点", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdAddChild();
            }
            if (dvui.menuItemLabel(@src(), "添加同级节点", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdAddSibling();
            }
            if (dvui.menuItemLabel(@src(), "删除节点", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdDeleteSelected();
            }
        }
    }
    {
        var m = dvui.menu(@src(), .horizontal, .{ .id_extra = 2 });
        defer m.deinit();
        if (dvui.menuItemLabel(@src(), "视图", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "展开当前节点", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdExpandCurrent();
            }
            if (dvui.menuItemLabel(@src(), "折叠当前节点", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdCollapseCurrent();
            }
            if (dvui.menuItemLabel(@src(), "全部展开", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdSetCollapseAll(false);
            }
            if (dvui.menuItemLabel(@src(), "全部折叠", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdSetCollapseAll(true);
            }
            if (dvui.menuItemLabel(@src(), "下一个标签页", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdNextTab();
            }
            if (dvui.menuItemLabel(@src(), "上一个标签页", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdPrevTab();
            }
        }
    }
    {
        var m = dvui.menu(@src(), .horizontal, .{ .id_extra = 3 });
        defer m.deinit();
        if (dvui.menuItemLabel(@src(), "帮助", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "关于", .{}, .{ .expand = .horizontal }) != null) {
                fw.close();
                app.cmdShowAbout();
            }
        }
    }
}

/// 「最近打开的文件」动态子菜单（参考 minidoc）：编号 + 路径，点击载入成
/// 新标签；行尾可钉住/取消钉住（钉住条目用强调色）与删除（免确认）。
/// 条目多时限高滚动。历史由 App 在打开/保存成功时记录并落盘 history.toml。
fn drawRecentMenu(app: *app_mod.App, fw: *dvui.FloatingMenuWidget) void {
    // 子菜单入口的写法与上面「导出」一致：menuItem + hbox（label + 右箭头），
    // 箭头颜色跟菜单文字走；activeRect 拿到入口矩形后挂 floatingMenu。
    var item = dvui.menuItem(@src(), .{ .submenu = true }, .{ .expand = .horizontal, .tag = "menu_recent" });
    const subrect: ?dvui.Rect.Natural = item.activeRect();
    {
        const arrow_color = item.style().color(.text);
        const label_opts = item.style().strip().override(.{ .label = .{ .for_id = item.data().id }, .expand = .horizontal });
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "最近打开的文件", .{}, label_opts);
        dvui.icon(@src(), "recent_arrow", dvui.entypo.chevron_right, .{ .fill_color = arrow_color, .stroke_color = arrow_color }, .{ .gravity_y = 0.5, .role = .none });
    }
    item.deinit();
    if (subrect) |sub_r| {
        var sub = dvui.floatingMenu(@src(), .{ .from = sub_r }, .{});
        defer sub.deinit();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .{ .w = 700, .h = 480 } });
        defer scroll.deinit();

        const gray = dvui.Color.fromHex("8a8f98");
        if (app.recent.entries.items.len == 0) {
            dvui.label(@src(), "（暂无历史）", .{}, .{ .color_text = .{ .color = gray } });
        }
        for (app.recent.entries.items, 0..) |entry, i| {
            var num_buf: [16]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "";
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i * 10 + 1, .expand = .horizontal });
            defer row.deinit();
            dvui.label(@src(), "{s}", .{num}, .{
                .id_extra = i * 10 + 2,
                .min_size_content = .{ .w = 20 },
                .gravity_x = 1.0,
                .font = dvui.Font.theme(.body).withStyle(.italic),
                .color_text = .{ .color = gray },
            });
            if (dvui.menuItemLabel(@src(), entry.path, .{}, .{ .expand = .horizontal, .id_extra = i * 10 + 3 })) |_| {
                sub.close();
                fw.close();
                // 载入是本地文件读取、不弹对话框，可在点击帧内直接执行；
                // 成功时 openPathAsTab 内部已 recordRecent 落盘
                app.cmdOpenRecent(entry.path);
                continue;
            }
            // 钉住/取消钉住（钉住条目用强调色）
            const pin_color: dvui.Color = if (entry.pinned) dvui.Color.fromHex("c07f1f") else gray;
            if (dvui.buttonIcon(@src(), "recent-pin", dvui.entypo.pin, .{}, .{ .fill_color = .{ .color = pin_color }, .stroke_color = .{ .color = pin_color } }, .{ .id_extra = i * 10 + 4, .gravity_y = 0.5 })) {
                app.recentSetPinned(entry.path, !entry.pinned);
                dvui.refresh(null, @src(), null);
            }
            // 删除（免确认）
            if (dvui.buttonIcon(@src(), "recent-del", dvui.entypo.cross, .{}, .{ .fill_color = .{ .color = gray }, .stroke_color = .{ .color = gray } }, .{ .id_extra = i * 10 + 5, .gravity_y = 0.5 })) {
                app.recentRemove(entry.path);
                dvui.refresh(null, @src(), null);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 标签栏：多文档切换
// ---------------------------------------------------------------------------

/// 标签栏。每个标签 = 「标题按钮（点一下切换）+ × 按钮（关闭该标签）」，
/// 末尾还有一个「+」直接开新标签。
///
/// 两个要点：
/// 1. 所有标签都在同一个 @src() 里循环，必须靠 id_extra 区分控件，
///    这里用 `下标*2`（标题）与 `下标*2+1`（关闭），另开一段给「+」；
/// 2. 关闭/新建会增删 app.docs，而本函数正在遍历它 —— 所以只挂
///    App.pending_tab_action，等帧末 runPendingTabAction 再执行。
pub fn drawTabBar(app: *app_mod.App) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .style = .window,
        .background = true,
        .expand = .horizontal,
        .padding = .{ .h = 3, .w = 4, .x = 4, .y = 3 },
    });
    defer bar.deinit();

    for (app.docs.items, 0..) |*d, i| {
        const is_active = (i == app.active);
        var tab = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @intCast(i * 2),
            .style = if (is_active) .window else .content,
            .background = true,
            .corners = dvui.CornerRect.round(4),
            .border = if (is_active) .{ .h = 1, .w = 1, .x = 1, .y = 1 } else .{},
            .color_border = if (is_active) .{ .color = dvui.themeGet().focus } else null,
        });
        defer tab.deinit();

        var name_buf: [64]u8 = undefined;
        var text_buf: [80]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, "{s}{s}", .{
            d.title(&name_buf),
            if (d.dirty) " *" else "",
        }) catch d.title(&name_buf);

        if (dvui.button(@src(), text, .{}, .{
            .id_extra = @intCast(i * 2),
            .style = .content,
            .background = false,
            .min_size_content = .{ .w = 96 },
        })) {
            app.cmdSelectTab(i);
        }
        if (dvui.buttonIcon(@src(), "close_tab", dvui.entypo.cross, .{}, .{}, .{
            .id_extra = @intCast(i * 2 + 1),
            .padding = .{ .h = 2, .w = 2, .x = 2, .y = 2 },
            .min_size_content = .{ .w = 10, .h = 10 },
        })) {
            app.pending_tab_action = .close;
            app.pending_tab_index = i;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .width(8), .id_extra = 900 });
    if (iconButton(@src(), "new_tab", dvui.entypo.plus, "新建标签页 (Ctrl+N)", 901)) {
        app.pending_tab_action = .new;
    }
}

// ---------------------------------------------------------------------------
// 工具栏
// ---------------------------------------------------------------------------

/// 图标按钮 + 悬停提示。
/// src 必须由调用点传入（每个按钮独占一行），否则 dvui 的 widget id 会撞车：
/// FloatingTooltipWidget.init 内部只用 src 建窗口 id，会丢掉 opts.id_extra，
/// 所以 tooltip 也必须用调用点 src，不能在这个函数体里写 @src()。
/// 默认 IconRenderOptions（fill/stroke 都是 white）表示「跟着主题文字色走」，
/// 所以浅色/深色主题下图标都可见，不用手动设颜色。
fn iconButton(
    src: std.builtin.SourceLocation,
    name: []const u8,
    tvg_bytes: []const u8,
    tip: []const u8,
    id_extra: u32,
) bool {
    return iconButtonStateful(src, name, tvg_bytes, tip, tip, id_extra, true, null);
}

/// 悬停提示的显示驻留帧数：指针在按钮上停留够这么多帧才挂 tooltip。
/// dvui 的 tooltip 浮动子窗口一显示就会按几何位置截走鼠标事件（它的
/// delay 参数只控制淡入动画，不拦安装）——tooltip 又排在按钮旁边，
/// 「悬停 A 后立刻点旁边的 B」第一次点击会被 A 的提示吃掉。自己数驻留
/// 帧，快移快点时干脆不装 tooltip。
const tooltip_dwell_frames: u32 = 3;

/// 带可用状态的图标按钮：不可用时图标置灰（dvui grayed：文字色混入底色），
/// 点击不触发动作，悬停提示换成 tip_disabled（说明为什么不可用）。
/// grayed 只是视觉态（dvui 仍会上报点击），门控在这里做。
/// tag 供无头测试定位（不测试的按钮传 null）。
fn iconButtonStateful(
    src: std.builtin.SourceLocation,
    name: []const u8,
    tvg_bytes: []const u8,
    tip: []const u8,
    tip_disabled: []const u8,
    id_extra: u32,
    enabled: bool,
    tag: ?[]const u8,
) bool {
    var bd: dvui.WidgetData = undefined;
    const clicked = dvui.buttonIcon(src, name, tvg_bytes, .{ .grayed = !enabled }, .{}, .{
        .id_extra = id_extra,
        .data_out = &bd, // 拿按钮矩形，用来挂 tooltip
        .min_size_content = .{ .w = 20, .h = 20 }, // 图标本体大小（不含 padding）
        .tag = tag,
    });
    // 驻留计时（按按钮 id 存，跨帧累计）：指针在按钮上才累加，离开即清零
    const inside = bd.borderRectScale().r.contains(dvui.currentWindow().mouse_pt);
    const dwell: u32 = if (inside) (dvui.dataGet(null, bd.id, "_dwell", u32) orelse 0) + 1 else 0;
    if (inside) {
        dvui.dataSet(null, bd.id, "_dwell", dwell);
    } else {
        dvui.dataRemove(null, bd.id, "_dwell");
    }
    if (dwell >= tooltip_dwell_frames) {
        dvui.tooltip(
            src,
            .{ .active_rect = bd.borderRectScale().r, .position = .horizontal },
            "{s}",
            .{if (enabled) tip else tip_disabled},
            .{},
        );
    }
    return clicked and enabled;
}

pub fn drawToolbar(app: *app_mod.App) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .style = .content,
        .background = true,
        .expand = .horizontal,
        .padding = .{ .h = 4, .w = 8, .x = 8, .y = 4 },
    });
    defer hbox.deinit();

    // 文件操作（打开/保存只挂号，帧末由 main 执行阻塞式系统对话框）
    if (iconButton(@src(), "new_doc", dvui.entypo.document, "新建脑图（新标签页 Ctrl+N）", 20)) {
        app.cmdNewDoc() catch app.setStatus("新建失败：内存不足");
    }
    if (iconButton(@src(), "open_doc", dvui.entypo.folder, "打开脑图文件（新标签页 Ctrl+O）", 21)) app.pending_file_action = .open;
    // 保存：当前文档没有未保存修改时置灰（点了也不会挂号）
    if (iconButtonStateful(@src(), "save_doc", dvui.entypo.save, "保存当前标签页 (Ctrl+S)", "没有未保存的修改", 22, app.doc().dirty, "tb_save")) app.pending_file_action = .save;
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12), .id_extra = 23 });

    // 撤销 / 重做（entypo 里用逆时针 / 顺时针箭头表示）。
    // 栈空时置灰：能不能撤/重做跟着当前标签页的撤销栈走。
    if (iconButtonStateful(@src(), "undo", dvui.entypo.ccw, "撤销 (Ctrl+Z)", "没有可撤销的操作", 24, app.canUndo(), "tb_undo")) app.cmdUndo();
    if (iconButtonStateful(@src(), "redo", dvui.entypo.cw, "重做 (Ctrl+Y)", "没有可重做的操作", 25, app.canRedo(), "tb_redo")) app.cmdRedo();
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12), .id_extra = 26 });

    // 结构操作（图标 + 悬停提示）
    if (iconButton(@src(), "add_child", dvui.entypo.flow_tree, "添加子节点 (Insert)", 10)) app.cmdAddChild();
    if (iconButton(@src(), "add_sibling", dvui.entypo.add_to_list, "添加同级节点 (Enter)", 11)) app.cmdAddSibling();
    if (iconButton(@src(), "delete", dvui.entypo.trash, "删除节点 (Delete)", 12)) app.cmdDeleteSelected();
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12) });
    // 四角箭头朝外 = 展开，朝内 = 折叠（作用于整篇文档）
    if (iconButton(@src(), "expand_all", dvui.entypo.resize_full_screen, "全部展开", 13)) app.cmdSetCollapseAll(false);
    if (iconButton(@src(), "collapse_all", dvui.entypo.resize_100, "全部折叠", 14)) app.cmdSetCollapseAll(true);
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12), .id_extra = 2 });
    // 实心三角朝下 = 展开，朝上 = 折叠（只作用于当前选中节点）
    if (iconButton(@src(), "expand_current", dvui.entypo.triangle_down, "展开当前节点及其子树", 15)) app.cmdExpandCurrent();
    if (iconButton(@src(), "collapse_current", dvui.entypo.triangle_up, "折叠当前节点", 16)) app.cmdCollapseCurrent();
}

// ---------------------------------------------------------------------------
// 侧栏：选中节点属性
// ---------------------------------------------------------------------------

/// 背景色预设色板（低饱和的浅/中色系，配自动黑/白文字都清晰）。
const bg_presets = [_]model.Rgba{
    .{ .r = 0xff, .g = 0xf3, .b = 0xb0 }, // 浅黄
    .{ .r = 0xff, .g = 0xe0, .b = 0xb2 }, // 浅橙
    .{ .r = 0xff, .g = 0xc4, .b = 0xc4 }, // 浅红
    .{ .r = 0xc8, .g = 0xe6, .b = 0xc9 }, // 浅绿
    .{ .r = 0xb3, .g = 0xe5, .b = 0xfc }, // 浅蓝
    .{ .r = 0xe1, .g = 0xbe, .b = 0xe7 }, // 浅紫
    .{ .r = 0xcf, .g = 0xd8, .b = 0xdc }, // 浅灰蓝
    .{ .r = 0x90, .g = 0xca, .b = 0xf9 }, // 中蓝
    .{ .r = 0xa5, .g = 0xd6, .b = 0xa7 }, // 中绿
    .{ .r = 0xff, .g = 0xab, .b = 0x91 }, // 珊瑚
};

/// 色板里的一个色块按钮（点击 = 一步撤销地上色）。
/// 所有色块共用同一个 @src()，必须用 id_extra 区分。
fn bgSwatchButton(app: *app_mod.App, color: model.Rgba, id_extra: u32) void {
    if (dvui.button(@src(), "", .{}, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = 22, .h = 22 },
        .color_fill = .{ .color = app_mod.App.dvuiColor(color) },
        .corners = dvui.CornerRect.round(4),
        .margin = .{ .x = 1, .y = 0, .h = 0, .w = 1 },
        .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
        .color_border = .{ .color = dvui.themeGet().color(.control, .border) },
    })) {
        app.cmdSetNodeBg(color);
    }
}

/// 背景色区：预设色板 + 自定义取色器 + 恢复默认。
/// 取色器拖动产生的连续变化由 App 的取色撤销会话收成一步撤销
/// （trackColorPicker 预备镜像 → 首次变色 commitColorEdit 入栈）。
fn drawBgColorSection(app: *app_mod.App, node: *model.Node) void {
    dvui.label(@src(), "背景色：", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });

    // 换了选中节点：收起上一个节点的取色器并结束它的撤销会话
    if (app.color_picker_node_id != node.id) {
        app.endColorSession();
        app.color_picker_open = false;
        app.color_picker_node_id = node.id;
    }

    // 预设色板：两行小色块，点一下上色（重复点当前色无动作，不产生空撤销步）。
    // 一行最多 5 个：侧栏最小宽 240px，超出会把侧栏撑宽、挤掉画布视口。
    {
        var pal = dvui.box(@src(), .{ .dir = .vertical }, .{ .margin = .{ .y = 4, .x = 0, .h = 0, .w = 0 } });
        defer pal.deinit();
        for (bg_presets, 0..) |_, i| {
            if (i % 5 != 0) continue;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @intCast(i / 5) });
            defer row.deinit();
            for (bg_presets[i..@min(i + 5, bg_presets.len)], 0..) |c, col| {
                bgSwatchButton(app, c, @intCast(i + col));
            }
        }
    }

    // 当前的自定义色值（跟随主题时不显示）
    if (node.bg) |bg| {
        var hexbuf: [9]u8 = undefined;
        dvui.label(@src(), "当前：{s}", .{bg.formatHex(&hexbuf)}, .{ .margin = .{ .y = 2, .x = 0, .h = 0, .w = 0 } });
        if (dvui.button(@src(), "恢复默认背景色", .{}, .{})) {
            app.cmdSetNodeBg(null);
        }
    }

    if (dvui.button(@src(), if (app.color_picker_open) "收起取色器" else "自定义颜色…", .{}, .{
        .tag = "side_color_pick_toggle",
        .expand = .horizontal,
    })) {
        app.color_picker_open = !app.color_picker_open;
        if (app.color_picker_open) {
            // 打开时从节点当前颜色初始化取色器，并预备撤销镜像
            app.color_picker_hsv = dvui.Color.HSV.fromColor(app_mod.App.dvuiColor(node.bg orelse model.Rgba{}));
            app.trackColorPicker(node.id);
        } else {
            app.endColorSession();
        }
    }

    if (app.color_picker_open) {
        // 会话可能被撤销/换标签重置过（两者都会同时收起取色器，这里只是兜底对准）
        app.trackColorPicker(node.id);
        if (dvui.colorPicker(@src(), .{ .hsv = &app.color_picker_hsv }, .{ .expand = .horizontal })) {
            app.commitColorEdit();
            const c = app.color_picker_hsv.toColor();
            app.applyNodeBg(node, .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a });
            app.cmdMarkDirty("背景色已更改");
        }
    }
}

/// 手动调整过尺寸的提示区：显示当前框尺寸 + 恢复自动尺寸按钮。
/// （调整入口在画布上：拖节点右/下边缘或右下角）
fn drawNodeSizeSection(app: *app_mod.App, node: *model.Node) void {
    if (node.user_w == null and node.user_h == null) return;
    var size_buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&size_buf, "尺寸：{d}×{d}（已手动调整）", .{
        @as(i64, @intFromFloat(@round(node.geom.w))),
        @as(i64, @intFromFloat(@round(node.geom.h))),
    }) catch "尺寸：已手动调整";
    dvui.label(@src(), "{s}", .{text}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });
    if (dvui.button(@src(), "恢复自动尺寸", .{}, .{})) {
        app.cmdClearNodeSize();
    }
}

/// 节点图片区：缩略图 + 选择/移除按钮。
/// 「从磁盘加载图片」是帧末系统对话框（阻塞），经 app.cmdPickImage 挂号后由
/// runPendingFileAction → runPickImage 消费（与打开/保存同款机制）；
/// 读入的数据按 md5 登记进文档图片池，同一张图自动复用已有 id。
fn drawImageSection(app: *app_mod.App, node: *model.Node) void {
    dvui.label(@src(), "图片：", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });
    if (node.hasImg()) {
        if (app.imageAsset(node)) |asset| {
            _ = dvui.image(@src(), .{
                .source = .{ .imageFile = .{
                    .bytes = asset.data.items,
                    .name = asset.img_type.items,
                    .invalidation = .bytes,
                } },
                .shrink = .ratio,
            }, .{
                .id_extra = node.id,
                .min_size_content = .{ .w = 96, .h = 96 },
                .label = .{ .text = "节点图片预览" },
            });
        }
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 4, .x = 0, .h = 0, .w = 0 } });
        defer row.deinit();
        if (dvui.button(@src(), "从磁盘加载图片", .{}, .{ .tag = "side_img_pick" })) {
            app.cmdPickImage();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .width(4), .id_extra = 1 });
        if (dvui.button(@src(), "移除图片", .{}, .{ .tag = "side_img_clear" })) {
            app.cmdClearNodeImg();
        }
    } else if (dvui.button(@src(), "从磁盘加载图片", .{}, .{ .tag = "side_img_pick", .expand = .horizontal })) {
        app.cmdPickImage();
    }
}

/// 属性表编辑区：逐行 属性名 / 值 输入框 + 删除按钮，底部「添加属性」。
/// 输入框直绑 p.name / p.value（ArrayList），撤销走 trackTextField 会话，
/// 与「标题」「正文描述」同款：整段输入算一步。
fn drawPropertySection(app: *app_mod.App, node: *model.Node, panel_avail_w: f32) void {
    _ = panel_avail_w;
    dvui.label(@src(), "属性表：", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });

    // 输入框高度必须显式给：只给 min_size_content 的宽度时 h 取 0，
    // textEntry 会缩成「只剩 margin+border+padding」的一条细缝（上下太小）。
    // 取字体实际文本高（不是 lineHeight——后者更大会让属性行比其他输入框高一截）。
    const entry_h = dvui.themeGet().font_body.textHeight();

    // 删除在遍历中进行会挪动下标：先记下、循环结束后统一执行
    var pending_remove: ?usize = null;

    for (node.properties.items, 0..) |*p, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .margin = .{ .y = 2, .x = 0, .h = 0, .w = 0 },
        });
        defer row.deinit();

        // dvui 的 tag 按**名字**全局唯一（id_extra 只影响控件 id，不影响 tag），
        // 多行属性表的 tag 必须带行号，否则同帧重名会报 duplicate tag。
        var tag_bufs: [3][40]u8 = @splat(@splat(0));
        const tag_name = std.fmt.bufPrint(&tag_bufs[0], "side_prop_name:{d}", .{i}) catch "side_prop_name";
        const tag_value = std.fmt.bufPrint(&tag_bufs[1], "side_prop_value:{d}", .{i}) catch "side_prop_value";
        const tag_del = std.fmt.bufPrint(&tag_bufs[2], "side_prop_del:{d}", .{i}) catch "side_prop_del";

        {
            var te = dvui.textEntry(@src(), .{
                .placeholder = "属性名",
                .text = .{ .array_list = .{ .backing = &p.name, .allocator = app.gpa } },
            }, .{
                .id_extra = i * 2,
                .min_size_content = .{ .w = 72, .h = entry_h },
                .expand = .horizontal,
                .tag = tag_name,
            });
            defer te.deinit();
            app.trackTextField(te.data().id.asUsize());
            if (te.text_changed) {
                app.commitTextFieldEdit();
                app.cmdMarkDirty("属性名已修改");
            }
        }
        {
            var te = dvui.textEntry(@src(), .{
                .placeholder = "值",
                .text = .{ .array_list = .{ .backing = &p.value, .allocator = app.gpa } },
            }, .{
                .id_extra = i * 2 + 1,
                .min_size_content = .{ .w = 56, .h = entry_h },
                .expand = .horizontal,
                .tag = tag_value,
            });
            defer te.deinit();
            app.trackTextField(te.data().id.asUsize());
            if (te.text_changed) {
                app.commitTextFieldEdit();
                app.cmdMarkDirty("属性值已修改");
            }
        }
        if (dvui.button(@src(), "删", .{}, .{
            .id_extra = i,
            .min_size_content = .{ .h = entry_h },
            .tag = tag_del,
        })) {
            pending_remove = i;
        }
    }

    if (pending_remove) |idx| app.cmdRemoveProperty(idx);

    if (dvui.button(@src(), "添加属性", .{}, .{ .tag = "side_prop_add", .expand = .horizontal })) {
        app.cmdAddProperty();
    }
}


/// 正文描述输入框下方的拖动把手：上下拖动改变输入框高度（app.note_editor_h，
/// 会话内记住；界面偏好，不进文档、不走撤销）。与画布节点缩放同款交互：
/// captureMouse + dragPreStart，motion 里按增量更新。
///
/// 提示文字做成把手旁的内联小字、整个「条 + 文字」都是拖拽热区——
/// 不用 dvui.tooltip：它是独立子窗口，侧栏贴着窗口右缘时提示必然翻转回来
/// 盖住把手，把按下事件吞掉（无头测试抓到过）。
fn drawNoteEditorGrip(app: *app_mod.App) void {
    var bd: dvui.WidgetData = undefined;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .tag = "note_editor_grip",
            .gravity_x = 0.5, // 在侧栏里居中
            .margin = .{ .x = 0, .y = 2, .h = 0, .w = 0 },
            .data_out = &bd,
        });
        defer row.deinit();

        {
            var bar = dvui.box(@src(), .{}, .{
                .min_size_content = .{ .w = 48, .h = 6 },
                .gravity_y = 0.5,
                .background = true,
                .color_fill = .{ .color = dvui.themeGet().color(.control, .border) },
                .corners = dvui.CornerRect.round(3),
            });
            defer bar.deinit();
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .width(8) });
        dvui.label(@src(), "拖动调整高度", .{}, .{
            .gravity_y = 0.5,
            .font = app_mod.App.descFont(),
        });
    }

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, &bd)) continue;
        switch (e.evt) {
            .mouse => |me| switch (me.action) {
                .press => if (me.button.pointer()) {
                    e.handle(@src(), &bd);
                    dvui.captureMouse(&bd, e.num);
                    dvui.dragPreStart(me.button, me.p, .{ .name = "note_editor_grip" });
                },
                .motion => {
                    if (dvui.captured(bd.id)) {
                        if (dvui.dragging(me, "note_editor_grip")) |dp| {
                            e.handle(@src(), &bd);
                            // dp 是物理像素增量，除以 scale 得自然像素；
                            // 把手画在框下方，下拖（dp.y > 0）= 变高
                            const s = bd.borderRectScale().s;
                            app.note_editor_h = std.math.clamp(
                                app.note_editor_h + dp.y / s,
                                app_mod.note_editor_min_h,
                                app_mod.note_editor_max_h,
                            );
                            dvui.refresh(null, @src(), null);
                        }
                    }
                },
                .release => if (me.button.pointer()) {
                    if (dvui.captured(bd.id)) {
                        e.handle(@src(), &bd);
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd(me.button);
                        app.setStatus("已调整描述输入框大小");
                    }
                },
                .position => dvui.cursorSet(.arrow_n_s),
                else => {},
            },
            else => {},
        }
    }
}

/// 正文描述输入框的最大宽度（自然像素）= 视图宽度 × note_editor_max_w_frac。
pub fn noteEditorMaxWidth() f32 {
    return dvui.windowRect().w * app_mod.note_editor_max_w_frac;
}

pub fn drawSidePanel(app: *app_mod.App) void {
    var panel_wd: dvui.WidgetData = undefined;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .style = .content,
        .background = true,
        .expand = .vertical,
        .min_size_content = .{ .w = 240 },
        .padding = .{ .h = 8, .w = 8, .x = 8, .y = 8 },
        .border = .{ .h = 0, .w = 1, .x = 0, .y = 0 },
        .data_out = &panel_wd,
    });
    defer panel.deinit();

    dvui.label(@src(), "节点属性", .{}, .{ .font = .theme(.title) });

    // 面板内容（输入框/色板/列表…）总高常超窗口：套滚动区，矮窗口下
    // 滚动查看，否则排到末尾的控件会被压成 0 高叠在一起。
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &app.side_scroll }, .{ .expand = .both });
    defer scroll.deinit();

    if (app.selectedNode()) |node| {
        dvui.label(@src(), "标题：", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });
        {
            var te = dvui.textEntry(@src(), .{
                .placeholder = "节点标题",
                .text = .{ .array_list = .{ .backing = &node.text, .allocator = app.gpa } },
            }, .{ .expand = .horizontal, .tag = "side_title" });
            defer te.deinit();
            // 撤销会话：聚焦时预备镜像，首次输入才入栈（整段输入算一步）
            app.trackTextField(te.data().id.asUsize());
            if (te.text_changed) {
                app.commitTextFieldEdit();
                app.cmdMarkDirty("标题已修改");
            }
        }

        dvui.label(@src(), "正文描述：", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });
        {
            // 宽度钳制：外框 ≤ 视图宽度的 20%（缺省，note_editor_max_w_frac），
            // 也不超过面板可用宽度。超过最大宽度的文本由 break_lines 自动
            // 折行（横向滚动随之禁用），不再溢出/需要横向拖动。
            // 注意 max_size_content 必须给：TextLayout 在 break_lines 下上报的
            // 最小宽度仍是不折行的整行宽度（dvui 已知语义），只靠 min_size
            // 钳不住，整行一长输入框就会被撑到整行宽。
            // textEntry 外框 = 内容 + margin 4 + border 1 + padding 6，左右两份。
            const chrome: f32 = 22;
            const avail_w = panel_wd.contentRect().w;
            const outer_w = @min(avail_w, noteEditorMaxWidth());
            const content_w = @max(outer_w - chrome, 60);
            var te = dvui.textEntry(@src(), .{
                .placeholder = "留空则只显示标题",
                .multiline = true, // 支持换行
                .break_lines = true, // 超过最大宽度自动折行
                .text = .{ .array_list = .{ .backing = &node.note, .allocator = app.gpa } },
                // 高度由用户拖动把手决定（app.note_editor_h）；折行需要更高时
                // 由 TextLayout 的最小尺寸自动撑大
            }, .{
                .min_size_content = .{ .w = content_w, .h = app.note_editor_h },
                .max_size_content = .width(content_w),
                .tag = "side_note",
            });
            defer te.deinit();
            app.trackTextField(te.data().id.asUsize());
            if (te.text_changed) {
                app.commitTextFieldEdit();
                app.cmdMarkDirty("正文已修改");
            }
        }
        drawNoteEditorGrip(app);

        if (node.hasNote()) {
            if (dvui.button(@src(), "清除正文描述", .{}, .{})) app.cmdClearNote();
        }

        // 连接线标题（与画布上双击连线编辑的是同一份数据）
        if (node.parent != null) {
            dvui.label(@src(), "连线标题：", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });
            {
                var te = dvui.textEntry(@src(), .{
                    .placeholder = "如：依赖 / 包含",
                    .text = .{ .array_list = .{ .backing = &node.link, .allocator = app.gpa } },
                }, .{ .expand = .horizontal });
                defer te.deinit();
                app.trackTextField(te.data().id.asUsize());
                if (te.text_changed) {
                    app.commitTextFieldEdit();
                    app.cmdMarkDirty("连线标题已修改");
                }
            }
            if (node.hasLink()) {
                if (dvui.button(@src(), "清除连线标题", .{}, .{})) app.cmdClearLink();
            }
        }

        drawBgColorSection(app, node);

        drawNodeSizeSection(app, node);

        drawImageSection(app, node);

        drawPropertySection(app, node, panel_wd.contentRect().w);

        _ = dvui.spacer(@src(), .{ .min_size_content = .height(8) });
        dvui.label(@src(), "ID: {d}", .{node.id}, .{});
        dvui.label(@src(), "子节点: {d}", .{node.children.items.len}, .{});
        drawChildOrderList(app, node, panel_wd.contentRect().w);

        _ = dvui.spacer(@src(), .{ .min_size_content = .height(8), .id_extra = 1 });
        if (node.children.items.len > 0) {
            if (dvui.button(@src(), if (node.collapsed) "展开此节点" else "折叠此节点", .{}, .{})) {
                app.cmdToggleCollapse(node);
            }
        }
    } else {
        dvui.label(@src(), "（未选中节点）", .{}, .{ .margin = .{ .y = 8, .x = 0, .h = 0, .w = 0 } });
    }
}

// ---------------------------------------------------------------------------
// 「下一级节点」列表：按导出顺序列出直接子节点标题，拖动换位改导出顺序
// ---------------------------------------------------------------------------

/// 「下一级节点」列表的最大宽度（自然像素）= 视图宽度 × child_list_max_w_frac。
pub fn childListMaxWidth() f32 {
    return dvui.windowRect().w * app_mod.child_list_max_w_frac;
}

/// 列表行高（内容像素）：拖动换位的目标下标按它折算，行高必须固定。
const child_list_row_h: f32 = 22;

/// 按导出顺序（seq*10^7+id）列出 node 的直接子节点标题。行可上下拖动：
/// 换位实时把各子节点的 seq 写成新列表下标（见 app.cmdMoveChildSeq），
/// 树本身的子节点顺序与画布布局不变。列表宽度钳到面板可用宽度与
/// 视图宽度 20%（缺省）的较小者。
fn drawChildOrderList(app: *app_mod.App, node: *model.Node, panel_avail_w: f32) void {
    if (node.children.items.len == 0) return;
    // 排序副本：拖动换位直接在这个副本上移动并写 seq，下一帧重排自然生效。
    // 分配失败退回未排序的树顺序（列表仍可用，只是顺序不保证）。
    const sorted = model.childrenForExport(app.gpa, node) catch null;
    defer if (sorted) |s| app.gpa.free(s);
    const kids: []*model.Node = sorted orelse node.children.items;

    dvui.label(@src(), "下一级节点（拖动调整导出顺序）：", .{}, .{ .font = app_mod.App.descFont(), .margin = .{ .y = 4, .x = 0, .h = 0, .w = 0 } });

    var list_wd: dvui.WidgetData = undefined;
    {
        var list = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{
                .w = @min(panel_avail_w, childListMaxWidth()),
                .h = @as(f32, @floatFromInt(kids.len)) * child_list_row_h,
            },
            .background = true,
            .style = .window,
            .border = .{ .h = 1, .w = 1, .x = 1, .y = 1 },
            .corners = dvui.CornerRect.round(4),
            .data_out = &list_wd,
        });
        defer list.deinit();

        for (kids, 0..) |c, i| {
            drawChildOrderRow(app, kids, i, c);
        }
    }
}

/// 列表的一行：拖动把手 + 子节点标题。按下捕获鼠标，motion 里按指针在
/// 列表内的行位置算目标下标，换位走 app.cmdMoveChildSeq（实时写 seq）。
fn drawChildOrderRow(app: *app_mod.App, kids: []*model.Node, i: usize, c: *model.Node) void {
    // tag 缓冲必须是本行的栈内存：各行共用一个缓冲会让先注册的 tag 切片
    // 被后写的行名覆盖（dvui.tag 不拷贝名字），全部别名成最后一行
    var tag_buf: [24]u8 = undefined;
    const row_tag: ?[]const u8 = std.fmt.bufPrint(&tag_buf, "child_item_{d}", .{c.id}) catch null;
    var row_wd: dvui.WidgetData = undefined;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = c.id,
            .tag = row_tag,
            .min_size_content = .{ .h = child_list_row_h },
            .expand = .horizontal,
            .padding = .{ .h = 0, .w = 4, .x = 4, .y = 0 },
            .data_out = &row_wd,
        });
        defer row.deinit();

        // 拖动把手（≡）提示可拖
        dvui.icon(@src(), "row_grip", dvui.entypo.menu, .{}, .{
            .gravity_y = 0.5,
            .role = .none,
            .min_size_content = .{ .w = 12, .h = 12 },
            .color_text = .{ .color = dvui.themeGet().color(.content, .border) },
        });
        dvui.label(@src(), "{s}", .{c.text.items}, .{ .gravity_y = 0.5, .padding = .{} });

        const dragging_this = app.seq_drag_index != null and app.seq_drag_index.? == i;
        if (dragging_this) {
            row.data().focusBorder();
        }

        for (dvui.events()) |*e| {
            if (!row.matchEvent(e)) continue;
            switch (e.evt) {
                .mouse => |me| switch (me.action) {
                    .press => if (me.button.pointer()) {
                        e.handle(@src(), row.data());
                        dvui.captureMouse(row.data(), e.num);
                        dvui.dragPreStart(me.button, me.p, .{ .name = "seq_reorder" });
                        app.seq_drag_index = i;
                        app.seq_drag_pushed = false;
                    },
                    .motion => {
                        if (dvui.captured(row.data().id)) {
                            if (dvui.dragging(me, "seq_reorder")) |_| {
                                e.handle(@src(), row.data());
                                // 目标下标 = 被拖行下标 + 指针相对被拖行顶缘的
                                // 行数（四舍五入）。全部用物理像素：行自身的
                                // borderRect 与事件 p 同一空间，不依赖外层容器
                                // 在滚动区里的坐标系。
                                const row_r = row.data().borderRectScale().r;
                                const rows_f = (me.p.y - row_r.y) / row_r.h;
                                const t_f = @as(f32, @floatFromInt(i)) + @round(rows_f);
                                const t: usize = @intFromFloat(std.math.clamp(t_f, 0, @as(f32, @floatFromInt(kids.len - 1))));
                                const from = app.seq_drag_index orelse i;
                                if (t != from) {
                                    app.cmdMoveChildSeq(kids, from, t);
                                    app.seq_drag_index = t;
                                    app.setStatus("拖动调整导出顺序中…");
                                    dvui.refresh(null, @src(), null);
                                }
                            }
                        }
                    },
                    .release => if (me.button.pointer()) {
                        if (dvui.captured(row.data().id)) {
                            e.handle(@src(), row.data());
                            dvui.captureMouse(null, e.num);
                            dvui.dragEnd(me.button);
                            if (app.seq_drag_index != null) app.setStatus("已调整导出顺序");
                            app.seq_drag_index = null;
                            app.seq_drag_pushed = false;
                            dvui.refresh(null, @src(), null);
                        }
                    },
                    .position => dvui.cursorSet(.arrow_n_s),
                    else => {},
                },
                else => {},
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 状态栏
// ---------------------------------------------------------------------------
pub fn drawStatusBar(app: *app_mod.App) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .style = .window,
        .background = true,
        .expand = .horizontal,
        .padding = .{ .h = 4, .w = 8, .x = 8, .y = 4 },
    });
    defer hbox.deinit();
    const d = app.doc();
    const path = d.pathSlice();
    dvui.label(@src(), "标签 {d}/{d}   |   {s}{s}   |   节点数 {d}   |   {s}", .{
        app.active + 1,
        app.docCount(),
        if (path.len == 0) "（未命名）" else path,
        if (d.dirty) " *" else "",
        model.countNodes(d.root),
        app.statusSlice(),
    }, .{ .expand = .horizontal });
}
