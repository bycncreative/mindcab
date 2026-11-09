//! zmind 平台相关辅助：Windows 控制台挂接、CJK 字体加载。
//! 与业务无关的系统胶水代码集中于此。
const std = @import("std");
const dvui = @import("dvui");

/// Windows 上挂父进程控制台。注意 0.16 的 BOOL 是枚举，用 `.FALSE`，
/// 不要 `std.os.windows.FALSE`（已删除）。
pub fn attachConsole() !void {
    const k32 = struct {
        extern "kernel32" fn AttachConsole(dw_process_id: std.os.windows.DWORD) std.os.windows.BOOL;
    };
    const attach_parent_process: std.os.windows.DWORD = 0xFFFFFFFF; // DWORD(-1)
    if (k32.AttachConsole(attach_parent_process) == .FALSE)
        return error.CouldNotAttachConsole;
}

/// 注册中文字体并切换 theme 字体族。dvui 内置字体（Vera 等）无 CJK 字形。
/// 优先级：工程 fonts/ 目录（便于日后随包分发）→ Windows 系统黑体。
pub fn loadCjkFont(win: *dvui.Window, gpa: std.mem.Allocator, io: std.Io) void {
    const candidates = [_][]const u8{
        "fonts/simhei.ttf",
        "fonts/NotoSansSC-Regular.ttf",
        "C:\\Windows\\Fonts\\simhei.ttf",
        "C:\\Windows\\Fonts\\msyh.ttc",
    };
    for (candidates) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch continue;
        win.addFont("ZMindCJK", data, gpa) catch {
            gpa.free(data); // addFont 失败时未接管内存
            continue;
        };
        // 字体族名与 addFont 的 name 对应，字号/行高沿用 theme 原值
        win.theme.font_body = win.theme.font_body.withFamily("ZMindCJK");
        win.theme.font_heading = win.theme.font_heading.withFamily("ZMindCJK");
        win.theme.font_title = win.theme.font_title.withFamily("ZMindCJK");
        std.log.info("CJK font loaded: {s}", .{path});
        return;
    }
    std.log.err("no CJK font found, Chinese text will render as boxes", .{});
}
