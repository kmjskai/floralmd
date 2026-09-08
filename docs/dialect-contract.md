# Markdown 方言契约（Dialect Contract）

> **这份契约是一条跨语言 seam。** FloralMD 的同一份 Markdown 方言语义被两侧各实现一遍：
> **Swift 侧**（`FloralMD/MarkdownRendering/EscapingHTMLFormatter.swift`，只读预览）与
> **JS 编辑 bundle 侧**（`FloralMD/Vendor/CodeMirror/mdedit.min.js`，实时编辑，上游
> `pluk-inc/markdown-preview`，补丁记录见 `FloralMD/Vendor/CodeMirror/LIVE_PREVIEW_PATCH.md`）。
>
> 任何一侧改动方言语义，必须同步：**本契约 + 两侧实现 + 下方语料断言**（fix once, fixed everywhere）。
> 只读预览不提供结构编辑入口（PRODUCT.md），因此本契约只约束"渲染语义"，不约束编辑交互。

语料断言集中在 `FloralMDTests/DialectContractTests.swift`，全部穿过 `MarkdownHTML.render` 这个唯一外部 seam。

---

## 1. Hashtag token 规则

**期望行为**：`#` 后跟 Unicode 字母/组合记号/数字/下划线/连字符，可选 `/` 分隔路径段（`#tag`、`#path/seg`、`#标签`）。以下不识别：

- 词内邻接（前置为字母、数字、下划线、`/` 或 `#`，如 `a#tag`）；
- 反斜杠转义（`\#tag`，详见规则 8）；
- 纯数字（`#123`）；
- 段全为连字符（`#---`）；
- 标题与链接文本内的 `#` 不渲染胶囊；表格单元格、引用块与脚注内正常渲染。

**Swift 实现**：`EscapingHTMLFormatter.visitText` + `hashtagRegex` + `isRenderedHashtag`（EscapingHTMLFormatter.swift，注释 "Same token rule as the editor bundle's hashtag scanner"）+ `protectEscapedHashtags`（预处理，见规则 8）。

**编辑 bundle 侧**：`mdedit.min.js` 的 hashtag scanner（token 规则相同；补丁与上游提交见 `LIVE_PREVIEW_PATCH.md`）。

**语料断言**：`hashtagTokenRendersCapsule` / `wordAdjacentHashtagStaysPlain` / `pureNumberHashtagStaysPlain` / `allHyphenSegmentStaysPlain` / `headingAndLinkTextNeverRenderHashtagCapsules`。

**已知边缘差异**：`\#tag` 转义因解析器在预览侧已消耗反斜杠而曾经显示胶囊；现由 `protectEscapedHashtags` 预处理固定为字面文本（奇数反斜杠）或真标签（偶数反斜杠），见规则 8 与 PROGRESS 2026-08-15 遗留稳定化。

---

## 2. 裸无序 marker 规则

**期望行为**：行首裸 `-`/`*`/`+`（marker 后**无**空白）不渲染为 CommonMark 空列表项，而是普通正文：独立成行时渲染为段落（无列表缩进）；位于列表项之后时保留列表排版但无悬挂盒（`md-bare-marker`）。**marker 后跟空白（`- `）才是真列表 marker**，渲染为空列表项并保留 bullet；`-\t` 同真 marker；CRLF 文件的行尾 `\r` 不是分隔符（`-\r` 仍算裸 marker）。

**Swift 实现**：`EscapingHTMLFormatter.visitListItem`（`md-bare-marker` 分支）+ `visitUnorderedList`（`standaloneBareMarkerList` 段落分支）+ `bareListItemMarker`/`strippedSourceLine`（含 `>` 引用块前缀剥离、缩进剥离、CR 剥离）。

**编辑 bundle 侧**：`mdedit.min.js` 的 Lezer bullet 规则（去掉 "marker 到行尾" 分支：只有后跟空白才作为 `ListMark` 渲染）。

**语料断言**：`bareMarkerLineStaysParagraph` / `bareMarkerAfterListItemKeepsListLayout` / `markerWithSpaceIsARealListMarker` / `markerWithTabIsARealListMarker` / `crlfBareMarkerStaysPlain` / `blockQuoteBareMarkerStaysPlain`。

---

## 3. 单波浪线不渲染删除线

**期望行为**：`~x~` 按字面输出（Obsidian 读作下标，编辑 bundle 只认 `~~`）；只有 `~~x~~` 渲染为删除线。

**Swift 实现**：`EscapingHTMLFormatter.visitStrikethrough`（依据语法树 range 在 `parsedLines` 中判别 delimiter 是否为双波浪线）。

**编辑 bundle 侧**：`mdedit.min.js` 只把 `~~` 渲染为删除线。

**语料断言**：`singleTildeStaysLiteral` / `doubleTildeRendersStrikethrough`。

---

## 4. 任务 marker 规则

**期望行为**：`- [ ]` / `- [x]` / `- [X]`（任务列表项）渲染为带只读复选框的任务项（`task-list-item` + `task-list-item-checkbox`）；预览侧复选框禁用（只读预览不提供结构编辑入口），勾选状态按源码 `[x]`/`[X]` 显示。

