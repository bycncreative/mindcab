//! zmind —— 脑图编辑器（Zig 0.16 + dvui + SDL3 后端）
//!
//! 模块结构（依赖方向单向：main → ui/canvas → app → model/xml/layout）：
//!   model.zig    节点树数据结构与纯树操作
//!   xml.zig      XML 序列化 / 反序列化
//!   layout.zig   布局算法（测量、树坐标、拖拽偏移、包围盒）
//!   app.zig      应用状态 + 命令层（所有文档修改的唯一入口）
//!   canvas.zig   画布视图（连线、节点框、选中/拖拽交互）
//!   ui.zig       菜单栏 / 标签栏 / 工具栏 / 侧栏 / 状态栏
//!   keys.zig     全局按键分发（帧首 + 帧末两段，见该文件头注释）
//!   platform.zig 平台辅助（控制台挂接、CJK 字体）
//!
//! 主循环结构照 dvui/examples/sdl-standalone.zig；SDL3 后端原因见 build.zig 注释。
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");

const app_mod = @import("app.zig");
const canvas = @import("canvas.zig");
const ui = @import("ui.zig");
const keys = @import("keys.zig");
const platform = @import("platform.zig");
const recent_files = @import("recent_files.zig");

/// 窗口图标（标题栏/任务栏）。exe 资源里的图标（src/app.rc）只管
/// 资源管理器里的文件图标，SDL3 窗口的图标必须运行时设置。
const logo_png = @embedFile("assets/logo64x64.png");

comptime {
    // 确认拿到的是 dvui 的 SDL 后端模块
    std.debug.assert(@hasDecl(SDLBackend, "SDLBackend"));
}

pub fn main(init: std.process.Init) !void {
    // 只在 Debug 构建挂父进程控制台（让 zig build run 时 std.log 可见）。
    // 发布版不能带：AttachConsole(ATTACH_PARENT_PROCESS) 是杀软启发式的常见
    // 特征（恶意程序用它做隐蔽输出），而且 GUI 子系统本来也没有控制台可挂。
    if (builtin.os.tag == .windows and builtin.mode == .debug) {
        // 注意：不用 dvui.Backend.Common.windowsAttachConsole()——它引用了
        // 0.16 已删除的 std.os.windows.FALSE（HOWTO §2），自己写才零补丁。
        platform.attachConsole() catch {};
    }

    SDLBackend.enableSDLLogging();
    std.log.info("SDL version: {f}", .{SDLBackend.getSDLVersion()});

    var app = try app_mod.App.init(init.gpa, init.io);
    defer app.deinit();

    // 最近打开的文件（文件菜单子菜单）：从 %USERPROFILE%/.mindcab/history.toml 载入
    {
        var hist_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (recent_files.defaultPath(&hist_buf)) |hist| {
            app.recent.loadFrom(init.io, hist);
        }
    }

    // 1) 创建 OS 窗口（后端持有）
    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        // org/app 与产物名保持一致（只用于 SDL_GetPrefPath → 存窗口位置
        // %APPDATA%\mindcab\mindcab\windows_geometry.zon，不含用户文档数据，
        // 改名不存在迁移负担）。注意窗口标题仍是「思维导图」，与文件名无关。
        .org = "mindcab",
        .app = "mindcab",
        .size = .{ .w = 1280.0, .h = 800.0 },
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .vsync = true,
        .title = "思维导图",
        .icon = logo_png,
    });
    defer backend.deinit();

    // 2) dvui 的 Window，映射到上面那个 OS 窗口
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .color_scheme = backend.preferredColorScheme(), // 跟随系统深浅色
    });
    defer win.deinit();

    // dvui 内置字体没有 CJK 字形，中文会渲染成方框；注册系统中文字体
    platform.loadCjkFont(&win, init.gpa, init.io);

    // 3) 主循环
    var interrupted = false;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted); // 与下面的 waitTime 配合 → 有事才画
        try win.begin(nstime); // 之后才能调 dvui 函数
        try backend.addAllEvents(&win); // SDL 事件 → dvui
        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 0);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer); // 防上一帧残影
        if (!guiFrame(&app)) break :main_loop; // 返回 false = 用户要退出
        const end_micros = try win.end(.{}); // 默认 manage_backend：内部已做 setCursor/textInputRect/renderPresent
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

/// 每帧 UI。返回 false 表示要退出。
fn guiFrame(app: *app_mod.App) bool {
    // 推进帧序号：字符串池 GC 的 trash 只允许跨帧释放
    app.tickFrame();
    // 消费上一帧确认框的结果：对话框在 Window.end 阶段绘制，
    // 与 App 之间靠 app.zig 的模块级变量中转，所以要等到下一帧开头才能落地。
    app.runPendingConfirm();

    // 撤销 / 重做等应用级按键必须在画控件**之前**处理：焦点在文本框里时
    // dvui 会吞掉键事件，帧末的全局循环就轮不到 Ctrl+Z / Esc / Insert 了。
    // 帧首 + 帧末两段全局按键分发统一放在 keys.zig（对应 report 缺陷 1/2/4/6）。
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

    // 标签栏正遍历 docs，标签的增删必须等它画完；文件对话框阻塞同理。
    app.runPendingTabAction();
    app.runPendingFileAction();
    // 侧栏文本框聚焦会话收尾：焦点离开才丢弃没入栈的预备快照
    app.endTextFieldSession();

    // PNG 导出走离屏纹理（Picture），必须在 Window.begin/end 期间绘制；
    // 放在所有 UI 控件与对话框之后、事件分发之前：用户已点的菜单项已挂号、
    // 后续 dvui.events() 跑的是本帧剩余事件，不会再干扰 offscreen 渲染。
    app.runPendingExport();

    // 全局事件：窗口关闭 + 快捷键（放在控件之后，只捡没人处理的；
    // 对话框打开期间跳过按键，见 keys.zig —— 缺陷 2）
    keys.afterWidgets(app);
    return !app.want_quit;
}
