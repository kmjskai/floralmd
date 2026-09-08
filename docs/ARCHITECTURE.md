# FloralMD 统一工作区架构

本文给工程维护者与后续 Codex 任务说明实现边界。产品行为以 [PRODUCT.md](PRODUCT.md) 为准，当前证据以 [PROGRESS.md](PROGRESS.md) 为准。

## 1. 核心数据模型

| 模型 | 职责 | 产品编号 |
| --- | --- | --- |
| `DraftWorkspaceLayout` | 给出 `notes/`、Markdown 图片与 Draft 绘图源的标准路径，并准备基础目录 | WS-01、NEW-01、NEW-02、DRAW-01、PASTE-01 |
| `ResourceKind` | 将 Markdown、`.excalidraw`、PNG/JPG/JPEG/GIF/WebP/SVG 归为三类 Surface | OPEN-01、SURFACE-01、IMAGE-01 |
| `ActiveResource` | 保存当前资源的标准化 URL 与类型；它是中央 Surface 的唯一选择输入 | BROWSE-01、SURFACE-01 |
| `WorkspaceSession` | 保存工作区根、Draft/文件推导/显式选择类型与活动资源 | OPEN-01、OPEN-02、OPEN-03 |
| `WorkspaceWindowState` | 保存显式工作区标准化路径，作为 SwiftUI 窗口恢复与去重身份 | OPEN-03 |
| `WorkspaceResolver` | 实现 Draft 优先、外部同级、无目标回落 Draft 的解析规则 | OPEN-01、OPEN-02 |
| `DrawingSVGSyncPolicy` | 表达 Draft-only、全部绘图、从不三种自动 SVG 决策 | DRAW-02 |
| `DrawingOriginalImageRequest` | 验证图片元素桥接载荷并保留原始 BinaryFile 字节 | DRAW-03 |

`WorkspaceResolver` 不搜索祖先目录、不创建 `.floralmd`、不修改文件。`WorkspaceSession` 要求活动资源始终位于会话根之内。

## 2. 窗口与控制流

应用入口是带 `WorkspaceWindowState` 恢复值的 `WindowGroup`，每个窗口独立持有 `WorkspaceController`，不再由 `DocumentGroup` 绑定单个 Markdown。控制流如下：

```text
启动 / Finder open / 快速记录 / 侧栏选择
                    │
                    ▼
           WorkspaceOpenRouter
                    │
                    ▼
            WorkspaceController
        解析会话、保存脏 Markdown、切换活动资源
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
      Markdown   Drawing    Image
      Surface    Surface    Surface
```

- `WorkspaceHostView` 获取并准备 Draft 根，然后创建控制器。
- `WorkspaceOpenRouter` 缓冲早于窗口创建到达的 Finder URL；控制器接入后再处理。
- `WorkspaceOpenRouter` 登记多个 controller/window；菜单与 Finder 路由优先使用 key window，显式打开同根时激活已有窗口。窗口关闭与 App 退出按 owner 分发，避免一个窗口覆盖另一个的 dirty 保护。
- `WorkspaceContentView` 组合统一侧栏、大纲、中央 Surface、标题、置顶、透明度与工具栏。
- `WorkspaceSidebarView` 递归列出普通目录与普通文件；隐藏项、package 和符号链接跳过，不可读子目录降级为带错误的目录行。只有 `ResourceKind` 支持项改变 `ActiveResource`，其他文件留给 Quick Look、Finder 与文件操作。
- `WorkspaceFileCatalog` 记录文件系统 resource identifier；刷新通知以 120ms 合并。展开状态按目录身份保存，`WorkspaceController` 用活动文件身份识别外部父目录/文件改名。活动项消失时进入明确的 missing 状态，Markdown 保存不会重新制造旧路径。
- Files 交互统一形成 `WorkspaceFileOperationRequest`：侧栏按钮、聚焦键盘命令、剪贴板和目录 drop 先做纯路由，再由 `WorkspaceContentView` 执行 dirty Markdown 前检，最后交给文件服务。成功结果重定向活动 URL、同步选择，并只发出一次合并刷新通知。
- `.excalidraw` 使用嵌入模式的既有 Excalidraw 视图；标准 App 场景不再声明独立绘图窗口。

对应 SURFACE-01、MD-01、DRAW-01、IMAGE-01、AUX-01。

### 小窗口宽度预算

`WorkspaceWindowLayout` 把窗口可用宽度分成文件侧栏、大纲和中央 Surface 三部分。窗口通过 `.windowResizability(.contentMinSize)` 与根视图共同声明 `760×540` 最小内容尺寸；默认尺寸仍为 `1100×760`。

文件侧栏有两种不同的宽度：

- **偏好宽度**：`@AppStorage` 持久化的用户选择，按 `180...420` 清理非法或历史值；
- **实际宽度**：每次布局由当前窗口宽度计算，等于偏好宽度与当前预算上限中的较小值。

