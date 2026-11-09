# tasks — zmind 2.0 img/property 实施清单

> 执行顺序即编号顺序；每步完成后运行 `& c:\zig\zig.exe build test` 保持全绿再进下一步。

- [x] T1 model.zig：`Node` 加 `img_type/img_data/properties` + `Property` 结构；改 `deinit`、`cloneTree`；加 `hasImg/setImg/clearImg` 与属性增删辅助。
- [x] T2 xml.zig：`save` 改 `version="2"`；`writeNode` 写 `<img>`/`<property>` 子元素（base64 编码 + 转义）；`Parser.parseNode` 解析两类子元素（解码失败容错丢弃）。
- [x] T3 测试：xml roundtrip v2、v1 兼容、cloneTree 深拷贝、撤销恢复（`src/app_test.zig`），跑到绿。
- [x] T4 layout.zig：`Metrics` 加 `img_icon/img_gap/prop_row_h`；`measure` 计入图标首行高与属性表高度。
- [x] T5 canvas.zig：`drawNodes` 内容区首行绘制 24×24 图标（显式 rect，离屏导出第二遍同样生效）。
- [x] T6 canvas.zig：绘制 property 表格（灰/浅绿单元格 + 1px 边框 + descFont 文字），加渲染像素断言测试。
- [x] T7 app.zig：`FileAction.pick_image` + `pending_image_target_id` + `runPendingFileAction` 文件读取；新命令 `cmdSetNodeImg/cmdClearNodeImg/cmdAddProperty/cmdRemoveProperty`（pushUndo + dirty + setStatus 模式；属性名/值由侧栏 textEntry 直绑，撤销走 trackTextField 会话，故不设独立写值命令）。
- [x] T8 ui.zig：`drawSidePanel` 插入图片区（缩略/选择/更换/移除）与属性区（name/value textEntry 走 trackTextField 撤销会话 + 删除/添加按钮），并加交互测试（点击添加/删除、键入写模型）。
- [x] T9 版本号：`app_version` → "2.0.0"，`src/app.rc` FILEVERSION → 2,0,0,0。
- [x] T10 终验：`& c:\zig\zig.exe build test` 全绿（exit 0，含 version="2"、`<img type="jpg">`、`<property name="权重">1</property>` 字面断言与属性表格/图标布局渲染断言）；渲染样式按截图实现（灰名格 + 浅绿值格）。

## 实施偏差记录（相对 spec）

- `Property.name/value` 用 `ArrayList(u8)`（非 `[]u8`），以便 dvui textEntry 直绑、与 `Node.text` 同款撤销会话机制。
- 属性名格宽度收敛到 `layout.propNameCellW()`（比例 0.4、下限 48、上限 70%），测量/绘制/测试共用，避免小节点值格被挤没。
- `cmdSetPropertyName/cmdSetPropertyValue` 未采用（textEntry 直绑 + `trackTextField` 会话已覆盖，独立命令会成为死代码）。
- 移除属性后的渲染断言按「节点框内不再有浅绿」区域断言（几何会变，定点比对不可靠）。
- 两次离屏 `renderMap` 之间需 `dvui.testing.settle` 隔帧，否则同帧 widget id 撞车。

## 缺陷修复记录（用户反馈「添加属性后表格显示错位」）

