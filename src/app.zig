//! zmind 应用状态与命令层。
//!
//! 【扩展点】所有对文档的修改都集中在本文件的 cmd* 方法中：
//! 将来要加 撤销/重做（undo/redo）、自动保存、变更日志、协作同步，
//! 只需在这里包一层，不动 UI 与模型代码。
//!
//! 【多文档】App 不再直接持有脑图树，而是持有 docs 数组（一个元素 = 一个标签页）
//! 和当前标签下标 active；所有命令都作用在 doc() 返回的当前文档上。
//! 关闭标签时会释放该标签的整棵节点树，切换标签不动任何数据。
const std = @import("std");
const dvui = @import("dvui");
const model = @import("model.zig");
const xml = @import("xml.zig");
const layout = @import("layout.zig");
const docx = @import("docx.zig");
const markdown = @import("markdown.zig");
const recent_files = @import("recent_files.zig");
const platform = @import("platform.zig");
const zstring = @import("zstring.zig");

const Allocator = std.mem.Allocator;

/// 应用版本号（「帮助 → 关于」对话框展示）。
pub const app_version = "2.0.1";

/// 作者联系方式（「帮助 → 关于」对话框展示）。
pub const app_author = "bingyecn@163.com";

/// 微信公众号二维码（「帮助 → 关于」展示）。@embedFile 编进 exe，
/// 发布单文件即可；替换 src/assets/wxqrcode.jpg 后重新构建即生效。
pub const wxqrcode_jpg = @embedFile("assets/wxqrcode.jpg");

/// 帧末执行的阻塞式文件操作。
/// 打开/保存对话框是阻塞式的：若在菜单项点击的同一帧内直接弹出，
/// 会打断 dvui 菜单的关闭流程（菜单残留在屏幕上）。
/// 因此菜单/工具栏只把意图挂到 App.pending_file_action，
/// 帧末由 main 调 App.runPendingFileAction 统一执行。
pub const FileAction = enum { none, open, save, save_as, export_png, export_docx, export_md, pick_image };

/// 导出目标的格式。pick 与真正导出分两帧进行，格式要跟着 pending_export_path
/// 一起挂号（见 pending_export_kind）。
pub const ExportKind = enum { png, docx, md };

/// 一次拖拽（移动/重挂父）里被拖的顶层节点：id + 拖动开始时的用户偏移。
/// 松手落到无效位置时按它恢复原位。
pub const DragEntry = struct {
    id: u32,
    ox0: f32,
    oy0: f32,
};

/// 空白处框选的矩形（画布坐标，x0/y0 = 按下点，x1/y1 = 当前鼠标点）。
/// add = shift 按下：不清空已有选择，在原集合上追加。
pub const RubberBand = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    add: bool,
};

/// 帧末执行的标签页操作。标签的增删会改动 docs 数组，
/// 必须等本帧 UI（标签栏正在遍历 docs）画完再做。
pub const TabAction = enum { none, new, close };

/// 画布内联编辑的目标：双击节点改标题，双击连线改连线标题。
pub const EditKind = enum { none, node_title, edge_title };

/// 节点缩放把手：右边缘（只调宽）/ 下边缘（只调高）/ 右下角（都调）/ 无。
/// 布局按层级锚定节点 x、按子树居中锚定 y，向左/上长会打乱自动布局，故不提供。
pub const ResizeEdge = enum { none, e, s, se };

/// 双击判定参数：两次按下的最大间隔与最大位移（画布坐标）。
pub const dbl_click_max_ms: i64 = 400;
pub const dbl_click_max_dist: f32 = 6;

/// 侧栏「正文描述」输入框的高度上下限（拖输入框下方的把手调整）。
pub const note_editor_min_h: f32 = 48;
pub const note_editor_max_h: f32 = 600;

/// 「正文描述」输入框的最大宽度占视图（窗口）宽度的比例，缺省 20%。
/// 输入框宽度钳到该值，超出的文本自动折行（ui.drawSidePanel 的 break_lines）。
pub const note_editor_max_w_frac: f32 = 0.20;

/// 「下一级节点」列表的最大宽度占视图（窗口）宽度的比例，缺省 20%。
pub const child_list_max_w_frac: f32 = 0.20;

/// 「有未保存修改」确认框的种类。
const ConfirmKind = enum(u8) { close_tab = 1, quit = 2 };

/// 用户对「有未保存修改」的回答。
const ConfirmChoice = enum(u8) { save, discard, cancel };

/// dvui 对话框的显示函数在 Window.end 阶段执行，拿不到 App 指针参数，
/// 所以用模块级变量中转：显示函数写结果，下一帧开头 App.runPendingConfirm 消费。
var pending_confirm: ?struct { kind: ConfirmKind, choice: ConfirmChoice, index: usize } = null;

/// 确认框文案缓冲区（同时只弹一个确认框，够用）。
var confirm_msg_buf: [256]u8 = @splat(0);

/// 标签标题格式化缓冲区（docTitle 返回切片的目标，须与 confirm_msg_buf
/// 同生命周期策略：模块级，调用方当场消费）。
var title_buf: [64]u8 = @splat(0);

/// 导出对话框初始文件名的缓冲（exportDialogStartPath 返回切片的目标，
/// 调用方当场传给系统对话框，一次性消费；PNG / docx 对话框共用，同帧只会开一个）。
var export_start_buf: [512]u8 = @splat(0);

// ---------------------------------------------------------------------------
// 撤销/重做：镜像快照
// ---------------------------------------------------------------------------

/// 撤销栈上限（每份是整棵树的深拷贝；50 步足够日常编辑，内存也不会失控）。
const undo_depth: usize = 50;

/// 一步操作的镜像：整棵树的深拷贝 + 与树绑定的状态。
///
/// 采用**镜像**而非增量：任何会改文档的命令在动手之前先把当前整棵树复制一份，
/// 撤销时把整棵树换回去。好处是命令层加新命令不必再写一份反向操作，
/// 也不会出现「某种修改忘了记增量」导致撤销后状态错乱。
pub const Snapshot = struct {
    root: *model.Node,
    next_id: u32,
    selected_id: ?u32,
    selected_edge_id: ?u32,
};

// ---------------------------------------------------------------------------
// 单个标签页（文档）的状态
// ---------------------------------------------------------------------------

/// 一个文档标签页：节点树 + 选中项 + 路径 + 脏标记 + 自己的滚动位置。
/// 这些字段全部随标签独立，切换标签只是换下标，不会互相污染。
pub const Doc = struct {
    gpa: Allocator,
    root: *model.Node,
    next_id: u32 = 1,
    selected_id: ?u32 = null,
    /// 多选集合（含主选中）。单选时只有 selected_id 一项；
    /// 框选 / shift+点击 会放入多个 id。selected_id 永远是其中之一（主选中，
    /// 侧栏属性面板、滚动定位、就地编辑都作用在它上面）。
    selected_ids: std.ArrayList(u32) = .empty,
    /// 当前选中的连线（以边的子节点 id 表示），用于高亮
    selected_edge_id: ?u32 = null,
    dirty: bool = false,
    path_buf: [512]u8 = @splat(0),
    /// 未命名文档的编号（新建后从未保存过的文档）
    untitled: u32 = 0,
    /// 每个标签各自记住自己的滚动位置
    scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
    /// 撤销栈（越靠后越新）与重做栈；每个标签各有一套
    undo_stack: std.ArrayList(Snapshot) = .empty,
    redo_stack: std.ArrayList(Snapshot) = .empty,
    /// 文档图片池：节点只存 img_ref（id），图片数据集中在这里。
    /// 不参与撤销快照（只增不删：撤销把引用撤掉后，重做还能找回同一份数据）。
    images: model.ImageStore = .{},
    /// 文档字符串池：Node.text/note/link（不可变 ZString）的字节唯一所有者。
    /// 与图片池同理不入快照——快照树与当前树按引用共享字符串，只有「改值」
    /// 才构造新串；废弃的旧版本由 gcStrings 的 mark-sweep 回收（根集合见该函数）。
    /// StringStore 无自引用指针，docs 数组扩容搬移 Doc 是安全的。
    strings: zstring.StringStore,

    pub fn deinit(self: *Doc, gpa: Allocator) void {
        self.root.deinit(gpa);
        for (self.undo_stack.items) |*s| s.root.deinit(gpa);
        for (self.redo_stack.items) |*s| s.root.deinit(gpa);
        self.undo_stack.deinit(gpa);
        self.redo_stack.deinit(gpa);
        self.selected_ids.deinit(gpa);
        self.images.deinit(gpa);
        self.strings.deinit();
    }

    /// id 是否在多选集合里。
    pub fn isSelected(self: *const Doc, id: u32) bool {
        return std.mem.indexOfScalar(u32, self.selected_ids.items, id) != null;
    }

    /// 单选：清空多选集合，只选中 id（主选中同步）。
    pub fn selectSingle(self: *Doc, id: u32) void {
        self.selected_ids.clearRetainingCapacity();
        self.selected_ids.append(self.gpa, id) catch {};
        self.selected_id = id;
        self.selected_edge_id = null;
    }

    /// 加入多选（已在内则不动）；集合为空时它成为主选中。
    pub fn selectAdd(self: *Doc, id: u32) void {
        if (self.isSelected(id)) return;
        self.selected_ids.append(self.gpa, id) catch return;
        if (self.selected_id == null) self.selected_id = id;
    }

    /// 从多选集合移除；主选中被移走时退到集合剩余的最后一个（没有则 null）。
    pub fn selectRemove(self: *Doc, id: u32) void {
        if (std.mem.indexOfScalar(u32, self.selected_ids.items, id)) |idx| {
            _ = self.selected_ids.orderedRemove(idx);
        }
        if (self.selected_id == id) {
            self.selected_id = if (self.selected_ids.items.len > 0)
                self.selected_ids.items[self.selected_ids.items.len - 1]
            else
                null;
        }
    }

    /// 清空全部选中（节点多选集合与连线选中一起清）。
    pub fn selectionClear(self: *Doc) void {
        self.selected_ids.clearRetainingCapacity();
        self.selected_id = null;
        self.selected_edge_id = null;
    }

    /// 文件路径（从未保存过的文档为空串）
    pub fn pathSlice(self: *const Doc) []const u8 {
        return self.path_buf[0..strLen(&self.path_buf)];
    }

    pub fn hasPath(self: *const Doc) bool {
        return self.pathSlice().len > 0;
    }

    /// 覆盖式写入文件路径；返回 false 表示路径过长。
    pub fn setPath(self: *Doc, path: []const u8) bool {
        if (path.len == 0 or path.len >= self.path_buf.len) return false;
        @memset(&self.path_buf, 0);
        @memcpy(self.path_buf[0..path.len], path);
        return true;
    }

    /// 标签标题：保存过的取文件名，否则「未命名N」。写入 out，不分配内存。
    pub fn title(self: *const Doc, out: []u8) []const u8 {
        const p = self.pathSlice();
        if (p.len == 0) {
            return std.fmt.bufPrint(out, "未命名{d}", .{self.untitled}) catch out[0..0];
        }
        return std.fmt.bufPrint(out, "{s}", .{baseName(p)}) catch out[0..0];
    }
};

/// 取路径里的文件名部分（同时认 / 与 \）。
fn baseName(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 0) {
        const c = p[end - 1];
        if (c == '/' or c == '\\') break;
        end -= 1;
    }
    return p[end..];
}

/// 以指定扩展名结尾的路径（大小写不敏感；没有就补上）。新分配，调用方负责 free。
pub fn pathWithExt(alloc: Allocator, path: []const u8, ext: []const u8) ![]u8 {
    var dot_buf: [16]u8 = undefined;
    const dot_ext = try std.fmt.bufPrint(&dot_buf, ".{s}", .{ext});
    if (std.ascii.endsWithIgnoreCase(path, dot_ext)) return alloc.dupe(u8, path);
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, ext });
}

/// 把 n（含子树）的 id 从 *next 依次重新分配。粘贴节点片段时用，
/// 避免剪贴板文本里的旧 id 与文档现有 id 冲突。
fn reassignIds(n: *model.Node, next: *u32) void {
    n.id = next.*;
    next.* += 1;
    for (n.children.items) |c| reassignIds(c, next);
}

/// 框选矩形与节点几何是否相交（边界相接不算）。
fn rectHitsGeom(r: dvui.Rect, g: model.Geometry) bool {
    return r.x < g.x + g.w and g.x < r.x + r.w and r.y < g.y + g.h and g.y < r.y + r.h;
}

// ---------------------------------------------------------------------------
// 应用状态
// ---------------------------------------------------------------------------