自适应只读取偏好，不写回。普通 Surface 预留 440pt；Markdown 大纲打开时先扣除固定 250pt 大纲，再为中央编辑/预览预留 330pt，因此 `760pt` 下文件侧栏收缩到 180pt。窗口恢复后，同一偏好会重新得到更宽的实际宽度。只有用户拖动结束或双击复位才写 `workspaceSidebarWidth`。

`WorkspaceContentView` 给中央 Surface 明确的预算宽度并裁切越界内容。内嵌 `DrawingWindowView` 的最小宽高为零；980×540 的固有下限只属于历史独立绘图窗口，不能向统一工作区父级传播。CodeMirror、Markdown 预览和 Quick Look 同样服从父级 frame，内容自己的代码块、表格或图片滚动只发生在 Surface 内部。

`WorkspaceSidebarScrollPolicy` 禁用文件列表 `NSScrollView` 的横向滚动条与弹性，并把已有横向 content offset 归零。它的 AppKit bridge 作为 `List` 的零尺寸 background 宿主，从最近的兄弟视图层级定位列表滚动视图，不能放进 `List` builder：macOS `List` 会把 builder 中视觉高度为零的 bridge 仍解释成一行并保留系统行高，从而把首个资源整体下推。真实宿主测试同时约束“AppKit 行数等于可见资源数”和行外 bridge 仍能应用滚动策略。侧栏标题自身采用可压缩的中间截断，避免标题、菜单与刷新按钮的固有宽度把整行从左侧推出可见区。

侧栏分隔线的完整 14pt 命中区由单一 `WorkspaceSidebarResizeHandleView` 拥有：同一个 AppKit `NSView` 既是窗口真实 hit view，又通过 `resetCursorRects()` 注册 `resizeLeftRight`，并处理 tracking area、拖动、双击复位、tooltip 与 accessibility splitter 语义。SwiftUI 只绘制不参与命中的视觉线条，并根据 AppKit 回调切换 hover/drag 强度；因此不存在透明 `Color`、SwiftUI gesture 与 cursor rect 视图之间的双层命中竞争。视图在加入窗口、布局变化以及窗口失焦/重新成为 key 时使 cursor rect 失效重建，且从不调用 `NSCursor.set/push/pop`。

工具栏保持原生 `.navigation` 与 `.primaryAction` placement，不建立覆盖中央内容的自定义浮层。当前必要操作在 760pt 最小宽度内可见；更窄尺寸由窗口约束阻止。

CodeMirror 与 Excalidraw 继续拥有各自的编辑命令。两种 WebView 共用一层很窄的 `performKeyEquivalent` 路由，只把 `Control+Command+F`、`Command+H`、`Option+Command+H` 转回窗口或应用，防止网页快捷键抢走系统全屏和隐藏；其他键仍交给 WebKit。Markdown 页面另外实现 `Command+F` 查找条：匹配计数按 Markdown 源文本计算，高亮则扫描 CodeMirror 当前真实显示且非隐藏的文本节点，再以反向 DOM→source 映射确定当前目标；页面依据完整 DOM Range 的 `getClientRects()` 绘制一层不接收事件的显式矩形覆盖层，全部可见命中为淡色、当前目标为深色，且不改变 CodeMirror selection。每次输入、跳转、滚动、尺寸变化或虚拟化刷新都会先整体替换覆盖层，避免 WebKit 保留上一轮短查询的绘制结果；Escape 同时清空并关闭查找条。

Markdown 正文的每个视觉行和普通空源行共享当前 `font-size × line-height` 的基础高度，软换行只增加相同高度的视觉行。CodeMirror bundle 标记的块分隔空行仍承载列表、引用、代码、表格和分隔线的语义留白，但宿主以当前排版 CSS 变量覆盖其创建时的固定像素令牌；普通段落把额外留白归零，语义块分别按预览节奏使用相对字号间距，因此字号或行高变化无需重建编辑器，也不会破坏 selection 与 Undo。