1. **画布属性表格错位**：单元格原用嵌套 `dvui.box` 绘制，而 `BoxWidget.init` 会把自身设为当前父级——循环里第二个单元格成了第一个单元格的子控件，`rect` 相对它定位，表现为值格向右下错位（并连带后续文字标签挂到错的父级）。改为 `fillCanvasRect()`（`dvui.Path.fillConvex` + `stroke`，画布绝对坐标，完全不参与控件布局/父级）。
2. **侧栏多行属性 tag 重复**：dvui 的 `tag` 按**名字**全局唯一（`id_extra` 只影响控件 id），多行共用 `side_prop_name/side_prop_value/side_prop_del` 会触发 duplicate tag 错误并可能串事件。改为带行号的 `side_prop_name:{i}` 等。
3. 回归测试：`导出渲染：属性表格画在节点框内，名格与值格同一行并排` 用颜色包围盒断言「同一行、并排、行高≈prop_row_h、都在节点框内」；侧栏测试改用 `side_prop_name:0` / `side_prop_del:0`。
4. **侧栏属性编辑框上下太小**：属性名/值两个 textEntry 只给了 `min_size_content` 的宽度（h=0），textEntry 高度缩成「只剩 margin+border+padding」的一条细缝。改为显式给高度 `font_body.textHeight()`（与「标题」输入框同高，`lineHeight` 会偏高），删除按钮同步 `min_size_content.h`；测试用 `tagGet("side_title")` 与 `tagGet("side_prop_name:0")` 比对高度锁定。
5. **表格样式打磨（用户反馈）**：
   - 表格与上方文字之间加半行间距：`Metrics.prop_gap = 10`，`layout.measure` 计入几何、画布 `table_y` 用同一常量，间距与布局一致。
   - 框线改为统一 1px：不再让每个单元格各自描边（相邻格边框会叠成粗线），改为「先填色，再统一画外框 + 竖分隔线 + 行分隔线」，`strokeCanvasLine()` 的 `thickness` 固定 1 物理像素（此前用 `rs.s`，125% 缩放下会变成 1.25px 显得粗而糊）。
   - 单元格文字上下居中：标签框高度取文本实测高，`y = 行顶 + (行高 − 文本高)/2`。
   - 布局测试同步期望值（`content_h + prop_gap + n×prop_row_h + 2×pad_y`）。
6. **XML 图片改为 images 池 + ref 引用（用户反馈）**：
   - 格式：`<mindmap version="2">` 下先写 `<images>`，每项 `<img id="<md5>" type="png" md5="<md5>">BASE64</img>`；节点内改为自闭合引用 `<img ref="..." />`。
   - 数据模型：`Node` 由 `img_type/img_data` 改为 `img_ref`（引用），新增文档级 `model.ImageStore`（`ImageAsset{id,img_type,md5,data}`，`findById/findByMd5/add/ensure/count`）；`Doc.images` 在 `deinit` 释放；撤销镜像只复制引用（共享池，池只增不删，重做仍可恢复）。
   - id = 图片内容 md5（32 位小写十六进制）→ 同内容天然复用同一 id；`md5` 属性作为缓存值一并写出。
   - 「从磁盘加载图片」（原「更换图片…」/「选择图片…」）：读入后 `cmdSetNodeImg` 先查池内 md5，命中则直接复用已有 id，不重复存数据。
   - 保存只写当前树引用到的资源（撤销/换图残留的不落盘）；读取兼容 2.0 早期内联 `<img type>BASE64</img>` 格式（转成池 + ref）。
   - 测试：`images` 池 + ref 往返、内联旧格式兼容、md5 去重（两节点同图只存一份）、cloneTree 只拷贝引用、坏 base64 容错（引用保留但资源缺失）。
7. **Ctrl+C / Ctrl+V 复制粘贴节点（用户需求）**：
   - `model.cloneShallow()`：只复制节点自身内容（标题/描述/连线标题/颜色/手动尺寸/属性/图片引用），不含子节点；geom 与 collapsed 属视图状态不复制（新节点按自动布局落位、保持展开）。
   - `App.cmdCopySelected()`：把选中节点浅拷贝进应用内剪贴板（`clipboard` + `clipboard_src_id` + `clipboard_parent_id`），不写系统剪贴板。
   - `App.cmdPasteNode()`：以剪贴板为模板新建节点，新 id = `doc.next_id`，父节点与原节点相同并插在原节点之后（原节点已删则追加到该父末尾，父也没了退回根），`pushUndo` 一步可撤销，粘贴后选中新节点并让它滚入视野；剪贴板可重复粘贴。
   - 按键：`keys.afterWidgets` 的 Ctrl 分支加 `.c` / `.v`；用 `text_focus_id` 挡一道——侧栏文本框有焦点时让给文本自身的复制粘贴。
   - 测试：同级/紧跟原节点/不带子节点/内容照搬/可撤销/可重复粘贴、空剪贴板与未选中不产生节点、真实按键帧下 Ctrl+C 与 Ctrl+V 生效。
