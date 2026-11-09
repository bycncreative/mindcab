//! 把一张 PNG 打包成单条目 .ico（条目数据就是原 PNG，Vista+ 全支持）。
//! 仓库里的 src/assets/zmind.ico 由 src/assets/logo64x64.png 生成：
//!   zig run tools/make_ico.zig -- src/assets/logo64x64.png src/assets/zmind.ico
//! logo 更新后重跑一次；.ico 作为产物提交进仓库，构建不再现场生成。
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]
    const in_path = args.next() orelse return error.MissingInputPath;
    const out_path = args.next() orelse return error.MissingOutputPath;

    const png = try std.Io.Dir.cwd().readFileAlloc(init.io, in_path, init.gpa, .unlimited);
    defer init.gpa.free(png);
    if (png.len > std.math.maxInt(u32)) return error.ImageTooBig;

    // 校验 PNG 签名，并从 IHDR（大端）取宽高写进目录条目
    if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.NotAPng;
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    if (w > 256 or h > 256) return error.IconSizeTooBig;

    var ico = try init.gpa.alloc(u8, 22 + png.len);
    defer init.gpa.free(ico);
    // ICONDIR：保留(0) / 类型 1=图标 / 条目数 1
    std.mem.writeInt(u16, ico[0..2], 0, .little);
    std.mem.writeInt(u16, ico[2..4], 1, .little);
    std.mem.writeInt(u16, ico[4..6], 1, .little);
    // ICONDIRENTRY：宽/高（256 记 0）、调色板色数 0、保留 0、平面数 1、位深 32、数据长、数据偏移
    ico[6] = if (w == 256) 0 else @intCast(w);
    ico[7] = if (h == 256) 0 else @intCast(h);
    ico[8] = 0;
    ico[9] = 0;
    std.mem.writeInt(u16, ico[10..12], 1, .little);
    std.mem.writeInt(u16, ico[12..14], 32, .little);
    std.mem.writeInt(u32, ico[14..18], @intCast(png.len), .little);
    std.mem.writeInt(u32, ico[18..22], 22, .little); // 6 字节 ICONDIR + 16 字节条目
    @memcpy(ico[22..], png);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = ico });
    std.debug.print("{s}: {d}x{d} png ({d} bytes) -> {s}\n", .{ in_path, w, h, png.len, out_path });
}