Markdown 打字机模式是默认关闭的 `UserDefaults` 偏好，由设置、编辑菜单和命令面板写入同一个键；命令不占用快捷键。宿主只把状态传给 CodeMirror 页面，跟随决策留在拥有真实布局几何的 Web 侧：用 `coordsAtPos(selection.head)` 获取软换行和实时预览后的 caret 矩形，以编辑区高度 47% 为目标；页面保持标准留白，开启打字机不改变任何布局——因此文档顶部打字时原生 keep-visible 的触发节奏与关闭时完全一致（代价是首/末视觉行的对齐会被滚动边界 clamp，够不到舒适线）。语义是"仅结构编辑拦截"：打字机对普通字符输入、软换行与中文 composition 零干预——不写 scrollTop（所有 typewriter 滚动写入统一经过 `setTypewriterScrollTop`，测试据此断言打字期间写入数为零），原生 keep-visible 滚动照常发生，任何缩放比例下打字行为都与关闭时逐帧一致；字符输入还会取消在途的阻尼动画。回车（新行）、退格与删除（合并行或收缩选区）做同帧对齐：页面滚动、光标视觉行回到 47% 舒适位（"光标不动只移动页面"），这也是打字机对滚动仅有的介入；方向键/PageUp/PageDown/Home/End 仍以可中断、无过冲、260ms 截止的近临界阻尼动画把当前视觉行带回舒适位。缩放、窗口 resize、内容宽度与中文输入法提交等布局变化从不滚动——光标停在布局留下的视口位置，与关闭打字机完全一致（此前由 ResizeObserver 与 `floralmd-layout-change` 驱动的"布局自动跟随"已整体删除：`typewriterFollowingActive` 一旦被任何按键置真就长期保持，打字停止后或输入法提交后迟到的内容/布局事件会让页面自己滚回舒适线，表现为"开了打字机后过一会页面自己滚动"）。pointer down、wheel 会暂停跟随，下一次回车或方向键恢复。切换开关不改 Markdown、selection 或撤销历史。

对应 AUX-02。

## 3. 打开规则与权限

1. 无目标：以配置的 Draft 根创建 `.draft` 会话。
2. 目标在 Draft 根内：保持 Draft 为根并选中目标。
3. 目标在 Draft 外：以目标父目录创建 `.externalFolder` 会话。
4. 不支持扩展名：在进入会话前报错。
5. 用户明确选择文件夹：以该整个文件夹创建 `.explicitFolder` 会话；之后选择嵌套资源不会缩小会话根。

Draft 根由 `QuickCaptureService` 的安全书签持有。外部工作区通过 `FolderAccessService` 按“目标父目录的完整标准化路径”恢复安全书签；没有书签时，打开路由或侧栏明确请求用户选择同一文件夹。授权选择必须与请求根完全一致，防止悄悄扩大访问范围。

显式工作区复用同一 `FolderAccessService` 书签表，但由用户在只允许单个目录的 `NSOpenPanel` 中直接选择根。重开窗口只恢复该精确根；书签无效、目录移动/删除或不可读时显示错误，不回落 Draft。

Finder 关联在 Info.plist 中声明 Markdown、Excalidraw 与支持的图片类型。App delegate 把 URL 转给统一路由，不再交给文档窗口控制器。

对应 OPEN-01、OPEN-02、OPEN-03、COMPAT-01。

## 4. 持久化边界

### Markdown

`WorkspaceController` 是统一窗口中的 Markdown 持久化所有者：

- 只读入/写出 UTF-8 源文本；
- 2 秒防抖自动保存，显式保存与退出保存共用同一写入路径；
- 菜单 `Command+S` 通过聚焦的统一保存动作路由：Markdown 调用 `WorkspaceController.save()`，Drawing 增加当前内嵌画布的保存请求，Image 为不可用；
- 切换资源前先保存脏 Markdown，失败则不继续切换；
- `WorkspaceFileStore` 使用原子写入；新建使用 `withoutOverwriting` 和递增候选名。

当前活动 Markdown 由 `ActiveMarkdownFileMonitor` 以父目录 `NSFilePresenter` 监控，而不是绑定可能被原子替换淘汰的文件 inode。presenter 回调在专用串行 `OperationQueue` 上接收，再以 trailing 150ms 合并后切回 `MainActor`；控制器 UUID generation 隔离旧 monitor 与延迟重试。每次切换、改名重绑或销毁都会先注销 presenter。监控复用 `WorkspaceSession` 已持有的 Draft/外部目录安全作用域，不自行扩大授权；`NSFileCoordinator` 统一协调读写。

磁盘快照记录标准化 URL、resource identifier、mtime、大小、SHA-256、文本和保存 generation。FloralMD 保存前登记 exact content + generation，事件到达后以实际磁盘内容识别自身保存；mtime 只作为诊断元数据。另维护 last-disk baseline，并对 BOM、CRLF/LF 和尾换行做 soft equality，避免云盘格式重写反复提示。外部读取失败按 50/150/300ms 有界重试；remove/rename 先按 resource identifier 重新扫描并确认最终存在性，避免原子 replace 的假删除。

clean 外改经 CodeMirror 单事务替换；selection 夹取到新文档范围，保留滚动与焦点，并在 composition 结束后执行。dirty 外改进入 conflict，自动保存、资源切换保存与关闭保存均不得覆盖磁盘；载入磁盘会丢弃本地 buffer，保留当前则更新磁盘 baseline、进入 divergent 且继续 dirty，之后只有显式保存可覆盖。重复的同一磁盘状态不会反复提示，磁盘后来与编辑器一致时自动解除 divergent。外部改名同步活动 URL、标题和侧栏通知；真正删除进入既有 missing 状态且不重建文件。

