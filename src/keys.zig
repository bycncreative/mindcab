//! 全局按键分发：帧首（控件绘制前）与帧末（控件绘制后）两次遍历 dvui 事件。
//!
//! 为什么必须分两段（对照 test/report.md 缺陷 1/2/4/6）：
//! - dvui 的 TextEntry 会把所有没被消费的按键标记 handled
//!   （TextEntryWidget.zig 1258 行起），帧末循环 `if (e.handled) continue`
//!   就收不到 —— 所以「编辑中按 Esc」「焦点在侧栏文本框时按 Insert」
//!   这类键必须在控件绘制**之前**抢下来（缺陷 1 / 6）。
//! - 画布滚动区处理 PageUp/PageDown 时不看 Ctrl 修饰
//!   （ScrollContainerWidget.zig 645 行起），同样要在帧首抢（缺陷 4）。
//! - 模态对话框在 Window.end 阶段才绘制并消费按键，比 guiFrame 晚一拍；
//!   它关闭的那次按键若被帧末循环当成快捷键就是按键泄漏（缺陷 2），
//!   所以对话框打开期间帧末只保留窗口关闭事件。
const std = @import("std");
const dvui = @import("dvui");
const app_mod = @import("app.zig");

/// 是否有 dvui 模态对话框（关于框 / 自定义确认框）正在打开。
/// 锁 dialogs.mutex：对话框登记（dialogAdd）的约定是加锁后由调用方解锁，
/// 读 stack 也要按同一把锁走。
pub fn anyDialogOpen() bool {
    const d = &dvui.currentWindow().dialogs;
    const io = dvui.io;
    d.mutex.lockUncancelable(io);
    defer d.mutex.unlock(io);
    return d.stack.items.len > 0;
}

/// 帧首全局按键（控件绘制之前）。对应缺陷 1 / 4 / 6。
///
/// 在这里标记 handled 的键，dvui 的 eventMatch 会直接跳过，
/// 后面的 TextEntry / 滚动区就收不到了 —— 这正是目的。
pub fn beforeWidgets(app: *app_mod.App) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.action != .down) continue;
        // 模态对话框打开时按键全部让给它（Esc 关 Ctrl+Z 也归对话框）。
        // 这里原本一声不吭，症状就是「按 Insert 完全没反应」，
        // 所以 Insert 单独给一句状态栏提示，免得跟别的原因混在一起。
        if (anyDialogOpen()) {
            if (ke.code == .insert) app.setStatus("有对话框开着：先关掉它才能插入子节点");
            continue;
        }

        const ctrl = ke.mod.has(.lcontrol) or ke.mod.has(.rcontrol);
        const shift = ke.mod.has(.lshift) or ke.mod.has(.rshift);

        // 缺陷 1：画布内联编辑中 Esc 取消编辑。必须在帧首抢——
        // 等控件画完，TextEntry 已把 Esc 标记 handled，帧末循环收不到。
        if (app.editing != .none and ke.code == .escape) {
            e.handled = true;
            app.cmdCancelEdit();
            continue;
        }

        if (ctrl) {
            switch (ke.code) {
                // 撤销/重做是应用级动作，优先于输入框自身处理（编辑中也生效）
                .z => {
                    e.handled = true;
                    if (shift) app.cmdRedo() else app.cmdUndo();
                },
                .y => {
                    e.handled = true;
                    app.cmdRedo();
                },
                // 缺陷 4：焦点在画布时滚动区会吞掉 PageUp/Down（不看 Ctrl），
                // 提到帧首抢。编辑中不切标签（与原帧末循环语义一致）。
                .tab, .page_down => if (app.editing == .none) {
                    e.handled = true;
                    app.cmdNextTab();
                },
                .page_up => if (app.editing == .none) {
                    e.handled = true;
                    app.cmdPrevTab();
                },
                else => {},
            }
            continue; // 其余 Ctrl 组合（Ctrl+N/O/S/W 等）留给帧末循环
        }

        // 编辑中：其余按键全部让给内联输入框。
        // 但 Insert 在这里确实被挡住了——不吭声的话用户看到的就是
        // 「节点明明选中了，按 Insert 却没反应」，所以给一句状态栏提示说明去向。
        if (app.editing != .none) {
            if (ke.code == .insert) app.setStatus("正在编辑标题：Enter 确认 / Esc 取消后才能插入子节点");
            continue;
        }

        // 缺陷 6：裸 Insert 插入子节点。焦点在侧栏文本框时它会把不认识的
        // 按键一律标记 handled（焦点为空时 eventMatch 甚至不做焦点过滤），
        // 帧末收不到；Insert 在文本编辑里没有用途，帧首抢是安全的。
        // shift+Insert 是 dvui 的粘贴（paste_1），留给文本框。
        if (ke.code == .insert and !shift) {
            e.handled = true;
            app.cmdAddChild();
        }
    }
}