**Swift 实现**：`EscapingHTMLFormatter.visitListItem` 的 `listItem.checkbox` 分支（`<input type="checkbox" class="task-list-item-checkbox" disabled="" [checked=""] />`）。

**编辑 bundle 侧**：`mdedit.min.js` 的任务 checkbox widget（`.cm-md-task-checkbox`，可交互，属编辑态）。

**语料断言**：`uncheckedTaskRendersDisabledCheckbox` / `checkedTaskRendersCheckedCheckbox`。

---

## 5. Setext 标题永不产生

**期望行为**：ATX `#` 是唯一标题语法。正文后的 `---`/`===` 永不产生 `<h1>`/`<h2>`：`---`（≥3 个）按分隔线 `<hr>` 显示，`===` 按普通文本段落显示；引用块内（`> 标题` 后 `> ---`/`> ===`）与 CRLF 换行文件同样不产生标题。

**Swift 实现**：`EscapingHTMLFormatter.visitHeading` 的 `setextSource` 分支（`setextMarker` 剥离引用块前缀、缩进与 `\r`）。

**编辑 bundle 侧**：`mdedit.min.js` 同样不渲染 Setext（gutter/大纲/实时编辑同一语义）。

**语料断言**：`setextHyphensRenderHorizontalRuleNotHeading` / `setextEqualsRenderParagraphNotHeading` / `setextInsideBlockQuoteNeverBecomesHeading` / `crlfSetextNeverBecomesHeading`。

---

## 6. Frontmatter 只认 YAML `---`

**期望行为**：只识别 YAML `---` 开闭（或 `...` 收尾）的 frontmatter，渲染为 frontmatter 区块；`+++`（TOML）按普通正文渲染。

**Swift 实现**：`MarkdownFrontmatter.split`（`FloralMD/MarkdownRendering/MarkdownFrontmatter.swift`）+ `MarkdownHTML.renderFrontmatter`（`<section class="md-frontmatter" data-source-line="1" ...>`）。

**编辑 bundle 侧**：编辑态 frontmatter 处理与预览一致（只认 YAML）。

**语料断言**：`yamlFrontmatterRendersAsSection` / `tomlFrontmatterStaysBodyText`。

---

## 7. 有序/无序 marker 同一悬挂列（1.6em）

**期望行为**：有序 marker（`1.`/`10.`/`100.`）与无序 marker（`- `）的正文起点在同一悬挂列（1.6em 槽），编辑与预览一致；宽数字（100+）自然扩展槽宽。

**Swift 实现**：预览侧输出 `<ol>`/`<ul>` + 列表 CSS（`MarkdownHTML.stylesheet`）；几何列对齐由编辑 bundle 的 `cm-md-ordered-marker` mark 承担，两侧共享 1.6em 约定。

**编辑 bundle 侧**：`mdedit.min.js` 的 ordered-marker mark（`display:inline-block; min-width:1.6em`）。

**语料断言**：该规则是几何行为，由 `MarkdownParagraphGeometryTests.orderedAndUnorderedItemTextShareTheSameColumn`（真实 WKWebView）覆盖；本契约引用该测试，不重复断言。渲染级 sanity：`orderedListRendersAsOl`。

---

## 8. 反斜杠转义 hashtag（`\#`）与偶数反斜杠

**期望行为**：普通文本上下文中：

- 奇数反斜杠 run 的 `\#tag` 显示字面 `#tag`，不渲染胶囊（`\\\#tag` 显示 `\#tag`）；
- 偶数反斜杠 run 的 `\\#tag` 固定为"真标签"意图：保留字面反斜杠并渲染胶囊（`\\#tag` → `\#tag` + 胶囊；`\\\\#tag` → `\\#tag` + 胶囊）；
- 同段真 tag 正常渲染；行内/围栏代码与链接目标不受影响。

**Swift 实现**：`EscapingHTMLFormatter.protectEscapedHashtags` / `protectEscapedHashtagsInLine`（逐行状态机跳过围栏/缩进代码、行内代码、HTML 跨距与链接 destination；U+FFFD 标记 = 字面、U+FFFC 标记 = 真标签）+ `visitText` 的标记抑制/丢弃逻辑。

**编辑 bundle 侧**：编辑态按源码文本显示（`\#tag` 原样文本）；预览侧经预处理后与编辑态一致渲染。

**语料断言**：`escapedHashtagStaysLiteral` / `evenBackslashHashtagRendersCapsule`。

---

## 变更纪律

1. 改任何一条规则：先改本契约的"期望行为"，再改两侧实现，最后补/改语料断言；
2. 语料断言必须穿过 `MarkdownHTML.render`（预览）或真实 WKWebView（几何类）；
3. bundle 侧改动经 `LIVE_PREVIEW_PATCH.md` 记录，并更新 bundle SHA-256（PROGRESS 惯例）；
4. 已知边缘差异（如规则 1 的历史遗留）如实记录在对应规则下，不静默"修掉"。