外部更新与改名成功属于中央 Surface 内的 2.5 秒紧凑 Toast，不进入窗口 `safeAreaInset`、不覆盖标题栏或横跨 Files 侧栏，也没有关闭按钮。冲突、divergent 和 missing 属于必须处理或知晓的常驻提示，同样只覆盖中央 Surface；冲突按钮与说明保持在同一紧凑面板内。

本阶段没有 Excalidraw 场景热重载、图片/SVG 自动刷新、整目录事件数据库或多标签批量冲突 UI。参考实现只用于原则校验：采纳 VMark 的 exact-content generation、baseline/divergent 与最终状态模型，以及 VMark/ColaMD 的父目录监听、重绑和 trailing debounce；不采用 ColaMD 的布尔计时器、自称 Agent 或 dirty 无条件覆盖，也不照搬 Tauri/Rust/Node 的 watcher 和批处理架构。

旧 `MarkdownDocument` 与旧视图仍保留用于兼容代码和既有测试，但标准 App 场景不再创建 `DocumentGroup`，避免双重保存所有权。

Markdown 的实时编辑 WebView 与只读预览 WebView 都通过 `MarkdownLocalResourceSchemeHandler` 安装 `floralmd-resource`，不再让 WebContent 直接读取 `file://`。每次活动文档变化时，主进程用不可推导的 scope 标识注册当前 `WorkspaceSession.rootURL` 与 Markdown 所在目录；页面只看见 scope 和工作区相对目录，不写入绝对本地路径或日志。Untitled Draft 以 `DraftWorkspaceLayout.notesDirectory` 作为未来文档目录；没有工作区会话的历史单文件入口不开放本地资源通道。

资源请求先逐段解码，再拒绝空段、`.`、编码斜杠与 NUL；`..` 只参与从当前 Markdown 目录出发的标准路径解析，不能逃出工作区。解析器逐段拒绝符号链接与目录目标，并在标准化和 `resolvingSymlinksInPath()` 后再次验证仍被授权根包含。最终只返回通过内容签名验证的 PNG/JPG/JPEG/GIF/WebP/SVG 普通文件及精确 MIME，SVG 明确使用 UTF-8；缺失、伪扩展、过期 scope 和越界请求全部失败。只允许内部生成的数字刷新查询参数用于绕过 WebKit 图片缓存，其他查询仍拒绝。

Markdown 导航不复用图片资源加载决策。CodeMirror 的 `Command`-点击和预览的普通点击都把原始 destination 交给 `MarkdownLinkNavigationResolver`；预览 HTML 以 `data-md-href` 保留尚未被 `<base>` 规范化的原始 `../`。`WorkspaceOpenRouter` 在当前附着的 `WorkspaceController` 内完成授权、逐段符号链接验证和 `open`，因此保存失败不切换、工作区外先授权、成功也不创建第二窗口。fragment 通过统一大纲定位；HTTP/HTTPS/mailto 交给 `NSWorkspace`，图片和绘图回落既有语义。

CodeMirror 非空文本选区使用规范化后的半开区间与 syntax tree 构造范围求交：任何被触及的 Markdown 构造都整体显露源码，不是只按 selection head 所在线或只显示部分 delimiter。列表与 task marker 按被选中的逻辑行显露；无序列表的 marker 与其源码分隔空白共同留在和预览 bullet 相同的固定悬挂槽内，嵌套源码缩进继续存在于 DOM、selection 与复制范围但不重复贡献语义深度已经提供的布局宽度，因此建立、反向拖动或折叠选区都不改变正文首字符列或行位置。ATX 标题、强调、链接、行内代码、围栏和表格按完整构造显露，同时取消这些构造的背景、圆角、语义色、粗斜体与交互 widget；独立的 geometry-only decoration 保留标题字号/行高/悬挂换行、列表缩进/间距和行内代码的字体尺寸/透明 padding，避免源码显露时纵向收缩。自定义 selection layer 在每个逻辑行内按视觉行归并相邻 DOM Range 矩形，遮平透明占位造成的小间隙，但不跨空白逻辑行或 block image widget；图片 gallery 及其后代另以 `user-select: none` 和透明 `::selection` 排除 WebKit 原生着色，因此图片预览不进入文字选区。普通正文不会带动未相交构造。选区折叠后重建完整实时预览；IME marked range 不视为用户源码选区，以保持组合输入期间的几何稳定，普通 caret、源码 offset 与复制内容继续沿用既有路径。

实时编辑的语义 token 同样由 CodeMirror syntax tree 产生 decoration：链接、图片引用、行内代码与 Markdown 标点只增加样式类，不改写 buffer。浅色/深色 CSS 变量分别给图片柔紫和代码暖棕，正文与标题继续使用主文字色；selection 使用系统 `Highlight` 且带更高 specificity，搜索命中继续由独立高层覆盖层绘制，错误 widget 保留自己的失败类。第一版没有设置开关。gutter 不再用宿主正则重复解析 Markdown，而是消费 bundle 从同一 syntax tree 导出的 H1–H6/CODE/IMG 行元数据；只有整行由一个或多个 Image 节点与空白组成时才输出 IMG。