/// 应用状态。用 struct 而非散落的全局变量：便于测试、也便于支持多文档标签。
pub const App = struct {
    gpa: Allocator,
    io: std.Io,

    // ---- 多文档（标签页）----
    /// 打开的文档列表，顺序即标签栏从左到右的顺序
    docs: std.ArrayList(Doc) = .empty,
    /// 当前标签下标（始终有效：关掉最后一个会自动补一个新示例文档）
    active: usize = 0,
    /// 新建未命名文档的编号（未命名1、未命名2……）
    next_untitled: u32 = 1,
    /// 文件对话框的初始路径（当前文档没有路径时用它）
    last_path_buf: [512]u8 = @splat(0),
    /// 最近打开的文件（文件菜单「最近打开的文件」子菜单）。历史落盘于
    /// %USERPROFILE%/.mindcab/history.toml，启动时由 main 调 loadFrom 载入，
    /// 打开/保存成功时经 recordRecent 记录并整份重写。
    recent: recent_files.RecentFiles = undefined,

    // ---- 界面状态 ----
    pending_file_action: FileAction = .none,
    pending_tab_action: TabAction = .none,
    pending_tab_index: usize = 0,
    /// 命令层改过选中项（加节点 / 撤销 / 重做…）：下一帧画布把选中节点滚进视野。
    /// 只有这个标志触发滚动，避免「用户自己滚走后又被拉回来」。
    reveal_selected: bool = false,
    /// 导出 PNG 时用户选的路径（由 runPendingFileAction 写入、runPendingExport 消费）。
    /// 整个生命周期只持有一个：导出成功或失败即清空。需要在 runPendingExport 后 free。
    pending_export_path: ?[]u8 = null,

    // ---- 系统剪贴板（Ctrl+C / Ctrl+V，见 cmdCopySelected / cmdPasteNode）----
    /// 复制 = 序列化 `<node>…</node>` 写进系统剪贴板；粘贴 = 读剪贴板按内容分派
    /// （节点 XML / 图片路径 / 普通文本 / 位图）。App 不保存剪贴板副本。
    /// pending_export_path 对应的导出格式，runPendingExport 按它分派。
    pending_export_kind: ExportKind = .png,
    /// 选图（FileAction.pick_image）的目标节点 id：挂起时记录，
    /// 帧末对话框返回后把图片读进该节点（读文件是阻塞操作，同款帧末执行）。
    pending_image_target_id: ?u32 = null,

    // ---- 画布内联编辑（双击节点标题 / 双击连线标题）----
    /// 正在编辑的目标。node_title 用 editing_id 指向节点；
    /// edge_title 用 editing_id 指向「边的子节点」（边 = 父 → 该节点）。
    editing: EditKind = .none,
    editing_id: u32 = 0,
    /// 刚进入编辑的第一帧：聚焦输入框并全选原文本（之后不再重置光标）
    edit_armed: bool = false,
    /// 进入编辑前的原文本，Esc 取消时回滚
    edit_backup: [512]u8 = @splat(0),
    edit_backup_len: usize = 0,

    // ---- 双击判定（dvui 没有双击事件，用 SDL 毫秒自行判定）----
    last_click_ms: i64 = -9999,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,
    /// 上次点击目标：高 32 位 EditKind、低 32 位节点 id，0 表示无记录
    last_click_target: u64 = 0,

    status_buf: [256]u8 = @splat(0),
    want_quit: bool = false,

    // ---- 拖拽状态（记录起始鼠标位置与各节点初始偏移）----
    drag_mouse_x: f32 = 0,
    drag_mouse_y: f32 = 0,
    /// 本次拖拽（移动或重挂父）涉及的顶层节点：id + 拖动前的用户偏移。
    /// 单选拖动只有一项；多选拖动/重挂父是「没有选中祖先」的那些选中节点。
    drag_entries: std.ArrayList(DragEntry) = .empty,
    /// 本次移动拖拽是否已压过快照（按下时不知道用户是点击还是拖动，
    /// 等第一次真正拖动再压，避免单击也留一个空的撤销步）。
    /// 重挂父拖拽不在这里压——成功落到新父节点下时 cmdReparentSelected 统一压。
    drag_snapshot_pushed: bool = false,
    /// true = shift 重挂父拖拽进行中（被拖节点与旧父的连线暂不绘制）。
    reparent_drag: bool = false,
    /// 重挂父拖拽中是否真的移动过（区分 shift+点击多选 与 shift+拖动重挂）。
    reparent_moved: bool = false,
    /// shift 按下时节点原本是否已在多选里（松手没拖 → 把它移出多选）。
    reparent_was_selected: bool = false,
    /// 重挂父拖拽中的鼠标位置（画布坐标）：画布据此高亮当前落点目标节点。
    reparent_mx: f32 = 0,
    reparent_my: f32 = 0,
    /// 图片区已按下、等松手才打开预览的节点 id（0 = 无挂起）。
    /// 预览不能在 press 时打开：模态框会吞掉这次点击的 release。
    image_press_id: u32 = 0,

    /// 侧栏「下一级节点」列表的拖动排序状态：正在拖的子节点当前下标
    /// （null = 没在拖）。换位时 seq 实时写入列表下标。
    seq_drag_index: ?usize = null,
    /// 本次拖动是否已压过撤销快照（一次手势 = 一步撤销，首次换位才压）。
    seq_drag_pushed: bool = false,

    /// 挂起中的重挂父目标（画布松手时挂号，canvas.draw 末尾整帧画完后执行）。
    /// 重挂会改树结构，必须等 drawNodes 的遍历全部结束。
    pending_reparent_target: ?u32 = null,

    /// 侧栏属性面板的滚动位置（面板内容超出窗口高度时滚动查看）。
    side_scroll: dvui.ScrollInfo = .{ .vertical = .auto, .horizontal = .none },

    // ---- 空白处框选（左键按下拖出的选择矩形，画布坐标）----
    rubber: ?RubberBand = null,

    // ---- 节点缩放状态（拖拽节点右/下边缘或右下角；resize_node_id != 0 = 进行中）----
    resize_node_id: u32 = 0,
    resize_edge: ResizeEdge = .se,
    /// 按下时节点框尺寸与鼠标位置（画布坐标），motion 里按差值更新 user_w/user_h
    resize_start_w: f32 = 0,
    resize_start_h: f32 = 0,
    resize_start_mx: f32 = 0,
    resize_start_my: f32 = 0,
    /// 本次缩放是否已压过快照（与移动拖拽同款：首次真正变化才压）
    resize_snapshot_pushed: bool = false,

    // ---- 文本输入的撤销会话 ----
    /// 侧栏文本框：当前已压过快照的那个输入框 id（0 = 没有会话）。
    /// 快照必须在「刚获得焦点」时预备——text_changed 触发时文本已经被改，
    /// 那时拍出来的是改后状态，撤销不动。
    text_focus_id: u64 = 0,
    /// 焦点落到侧栏输入框时预备的镜像；首次 text_changed 才正式入撤销栈
    pending_field_snapshot: ?Snapshot = null,
    /// 画布内联编辑：进入编辑时压过快照（Esc 取消时把这份空快照丢掉）
    edit_snapshot_pushed: bool = false,
    /// 帧序号：GC 的 trash 只在跨帧后释放（见 zstring.freeTrashOlderThan）。
    /// main.guiFrame 每帧开头调用 tickFrame() 递增。
    frame_epoch: u64 = 0,

    // ---- 文本编辑草稿（text 改为不可变 ZString 后，输入框不能直接绑定
    // 节点字节，一律先打进草稿 ArrayList，提交时才用 StringStore 构造新串）----
    /// 画布内联编辑（标题/连线标题共用）的草稿；beginEdit 时以原文本初始化。
    edit_draft: std.ArrayList(u8) = .empty,
    /// 侧栏三个文本框（标题/正文/连线标题）各自的草稿与归属节点 id
    ///（0 = 未初始化，下次渲染该字段时从节点文本重置）。
    /// undo / 换标签 / 画布编辑提交等会改写节点文本的路径必须让归属失效
    ///（invalidateSideDrafts），否则草稿会带着过期文本覆盖回来。
    title_draft: std.ArrayList(u8) = .empty,
    note_draft: std.ArrayList(u8) = .empty,
    link_draft: std.ArrayList(u8) = .empty,
    title_draft_node: u32 = 0,
    note_draft_node: u32 = 0,
    link_draft_node: u32 = 0,

    // ---- 背景色拾取的撤销会话 ----
    /// 侧栏取色器对同一节点连续调色（拖动取色框）只算一步撤销：
    /// 打开时预备镜像，首次真正变色才入栈，关闭/换节点时丢弃没入栈的镜像。
    color_session_node_id: u32 = 0,
    pending_color_snapshot: ?Snapshot = null,

    // ---- 侧栏背景色拾取器的 UI 状态 ----
    color_picker_open: bool = false,
    /// 拾取器针对的节点（换选中节点自动收起）
    color_picker_node_id: u32 = 0,
    color_picker_hsv: dvui.Color.HSV = .{},

    // ---- 侧栏「正文描述」输入框 ----
    /// 输入框高度：拖输入框下方的把手调整，会话内记住（对每个标签、每个节点
    /// 生效）。属于界面偏好而非文档数据，不进 XML、不走撤销。
    note_editor_h: f32 = 64,

    // ---------------------------------------------------------------
    // 生命周期
    // ---------------------------------------------------------------

    pub fn init(gpa: Allocator, io: std.Io) !App {
        var self = App{ .gpa = gpa, .io = io, .recent = recent_files.RecentFiles.init(gpa) };
        @memcpy(self.last_path_buf[0..12], "mindmap.mcab");
        try self.cmdNewDoc(); // 启动即有一个示例标签页
        self.setStatus("就绪 —— 点击选中 · Insert 加子节点 · Enter 加同级 · 拖拽移动子树 · 拖右/下边缘调大小");
        return self;
    }

    pub fn deinit(self: *App) void {
        if (self.pending_export_path) |p| self.gpa.free(p);
        self.dropPendingFieldSnapshot();
        self.dropPendingColorSnapshot();
        self.drag_entries.deinit(self.gpa);
        self.edit_draft.deinit(self.gpa);
        self.title_draft.deinit(self.gpa);
        self.note_draft.deinit(self.gpa);
        self.link_draft.deinit(self.gpa);
        self.recent.deinit();
        for (self.docs.items) |*d| d.deinit(self.gpa);
        self.docs.deinit(self.gpa);
    }

    // ---------------------------------------------------------------
    // 标签页
    // ---------------------------------------------------------------

    /// 当前活动文档（始终至少有一个）。
    pub fn doc(self: *App) *Doc {
        return &self.docs.items[self.active];
    }

    pub fn docCount(self: *const App) usize {
        return self.docs.items.len;
    }

    pub fn docAt(self: *App, index: usize) *Doc {
        return &self.docs.items[index];
    }

    /// 有未保存修改的文档数。
    pub fn dirtyCount(self: *const App) usize {
        var n: usize = 0;
        for (self.docs.items) |d| {
            if (d.dirty) n += 1;
        }
        return n;
    }

    /// 新建标签页（示例脑图，方便首启预览）。
    pub fn cmdNewDoc(self: *App) !void {
        var strings = zstring.StringStore.init(self.gpa);
        errdefer strings.deinit();
        const root = try self.buildSampleTree(&strings);
        const index = self.appendDoc(root, 4, 1, "", self.next_untitled, .{}, strings) catch |err| {
            root.deinit(self.gpa);
            return err;
        };
        self.next_untitled += 1;
        self.activateTab(index);
        self.setStatus("已新建脑图（新增标签页）");
    }

    /// 切换到第 index 个标签（越界或已在当前标签则忽略）。
    pub fn cmdSelectTab(self: *App, index: usize) void {
        if (index >= self.docs.items.len or index == self.active) return;
        self.activateTab(index);
        self.setStatus("已切换标签页");
    }

    /// 下一个 / 上一个标签（到末尾绕回）。
    pub fn cmdNextTab(self: *App) void {
        const n = self.docs.items.len;
        if (n < 2) return;
        self.cmdSelectTab((self.active + 1) % n);
    }

    pub fn cmdPrevTab(self: *App) void {
        const n = self.docs.items.len;
        if (n < 2) return;
        self.cmdSelectTab((self.active + n - 1) % n);
    }

    /// 关闭第 index 个标签；该文档有未保存修改时先弹确认框。
    pub fn cmdCloseTab(self: *App, index: usize) void {
        if (index >= self.docs.items.len) return;
        // 先提交正在进行的画布内联编辑：关闭不经过画布失焦，不提交就会丢输入。
        // 必须在判 dirty 之前——提交本身可能把文档改脏。
        self.cmdCommitEdit();
        if (self.docs.items[index].dirty) {
            self.showConfirm(.close_tab, index);
            return;
        }
        self.closeTabAt(index);
    }

    /// 真正执行关闭：释放节点树、必要时补一个新文档、把活动下标夹回范围。
    fn closeTabAt(self: *App, index: usize) void {
        if (index >= self.docs.items.len) return;
        const closing_active = index == self.active;
        // 关活动标签前先把绑在它身上的会话清干净：预备字段快照、预备取色快照、
        // 侧栏草稿、内联编辑草稿都指向 dead 的字符串池，dead.deinit 之后全是
        // 悬垂指针（见 docs/review-zstring-lifetime.md P1）。
        // 关别的标签不动这些状态——它们属于活动文档，池也还活着。
        if (closing_active) {
            self.clearEdit();
            self.text_focus_id = 0;
            self.dropPendingFieldSnapshot();
            self.endColorSession();
            self.color_picker_open = false;
            self.invalidateSideDrafts();
            // 缩放/双击记录绑的是旧文档的节点 id，换到新活动文档后必须清零
            self.resize_node_id = 0;
            self.last_click_target = 0;
        }
        var dead = self.docs.orderedRemove(index);
        dead.deinit(self.gpa);
        self.setStatus("已关闭标签页");

        if (self.docs.items.len == 0) {
            // 不允许 0 个标签：补一个示例文档，否则画布/侧栏无处可画
            var strings = zstring.StringStore.init(self.gpa);
            errdefer strings.deinit();
            const root = self.buildSampleTree(&strings) catch null;
            if (root) |r| {
                const idx = self.appendDoc(r, 4, 1, "", self.next_untitled, .{}, strings) catch {
                    r.deinit(self.gpa);
                    return;
                };
                self.next_untitled += 1;
                self.active = idx;
            }
            return;
        }
        // 关掉的是活动标签前面的一个：后面的标签整体前移，活动下标要跟着减，
        // 否则会「悄悄切到另一个文档」（min 夹紧只能兜住关最后一个的情况）。
        if (index < self.active) self.active -= 1;
        self.active = @min(self.active, self.docs.items.len - 1);
    }

    /// 切换活动标签并清掉与旧标签绑定的临时状态（内联编辑、双击记录、取色器）。
    fn activateTab(self: *App, index: usize) void {
        // 先把旧标签的内联编辑提交掉：cmdCommitEdit 用 self.doc() 定位节点，
        // 必须发生在切 active 之前，否则会拿新文档的树去找旧 id（找不到就丢输入）。
        self.cmdCommitEdit();
        self.active = index;
        self.clearEdit();
        self.text_focus_id = 0;
        self.dropPendingFieldSnapshot();
        self.invalidateSideDrafts(); // 草稿按节点 id 记归属，不跨标签复用
        self.endColorSession();
        self.color_picker_open = false;
        // 缩放/双击记录都绑定旧标签的节点，一并清掉
        self.resize_node_id = 0;
        self.last_click_target = 0; // 双击判定不跨标签
    }

    /// 把一棵节点树挂成新标签（不含切换激活），返回下标。
    /// images 是随文档带入的图片池（打开文件时来自 loadEx，新建时传空）；
    /// strings 是随文档带入的字符串池（节点 text/note/link 的字节所有者，
    /// 打开文件时来自 loadEx，新建时调用方先 init 再用同一个池建树）。
    fn appendDoc(
        self: *App,
        root: *model.Node,
        next_id: u32,
        selected_id: ?u32,
        path: []const u8,
        untitled: u32,
        images: model.ImageStore,
        strings: zstring.StringStore,
    ) !usize {
        var d = Doc{
            .gpa = self.gpa,
            .root = root,
            .next_id = next_id,
            .selected_id = selected_id,
            .untitled = untitled,
            .images = images,
            .strings = strings,
        };
        if (path.len > 0) _ = d.setPath(path);
        try self.docs.append(self.gpa, d);
        const idx = self.docs.items.len - 1;
        // 主选中同步进多选集合（初始的示例文档根节点就是选中状态）
        if (selected_id) |sid| self.docs.items[idx].selectSingle(sid);
        return idx;
    }

    /// 新建文档用的示例树（中心主题 + 两个分支；连线默认无标题）。
    /// 文本字节写入 store（将来会随 appendDoc 一起挂进 Doc）。
    fn buildSampleTree(self: *App, store: *zstring.StringStore) !*model.Node {
        const root = try model.createNode(store, 1, "中心主题");
        root.bg = .{ .r = 0xff, .g = 0xf3, .b = 0xb0 }; // 示例：自定义背景色
        errdefer root.deinit(self.gpa);
        try model.setNote(store, root, "可编辑标题与正文描述");
        const c1 = try model.addChild(store, root, 2, "分支一");
        try model.setNote(store, c1, "带正文描述的节点");
        _ = try model.addChild(store, root, 3, "分支二");
        return root;
    }

    /// 路径是否已经在某个标签里打开了（避免同一文件开两个标签）。
    pub fn indexOfPath(self: *const App, path: []const u8) ?usize {
        for (self.docs.items, 0..) |d, i| {
            if (std.mem.eql(u8, d.pathSlice(), path)) return i;
        }
        return null;
    }

    // ---------------------------------------------------------------
    // 撤销 / 重做（镜像快照）
    // ---------------------------------------------------------------

    /// 有没有可撤销/可重做（工具栏与菜单据此提示；两个栈都按标签独立）。
    pub fn canUndo(self: *const App) bool {
        return self.docs.items[self.active].undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const App) bool {
        return self.docs.items[self.active].redo_stack.items.len > 0;
    }

    /// 把当前整棵树镜像一份压进撤销栈。**必须在修改之前调用**。
    pub fn pushUndo(self: *App) bool {
        const snap = self.snapshotDoc(self.doc()) orelse {
            self.setStatus("撤销记录失败：内存不足");
            return false;
        };
        return self.pushSnapshot(snap);
    }

    /// 把一份已拍好的镜像入栈：清空重做栈、限制栈深。
    /// 压栈同时清空重做栈——一旦从历史中间点继续编辑，原来的 redo 分支就作废了。
    fn pushSnapshot(self: *App, snap: Snapshot) bool {
        const d = self.doc();
        // 超深先丢最老的一份，保证长期编辑不会无限吃内存
        if (d.undo_stack.items.len >= undo_depth) {
            var oldest = d.undo_stack.orderedRemove(0);
            oldest.root.deinit(self.gpa);
        }
        d.undo_stack.append(self.gpa, snap) catch {
            var s = snap;
            s.root.deinit(self.gpa);
            self.setStatus("撤销记录失败：内存不足");
            return false;
        };
        for (d.redo_stack.items) |*s| s.root.deinit(self.gpa);
        d.redo_stack.clearRetainingCapacity();
        self.gcStrings();
        return true;
    }

    /// 丢掉最近一份撤销快照（内联编辑按 Esc 取消时用：那次编辑已经回滚，
    /// 留在栈里只会变成一个按了没反应的空撤销步）。
    fn dropLastUndo(self: *App) void {
        const d = self.doc();
        if (d.undo_stack.items.len == 0) return;
        var last = d.undo_stack.pop().?;
        last.root.deinit(self.gpa);
        self.gcStrings();
    }

    /// 字符串池的 mark-sweep 回收（见 zstring.zig 文件头）。
    /// 根集合 = 当前树 + 撤销栈 + 重做栈 + 各预备快照（字段输入/取色会话）。
    /// **调用纪律**：只在快照被挤掉 / redo 清空 / 旧树被 restoreDoc 换掉这些
    /// 「垃圾真正产生」的时机调用；正在命令中途游离于树外的节点不允许存在
    ///（本工程的重挂父流程先挂新父再 detach，无游离窗口，满足该前提）。
    /// sweep 只把死块挪进 trash 延迟释放（帧中途的 dvui 控件可能还握着旧串
    /// 切片），freeTrashOlderThan 在下一个帧才真正回收（同帧二次 GC 安全）。
    /// 每帧开头调用：推进帧序号，让 GC 的 trash 有「是否已跨帧」的依据。
    pub fn tickFrame(self: *App) void {
        self.frame_epoch +%= 1;
    }

    fn gcStrings(self: *App) void {
        const d = self.doc();
        // 只释放上一帧及更早判死的块：同一帧里二次进 GC（pushSnapshot 后又
        // dropLastUndo 等）不会提前 free 本帧 dvui 控件仍可能引用的旧串。
        d.strings.freeTrashOlderThan(self.frame_epoch);
        if (!d.strings.shouldGc()) return;
        var g = d.strings.beginGcEpoch(self.frame_epoch);
        model.markStrings(&g, d.root);
        for (d.undo_stack.items) |*s| model.markStrings(&g, s.root);
        for (d.redo_stack.items) |*s| model.markStrings(&g, s.root);
        if (self.pending_field_snapshot) |s| model.markStrings(&g, s.root);
        if (self.pending_color_snapshot) |s| model.markStrings(&g, s.root);
        g.sweep();
    }

    fn snapshotDoc(self: *App, d: *Doc) ?Snapshot {
        const root = model.cloneTree(self.gpa, d.root) catch return null;
        return .{
            .root = root,
            .next_id = d.next_id,
            .selected_id = d.selected_id,
            .selected_edge_id = d.selected_edge_id,
        };
    }

    /// 整棵树换成快照里的镜像（快照的所有权随之转移给文档）。
    fn restoreDoc(self: *App, d: *Doc, s: Snapshot) void {
        d.root.deinit(self.gpa);
        d.root = s.root;
        d.next_id = s.next_id;
        d.selected_id = s.selected_id;
        d.selected_edge_id = s.selected_edge_id;
        // 快照只记主选中：撤销后多选集合收缩回这一个（不把列表塞进快照，
        // 免去快照生命周期的堆分配/释放管理）
        d.selected_ids.clearRetainingCapacity();
        if (s.selected_id) |sid| d.selected_ids.append(self.gpa, sid) catch {};
        // 正在编辑的目标可能已经不在新树里了
        self.clearEdit();
        self.text_focus_id = 0;
        self.dropPendingFieldSnapshot();
        // 新树的节点对象是全新的：侧栏草稿（按节点 id 记归属）必须失效，
        // 否则下一帧会用旧树时期的草稿文本覆盖新树的文本
        self.invalidateSideDrafts();
        // 取色会话的预备镜像拍的是旧树，撤销后继续用它会跳回多个步骤
        self.endColorSession();
        self.color_picker_open = false;
        d.dirty = true;
    }

    pub fn cmdUndo(self: *App) void {
        const d = self.doc();
        if (d.undo_stack.items.len == 0) {
            self.setStatus("没有可撤销的操作");
            return;
        }
        // 当前状态先存进重做栈，才能再「重做」回来
        const cur = self.snapshotDoc(d) orelse {
            self.setStatus("撤销失败：内存不足");
            return;
        };
        d.redo_stack.append(self.gpa, cur) catch {
            var c = cur;
            c.root.deinit(self.gpa);
            self.setStatus("撤销失败：内存不足");
            return;
        };
        self.restoreDoc(d, d.undo_stack.pop().?);
        self.reveal_selected = true; // 撤销可能把选中项挪回视口外
        self.gcStrings(); // restoreDoc 换掉的旧树 = 一批死串，就地回收
        self.setStatus("已撤销");
    }

    pub fn cmdRedo(self: *App) void {
        const d = self.doc();
        if (d.redo_stack.items.len == 0) {
            self.setStatus("没有可重做的操作");
            return;
        }
        const cur = self.snapshotDoc(d) orelse {
            self.setStatus("重做失败：内存不足");
            return;
        };
        d.undo_stack.append(self.gpa, cur) catch {
            var c = cur;
            c.root.deinit(self.gpa);
            self.setStatus("重做失败：内存不足");
            return;
        };
        self.restoreDoc(d, d.redo_stack.pop().?);
        self.reveal_selected = true;
        self.gcStrings();
        self.setStatus("已重做");
    }

    /// 侧栏文本框的撤销会话：焦点刚落到某个输入框时**预备**一份镜像
    /// （此刻文本还没被改，镜像就是编辑前的状态）。
    /// 真正打字（text_changed）才由 commitTextFieldEdit 把它正式入栈——
    /// 只是点进输入框看一眼又走开，不会留下一个按了没反应的撤销步。
    pub fn trackTextField(self: *App, field_id: u64) void {
        if (field_id == 0 or self.text_focus_id == field_id) return;
        const focused = dvui.focusedWidgetIdInCurrentSubwindow() orelse return;
        if (focused.asUsize() != field_id) return;
        self.dropPendingFieldSnapshot();
        self.text_focus_id = field_id;
        self.pending_field_snapshot = self.snapshotDoc(self.doc());
    }

    /// 文本框内容变了：把预备镜像正式压进撤销栈（整个输入会话只算一步）。
    pub fn commitTextFieldEdit(self: *App) void {
        const snap = self.pending_field_snapshot orelse return;
        self.pending_field_snapshot = null;
        _ = self.pushSnapshot(snap);
    }

    /// 每帧末尾调用：焦点离开侧栏文本框 = 本次输入会话结束，
    /// 没来得及入栈的预备镜像直接丢弃。
    pub fn endTextFieldSession(self: *App) void {
        if (self.text_focus_id == 0 and self.pending_field_snapshot == null) return;
        const focused = dvui.focusedWidgetIdInCurrentSubwindow() orelse {
            self.text_focus_id = 0;
            self.dropPendingFieldSnapshot();
            return;
        };
        if (focused.asUsize() != self.text_focus_id) {
            self.text_focus_id = 0;
            self.dropPendingFieldSnapshot();
        }
    }

    fn dropPendingFieldSnapshot(self: *App) void {
        if (self.pending_field_snapshot) |*s| s.root.deinit(self.gpa);
        self.pending_field_snapshot = null;
    }

    // ---------------------------------------------------------------
    // 背景色拾取的撤销会话（与文本输入的撤销会话同款策略）
    // ---------------------------------------------------------------

    /// 取色器打开/对准某节点时调用：首次为该节点预备编辑前镜像，
    /// 之后整个调色会话（拖动取色框产生的连续变化）只算一步撤销。
    pub fn trackColorPicker(self: *App, node_id: u32) void {
        if (node_id == 0 or self.color_session_node_id == node_id) return;
        self.dropPendingColorSnapshot();
        self.color_session_node_id = node_id;
        self.pending_color_snapshot = self.snapshotDoc(self.doc());
    }

    /// 背景色第一次变化：把预备镜像正式入栈（会话内后续变化不再入栈）。
    pub fn commitColorEdit(self: *App) void {
        const snap = self.pending_color_snapshot orelse return;
        self.pending_color_snapshot = null;
        _ = self.pushSnapshot(snap);
    }

    /// 取色会话结束（收起取色器 / 换选中节点 / 换标签 / 撤销）：
    /// 没来得及入栈的预备镜像直接丢弃（用户只是打开看了一眼）。
    pub fn endColorSession(self: *App) void {
        if (self.color_session_node_id == 0 and self.pending_color_snapshot == null) return;
        self.color_session_node_id = 0;
        self.dropPendingColorSnapshot();
    }

    fn dropPendingColorSnapshot(self: *App) void {
        if (self.pending_color_snapshot) |*s| s.root.deinit(self.gpa);
        self.pending_color_snapshot = null;
    }

    // ---------------------------------------------------------------
    // 文档命令（唯一修改入口）
    // ---------------------------------------------------------------

    /// 添加子节点（作用于选中节点，未选中则作用于根）。
    pub fn cmdAddChild(self: *App) void {
        const d = self.doc();
        const target = self.selectedNode() orelse d.root;
        _ = self.pushUndo();
        const n = model.addChild(&d.strings, target, d.next_id, "新节点") catch {
            self.setStatus("添加失败：内存不足");
            return;
        };
        d.next_id += 1;
        d.selectSingle(n.id);
        d.dirty = true;
        self.reveal_selected = true; // 新节点可能落在视口外，画布要把它滚进视野
        self.setStatus("已添加子节点");
    }

    /// 添加同级节点（根节点退化为添加子节点）。
    pub fn cmdAddSibling(self: *App) void {
        const d = self.doc();
        const target = self.selectedNode() orelse d.root;
        _ = self.pushUndo();
        const n = model.addSibling(&d.strings, target, d.next_id, "新节点") catch {
            self.setStatus("添加失败：内存不足");
            return;
        };
        d.next_id += 1;
        d.selectSingle(n.id);
        d.dirty = true;
        self.reveal_selected = true;
        self.setStatus("已添加同级节点");
    }

    /// 复制选中节点到系统剪贴板：序列化成 `<node>…</node>` 文本（只复制节点自身，
    /// 不含子节点；图片内联 base64，跨文档粘贴也能还原）。其他程序可读可再粘回。
    pub fn cmdCopySelected(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中要复制的节点");
            return;
        };
        const text = xml.serializeNodeFragment(self.gpa, node, &self.doc().images) catch {
            self.setStatus("复制失败：内存不足");
            return;
        };
        defer self.gpa.free(text);
        dvui.clipboardTextSet(text);
        self.setStatus("已复制节点（不含子节点）——Ctrl+V 粘贴为同级新节点");
    }

    /// 粘贴系统剪贴板内容，按内容分派（必须先选中节点）：
    /// 1. `<node …>` 开头的文本 → 反序列化新建节点，父节点与选中节点相同、
    ///    插在选中节点之后（选中为根则挂到根下），id 从文档 next_id 重新分配；
    /// 2. 图片文件路径（jpg/jpeg/png）→ 读文件设为选中节点的图片；
    /// 3. 其他非空文本 → 直接作为选中节点的标题；
    /// 4. 无文本（位图，如截图）→ 转 PNG 设为选中节点的图片。
    pub fn cmdPasteNode(self: *App) void {
        const sel = self.selectedNode() orelse {
            self.setStatus("请先选中节点：粘贴需要一个目标（同级新节点 / 标题 / 图片）");
            return;
        };
        if (self.editing != .none) {
            self.setStatus("正在编辑：先按 Esc 退出编辑再粘贴");
            return;
        }
        // 剪贴板文本是帧 arena 所有，本帧内用完即弃，无需 free
        const text = std.mem.trim(u8, dvui.clipboardText(), " \t\r\n\x0c");
        if (std.mem.startsWith(u8, text, "<node")) {
            self.pasteNodeFragment(sel, text);
            return;
        }
        if (text.len > 0) {
            if (self.pasteTextAsImage(sel, text)) return;
            self.pasteTextAsTitle(sel, text);
            return;
        }
        self.pasteClipboardImage(sel);
    }

    /// 剪贴板是 `<node>` XML：解析（内联图转进文档图片池）→ 换新 id → 同级插入。
    /// pub 只为让测试直接驱动这条路径（剪贴板在无头窗口里没法用）。
    pub fn pasteNodeFragment(self: *App, sel: *model.Node, text: []const u8) void {
        const d = self.doc();
        // 顺序要害：先压快照、再解析。解析会把新串写进文档字符串池，而此刻节点
        // 还没挂上树，不属于 gcStrings 的任何一个根（当前树/撤销栈/重做栈/预备
        // 快照）。pushUndo 里若恰好触发 GC（池里攒够了垃圾就会），新节点的
        // text/note/link 会被判死回收，随后入树的节点就带着悬垂指针。
        // 见 docs/review-zstring-lifetime.md P0。
        const pushed = self.pushUndo();
        const n = xml.parseNodeFragment(self.gpa, text, &d.images, &d.strings) catch |err| {
            // 树没变：这份快照对应不到任何改动，丢掉（顺带回收刚解析出的无主串）
            if (pushed) self.dropLastUndo();
            self.setStatus(if (err == error.OutOfMemory)
                "粘贴失败：内存不足"
            else
                "粘贴失败：剪贴板内容不是有效的节点 XML");
            return;
        };
        // 全部换新 id（含片段里带了子节点的极端情况），避免与现有 id 冲突
        var next = d.next_id;
        reassignIds(n, &next);
        const parent: *model.Node = sel.parent orelse d.root; // 选中根 → 挂根下
        var idx: usize = parent.children.items.len;
        if (sel.parent == parent) {
            if (std.mem.indexOfScalar(*model.Node, parent.children.items, sel)) |i| idx = i + 1;
        }
        parent.children.ensureUnusedCapacity(self.gpa, 1) catch {
            n.deinit(self.gpa);
            if (pushed) self.dropLastUndo(); // 同样：树没变，撤销步无意义
            self.setStatus("粘贴失败：内存不足");
            return;
        };
        parent.children.insertAssumeCapacity(idx, n);
        n.parent = parent;
        parent.collapsed = false;
        d.next_id = next;
        d.selectSingle(n.id);
        d.dirty = true;
        self.reveal_selected = true;
        self.setStatus("已粘贴节点（同级，不含子节点）");
    }

    /// 剪贴板文本是否按「图片路径」处理。返回 true 表示已按图片分派
    ///（成功设置或给出失败提示），调用方不再把它当标题。
    fn pasteTextAsImage(self: *App, sel: *model.Node, text: []const u8) bool {
        var p = text;
        // 常见的复制带引号路径 / file:// URL（file:///C:/dir/img.png）
        if (p.len >= 2 and (p[0] == '"' or p[0] == '\'') and p[p.len - 1] == p[0]) {
            p = p[1 .. p.len - 1];
        }
        if (std.ascii.startsWithIgnoreCase(p, "file:///")) p = p[8..];
        const ext = std.fs.path.extension(p);
        if (ext.len <= 1) return false;
        const is_img = std.ascii.eqlIgnoreCase(ext[1..], "jpg") or
            std.ascii.eqlIgnoreCase(ext[1..], "jpeg") or
            std.ascii.eqlIgnoreCase(ext[1..], "png");
        if (!is_img) return false;
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, std.Io.Limit.limited(64 * 1024 * 1024)) catch {
            self.setStatus("粘贴图片失败：读不到文件");
            return true;
        };
        defer self.gpa.free(data);
        // type 记文件后缀（jpg/png），与「从磁盘加载图片」一致
        const t = if (ext.len > 1) ext[1..] else "img";
        self.cmdSetNodeImg(sel, t, data) catch {
            self.setStatus("设置图片失败：内存不足");
            return true;
        };
        return true;
    }

    /// 剪贴板普通文本 → 直接作为选中节点的标题（一步撤销）。
    fn pasteTextAsTitle(self: *App, sel: *model.Node, text: []const u8) void {
        _ = self.pushUndo();
        model.setText(&self.doc().strings, sel, text) catch {
            self.setStatus("粘贴失败：内存不足");
            return;
        };
        self.doc().dirty = true;
        self.setStatus("已把剪贴板文本粘贴为节点标题");
    }

    /// 剪贴板没有文本：尝试读位图（Windows CF_DIB → PNG）设为节点图片。
    fn pasteClipboardImage(self: *App, sel: *model.Node) void {
        const png = platform.clipboardImagePng(self.gpa) orelse {
            self.setStatus("剪贴板没有可粘贴的内容（文本 / 图片）");
            return;
        };
        defer self.gpa.free(png);
        self.cmdSetNodeImg(sel, "png", png) catch {
            self.setStatus("粘贴图片失败：内存不足");
            return;
        };
    }

    /// 删除选中节点及其子树（根节点不可删）。多选时一次全删，算一步撤销。
    pub fn cmdDeleteSelected(self: *App) void {
        const d = self.doc();
        if (d.selected_ids.items.len == 0) {
            self.setStatus("请先选中要删除的节点");
            return;
        }
        var removed: usize = 0;
        var last_parent: ?*model.Node = null;
        for (d.selected_ids.items) |sid| {
            // 前面的删除可能已把后面的节点（子孙）连带删掉：find 只走活树，
            // 找不到就说明已经随某个祖先一起没了
            const node = model.find(d.root, sid) orelse continue;
            if (node == d.root) continue;
            if (removed == 0) _ = self.pushUndo();
            last_parent = node.parent;
            model.remove(self.gpa, node);
            if (self.editing_id == sid) self.clearEdit();
            removed += 1;
        }
        if (removed == 0) {
            self.setStatus(if (d.selected_ids.items.len == 1 and d.selected_id != null and d.selected_id.? == d.root.id)
                "根节点不可删除"
            else
                "没有可删除的节点");
            return;
        }
        d.selectionClear();
        if (last_parent) |p| d.selectSingle(p.id);
        d.dirty = true;
        self.setStatus(if (removed == 1) "已删除节点" else "已删除节点（含子树）");
    }

    /// shift+拖放重挂父：把拖拽中的顶层节点逐个挂到 target 下（子树跟着走）。
    /// 跳过非法项：root、target 自身、target 的祖先（会成环）、已是 target
    /// 子节点（无变化）——被跳过的节点按 drag_entries 记的初始偏移弹回原位。
    /// 至少移动一个节点才压撤销步（一次拖放算一步，多选整体重挂可一起撤销）。
    pub fn cmdReparentSelected(self: *App, target_id: u32) void {
        const d = self.doc();
        const target = model.find(d.root, target_id) orelse return;
        var movable: usize = 0;
        for (self.drag_entries.items) |e| {
            const n = model.find(d.root, e.id) orelse continue;
            if (n == d.root or n == target or n.parent == target or model.isAncestor(n, target)) continue;
            movable += 1;
        }
        if (movable == 0) {
            self.restoreDragOffsets();
            self.setStatus("不能挂到该节点下");
            return;
        }
        _ = self.pushUndo();
        for (self.drag_entries.items) |e| {
            const n = model.find(d.root, e.id) orelse continue;
            if (n == d.root or n == target or n.parent == target or model.isAncestor(n, target)) continue;
            // 先挂到新父、再从旧父摘下：append 失败时树结构还没动过
            target.children.append(self.gpa, n) catch {
                n.geom.ox = e.ox0;
                n.geom.oy = e.oy0;
                self.setStatus("移动失败：内存不足");
                continue;
            };
            model.detach(n);
            n.parent = target;
            // 用户偏移清零：节点落到新父的自动布局位置
            n.geom.ox = 0;
            n.geom.oy = 0;
            target.collapsed = false;
        }
        d.dirty = true;
        self.reveal_selected = true; // 新父可能落在视口外
        self.setStatus("已移动到新父节点");
    }

    /// 拖拽集合里的每个节点按 drag_entries 记录的初始偏移弹回原位
    /// （重挂父拖放落空时用：拖拽过程挪过的 ox/oy 全部还原）。
    pub fn restoreDragOffsets(self: *App) void {
        for (self.drag_entries.items) |e| {
            const n = model.find(self.doc().root, e.id) orelse continue;
            n.geom.ox = e.ox0;
            n.geom.oy = e.oy0;
        }
    }

    /// 「下一级节点」列表拖动换位：把 kids（parent 子节点按导出排序的副本）
    /// 中下标 from 的节点移到 to，并给全部子节点写 seq = 新列表下标——
    /// 文档导出按 seq*10^7+id 排序，重排即改导出顺序（树本身的子节点顺序
    /// 不动，画布布局不变）。一次拖动手势只压一步撤销（seq_drag_pushed）。
    pub fn cmdMoveChildSeq(self: *App, kids: []*model.Node, from: usize, to: usize) void {
        if (from == to or from >= kids.len or to >= kids.len) return;
        if (!self.seq_drag_pushed) {
            _ = self.pushUndo();
            self.seq_drag_pushed = true;
        }
        const item = kids[from];
        if (to > from) {
            std.mem.copyForwards(*model.Node, kids[from..to], kids[from + 1 .. to + 1]);
        } else {
            std.mem.copyBackwards(*model.Node, kids[to + 1 .. from + 1], kids[to..from]);
        }
        kids[to] = item;
        for (kids, 0..) |c, idx| c.seq = idx;
        self.doc().dirty = true;
    }

    /// id 是否在本次拖拽集合里（重挂父拖拽时画布据此隐藏被拖节点的旧父连线）。
    pub fn dragEntryHas(self: *const App, id: u32) bool {
        for (self.drag_entries.items) |e| {
            if (e.id == id) return true;
        }
        return false;
    }

    /// 框选：选中几何与 rect 相交的可见节点（折叠节点的子树不可见，不参与）。
    /// add=false 先清空再选，主选中 = 先序遍历第一个命中的节点；
    /// add=true（shift 框选）在原集合上追加，主选中保持不变。
    pub fn selectNodesInRect(self: *App, rect: dvui.Rect, add: bool) void {
        const d = self.doc();
        if (!add) {
            d.selected_ids.clearRetainingCapacity();
            d.selected_id = null;
            d.selected_edge_id = null;
        }
        self.collectNodesInRect(d.root, rect);
    }

    fn collectNodesInRect(self: *App, node: *model.Node, rect: dvui.Rect) void {
        const d = self.doc();
        if (rectHitsGeom(rect, node.geom)) {
            const was_empty = d.selected_id == null;
            d.selectAdd(node.id);
            if (was_empty) d.selected_id = node.id;
        }
        if (node.collapsed) return;
        for (node.children.items) |c| self.collectNodesInRect(c, rect);
    }

    /// 全部展开 / 全部折叠。
    /// 折叠时根节点也一并折叠——根右侧会显示「+」徽章，点一下即可展开，
    /// 所以不会出现「整张图只剩一个节点且无处可点」的死角。
    pub fn cmdSetCollapseAll(self: *App, collapsed: bool) void {
        const d = self.doc();
        _ = self.pushUndo();
        model.setCollapseAll(d.root, collapsed);
        d.dirty = true;
        self.setStatus(if (collapsed) "已全部折叠，点节点右侧 + 展开" else "已全部展开");
    }

    /// 折叠当前选中节点（隐藏其整棵子树）。
    /// 只翻节点自身的 collapsed —— 后代保持各自的折叠状态，
    /// 下次展开时逐层显示，与「+」徽章的单层展开行为一致。
    pub fn cmdCollapseCurrent(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (node.children.items.len == 0) {
            self.setStatus("该节点没有子节点，无需折叠");
            return;
        }
        if (node.collapsed) {
            self.setStatus("该节点已处于折叠状态");
            return;
        }
        _ = self.pushUndo();
        node.collapsed = true;
        self.doc().dirty = true;
        self.setStatus("已折叠当前节点");
    }

    /// 展开当前选中节点及其全部后代。
    /// 与「+」徽章互补：徽章只展开一层，这里一次展开整棵子树，
    /// 适合「先全部折叠、再单独看某个分支」的场景。
    pub fn cmdExpandCurrent(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (node.children.items.len == 0) {
            self.setStatus("该节点没有子节点，无需展开");
            return;
        }
        _ = self.pushUndo();
        model.setCollapseAll(node, false);
        self.doc().dirty = true;
        self.setStatus("已展开当前节点及其子树");
    }

    /// 折叠/展开单个节点。
    pub fn cmdToggleCollapse(self: *App, node: *model.Node) void {
        _ = self.pushUndo();
        node.collapsed = !node.collapsed;
        self.doc().dirty = true;
        self.setStatus(if (node.collapsed) "已折叠节点" else "已展开节点");
    }

    /// 标记文本已修改（文本框直改 node.text / node.note 后调用）。
    pub fn cmdMarkDirty(self: *App, msg: []const u8) void {
        self.doc().dirty = true;
        self.setStatus(msg);
    }

    /// 清除选中节点的正文描述（退回只显示标题）。
    pub fn cmdClearNote(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (!node.hasNote()) {
            self.setStatus("该节点没有正文描述");
            return;
        }
        _ = self.pushUndo();
        model.setNote(&self.doc().strings, node, "") catch {
            self.setStatus("清除失败：内存不足");
            return;
        };
        self.doc().dirty = true;
        self.setStatus("已清除正文描述");
    }

    /// 清除选中节点的连线标题（连线恢复为无标题）。
    pub fn cmdClearLink(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (!node.hasLink()) {
            self.setStatus("该节点的连线没有标题");
            return;
        }
        _ = self.pushUndo();
        model.setLink(&self.doc().strings, node, "") catch {
            self.setStatus("清除失败：内存不足");
            return;
        };
        self.doc().dirty = true;
        self.setStatus("已清除连线标题");
    }

    /// 直接写入节点背景色。不改撤销栈——预设色板走 cmdSetNodeBg（一步撤销），
    /// 取色器走撤销会话（整个调色过程算一步）。
    pub fn applyNodeBg(self: *App, node: *model.Node, color: ?model.Rgba) void {
        node.bg = color;
        self.doc().dirty = true;
    }

    /// 设置选中节点的背景色（预设色板 / 清除按钮：一次点击 = 一步撤销）。
    /// 传 null 恢复跟随主题；与当前颜色相同则不动作（不产生空撤销步）。
    pub fn cmdSetNodeBg(self: *App, color: ?model.Rgba) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (std.meta.eql(node.bg, color)) {
            self.setStatus(if (color == null) "节点已是默认背景色" else "节点已是这个背景色");
            return;
        }
        _ = self.pushUndo();
        self.applyNodeBg(node, color);
        self.setStatus(if (color == null) "已恢复默认背景色" else "已更改节点背景色");
    }

    /// 恢复选中节点的自动尺寸（清除手动调整的宽/高下限）。
    pub fn cmdClearNodeSize(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (node.user_w == null and node.user_h == null) {
            self.setStatus("该节点未手动调整过尺寸");
            return;
        }
        _ = self.pushUndo();
        node.user_w = null;
        node.user_h = null;
        self.doc().dirty = true;
        self.setStatus("已恢复自动尺寸");
    }

    // ---------------------------------------------------------------
    // 节点图片与属性表（2.0）
    // ---------------------------------------------------------------

    /// 挂起「选择节点图片」：帧末弹系统对话框，读入后写进 target_id 节点。
    /// 目标在挂起时记下——对话框弹出期间选中项可能变化，读文件要落回原目标。
    pub fn cmdPickImage(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        self.pending_image_target_id = node.id;
        self.pending_file_action = .pick_image;
    }

    /// 帧末消费选图请求：弹对话框选文件 → 读全部字节 → cmdSetNodeImg
    /// （cmdSetNodeImg 按 md5 查图片池：md5 相同且内容一致则复用同一 uuid，不重复存）。
    fn runPickImage(self: *App) void {
        const target_id = self.pending_image_target_id orelse return;
        self.pending_image_target_id = null;
        const node = model.find(self.doc().root, target_id) orelse {
            self.setStatus("目标节点已不存在");
            return;
        };
        if (!dvui.useTinyFileDialogs) {
            self.setStatus("加载图片：当前构建没有可用的系统对话框");
            return;
        }
        const picked = dvui.dialogNativeFileOpen(self.gpa, .{
            .title = "从磁盘加载图片",
            .path = self.dialogStartPath(),
            .filters = &.{ "*.jpg", "*.jpeg", "*.png" },
            .filter_description = "图片文件 (*.jpg; *.png)",
        }) catch {
            self.setStatus("加载图片失败：无法弹出系统对话框");
            return;
        };
        const p = picked orelse {
            self.setStatus("已取消加载图片");
            return;
        };
        defer self.gpa.free(p);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, p, self.gpa, std.Io.Limit.limited(64 * 1024 * 1024)) catch {
            self.setStatus("读取图片失败");
            return;
        };
        defer self.gpa.free(data);
        // type 记文件后缀（jpg/png），保存时写 <img type="...">
        const ext = std.fs.path.extension(p);
        const t = if (ext.len > 1) ext[1..] else "img";
        self.cmdSetNodeImg(node, t, data) catch {
            self.setStatus("设置图片失败：内存不足");
        };
    }

    /// 设置节点图片：按 md5 查图片池，相同内容复用同一 uuid（新图生成新 uuid），
    /// 节点只写引用。空 data 视为不设置。
    pub fn cmdSetNodeImg(self: *App, node: *model.Node, img_type: []const u8, data: []const u8) !void {
        if (data.len == 0) return;
        _ = self.pushUndo();
        const d = self.doc();
        const id = try d.images.ensure(self.gpa, img_type, data);
        try model.setImgRef(self.gpa, node, id);
        d.dirty = true;
        self.setStatus("已设置节点图片");
    }

    /// 取节点引用的图片资源（池里没有时返回 null——文件损坏时画不出图标）。
    pub fn imageAsset(self: *App, node: *model.Node) ?*model.ImageAsset {
        if (!node.hasImg()) return null;
        return self.doc().images.findById(node.img_ref.items);
    }

    /// 清除选中节点的图片引用（资源本身留在池里，重做/再引用时还能用）。
    pub fn cmdClearNodeImg(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (!node.hasImg()) {
            self.setStatus("该节点没有图片");
            return;
        }
        _ = self.pushUndo();
        model.clearImgRef(node);
        self.doc().dirty = true;
        self.setStatus("已移除节点图片");
    }

    /// 给选中节点追加一条空属性（侧栏「添加属性」按钮）。
    pub fn cmdAddProperty(self: *App) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        _ = self.pushUndo();
        model.addProperty(self.gpa, node, "", "") catch {
            self.setStatus("添加失败：内存不足");
            return;
        };
        self.doc().dirty = true;
        self.setStatus("已添加属性行");
    }

    /// 删除选中节点的第 index 条属性。
    pub fn cmdRemoveProperty(self: *App, index: usize) void {
        const node = self.selectedNode() orelse {
            self.setStatus("请先选中节点");
            return;
        };
        if (index >= node.properties.items.len) return;
        _ = self.pushUndo();
        model.removeProperty(self.gpa, node, index);
        self.doc().dirty = true;
        self.setStatus("已删除属性");
    }

    // ---------------------------------------------------------------
    // 画布内联编辑（双击）
    // ---------------------------------------------------------------

    /// 双击节点：进入标题内联编辑。
    pub fn cmdBeginEditNodeTitle(self: *App, node: *model.Node) void {
        self.beginEdit(.node_title, node);
    }

    /// 双击连线：进入连线标题内联编辑（child = 这条边的子节点端）。
    pub fn cmdBeginEditEdgeTitle(self: *App, child: *model.Node) void {
        self.beginEdit(.edge_title, child);
    }

    fn beginEdit(self: *App, kind: EditKind, node: *model.Node) void {
        const cur = switch (kind) {
            .node_title => node.text.slice(),
            .edge_title => node.link.slice(),
            .none => unreachable,
        };
        // 草稿是输入缓冲：节点文本此刻还不变，提交时才构造新 ZString
        self.edit_draft.clearRetainingCapacity();
        self.edit_draft.appendSlice(self.gpa, cur) catch {};
        self.edit_backup_len = @min(cur.len, self.edit_backup.len - 1);
        @memcpy(self.edit_backup[0..self.edit_backup_len], cur[0..self.edit_backup_len]);
        // 进入编辑先压镜像：此刻文本还没被改，撤销一次就回到编辑前。
        // （不能等 text_changed 再压——那时文本已经是改后状态了）
        self.edit_snapshot_pushed = self.pushUndo();
        self.editing = kind;
        self.editing_id = node.id;
        self.edit_armed = true; // 下一帧聚焦并全选
        self.doc().dirty = true;
        self.setStatus(if (kind == .node_title) "编辑节点标题：Enter 确认 · Esc 取消" else "编辑连线标题：Enter 确认 · Esc 取消");
    }

    /// 确认编辑（Enter / 点到别处）：把草稿提交为新 ZString。
    /// （在此之前节点文本一直是编辑前的旧串——撤销快照在 beginEdit 时拍的
    /// 就是它，输入过程中undo不会被草稿里的中间态污染。）
    pub fn cmdCommitEdit(self: *App) void {
        if (self.editing == .none) return;
        const kind = self.editing;
        const id = self.editing_id;
        const node = model.find(self.doc().root, id) orelse {
            self.clearEdit();
            return;
        };
        // 新串必须在 clearEdit **之前**构造：draft 指向 edit_draft 的缓冲区，
        // 现在只因为 clearRetainingCapacity 不归还内存才侥幸有效，
        // 哪天改成 deinit 就是 UAF（见 docs/review-zstring-lifetime.md P3）。
        switch (kind) {
            .node_title => if (!node.text.eqlSlice(self.edit_draft.items))
                model.setText(&self.doc().strings, node, self.edit_draft.items) catch {},
            .edge_title => if (!node.link.eqlSlice(self.edit_draft.items))
                model.setLink(&self.doc().strings, node, self.edit_draft.items) catch {},
            .none => {},
        }
        self.clearEdit();
        self.invalidateSideDrafts(); // 同一节点可能正显示在侧栏，草稿作废重取
        self.setStatus(if (kind == .node_title) "已更新节点标题" else "已更新连线标题");
    }

    /// 取消编辑（Esc）：回滚到进入编辑前的文本。
    pub fn cmdCancelEdit(self: *App) void {
        if (self.editing == .none) return;
        const kind = self.editing;
        const id = self.editing_id;
        const backup = self.edit_backup[0..self.edit_backup_len];
        // 这次编辑已经整体回滚，进入时压的那份快照就是多余的：丢掉，
        // 否则撤销栈里会留一个「按了没反应」的空步
        if (self.edit_snapshot_pushed) {
            self.dropLastUndo();
            self.edit_snapshot_pushed = false;
        }
        const node = model.find(self.doc().root, id) orelse {
            self.clearEdit();
            return;
        };
        switch (kind) {
            .node_title => model.setText(&self.doc().strings, node, backup) catch {},
            .edge_title => model.setLink(&self.doc().strings, node, backup) catch {},
            .none => {},
        }
        self.clearEdit();
        self.setStatus("已取消编辑");
    }

    fn clearEdit(self: *App) void {
        self.editing = .none;
        self.editing_id = 0;
        self.edit_armed = false;
        self.edit_backup_len = 0;
        self.edit_snapshot_pushed = false;
        self.edit_draft.clearRetainingCapacity();
    }

    // ---------------------------------------------------------------
    // 侧栏文本框草稿（标题/正文/连线标题）
    // ---------------------------------------------------------------

    /// 让三个侧栏草稿在下一帧从节点文本重新初始化。
    /// 节点文本被草稿以外的路径改掉时必须调用（画布编辑提交、undo 换树、
    /// 换标签），否则草稿里的过期文本会在下次提交时把新值覆盖回去。
    fn invalidateSideDrafts(self: *App) void {
        self.title_draft_node = 0;
        self.note_draft_node = 0;
        self.link_draft_node = 0;
    }

    /// 侧栏标题输入框的草稿：第一次渲染该字段（或换节点/草稿失效）时
    /// 以节点当前文本初始化，之后每帧直接续用（输入框的实时缓冲）。
    pub fn sideTitleDraft(self: *App, node: *model.Node) *std.ArrayList(u8) {
        if (self.title_draft_node != node.id) {
            self.title_draft.clearRetainingCapacity();
            self.title_draft.appendSlice(self.gpa, node.text.slice()) catch {};
            self.title_draft_node = node.id;
        }
        return &self.title_draft;
    }

    /// 侧栏标题框内容变了：草稿 → 新 ZString（内容没变则不动节点），整个
    /// 输入会话的撤销步由 commitTextFieldEdit 统一入栈。
    pub fn commitSideTitle(self: *App, node: *model.Node) void {
        if (!node.text.eqlSlice(self.title_draft.items)) {
            model.setText(&self.doc().strings, node, self.title_draft.items) catch return;
        }
        self.commitTextFieldEdit();
        self.cmdMarkDirty("标题已修改");
    }

    /// 侧栏正文描述输入框的草稿（同 sideTitleDraft）。
    pub fn sideNoteDraft(self: *App, node: *model.Node) *std.ArrayList(u8) {
        if (self.note_draft_node != node.id) {
            self.note_draft.clearRetainingCapacity();
            self.note_draft.appendSlice(self.gpa, node.note.slice()) catch {};
            self.note_draft_node = node.id;
        }
        return &self.note_draft;
    }

    pub fn commitSideNote(self: *App, node: *model.Node) void {
        if (!node.note.eqlSlice(self.note_draft.items)) {
            model.setNote(&self.doc().strings, node, self.note_draft.items) catch return;
        }
        self.commitTextFieldEdit();
        self.cmdMarkDirty("正文已修改");
    }

    /// 侧栏连线标题输入框的草稿（同 sideTitleDraft）。
    pub fn sideLinkDraft(self: *App, node: *model.Node) *std.ArrayList(u8) {
        if (self.link_draft_node != node.id) {
            self.link_draft.clearRetainingCapacity();
            self.link_draft.appendSlice(self.gpa, node.link.slice()) catch {};
            self.link_draft_node = node.id;
        }
        return &self.link_draft;
    }

    pub fn commitSideLink(self: *App, node: *model.Node) void {
        if (!node.link.eqlSlice(self.link_draft.items)) {
            model.setLink(&self.doc().strings, node, self.link_draft.items) catch return;
        }
        self.commitTextFieldEdit();
        self.cmdMarkDirty("连线标题已修改");
    }

    /// 当前正在编辑的节点（node_title = 节点本身；edge_title = 边的子节点端）。
    pub fn editingNode(self: *App) ?*model.Node {
        if (self.editing == .none) return null;
        return model.find(self.doc().root, self.editing_id);
    }

    /// dvui 没有双击事件，这里按「同目标 + 400ms 内 + 6px 内」自行判定。
    /// 调用后无论是否构成双击都会记录本次点击，供下一次比较。
    pub fn clickIsDouble(self: *App, kind: EditKind, id: u32, x: f32, y: f32, now_ms: i64) bool {
        const target = (@as(u64, @backingInt(kind)) << 32) | @as(u64, id);
        const dx = x - self.last_click_x;
        const dy = y - self.last_click_y;
        const is_double = target == self.last_click_target and
            (now_ms - self.last_click_ms) <= dbl_click_max_ms and
            (dx * dx + dy * dy) <= dbl_click_max_dist * dbl_click_max_dist;
        self.last_click_ms = now_ms;
        self.last_click_x = x;
        self.last_click_y = y;
        self.last_click_target = target;
        return is_double;
    }

    // ---------------------------------------------------------------
    // 文件命令（多文档：打开进新标签、保存/另存为作用于当前标签）
    // ---------------------------------------------------------------

    /// 打开：弹系统文件选择对话框，把选中的文件**开成新标签**；
    /// 若该文件已在某个标签里，直接切到那个标签。
    /// 用户取消则保持原状。未启用 tinyfiledialogs 时退化为直接加载当前标签路径。
    pub fn cmdOpen(self: *App) void {
        self.cmdCommitEdit(); // 打开新标签前先提交当前编辑
        if (!dvui.useTinyFileDialogs) {
            _ = self.openPathAsTab(self.doc().pathSlice());
            return;
        }
        const picked = dvui.dialogNativeFileOpen(self.gpa, .{
            .title = "打开脑图",
            .path = self.dialogStartPath(),
            .filters = &.{"*.mcab"},
            .filter_description = "脑图文件 (*.mcab)",
        }) catch {
            self.setStatus("打开失败：无法弹出系统对话框");
            return;
        };
        const p = picked orelse {
            self.setStatus("已取消打开");
            return;
        };
        defer self.gpa.free(p);
        _ = self.rememberPath(p);
        _ = self.openPathAsTab(p);
    }

    /// 保存当前标签：已有路径直接写盘；未命名的新标签自动走「另存为」。
    pub fn cmdSave(self: *App) void {
        self.cmdCommitEdit(); // 编辑中的标题先提交，否则存的是旧文本
        const d = self.doc();
        if (!d.hasPath()) {
            self.cmdSaveAs();
            return;
        }
        _ = self.saveDoc(d);
    }

    /// 另存为：弹系统保存对话框选定路径后写入（当前标签获得该路径）。
    pub fn cmdSaveAs(self: *App) void {
        self.cmdCommitEdit(); // 同 cmdSave：提交编辑中的标题
        const d = self.doc();
        if (!dvui.useTinyFileDialogs) {
            // 无对话框可用：退化为写到最后一次用过的路径
            const fallback = self.lastPathSlice();
            if (fallback.len == 0) {
                self.setStatus("没有可用的文件路径");
                return;
            }
            if (!d.setPath(fallback)) {
                self.setStatus("保存失败：路径过长");
                return;
            }
            _ = self.saveDoc(d);
            return;
        }
        const picked = dvui.dialogNativeFileSave(self.gpa, .{
            .title = "保存脑图",
            .path = self.dialogStartPath(),
            .filters = &.{"*.mcab"},
            .filter_description = "脑图文件 (*.mcab)",
        }) catch {
            self.setStatus("保存失败：无法弹出系统对话框");
            return;
        };
        const p = picked orelse {
            self.setStatus("已取消保存");
            return;
        };
        defer self.gpa.free(p);
        if (!d.setPath(p)) {
            self.setStatus("保存失败：路径过长");
            return;
        }
        _ = self.rememberPath(p);
        _ = self.saveDoc(d);
    }

    /// 执行挂号中的文件操作（在整帧 UI 绘制完毕后调用）。
    /// 对话框是阻塞式、必须放在本帧 UI 全画完之后才弹——否则菜单不消失。
    pub fn runPendingFileAction(self: *App) void {
        switch (self.pending_file_action) {
            .none => {},
            .open => self.cmdOpen(),
            .save => self.cmdSave(),
            .save_as => self.cmdSaveAs(),
            .export_png => self.cmdExportPngPick(),
            .export_docx => self.cmdExportDocxPick(),
            .export_md => self.cmdExportMdPick(),
            .pick_image => self.runPickImage(),
        }
        self.pending_file_action = .none;
    }

    /// 「文件 → 导出 → 导出为 PNG」的第一步：弹保存对话框选定路径。
    /// 拿到路径后存入 pending_export_path；真正导出在 runPendingExport 里做。
    pub fn cmdExportPngPick(self: *App) void {
        self.cmdExportPick(.png);
    }

    /// 「文件 → 导出 → 导出为 docx」：同 PNG 的两步挂号，格式不同。
    pub fn cmdExportDocxPick(self: *App) void {
        self.cmdExportPick(.docx);
    }

    /// 「文件 → 导出 → 导出为 Markdown」：同 docx 的两步挂号，格式不同。
    pub fn cmdExportMdPick(self: *App) void {
        self.cmdExportPick(.md);
    }

    fn cmdExportPick(self: *App, kind: ExportKind) void {
        self.cmdCommitEdit(); // 导出读的是节点树，编辑中的标题必须先落进树
        self.pending_export_kind = kind;
        const ext, const title, const filter_desc = switch (kind) {
            .png => .{ "png", "导出为 PNG", "PNG 图片 (*.png)" },
            .docx => .{ "docx", "导出为 docx", "Word 文档 (*.docx)" },
            .md => .{ "md", "导出为 Markdown", "Markdown 文档 (*.md)" },
        };
        if (!dvui.useTinyFileDialogs) {
            // 没有系统对话框就退化为「导出到当前文档同目录」的目标文件
            const guess = self.exportDialogStartPath(ext);
            self.pending_export_path = self.gpa.dupe(u8, guess) catch {
                self.setStatus("导出失败：内存不足");
                return;
            };
            return;
        }
        const picked = dvui.dialogNativeFileSave(self.gpa, .{
            .title = title,
            .path = self.exportDialogStartPath(ext),
            .filters = &.{switch (kind) {
                .png => "*.png",
                .docx => "*.docx",
                .md => "*.md",
            }},
            .filter_description = filter_desc,
        }) catch {
            self.setStatus("导出失败：无法弹出系统对话框");
            return;
        };
        const p = picked orelse {
            self.setStatus("已取消导出");
            return;
        };
        defer self.gpa.free(p);
        // 系统对话框不自动补扩展名：用户填的名字没有目标后缀就补上
        self.pending_export_path = pathWithExt(self.gpa, p, ext) catch {
            self.setStatus("导出失败：内存不足");
            return;
        };
    }

    /// 导出对话框的初始文件名：当前文档名换成指定后缀（目录跟着文档走）；
    /// 已知的文档/导出后缀（.mcab，兼容旧档的 .xml，以及 .png/.docx/.md）
    /// 先剥掉再换，从没保存过则用 mindmap.<ext>。写入模块级缓冲，调用方
    /// 当场传给对话框，一次性消费（与 title_buf 同生命周期策略）。
    pub fn exportDialogStartPath(self: *App, ext: []const u8) []const u8 {
        const p = self.doc().pathSlice();
        if (p.len == 0) return std.fmt.bufPrint(&export_start_buf, "mindmap.{s}", .{ext}) catch "mindmap";
        var stem_len = p.len;
        inline for (.{ ".mcab", ".xml", ".png", ".docx", ".md" }) |known| {
            if (std.ascii.endsWithIgnoreCase(p, known)) stem_len -= known.len;
        }
        return std.fmt.bufPrint(&export_start_buf, "{s}.{s}", .{ p[0..stem_len], ext }) catch "mindmap";
    }

    /// 执行挂号中的导出（PNG 或 docx，按 pending_export_kind 分派）。
    /// **必须在 Window.begin/end 期间调用**（PNG 的 Picture 需要当前窗口；
    /// docx 纯内存生成，放这里只是共用流程）。
    /// 成功/失败后清空 pending_export_path 并 free。
    pub fn runPendingExport(self: *App) void {
        const path = self.pending_export_path orelse return;
        defer {
            self.gpa.free(path);
            self.pending_export_path = null;
        }
        switch (self.pending_export_kind) {
            .png => {
                const canvas = @import("canvas.zig");
                canvas.exportToPng(self, path) catch |err| {
                    self.setStatus(switch (err) {
                        error.PictureInitFailed => "导出失败：无法创建离屏纹理",
                        error.OpenWriteFailed => "导出失败：无法写入文件",
                        else => "导出失败",
                    });
                    return;
                };
                self.setStatus("已导出为 PNG");
            },
            .docx => {
                docx.exportToDocx(self.gpa, self.io, self.doc().root, path) catch |err| {
                    self.setStatus(switch (err) {
                        error.OpenWriteFailed => "导出失败：无法写入文件",
                        else => "导出失败",
                    });
                    return;
                };
                self.setStatus("已导出为 docx");
            },
            .md => {
                markdown.exportToMarkdown(self.gpa, self.io, self.doc().root, path) catch |err| {
                    self.setStatus(switch (err) {
                        error.OpenWriteFailed => "导出失败：无法写入文件",
                        else => "导出失败",
                    });
                    return;
                };
                self.setStatus("已导出为 Markdown");
            },
        }
    }

    /// 执行挂号中的标签操作（会增删 docs，必须等标签栏遍历结束后）。
    pub fn runPendingTabAction(self: *App) void {
        const index = self.pending_tab_index;
        switch (self.pending_tab_action) {
            // 无事可做时必须直接返回：本函数 guiFrame 每帧都调，
            // 无条件 dvui.refresh 会让主循环永远等不到空闲（CPU/GPU 常驻 26%）。
            .none => return,
            .new => self.cmdNewDoc() catch self.setStatus("新建失败：内存不足"),
            .close => self.cmdCloseTab(index),
        }
        self.pending_tab_action = .none;
        dvui.refresh(null, @src(), null);
    }

    /// 请求退出：有未保存修改时先弹确认框（可在框里改主意）。
    pub fn cmdRequestQuit(self: *App) void {
        if (self.dirtyCount() > 0) {
            self.showConfirm(.quit, 0);
            return;
        }
        self.want_quit = true;
    }

    /// 「帮助 → 关于」：模态对话框展示版本号与作者。
    pub fn cmdShowAbout(self: *App) void {
        _ = self;
        dvui.dialog(@src(), .{}, .{
            .title = "关于",
            .message = "脑图编辑器\n\n版本：" ++ app_version ++ "\n作者：" ++ app_author,
            .ok_label = "关闭",
            .displayFn = aboutDisplay,
        });
    }

    /// 「关于」对话框的自定义绘制：在标准框（标题栏 + 文案 + 关闭按钮）的
    /// 基础上，把微信公众号二维码图片画在文案下方。二维码字节由 @embedFile
    /// 编进 exe（见 wxqrcode_jpg），发布单文件即可，无需附带图片文件。
    fn aboutDisplay(id: dvui.Id) !void {
        // 以下数据键与 dvui.dialog 的标准装配一一对应（displayFn 替换时可用）
        const modal = dvui.dataGet(null, id, "_modal", bool) orelse {
            dvui.dialogRemove(id);
            return;
        };
        const title = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
            dvui.dialogRemove(id);
            return;
        };
        const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
            dvui.dialogRemove(id);
            return;
        };
        const ok_label = dvui.dataGetSlice(null, id, "_ok_label", []u8) orelse {
            dvui.dialogRemove(id);
            return;
        };
        const center_on = dvui.dataGet(null, id, "_center_on", dvui.Rect.Natural) orelse dvui.currentWindow().subwindows.current_rect;

        var win = dvui.floatingWindow(@src(), .{ .modal = modal, .center_on = center_on, .window_avoid = .nudge }, .{ .role = .dialog, .id_extra = id.asUsize() });
        defer win.deinit();

        var header_openflag = true;
        win.dragAreaSet(dvui.windowHeader(title, "", &header_openflag));
        if (!header_openflag) {
            dvui.dialogRemove(id);
            return;
        }

        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .margin = .all(4) });
        defer vbox.deinit();

        dvui.label(@src(), "{s}", .{message}, .{ .gravity_x = 0.5 });

        // 公众号二维码：固定显示尺寸，二维码按比例缩放不影响扫码
        const image_source: dvui.ImageSource = .{ .imageFile = .{ .bytes = wxqrcode_jpg, .name = "wxqrcode.jpg" } };
        _ = dvui.image(@src(), .{ .source = image_source, .shrink = .ratio }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = 200, .h = 200 },
            .label = .{ .text = "微信公众号二维码" },
        });
        dvui.label(@src(), "使用帮助和技巧", .{}, .{ .gravity_x = 0.5, .font = descFont(), .margin = .{ .y = 4, .x = 0, .h = 0, .w = 0 } });

        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 1.0, .margin = .all(4) });
            defer hbox.deinit();
            if (dvui.button(@src(), ok_label, .{}, .{ .gravity_x = 1.0 })) {
                dvui.dialogRemove(id);
            }
        }
    }

    /// 「图片预览」：点击节点图片弹出（canvas.drawNodes 的图片命中分支调用）。
    /// 全窗口模态：占满整个 OS 窗口，标题栏 + Esc / 点击任意处 / 关闭按钮退出。
    /// 图片字节直接引用文档图片池——模态框打开期间画布、侧栏、菜单全被挡住，
    /// 撤销（快照不含图片池，池不被替换）也不会动这些字节，引用安全。
    pub fn cmdShowImagePreview(self: *App, node: *model.Node) void {
        const asset = self.imageAsset(node) orelse return;
        // 资源指针进对话框数据（dataGet 每帧保活）。不传字节切片：
        // dvui.dialog 的 user_struct 切片字段在本 dvui+zig0.17 组合下会被
        // 当成单值存（stored []u8 single_item），dataGetSlice 取回直接 panic。
        // 模态框打开期间文档不可改、图片池不被撤销快照替换，指针稳定。
        dvui.dialog(@src(), .{
            .asset = asset,
        }, .{
            .title = "图片预览",
            .message = "",
            .ok_label = "关闭",
            .displayFn = imagePreviewDisplay,
        });
    }

    /// 图片预览对话框的绘制：floatingWindow 直接给整窗 rect（区别于
    /// aboutDisplay 的自适应小窗），图片在可用区内保持纵横比铺满。
    fn imagePreviewDisplay(id: dvui.Id) !void {
        const modal = dvui.dataGet(null, id, "_modal", bool) orelse {
            dvui.dialogRemove(id);
            return;
        };
        const title = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
            dvui.dialogRemove(id);
            return;
        };

        // 保活用户数据（asset 指针）：本函数每帧 dataGet 即保活（Data 的
        // 过期规则：一帧内没有任何 dataGet/dataSet 的键被释放）
        const asset = dvui.dataGet(null, id, "asset", *model.ImageAsset) orelse {
            dvui.dialogRemove(id);
            return;
        };

        // 整窗 rect：既当初始尺寸也当居中基准（auto_pos 重心重算仍得全窗）；
        // window_avoid = .none，否则「正好占满」会被当成重叠往下挤 24px
        const win_r = dvui.windowRect();
        var win = dvui.floatingWindow(@src(), .{
            .modal = modal,
            .center_on = win_r,
            .window_avoid = .none,
            .resize = .none, // 已占满整窗，边缘缩放无意义
        }, .{
            .role = .dialog,
            .id_extra = id.asUsize(),
            // Options.rect 是 Rect（natural 坐标的 none-flavor），windowRect 返回 Natural
            .rect = dvui.Rect.cast(win_r),
        });
        defer win.deinit();

        var header_openflag = true;
        win.dragAreaSet(dvui.windowHeader(title, "", &header_openflag));
        if (!header_openflag) {
            dvui.dialogRemove(id);
            return;
        }

        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .all(8) });
        defer vbox.deinit();

        // 可用区（整窗减标题栏与边距）内等比缩放，但**只缩小、不放大**：
        // 小图按原始像素尺寸居中显示，避免低分辨率图片被拉大后发虚。
        // （placeIn 的 .ratio 会把小图也铺满可用区，所以再用自然尺寸夹一次。）
        const avail = vbox.data().contentRect();
        const source: dvui.ImageSource = .{ .imageFile = .{
            .bytes = asset.data.items,
            .name = if (asset.img_type.items.len > 0) asset.img_type.items else "png",
            // 图片池内容只在节点编辑时变（模态期间不可能），.bytes 无妨
            .invalidation = .bytes,
        } };
        const nat = dvui.imageSize(source) catch dvui.Size{ .w = avail.w, .h = avail.h };
        const fit = dvui.placeIn(avail, nat, .ratio, .{ .x = 0.5, .y = 0.5 });
        // 两个分量同取 min 不会破坏纵横比：大图时 fit 等比≤nat，小图时 nat≤fit。
        const shown = dvui.Size{
            .w = @min(nat.w, fit.w),
            .h = @min(nat.h, fit.h),
        };
        const shown_rect = dvui.Rect{
            .x = avail.x + (avail.w - shown.w) / 2,
            .y = avail.y + (avail.h - shown.h) / 2,
            .w = @max(shown.w, 1),
            .h = @max(shown.h, 1),
        };
        _ = dvui.image(@src(), .{ .source = source, .shrink = .ratio }, .{
            .rect = shown_rect,
            .min_size_content = .{ .w = shown_rect.w, .h = shown_rect.h },
            .label = .{ .text = "节点图片预览" },
        });

        // Esc / 点击任意处关闭。对话框绘制在 Window.end：此时 keys.afterWidgets
        // 因 anyDialogOpen 已跳过全部按键，Esc 一定落到这里；
        // 标题栏（拖动 / 关闭 X）与前面控件已把各自的事件标 handled，
        // 能到这里还没被处理的 press 只可能是点在窗口背景或图片上。
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            switch (e.evt) {
                .key => |ke| if (ke.action == .down and ke.code == .escape) {
                    e.handle(@src(), win.data());
                    dvui.dialogRemove(id);
                    return;
                },
                .mouse => |me| if (me.action == .press) {
                    e.handle(@src(), win.data());
                    dvui.dialogRemove(id);
                    return;
                },
                else => {},
            }
        }
    }

    // ---------------------------------------------------------------
    // 最近打开的文件（%USERPROFILE%/.mindcab/history.toml）
    // ---------------------------------------------------------------

    /// 「最近打开的文件」子菜单点击：载入成新标签（成功即已记录进历史）。
    pub fn cmdOpenRecent(self: *App, path: []const u8) void {
        _ = self.openPathAsTab(path);
    }

    /// 菜单里钉住/取消钉住某条历史。
    pub fn recentSetPinned(self: *App, path: []const u8, pinned: bool) void {
        self.recent.setPinned(path, pinned);
        self.flushRecent();
    }

    /// 菜单里删除某条历史（免确认）。
    pub fn recentRemove(self: *App, path: []const u8) void {
        self.recent.remove(path);
        self.flushRecent();
    }

    /// 打开/保存成功后记录进历史并落盘（去重、提升到所在区顶部）。
    fn recordRecent(self: *App, path: []const u8) void {
        self.recent.record(path) catch return; // OOM：历史尽力而为，不影响主流程
        self.flushRecent();
    }

    /// 历史有变即整份重写（文件小、频次低；flush 内部临时文件 + rename 原子替换）。
    fn flushRecent(self: *App) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const hist = recent_files.defaultPath(&buf) orelse return;
        self.recent.flush(self.io, hist);
    }

    /// 把文件载入成新标签；返回是否成功（已在别处打开则切过去，也算成功）。
    fn openPathAsTab(self: *App, path: []const u8) bool {
        if (path.len == 0) {
            self.setStatus("没有可用的文件路径");
            return false;
        }
        if (self.indexOfPath(path)) |i| {
            self.activateTab(i);
            self.setStatus("该文件已在标签页中打开，已切换过去");
            return true;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .unlimited) catch {
            self.setStatus("打开失败：无法读取文件");
            return false;
        };
        defer self.gpa.free(data);
        var loaded = xml.loadEx(self.gpa, data) catch {
            self.setStatus("打开失败：XML 解析错误");
            return false;
        };
        const new_root = loaded.root;
        // 文档带 position="true"：按保存的 left/top 恢复各节点视口位置
        //（差值折算成拖拽偏移，之后每帧自动重排版结果不变）
        if (loaded.positioned) {
            layout.restoreSavedPositions(new_root, null, App.measureText);
        }
        const index = self.appendDoc(new_root, model.maxId(new_root) + 1, new_root.id, path, 0, loaded.images, loaded.strings) catch {
            new_root.deinit(self.gpa);
            loaded.images.deinit(self.gpa);
            loaded.strings.deinit();
            self.setStatus("打开失败：内存不足");
            return false;
        };
        self.activateTab(index);
        self.setStatus("已在新标签页打开");
        self.recordRecent(path);
        return true;
    }

    /// 写盘；成功返回 true（并清掉该文档的脏标记）。
    fn saveDoc(self: *App, d: *Doc) bool {
        const path = d.pathSlice();
        if (path.len == 0) {
            self.setStatus("没有可用的文件路径");
            return false;
        }
        const doc_xml = xml.save(d.root, &d.images, self.gpa) catch {
            self.setStatus("保存失败：内存不足");
            return false;
        };
        defer self.gpa.free(doc_xml);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = doc_xml }) catch {
            self.setStatus("保存失败：无法写入文件");
            return false;
        };
        d.dirty = false;
        _ = self.rememberPath(path);
        self.recordRecent(path); // 另存为得到的新路径也要进「最近打开的文件」
        self.setStatus("已保存");
        return true;
    }

    /// 记住最近一次用过的路径，供下次对话框定位。
    fn rememberPath(self: *App, path: []const u8) bool {
        if (path.len == 0 or path.len >= self.last_path_buf.len) return false;
        @memset(&self.last_path_buf, 0);
        @memcpy(self.last_path_buf[0..path.len], path);
        return true;
    }

    fn lastPathSlice(self: *const App) []const u8 {
        return self.last_path_buf[0..strLen(&self.last_path_buf)];
    }

    /// 文件对话框的初始路径：当前文档路径 → 最近用过的路径 → mindmap.mcab。
    fn dialogStartPath(self: *App) []const u8 {
        const p = self.doc().pathSlice();
        if (p.len > 0) return p;
        const l = self.lastPathSlice();
        if (l.len > 0) return l;
        return "mindmap.mcab";
    }

    // ---------------------------------------------------------------
    // 「有未保存修改」确认框（自定义 2/3 按钮模态框）
    // ---------------------------------------------------------------

    fn showConfirm(self: *App, kind: ConfirmKind, index: usize) void {
        // 文案要显示文档名，只能在这里（对话框显示函数拿不到 App）拼好，
        // 结果写在模块级缓冲里，生命周期覆盖对话框的显示与下一帧消费。
        _ = switch (kind) {
            .close_tab => std.fmt.bufPrint(
                &confirm_msg_buf,
                "「{s}」有未保存的修改。\n\n保存：先写入文件再关闭\n不保存：丢弃修改并关闭\n取消：回到编辑器",
                .{self.docTitle(index)},
            ) catch null,
            .quit => std.fmt.bufPrint(
                &confirm_msg_buf,
                "有 {d} 个标签页存在未保存的修改，退出将丢失这些修改。\n\n放弃并退出：直接关闭程序\n取消：回到编辑器",
                .{self.dirtyCount()},
            ) catch null,
        };
        const idm = dvui.dialogAdd(null, @src(), @backingInt(kind), confirmDisplay);
        const id = idm.id;
        dvui.dataSet(null, id, "_kind", @backingInt(kind));
        dvui.dataSet(null, id, "_index", index);
        // 只存有效长度：bufPrint 之后的缓冲尾部是未初始化的 0，整片交给 textLayout
        // 会把每个 \0 当缺字形字符渲染成小方块（实测：正文后跟 ~200 个方框）
        dvui.dataSetSlice(null, id, "_message", confirm_msg_buf[0..strLen(&confirm_msg_buf)]);
        idm.mutex.unlock(dvui.io);
    }

    /// 第 index 个标签的标题（越界时给个占位名）。
    /// 注意 Doc.title() 写调用方缓冲区、返回的切片绑定该缓冲区：
    /// 必须用模块级缓冲（调用方 showConfirm 在同一表达式内消费，不会有两个
    /// 标题同时存活）。用局部 buf 会返回悬空栈指针——实测「未命名1」的
    /// 「名1」两字被后续 bufPrint 的栈帧覆写、渲染成方块。
    pub fn docTitle(self: *App, index: usize) []const u8 {
        if (index >= self.docs.items.len) return "文档";
        return self.docs.items[index].title(&title_buf);
    }

    /// 消费上一帧确认框的结果（在 guiFrame 开头调用）。
    pub fn runPendingConfirm(self: *App) void {
        const p = pending_confirm orelse return;
        pending_confirm = null;
        switch (p.kind) {
            .close_tab => switch (p.choice) {
                .cancel => self.setStatus("已取消关闭"),
                .discard => self.closeTabAt(p.index),
                .save => {
                    if (p.index >= self.docs.items.len) return;
                    if (!self.docs.items[p.index].hasPath()) {
                        // 未命名文档没有落点：先补一次「另存为」，取消则标签保留
                        self.active = p.index;
                        self.pending_file_action = .save_as;
                        self.setStatus("请先选择保存位置");
                        return;
                    }
                    if (!self.saveDoc(&self.docs.items[p.index])) {
                        self.setStatus("保存失败，标签页未关闭");
                        return;
                    }
                    self.closeTabAt(p.index);
                },
            },
            .quit => switch (p.choice) {
                .cancel => self.setStatus("已取消退出"),
                else => self.want_quit = true,
            },
        }
    }

    // ---------------------------------------------------------------
    // 查询辅助
    // ---------------------------------------------------------------

    pub fn selectedNode(self: *App) ?*model.Node {
        const d = self.doc();
        const sid = d.selected_id orelse return null;
        return model.find(d.root, sid);
    }

    pub fn statusSlice(self: *const App) []const u8 {
        return self.status_buf[0..strLen(&self.status_buf)];
    }

    /// model.Rgba → dvui.Color（画布节点框与侧栏色板共用）。
    pub fn dvuiColor(c: model.Rgba) dvui.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }

    pub fn setStatus(self: *App, msg: []const u8) void {
        @memset(&self.status_buf, 0);
        const n = @min(msg.len, self.status_buf.len - 1);
        @memcpy(self.status_buf[0..n], msg[0..n]);
    }

    /// 文本测量回调（绑定 dvui 字体），供 layout 使用。
    /// 标题用正文字号，正文描述按 metrics.desc_font_delta 缩小。
    pub fn measureText(ctx: ?*anyopaque, text: []const u8, kind: layout.TextKind) layout.Size {
        _ = ctx;
        const font = switch (kind) {
            .title => dvui.themeGet().font_body,
            .desc => descFont(),
        };
        return measureMultiline(font, text);
    }

    /// 多行文本的包围尺寸：宽取最宽行，高按 dvui LabelWidget 的逐行渲染
    /// 公式累加（每行 `font.textSize(line).h`，行间 `textHeight()*(line_height_factor-1)`）。
    ///
    /// 之所以不直接用 `Font.textSize`：它行间用「上一行的 s.h*(factor-1)」，
    /// LabelWidget 用「font.textHeight()*(factor-1)」，两者在行高不等时会岔开；
    /// 节点框、标签 rect、布局测量三处必须与实际绘制**逐像素一致**，
    /// 否则第二行会被裁掉（report 缺陷 3）。
    pub fn measureMultiline(font: dvui.Font, text: []const u8) layout.Size {
        const line_gap = font.textHeight() * (font.line_height_factor - 1.0);
        var w: f32 = 0;
        var h: f32 = 0;
        var first = true;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (!first) h += line_gap;
            first = false;
            const s = font.textSize(line);
            h += s.h;
            w = @max(w, s.w);
        }
        if (first) {
            // 空文本：splitScalar 至少产出一段，此分支仅防万一，取单行高
            h = font.textHeight();
        }
        return .{ .w = w, .h = h };
    }

    /// 正文描述字体（标题字体的略小变体，画布与测量共用，保证尺寸一致）。
    pub fn descFont() dvui.Font {
        return dvui.themeGet().font_body.larger(layout.metrics.desc_font_delta);
    }

    /// 一键布局：测量 + 布局 + 偏移 + 包围盒（只针对当前标签的树）。
    pub fn layoutTree(self: *App) layout.Bounds {
        return layout.layoutAll(self.doc().root, null, measureText);
    }
};

