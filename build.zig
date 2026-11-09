const std = @import("std");

pub fn build(b: *std.Build) void {
    // 发布包要能在别人的机器上跑，默认不能用 host 的 native CPU：
    // 本机是 AMD A8-5600K（LLVM 型号 bdver2），native 会打开 XOP/FMA4/TBM，
    // 而 Intel 从未支持过这三组指令、AMD Zen 之后也已移除，优化构建一执行就
    // 0xC000001D（非法指令）。x86_64_v2（SSE4.2/POPCNT）2009 年后的 x64 都支持。
    // 需要更快/更保守时用 -Dcpu=x86_64_v3 或 -Dcpu=baseline 覆盖。
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 } },
    });
    const optimize = b.standardOptimizeOption(.{});

    // dvui + SDL3 后端。
    // .backend 决定 dvui 构建哪个后端模块（dvui_sdl3 / sdl3）。
    // 注意：SDL2 后端在 Windows + Zig 0.16.0 下会引用已被 std 移除的
    // std.os.windows.advapi32（Window.init 查询系统深浅色时触发），故必须用 SDL3。
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = "sdl3",
    });
    const dvui_mod = dvui_dep.module("dvui_sdl3");
    const sdl_backend_mod = dvui_dep.module("sdl3");

    const exe = b.addExecutable(.{
        // 产物名即发布名：zig-out/bin/mindcab.exe（调试构建为 mindcab.pdb）。
        // 名字必须在构建期就定下来，不要发布时手动改名——否则 exe 资源里的
        // OriginalFilename 会和实际文件名不一致，反而更像“伪装”而被杀软扣分。
        .name = "mindcab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // 源码里写 `@import("dvui")` / `@import("sdl-backend")`
                .{ .name = "dvui", .module = dvui_mod },
                .{ .name = "sdl-backend", .module = sdl_backend_mod },
            },
        }),
    });

    // Windows GUI 程序：无控制台窗口（启动不闪黑框），
    // 并由 main.manifest 声明 PerMonitorV2 DPI 感知（否则高 DPI 下界面糊）。
    exe.subsystem = .windows;
    exe.win32_manifest = b.path("src/main.manifest");
    // exe 资源图标（app.rc -> assets/zmind.ico）：资源管理器/任务栏显示。
    // 非 PE 目标会被构建系统自动忽略，无需平台判断。
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/app.rc") });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // 多文档（标签页）逻辑的单元测试：App 里每个标签的状态必须互相隔离，
    // 这类回归靠手点很难发现，所以固化成 `zig build test`。
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_mod },
                // app_test 要驱动 canvas.draw（内联编辑、节点框的回归测试），
                // canvas.zig 引用了 SDL 后端（双击计时用 SDL_GetTicks）
                .{ .name = "sdl-backend", .module = sdl_backend_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