编辑态图片由 CodeMirror `StateField` 持有 block widget decoration。解析只读取 Markdown 语法树中的 `Image` 节点，源码本身不替换、不隐藏；每行图片在对应源码行后形成 gallery。图片路径所在行发生文档变化时重建相关 decoration，其他输入只映射既有 ranges；应用内图片落盘或用户点击工作区刷新时，原生通知经过 120ms debounce 调用 `refreshImages()`，递增本地资源缓存键，不重载页面。加载失败只把 widget 标为 `Image unavailable`，语法、selection、IME 与 CodeMirror undo history 均留在原编辑状态。

实时编辑表格继续由 bundle 解析、序列化并以单次 CodeMirror transaction 修改，Swift 不重复实现 Markdown 表格 parser。表格 widget 是 Markdown 源的确定性投影：未聚焦单元格通过正文同一 `markdownLanguage.parser`、行内公式 scanner/KaTeX renderer 和安全 DOM renderer 显示 strong/emphasis/strikethrough、行内代码、行内公式、链接、图片与反斜杠转义；只用 `textContent` / DOM node 构造，不解释原始 HTML。相对图片沿用当前页面的 `floralmd-resource` base URL，因此仍经过工作区 containment、符号链接、签名与 MIME 校验。单元格 focus 从 table model 恢复原始 Markdown plaintext，未改动 blur 只恢复投影、不发 transaction；内容改变后仍由既有 `serializeTable` 一次 dispatch，因而一次 Undo 可完整恢复。单元格右键不再被表格结构编辑拦截，也不再经过 Web → Swift → AppKit 菜单协议；结构操作集中在表体左侧/表头上方的可视行列把手和分隔线/外缘 `+`。只有 widget 持有显式行或列结构选区时，Delete/Backspace 才删除整行或整列；单元格 caret 保留正文删除语义。内部横/竖分隔线按钮按当前 DOM 几何定位并随横向滚动、尺寸变化重测，分别调用 `insertRowBefore` / `insertColumnBefore`；外缘按钮继续末尾追加。结构按钮为空文本 DOM，视觉符号由 CSS 伪元素绘制，localized `aria-label` 由 Swift 注入，因此不污染 Markdown 或查找。该协议仅安装在 CodeMirror 实时编辑页，只读预览不包含入口。

已加载 widget 的双击或 `Command`-点击只向宿主提交 `destination/sourceFrom/sourceTo/activation` 的强类型 `openImage` 消息；bridge 拒绝绝对 URL、协议与窗口参数。宿主把相对 destination 重新交给当前 `MarkdownLocalResourceSchemeHandler`，复用其工作区 containment、逐段解码、符号链接、文件签名和 MIME 决策。解析成功后，`FloralMDImageViewerCoordinator` 按标准化文件 URL 去重 `NSWindowController`；失败或尚未加载的 widget 仍只定位源码。普通链接继续走 `openLink`，两条控制流不互相降级。

正文 decoration 与表格 inactive renderer 复用同一个 hashtag token scanner，统一字符、路径分段、非纯数字、词内邻接与反斜杠转义边界；code、link、URL、HTML 和 Table 等结构排除仍由各自 syntax seam 负责。表格只在安全普通文本 gap 中构造 `.cm-md-tag` DOM，focus 仍恢复原始 `#tag` 文本。

对应 NEW-01、MD-01。

### Drawing

`DrawingStorageLayout` 有 Draft 与外部两种 scope：

- Draft 新建源文件直接到 `drawings/`；笔记局部或外部源文件保持原目录，不新增 `excalidraw/` 子目录。
- 每个标准 SVG 固定为源文件父目录的 `exports/<同名>.svg`。因此同一规则覆盖 Draft 根 `drawings/`、笔记局部 `drawings/` 与外部绘图目录。
- `.excalidraw` 的 `files`/`dataURL` 是图片唯一事实源；Swift 验证 scene 与图片载荷，但不再把图片另写到 `images/`。
- 旧 `drawings/images/`、`notes/assets/drawing-exports/` 和旧同级 SVG 不自动迁移或删除；新保存停止双写。

`DrawingSVGSyncPolicy` 通过 `UserDefaults` 保存三档设置：`.draftOnly`（默认）、`.allDrawings`、`.never`。发起画布 completion 前，`DrawingWindowView` 把当前 layout 与 `syncSVG` 冻结在 completion intent 中，避免异步返回期间设置变化导致请求与写入计划不一致。

保存链根据冻结计划决定是否请求 SVG：

```text
Command+S / 完成绘图
  → 冻结 DrawingStorageLayout + DrawingSVGSyncPolicy
  → 需要自动 SVG：请求自包含 scene + SVG
  → 不需要自动 SVG：只请求自包含 scene，payload.svg = nil
  → DrawingStore 暂存源与可选 SVG
  → 提交目标；失败时恢复本次涉及的旧文件
```

