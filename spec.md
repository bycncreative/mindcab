# zmind 2.0 — 节点图片（img）与属性（property）规格

## 1. 背景与目标

基于 1.0（源码已复制至本工程）升级：

1. 保存的 mcab 文件写 `<mindmap version="2">`，图片数据集中在 `<images>` 池里，
   `<node>` 只用 `<img ref="id" />` 引用：
   ```xml
   <mindmap version="2" position="true">
     <images>
       <img id="<md5>" type="png" md5="<md5>">BASE64数据</img>
     </images>
     <node id="1" text="中心主题">
       <node id="2" text="分支一">
         <img ref="<md5>" />
         <property name="权重">1</property>（可多条）
       </node>
     </node>
   </mindmap>
   ```
   `id` 取图片内容的 md5（32 位小写十六进制），`md5` 属性是它的缓存值；
   同一张图片（内容相同）自动复用同一 id，文件里只存一份。
2. 渲染：有 img 的节点在开头绘制图片图标；有 property 的节点在框下方显示属性表格（灰色属性名格 + 浅绿色值格，逐行）。
3. 侧栏（属性面板）提供编辑：「从磁盘加载图片」（读入后按 md5 进图片池，已有同图复用 id）、属性名/值增删改，均带撤销。
4. 1.0 的 mcab 文件仍可加载（version=1 无 img/property，正常读）；2.0 早期把 base64
   内联在节点 `<img type="...">` 里的文件也能读（读取时转成图片池 + ref）。

## 2. 数据模型 — `src/model.zig`

文档级图片池 + 节点只存引用：

```zig
pub const ImageAsset = struct {  // 池里的一项
    id: std.ArrayList(u8),       // 内容寻址 id（= md5 十六进制）
    img_type: std.ArrayList(u8), // jpg / png
    md5: std.ArrayList(u8),      // 内容 md5（十六进制）
    data: std.ArrayList(u8),     // 原始二进制
};

pub const ImageStore = struct { items: std.ArrayList(ImageAsset) };
// findById / findByMd5 / add / ensure（按 md5 去重复用）/ count

pub const Node = struct {
    img_ref: std.ArrayList(u8) = .empty,  // 引用池内某项的 id；空 = 无图片
    properties: std.ArrayList(Property) = .empty,
};
```

配套修改：

- `Node.deinit` 释放 `img_ref`（不再持有图片数据）；`Doc.deinit` 释放 `Doc.images`。
- `cloneTree` 深拷贝 `img_ref`/properties（撤销镜像只复制引用，图片数据共享池）。
- `ImageStore` 只增不删（撤销/换图后重做仍能找回数据）；保存时只写当前树引用到的资源。
- 辅助方法：
  - `pub fn hasImg(self) bool` → `img_ref.items.len > 0`
  - `pub fn setImgRef(gpa, id) !void` / `pub fn clearImgRef(node) void`
  - `pub fn addProperty(gpa, list, name, value) !void` / `removeProperty(gpa, list, idx) void`（命名可按现有风格调整）

内存策略：与 text/note/link 一致 —— 节点持有 dupe 后的堆内存，生命周期归节点。

## 3. XML 序列化 — `src/xml.zig`

### 保存（version=2）

- `save()`：根标签 `version="1"` → `version="2"`（`position="true"` 等其余属性不变）。
- `writeNode()`：在 `<node ...>` 开头之后（即自闭合/子节点之前）先写子元素：
  ```xml
  <img type="jpg">BASE64</img>
  <property name="权重">1</property>
  ```
  - base64 编码：`std.base64.standard.Encoder`，写入 `ArrayList(u8)` 后输出，写完释放。
  - name 属性值与 property 值需经现有 `escape()` 转义；img 的 base64 字符（`A-Za-z0-9+/=`）无需转义但仍走同一写出路径无害。
  - 有子节点时保持现有 `<node ...>` / `<node>` 结构顺序：属性 → img/property → 子 node → `</node>`。

### 加载