// ---------------------------------------------------------------------------
// 确认框的显示函数（在 Window.end 阶段由 dvui 调用）
// ---------------------------------------------------------------------------

fn confirmFinish(id: dvui.Id, kind: ConfirmKind, choice: ConfirmChoice, index: usize) void {
    dvui.dialogRemove(id);
    pending_confirm = .{ .kind = kind, .choice = choice, .index = index };
}

/// 确认框的显示函数：仿 dvui.dialogDisplay，但按钮可自定义数量。
fn confirmDisplay(id: dvui.Id) !void {
    const kind_code: u8 = dvui.dataGet(null, id, "_kind", u8) orelse {
        dvui.dialogRemove(id);
        return;
    };
    const kind: ConfirmKind = @fromBackingInt(@intCast(kind_code));
    const index: usize = dvui.dataGet(null, id, "_index", usize) orelse 0;
    const msg = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        dvui.dialogRemove(id);
        return;
    };

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .center_on = dvui.currentWindow().subwindows.current_rect,
        .window_avoid = .nudge,
    }, .{ .role = .dialog, .id_extra = id.asUsize() });
    defer win.deinit();

    var header_openflag = true;
    win.dragAreaSet(dvui.windowHeader(if (kind == .close_tab) "关闭标签页" else "退出", "", &header_openflag));
    if (!header_openflag) {
        confirmFinish(id, kind, .cancel, index);
        return;
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 1.0 });
        defer hbox.deinit();
        if (dvui.button(@src(), "取消", .{}, .{ .tab_index = 1 })) {
            confirmFinish(id, kind, .cancel, index);
            return;
        }
        if (kind == .close_tab and dvui.button(@src(), "不保存", .{}, .{ .tab_index = 2 })) {
            confirmFinish(id, kind, .discard, index);
            return;
        }
        if (dvui.button(@src(), if (kind == .close_tab) "保存并关闭" else "放弃并退出", .{}, .{ .tab_index = 3 })) {
            confirmFinish(id, kind, if (kind == .close_tab) .save else .discard, index);
            return;
        }
    }

    // 按钮先画（保证可见），剩下的空间给消息文本
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    var tl = dvui.textLayout(@src(), .{}, .{ .background = false });
    tl.addText(msg, .{});
    tl.deinit();
    scroll.deinit();
}

fn strLen(buf: []const u8) usize {
    return std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
}