`DrawingStore` 在不自动同步时不创建 `exports/`、不检查或改写已有派生物。自动同步要求 SVG 时，SVG 缺失或验证失败会让整个保存失败并保留旧源；源与标准 export 的替换共享一次回滚事务。已有绘图的源 URL 必须符合当前 layout，防止越界写入。

手动导出是独立的 `.exportSVG(destination)` completion intent：先通过 `NSSavePanel` 选择目标并由系统处理覆盖确认，再请求和验证 SVG，最后原子写入选定文件。它不保存 `.excalidraw`、不改变会话 baseline，也不改变自动同步设置。

图片元素原图导出走另一条只读 scene 流：离线宿主通过 Excalidraw 公开 `onPointerDown` 订阅取得 `PointerDownState.hit.element`；仅当右键命中 `image` 且 `getFiles()[fileId]` 存在时，才把强类型载荷交给 `ExcalidrawBridge`。Swift 的 `DrawingOriginalImageRequest` 不信任 Web 载荷，会重新核对 MIME 与 data URL header、解码非空字节并限定为当前 Excalidraw `IMAGE_MIME_TYPES`。宿主在对应画布坐标显示最小原生 `NSMenu`，用户确认菜单后才打开 `NSSavePanel`；`DrawingOriginalImageExporter` 只原子写入选定 URL，不请求 completion、不保存 scene，也不触碰 baseline、dirty 或 `exports/`。

可维护的宿主源码位于 `scripts/excalidraw-bundle/`，固定 Excalidraw、React 与 Vite 版本。`npm test` 验证右键命中协议，`npm run build` 从源码生成并安装 `FloralMD/Vendor/Excalidraw`；安装步骤同时复制 Excalidraw 运行时按 `EXCALIDRAW_ASSET_PATH` 查找的完整字体树。仓库不直接维护手改的压缩 JS。

对应 DRAW-01、DRAW-02、DRAW-03、COMPAT-01。

### Image preview

PNG、JPEG、GIF、WebP 与 SVG 共用 `WorkspaceImagePreview`，由 `WorkspaceImageWebView` 将受控 `WKWebView` 嵌入统一窗口中央 Surface。查看器生成一页仅含 `<img>` 的本地 HTML；所有支持图片都作为图片资源载入，因此 SVG 不以可执行顶层文档运行。

WebContent 子进程不直接读取 `file://`。主进程先把已经由工作区授权范围覆盖的文件注册为一次性 `floralmd-image://resource/<id>`，`WorkspaceImageResourceSchemeHandler` 再按真实类型返回字节与 MIME；未知 ID 和其他协议不会映射到磁盘。内容安全策略默认拒绝资源，只允许该应用内部协议或 data 图片，以及查看器自身的内联样式和脚本；WebKit 使用非持久数据存储。这个边界既避免 WebKit 沙盒导致“无法显示”，也不扩大工作区本来拥有的文件权限。

`WorkspaceZoomingImageWebView` 把普通 macOS `scrollWheel` 的水平/垂直增量交给页面平移；带 `Command` 的纵向滚动与 `magnify` 则转换为指针中心缩放。非精确鼠标滚轮会换算为可感知的平移/缩放步长，触控板精确增量保持系统惯性。本地页面处理 pointer drag 平移、适应窗口、1:1 与双击切换，并在 CSS 和事件层禁止浏览器选区。页面通过单一 message handler 回报 `scale/offsetX/offsetY`，Coordinator 按标准化 URL 保存状态并在切回资源后恢复。缩放限制与按钮步进由 `WorkspaceImageZoom` 集中定义，SwiftUI 工具条只发送受限命令，不接受任意脚本输入。

查看器按扩展名/MIME 已确定的资源类型选择绘制策略，但继续共用同一个 `<img>`、状态模型与手势数学。PNG/JPEG/GIF/WebP 保持固定 intrinsic layout，并用 CSS transform 表达位图缩放。SVG 则在每次倍率变化时增加 `<img>` 的实际 `width`/`height`，促使 WebKit 以新的 SVG viewport 重绘路径、文字与滤镜子树；常规图片在 800% 等倍率不再只放大初始合成层。

SVG 重绘尺寸不再使用固定 4096 CSS px 上限。`WorkspaceVectorRedrawBudget` 以当前机器物理内存的 1/16 建立 192–512 MiB 的单预览峰值预算；页面再同时考虑目标倍率、intrinsic 宽高比、窗口可视尺寸、`devicePixelRatio`、物理像素面积、双缓冲 RGBA 的 8 bytes/px 峰值估算，以及 16384 CSS px 病态尺寸硬边界。预算允许时使用完整布局重绘，超出时只把有界 `paintScale` 交给 WebKit，剩余倍率继续由 transform 合成；极端 intrinsic 尺寸允许布局低于 1 倍后再合成，以免仅显示 1:1 就创建失控表面。倍率或窗口缩小时重新计算并回落布局尺寸，从而释放高分辨率层。该预算只作用于 SVG 分支，不改变普通位图或 SVG 内嵌位图的像素语义。