- `Parser.parseNode()` 循环内识别子元素：
  - `img`：读 `type` 属性；读元素文本（原始 base64，不做 unescape——base64 无实体字符，但沿用读文本函数即可）；`std.base64.standard.Decoder` 解码，存 `img_data`；解码失败则丢弃图片（容错，不报错中断）。
  - `property`：读 `name` 属性；元素文本为值；unescape 后 append 到 `properties`。
  - 未知子元素：保持现有容错策略（跳过至匹配的闭合标签）。
- version 属性本身不参与分支——1.0 文件无这两类子元素，天然兼容。

## 4. 布局测量 — `src/layout.zig`

`measure()` 中，除标题/描述外：

- **图片图标**：有 img 时，标题前（内容开头）预留一个图标位：
  - 图标尺寸常量放 `Metrics`：`img_icon: f32 = 24`（24×24），间距 `img_gap: f32 = 4`。
  - 宽度：`content_w = title_w`；若有 img：`content_w = img_icon + img_gap + title_w`（图片在首行与标题同行，垂直居中）。
  - 高度：首行高度 `line_h = @max(title_h, img_icon)`；`h = line_h`（+ 描述部分，同现状）。
- **property 表格**：高度追加到节点框内（表格在框内底部，按截图挂在节点下方、属于节点框一部分）：
  - 每行高 `prop_row_h: f32 = 18`，行间无额外间隙（贴合截图的表格样式）。
  - `h += properties.len * prop_row_h`。
  - 宽度：表格不撑宽节点（表格左右对齐内容区；值文本截断/省略不做——超出部分允许被裁剪，一期不做换行）。**决策：表格宽度 = 节点内容区宽，name 格占 40%（最小 48px），value 格占余下。**
- geom.w/h 仍按现有 `pad_x/pad_y`、`node_min_*`、`user_w/user_h` 规则合成。

## 5. 绘制 — `src/canvas.zig`（drawNodes 内容区，显式 rect 路径）

节点内容区（box 内）自上而下：

1. **首行**（有 img 时）：在内容区左上角画 24×24 图片图标，右侧留 `img_gap` 后画标题（标题 rect 相应右移；无 img 时标题位置与现状完全一致）。
   - 图片绘制用 `dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = data, .name = img_type } }, .shrink = .ratio }, .{ .rect = ... })` 风格；**必须支持显式 rect**（导出第二遍 expand 不渲染）——若 dvui.image 的 wd 参数支持 `.rect` 则直接用；否则退化为在该 rect 画裁剪框 + image（实现时以 dvui 0.6.0-dev 实际 API 为准）。
   - 离屏导出（renderMap 第二遍）必须同样绘制图标。
2. **描述**（现状不变，位于首行下方）。
3. **property 表格**（有属性时，位于描述/标题下方，贴内容区底部）：
   - 每行两个单元格：左格背景灰（`dvui.Color{ .r=0.85, .g=0.85, .b=0.85 }`，即截图的灰），右格背景浅绿（`{ .r=0.82, .g=0.93, .b=0.82 }`）。
   - 单元格边框 1px 深灰描线；格内文字用显式 rect 标签绘制，左对齐、垂直居中，字号用 `descFont()`。
   - 表格整体 = 节点框内容区宽 × `len × prop_row_h`。
   - 绘制顺序：先于文字标签画底色矩形（用 `dvui.box` + 显式 rect 或 `dvui.renderGeometry` 矩形，以现有绘制风格为准），保证不遮挡标签。

崩溃/样式护栏：属性表与标题、描述、缩放把手、就地编辑框互不重叠 —— 由 measure 的高度叠加保证。

## 6. 侧栏编辑 UI — `src/ui.zig`（drawSidePanel，插在「节点尺寸」区之后）

当选中单个节点时显示两个新区块：

### 6.1 图片区

