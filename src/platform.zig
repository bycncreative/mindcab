//! zmind 平台相关辅助：Windows 控制台挂接、CJK 字体加载、系统剪贴板位图读取。
//! 与业务无关的系统胶水代码集中于此。
const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

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

// ---------------------------------------------------------------------------
// 系统剪贴板位图（Ctrl+V 粘贴图片）
// ---------------------------------------------------------------------------

/// Windows BITMAPINFOHEADER（CF_DIB 的开头一段）。
const BitmapInfoHeader = extern struct {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bit_count: u16,
    compression: u32,
    size_image: u32,
    x_pels_per_meter: i32,
    y_pels_per_meter: i32,
    clr_used: u32,
    clr_important: u32,
};

const CF_DIB: u32 = 8;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;

/// 从 Windows 剪贴板读位图（CF_DIB：截图 / 浏览器「复制图片」的载体），
/// 编码成 PNG 返回（新分配，调用方负责 free）。
/// dvui/SDL 的剪贴板只暴露文本，位图只能直接走 user32。
/// 剪贴板里没有位图、或格式不支持（调色板 / 16bpp / RLE 等）时返回 null。
/// 仅 Windows；其他平台永远返回 null（调用方按「没有可粘贴内容」提示）。
pub fn clipboardImagePng(gpa: Allocator) ?[]u8 {
    if (comptime builtin.target.os.tag != .windows) return null;
    const win = struct {
        extern "user32" fn OpenClipboard(hWndNewOwner: ?*anyopaque) i32;
        extern "user32" fn CloseClipboard() i32;
        extern "user32" fn IsClipboardFormatAvailable(format: u32) i32;
        extern "user32" fn GetClipboardData(format: u32) ?*anyopaque;
        extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) ?*anyopaque;
        extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) i32;
        extern "kernel32" fn GlobalSize(hMem: ?*anyopaque) usize;
    };
    if (win.IsClipboardFormatAvailable(CF_DIB) == 0) return null;
    if (win.OpenClipboard(null) == 0) return null;
    defer _ = win.CloseClipboard();
    const handle = win.GetClipboardData(CF_DIB) orelse return null;
    const size = win.GlobalSize(handle);
    if (size == 0) return null;
    const locked = win.GlobalLock(handle) orelse return null;
    defer _ = win.GlobalUnlock(handle);
    const dib = @as([*]const u8, @ptrCast(locked))[0..size];
    return dibToPng(gpa, dib) catch null;
}

/// CF_DIB 内存 → PNG（RGBA 交错，dvui.PNGEncoder 同一编码器）。
/// 支持 24/32bpp 的 BI_RGB 与 32bpp 的 BI_BITFIELDS；height 正 = 自底向上行序，
/// 负 = 自顶向下。GDI 截图常见「alpha 全 0」按不透明处理，否则整张图全透明。
fn dibToPng(gpa: Allocator, dib: []const u8) ![]u8 {
    if (dib.len < @sizeOf(BitmapInfoHeader)) return error.BadDib;
    const hdr: *const BitmapInfoHeader = @alignCast(@ptrCast(dib.ptr));
    const w: usize = @intCast(@abs(hdr.width));
    const h: usize = @intCast(@abs(hdr.height));
    const bpp: usize = hdr.bit_count;
    if (w == 0 or h == 0 or w > 65535 or h > 65535) return error.BadDib;
    if (bpp != 24 and bpp != 32) return error.UnsupportedDib;
    if (hdr.compression != BI_RGB and hdr.compression != BI_BITFIELDS) return error.UnsupportedDib;
    // 像素数据偏移：40 字节 BITMAPINFOHEADER +（BI_BITFIELDS 且旧头时跟 3 个掩码）
    var pixel_off: usize = hdr.size;
    if (hdr.compression == BI_BITFIELDS and hdr.size == 40) pixel_off += 12;
    const row_bytes = ((w * bpp / 8) + 3) & ~@as(usize, 3); // DIB 行按 4 字节对齐
    if (pixel_off + row_bytes * h > dib.len) return error.BadDib;
    const top_down = hdr.height < 0;

    const rgba = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(rgba);
    var alpha_seen = false;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src_y = if (top_down) y else h - 1 - y;
        const row = dib[pixel_off + src_y * row_bytes ..][0 .. w * bpp / 8];
        const dst = rgba[y * w * 4 ..][0 .. w * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (bpp == 32) {
                // DIB 是 BGRA：通道交换
                dst[x * 4 + 0] = row[x * 4 + 2];
                dst[x * 4 + 1] = row[x * 4 + 1];
                dst[x * 4 + 2] = row[x * 4 + 0];
                dst[x * 4 + 3] = row[x * 4 + 3];
                if (row[x * 4 + 3] != 0) alpha_seen = true;
            } else {
                dst[x * 4 + 0] = row[x * 3 + 2];
                dst[x * 4 + 1] = row[x * 3 + 1];
                dst[x * 4 + 2] = row[x * 3 + 0];
                dst[x * 4 + 3] = 255;
            }
        }
    }
    if (bpp == 32 and !alpha_seen) {
        var i: usize = 3;
        while (i < rgba.len) : (i += 4) rgba[i] = 255;
    }
    // 分辨率 0 = 不写 pHYs chunk（与窗口缩放无关，剪贴板图不必标 dpi）
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, @max(4096, dvui.PNGEncoder.min_buffer_size));
    defer aw.deinit();
    try dvui.PNGEncoder.writeWithResolution(&aw.writer, rgba, @intCast(w), @intCast(h), 0);
    return try gpa.dupe(u8, aw.writer.buffered()[0..aw.writer.end]);
}