1:1 以图片首次 `load` 时冻结的 `naturalWidth/naturalHeight` 为准，后续布局变化不反读 WebKit 会随 SVG CSS viewport 改变的 `naturalWidth`。绝对 `width`/`height` 给出 intrinsic viewport；只有 `viewBox` 或百分比尺寸配合 `viewBox` 时使用 `viewBox` 尺寸；百分比且无 `viewBox` 时采用 WebKit 的 300×150 回落。该策略同样覆盖极小和超大画布，不解析、重写或重新导出 SVG。Excalidraw 自包含 SVG 的路径和文字随 viewport 重绘；其中内嵌 PNG/JPEG 仍受自身像素分辨率限制。

外部图片继续依赖 WorkspaceResolver 已取得的工作区根安全作用域，不另行申请单文件权限；查看器只读原文件，不提供保存路径，也不会把预览状态写入工作区。

Markdown 独立图片窗口注入同一个 `WorkspaceImagePreviewController`，因此不复制渲染器、缩放状态或 SVG 重绘算法。`MarkdownImageViewerInitialLayout` 用 `NSImage` 解码得到的固有尺寸、内容留白、实际窗口装饰和来源窗口所在屏幕的 visible frame 计算首次 frame：720×520 为常规下限，宽高分别不超过可见区域 84%，并只在创建时居中；Web 页面继续以不超过 100% 的 fit scale 完整显示并居中。窗口标题和 represented URL 来自已解析文件，按标准化 URL 单例化，重复激活不重算 frame 或预览状态，并额外提供 Finder reveal。每个窗口以 `.floating` 独立默认置顶，工具条按钮只切换该窗口 `.floating/.normal`，关闭重开恢复统一的默认置顶而不建立全局偏好。关闭或 `Command+W` 会拆除 SwiftUI 宿主、WebKit message handler、navigation delegate 与 scheme 注册，再释放该工作区根的安全作用域 lease；侧栏选择图片仍使用中央 Surface，不进入这个窗口协调器。

对应 IMAGE-01。

## 5. Markdown 图片粘贴事务

```text
Web paste 事件
  → 捕获 CodeMirror selection
  → Promise.all 按剪贴板顺序读取全部 File 数据与 MIME
  → 单个批量 payload 由原生桥接解码 Base64
  → 在写入前校验全部真实 PNG/JPEG/GIF/WebP/SVG 载荷
  → 解析 Draft 或外部 Markdown 目标目录
  → 用注入 clock/calendar/timeZone 生成本地 `yyyy-MM-dd-HH-mm-ss`
  → 临时文件原子写入并无覆盖 move；失败回滚本批已创建文件
  → 按顺序计算并编码全部相对 Markdown 路径
  → 回到捕获 selection，以一次 CodeMirror 事务插入全部 ![](...)
```

任何一步抛错都会在“回插链接”之前终止。Draft 无活动文档时以 `notes/` 为链接基准；编辑器收到插入内容后会创建 Draft Markdown。外部会话必须已有位于工作区内的 Markdown，图片进入文档同级 `assets/images/`。

`MarkdownImageAssetStore` 不信任 MIME 或扩展名：PNG/JPEG/GIF/WebP 检查文件签名与必要头字段，SVG 用禁用外部实体解析的 XML 根元素校验。剪贴板内容忽略 `image.png`、`clipboard.png` 等建议名，以 POSIX locale 保证时间名使用 ASCII 数字，验证后的格式决定扩展名；同秒和跨扩展同 stem 碰撞使用 `-2/-3`。Finder 文件入口仍保留并清洗原文件名。

对应 PASTE-01、COMPAT-01。

## 6. 侧栏资源引用拖放

```text
WorkspaceSidebar 文件行
  → NSItemProvider: public.file-url
  → EditorResourceDropWebView 读取 NSURL 与鼠标落点
  → WorkspaceSession 根目录 + 符号链接真实路径双重边界校验
  → MarkdownResourceReferenceResolver
      ├─ 图片：原文件
      ├─ Markdown：frontmatter title → 首标题 → 文件名
      └─ Excalidraw：源父目录 `exports/<同名>.svg`（必须已存在）
  → 以当前 Markdown 目录计算并逐段 URL 编码相对路径
  → CodeMirror posAtCoords
  → 一次 dispatch(userEvent: input.drop)
  → change bridge → WorkspaceController dirty → 既有自动保存
```