- 已有图片：显示缩略（复用 dvui.image，min_size 约 96px）+ 「更换」「移除」按钮。
- 无图片：仅「选择图片…」按钮。
- 点击按钮 → **帧末弹系统文件对话框**：沿用 `pending_file_action` 机制，`FileAction` 增加 `pick_image`；`runPendingFileAction` 中 `dvui.dialogNativeFileOpen`，filters `&.{ "*.jpg", "*.jpeg", "*.png" }`（type 固定写 "jpg" 仅当所选为 jpg；**决策：扩展名统一记为所选文件后缀（jpg/png），type 字段即后缀**）。
- 读文件 → `cmdSetNodeImg(id, type, bytes)`：
  - `pushUndo()` → `node.setImg(...)` → `d.dirty = true` → `setStatus("已设置节点图片")`。
- 「移除」→ `cmdClearNodeImg(id)`，同模式。
- 读文件失败 → `setStatus("读取图片失败: ...")`，不改文档。

### 6.2 属性区

- 逐行显示：name textEntry + value textEntry + 「删除」按钮（`cmdRemoveProperty(id, idx)`）。
- 底部「添加属性」按钮 → `cmdAddProperty(id)`（追加空 name/value 行）。
- textEntry 编辑沿用现有撤销会话：`trackTextField(id)` + `text_changed → commitTextFieldEdit() + cmdMarkDirty`；提交属性名/值的命令为 `cmdSetProperty(id, idx, field, text)`（pushUndo + 写值 + dirty）。
  - **决策**：为避免每次按键 pushUndo，name/value 的修改走既有 `commitTextFieldEdit` 会话（会话开始时已 pushUndo 快照），与「正文描述」完全同模式。

### 6.3 命令层 — `src/app.zig`

新增命令（全部遵循 `pushUndo() → 修改 → d.dirty = true → setStatus()`）：

- `cmdSetNodeImg(id, img_type, bytes)`
- `cmdClearNodeImg(id)`
- `cmdAddProperty(id)`
- `cmdRemoveProperty(id, index)`
- `cmdSetPropertyName(id, index, text)` / `cmdSetPropertyValue(id, index, text)`（内部只写字段，由 textEntry 会话触发）

`FileAction` 增 `pick_image`；`pending_image_target_id: ?u32`（挂起时记下目标节点 id，帧末消费）。

## 7. 版本号与资源

- `app.zig` `app_version` "1.0.3" → "2.0.0"；`src/app.rc` FILEVERSION 同步 2,0,0,0（AGENTS.md 硬约束）。

## 8. 测试 — `src/app_test.zig`

新增/扩展断言：

1. **XML roundtrip（version=2）**：构造含 img（小 JPEG 字节→base64）与 2 条 property 的树 → `xml.save` → 断言输出含 `version="2"`、`<img type="jpg">`、`<property name="权重">1</property>` → `xml.load` 回读 → 字节/名称/值逐项相等。
2. **version=1 兼容**：现有 1.0 样例文件仍可 load。
3. **cloneTree 深拷贝**：克隆后改原树 img/property，克隆体不变；双 deinit 无泄漏（现有测试框架跑 ASAN/测试 allocator）。
4. **布局**：有 property 的节点 geom.h 比无属性时大 `len*18`；有 img 时首行高 ≥ 24+pad。
5. **渲染像素**：`renderMap` 后在属性表格区域断言存在浅绿色像素、图标区域非白（延续现有像素断言写法）。
6. 撤销：`cmdSetNodeImg` 后 `cmdUndo` 恢复无图状态。

## 9. 验证步骤

1. `& c:\zig\zig.exe build test` 全绿（AGENTS.md 规定的构建/测试命令）。
2. 手动冒烟（如环境允许）：新建节点 → 侧栏选图 → 添加属性「权重/1」→ 保存 → 检查 mcab 内容 → 重开验证渲染与截图一致。

## 10. 明确不做（本期边界）

- 属性表格宽度自适应/换行、图片等比缩放策略（固定 24px 图标）。
- 拖拽导入图片、剪贴板贴图。
- `docx/markdown` 导出中带 img/property（导出保持 1.0 行为，不报错）。