/// 帧末全局按键 + 窗口关闭（控件绘制之后，只捡没人处理的）。
///
/// 对话框打开期间跳过全部按键（缺陷 2）：对话框在 Window.end 才绘制，
/// 它消费/关闭按键发生在本函数之后，这里先动手就会把关闭对话框的
/// 那次按键（如 Enter）泄漏成「加同级节点」。
pub fn afterWidgets(app: *app_mod.App) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .window => |we| {
                // 窗口关闭不受对话框门控：确认框本身就是它弹出来的
                if (we.action == .close) app.cmdRequestQuit();
            },
            .key => |ke| {
                if (ke.action != .down) continue;
                if (anyDialogOpen()) continue;
                // 画布内联编辑中：Enter/Esc 归输入框与编辑命令（Esc 已在
                // 帧首处理），其余快捷键一律让位，否则打字时按
                // Insert/Enter/Delete 会误触发加节点 / 删节点
                if (app.editing != .none) continue;
                // 【扩展点】加快捷键只需在此 switch 加一行
                const ctrl = ke.mod.has(.lcontrol) or ke.mod.has(.rcontrol);
                const shift = ke.mod.has(.lshift) or ke.mod.has(.rshift);
                if (ctrl) {
                    switch (ke.code) {
                        .n => {
                            e.handled = true;
                            app.cmdNewDoc() catch app.setStatus("新建失败：内存不足");
                        },
                        .o => {
                            e.handled = true;
                            app.pending_file_action = .open;
                        },
                        .s => {
                            e.handled = true;
                            app.pending_file_action = if (shift) .save_as else .save;
                        },
                        .w => {
                            e.handled = true;
                            app.cmdCloseTab(app.active);
                        },
                        // 复制/粘贴节点：焦点在侧栏文本框时 dvui 的 TextEntry 会
                        // 先把这两个键标 handled（走的是文本复制粘贴），到不了这里；
                        // 万一它没消费（没选中文字），也不该退化成「复制/粘贴节点」，
                        // 所以用 text_focus_id 再挡一道。
                        .c => if (app.text_focus_id == 0) {
                            e.handled = true;
                            app.cmdCopySelected();
                        },
                        .v => if (app.text_focus_id == 0) {
                            e.handled = true;
                            app.cmdPasteNode();
                        },
                        // 撤销/重做、Ctrl+Tab、Ctrl+PageUp/PageDown 已在帧首
                        // 处理（见 beforeWidgets），焦点在文本框里时这里收不到
                        else => {},
                    }
                } else switch (ke.code) {
                    .delete => {
                        e.handled = true;
                        app.cmdDeleteSelected();
                    },
                    .insert => {
                        e.handled = true;
                        app.cmdAddChild();
                    },
                    // 键帽写 Ins、实际以扫描码 0x52（不带 E0 扩展位）到达的键盘
                    // ——SDL 归类成小键盘 kp_0，实测 zmind 的 Insert 对它是死的。
                    // 必须放帧末而不是帧首：焦点在文本框里时 TextEntry 会先把它
                    // 标 handled（见 TextEntryWidget.zig 1261 起），打字输 0 不受影响；
                    // 只有「谁都没要这个键」时，才把它当成 Insert。
                    .kp_0 => {
                        e.handled = true;
                        app.cmdAddChild();
                    },
                    .enter, .kp_enter => {
                        e.handled = true;
                        app.cmdAddSibling();
                    },
                    .escape => {
                        // Esc 清空选中（多选集合与连线一起）；编辑态的 Esc
                        // 已在帧首取消编辑，不会走到这里
                        e.handled = true;
                        app.doc().selectionClear();
                        app.setStatus("已取消选择");
                    },
                    else => {},
                }
                // 按键诊断：键到了 dvui、控件没收、我们也没有任何绑定 →
                // 说明收到的键码不是预期的那个（典型：键帽写 Ins、实际发出来
                // 的是小键盘 kp_0 或 Fn 层的别的键）。状态栏直接点名，
                // 「完全没变化」则说明 SDL 压根没收到这个键。
                if (!e.handled) traceUnhandled(app, ke, ctrl, shift);
            },
            else => {},
        }
    }
}

/// zmind 没有绑定动作的「功能类」按键：它们到达了却没人处理时才值得喊一声。
///
/// 字母/数字/标点/空格/回车/Esc/方向键/大小写锁这些不看 ——
/// 打字时它们没被消费是常态，逐个上报会把状态栏刷成噪音。
fn watchKey(code: dvui.enums.Key) bool {
    return switch (code) {
        .insert,
        .delete,
        .unknown,
        .home,
        .end,
        .page_up,
        .page_down,
        .print,
        .menu,
        .pause,
        .scroll_lock,
        .kp_enter,
        .kp_divide,
        .kp_multiply,
        .kp_subtract,
        .kp_add,
        .kp_decimal,
        .kp_0,
        .kp_1,
        .kp_2,
        .kp_3,
        .kp_4,
        .kp_5,
        .kp_6,
        .kp_7,
        .kp_8,
        .kp_9,
        .f1,
        .f2,
        .f3,
        .f4,
        .f5,
        .f6,
        .f7,
        .f8,
        .f9,
        .f10,
        .f11,
        .f12,
        => true,
        else => false,
    };
}

/// 把「收到了没人要的键」写进状态栏。读法：
/// - 状态栏出现「按键 XXX 未处理」→ SDL 收到了，但键码不是 .insert
///   （看 XXX：kp_0 = 小键盘 0/Ins，unknown = Fn 层或映射不到的键）；
/// - 状态栏是「正在编辑标题…」/「有对话框开着…」→ 收到了且确实是 Insert，被门挡了；
/// - 状态栏纹丝不动（还停在「已选中节点…」）→ dvui 根本没收到这个键，
///   问题在键盘/焦点，不在 zmind 的快捷键逻辑。
fn traceUnhandled(app: *app_mod.App, ke: dvui.Event.Key, ctrl: bool, shift: bool) void {
    if (!watchKey(ke.code)) return;
    const prefix = if (ctrl) "Ctrl+" else if (shift) "Shift+" else "";
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "按键 {s}{s} 未处理（没有这个绑定）", .{
        prefix,
        @tagName(ke.code),
    }) catch return;
    app.setStatus(msg);
}