侧栏只声明一个标准 `public.file-url` 数据表示，不设置会被 WebKit 当作额外文本插入的 suggested name，也不创建文件事务。编辑器的 AppKit 拖放目的地按 pasteboard item 精确读取 `file-url`，忽略 plain text/裸路径并按标准 URL 去重；它注销内部 `WKContentView` 的原生 drag destination，并在成功、失败或不支持时都终止文件拖放传播，因此一次事件只能进入一次 resolver/CodeMirror 事务，不能回落成 WebKit 默认 URL、绝对路径、文件名插入或页面导航。resolver 同时检查词法工作区边界和解析符号链接后的真实边界；Finder 中属于已授权工作区的文件走相同入口，外部文件由 resolver 明确拒绝且不扩大授权。

`draggingLocation` 先从窗口基准坐标转换到 flipped 的 `WKWebView` 本地坐标；该 y 已与 CSS viewport 同为从顶部计量，因此只除以 `pageZoom`，不能再次按视图高度翻转。文档滚动由 CodeMirror 的 `posAtCoords` 按当前 viewport 解释，原生层不重复叠加 `scrollTop`。坐标可映射时，外部资源在释放点插入，不删除与释放点无关的既有非空选区；坐标不可映射时，使用事务到达 CodeMirror 时捕获的 selection，并按粘贴语义替换该选区，绝不追加文末。两条路径都只执行一次 `dispatch(userEvent: input.drop)`，保持一次 Undo 与编辑焦点。

`MarkdownResourceReferenceResolver` 是纯决策层：图片与 Markdown 直接引用原 URL；绘图通过 `DrawingStorageLayout` 复用真实 SVG 目标规则，且在 SVG 不存在时失败。它复用图片粘贴链的逐路径段百分号编码规则，因此不复制资源，也不改写源文件。

只有实时编辑的 `CodeMirrorEditorView` 安装可接受目的地。预览、绘图与图片 Surface 用拒绝型 `DropDelegate` 对 `public.file-url` 返回禁止反馈；编辑器专属 WebView 独占文件拖放并拦截完成后的主框架导航，避免文件表示被 Web 内容二次消费或让页面跳离编辑器。

对应 DRAG-01。

## 7. 模块依赖边界

- `Workspace.swift`：纯 Foundation 领域模型和解析，无 UI、无书签、无迁移。
- `WorkspaceController.swift`：会话控制与 Markdown 文件事务，不持有 WebView/AppKit 文档。
- `WorkspaceContentView.swift`：应用编排和 Surface 路由，不实现底层文件格式。
- `WorkspaceSidebar.swift`：目录目录树、授权失败恢复与选择事件，不保存编辑内容。
- `WorkspaceFileOperations.swift`：工作区限定的创建、复制、重命名、移动与废纸篓事务；统一执行名称校验、冲突拒绝、循环移动拒绝与大小写改名回滚，UI 不直接调用 `FileManager` 写操作。
- `WorkspaceFileInteractions.swift`：内部默认移动/Option 复制与外部导入的纯 drop 决策、真实 file URL pasteboard、Quick Look 和仅在侧栏聚焦时生效的命令路由。Finder 外部输入只复制；已知跨卷移动由服务层拒绝，绝不隐式复制后删除。
- `WorkspaceController.swift` 在文件事务前保存受影响的 dirty Markdown，并在成功后重定向活动资源 URL；活动绘图影响操作明确拒绝，直到用户先保存并切换离开。
- `Drawing/*`：Excalidraw 桥接、会话、自包含源文件与可选 SVG 事务。
- `MarkdownRendering/*`：CodeMirror/预览与消息桥接；图片文件规则委托给资产存储层。
- `MarkdownImageAssetStore.swift`：纯文件路由、校验、命名与写入；成功后才返回 Markdown。
- `MarkdownResourceReference.swift`：纯引用类型映射、权限边界、绘图导出解析、标题回落与相对路径生成；不写文件。
- `QuickCapture.swift`：Draft 与外部目录安全书签、全局快捷入口、App 生命周期兼容辅助。

## 8. 兼容与迁移边界

- 不移动、删除或批量重写任何旧文件。
- 新建内容只使用唯一正式目录；旧原型绘图目录不再特殊识别或原位回写。
- 不兼容不等于删除：旧目录与文件留在磁盘，用户可自行从普通外部文件夹打开受支持文件或手动整理。
- 外部 Markdown 的既有相对链接保持原样。
- 不推断外部文件父目录以上的“项目根”。
- 不引入隐藏工作区元数据文件。
- `.excalidraw` 与任意 SVG 在 Files 服务中没有配对身份；所有操作只作用于用户明确选择的单个项目。
- Files 当前只支持单选；没有批量事务或文件操作撤销。冲突与外部变化通过失败、保留源文件和刷新后的真实目录状态收口。
- 自动化只验证可重复的模型、文件事务与 Web 组件；Finder、真实剪贴板、窗口生命周期和沙盒授权仍由 [PROGRESS.md](PROGRESS.md) 的人工清单收口。
