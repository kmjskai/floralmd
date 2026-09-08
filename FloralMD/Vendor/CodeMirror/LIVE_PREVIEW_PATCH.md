# FloralMD CodeMirror live-preview additions

`mdedit.min.js` is generated from `scripts/editor-bundle/entry-cm.js` in
`pluk-inc/markdown-preview` at commit
`0b7206b` (MIT), which combines hashtag capsules, removal of the table
context-menu bridge, and inactive table-cell inline Markdown rendering, plus FloralMD-local
behavior required by the product's editing mode.

The local bundle adds:

- GFM task-list checkbox widgets that update `[ ]` and `[x]` in the source;
- inline `$...$` and display `$$...$$` KaTeX widgets that reveal source when
  selected;
- selection painting split by logical line over continuous source DOM, so
  empty lines create no blue rectangle; nearby styled fragments on one visual
  row are compacted into one continuous highlight without crossing a logical
  line or block image widget;
  WebKit retains the native caret and CodeMirror retains source offsets;
- image gallery widgets and descendants opt out of WebKit text selection
  painting, so selecting their Markdown source never tints the rendered image;
- complete source reveal for every Markdown construct intersected by a
  non-empty selection, including list/task markers, ATX prefixes, inline
  delimiters, links, fences, and tables; intersected constructs also drop
  preview backgrounds, semantic colors, emphasis, and widgets while selected;
  geometry-only decorations retain heading font size/line height, list layout,
  and inline-code line metrics, while collapsed carets retain the existing
  active-construct behavior and IME marked ranges retain stable composition
  geometry;
- selected unordered-list marker source keeps its literal separator in the
  same fixed-width hanging slot as the inactive bullet widget; nested source
  indentation stays selectable and copyable in a zero-layout-width mark because
  semantic list depth already owns that space, so starting, reversing, or
  clearing a text selection moves neither the list body column nor its row;
- FloralMD's Markdown dialect recognizes headings only through ATX `#`
  prefixes; Setext underline-shaped source stays as two ordinary editable
  lines and never contributes H1/H2 live-preview styling or gutter labels;
- Mermaid rendering for fences authored after the editor page has loaded;
- complete fenced-code source reveal while a code block is active; and
- incomplete opening fences remain visible and undecorated until a matching
  closing fence exists;
- syntax-tree decorations for system-blue links, softly purple image references,
  warm inline code, and secondary-color Markdown delimiters without changing source;
- visible-range hashtag marks for Unicode tags and slash-separated tag paths,
  with syntax-tree exclusions for headings, code, links, URLs, frontmatter,
  HTML, and rendered tables; the marks never replace source text and drop their
  capsule fill while selected; body decorations and inactive table cells share
  one hashtag token scanner, while each renderer retains its structural exclusions;
- block image widgets below still-visible Markdown image syntax, with
  incremental path edits and explicit cache-busting refresh effects;
- image-widget pointer handling that maps only actual image or gallery
  whitespace clicks back to neighboring Markdown source, while real
  `.cm-line` clicks remain under CodeMirror's native hit testing;
- loaded image widgets send a typed relative `openImage` request on
  Command-click or a second native mouse-down; ordinary clicks still select
  the Markdown image source, and loading/error widgets never request a window;
- measured image-widget spacing uses padding on the widget box rather than
  unmeasured margins, keeping CodeMirror's height map aligned with WebKit;
- source-line ArrowUp / ArrowDown navigation whenever image previews are
  present, preserving the logical source column instead of resolving through
  a non-editable image block's visual height;
- editable table cells with single-transaction row/column structure commands
  and stable Tab/Shift-Tab focus restoration; inactive cells use the shared
  Markdown parser and inline-math renderer for emphasis, strikethrough, code,
  hashtag capsules, links, images, escapes, and `$...$`, while focus restores raw Markdown;
  table-cell context menus remain un-intercepted while explicit row/column
  handles own structural deletion;
- Command-Enter in any editable table cell commits pending cell text and moves
  the CodeMirror selection to the first table-body boundary in one transaction;
  terminal tables gain one empty body line, while existing body lines and blank
  separators are reused without appending a table row or duplicate spacing;
- localized, empty-text add-row and add-column edge buttons that appear only
  on table hover or focus-within and expose accessible labels without entering
  Markdown source or search text;
- empty-text row/column selection points plus divider insertion buttons whose
  positions follow the rendered grid during resize and horizontal scrolling;
- Command-click routing for rendered links through the Swift host bridge;
- syntax-tree semantic row metadata for neutral `H1`–`H6`, warm `CODE`, and
  softly purple standalone image or image-gallery `IMG` gutter badges;
- inactive ATX prefixes retained as zero-width CodeMirror text marks rather
  than replace decorations or whole-line CSS transforms, keeping text,
  selection, caret, wrapping, and pointer hit testing in one measured
  coordinate system without duplicate selection rectangles;
- an internal `_view` bridge used only by FloralMD's host-managed editor
  gutter.

The host renders virtualized line numbers and compact `H1`–`H6` / `CODE`
structure badges from that view. Keeping the gutter in the host preserves the
existing FloralMD-local CodeMirror behavior while sharing the editor's
virtualized viewport geometry and coalescing visible-row updates by frame.

The generated bundle SHA-256 is:

`e2f09e23793e51c63942e215efd76a0ea61d5f5e9aec9b3b7edfc0fc2462372e`

## FloralMD direct patch: dash-space list trigger and IME stability

`2026-08-14` — the vendored bundle was patched in place (the FloralMD-local
`entry-cm.js` source is not part of this repository), changing two behaviors:

- a bullet marker (`-`, `*`, `+`) must now be followed by whitespace to parse
  as a `ListMark`; a bare marker at end of line stays an ordinary paragraph, so
  typing `-` no longer enters the rendered list state until a space follows
  (`- `). The CommonMark-only "marker at end of line" acceptance was removed
  from the bullet-list rule (`Gl`); ordered lists and task markers are
  unchanged. The raw-indented fallback decorator (`Cr` + list line) applies the
  same rule: a marker with no following whitespace gets list typography but
  never the hanging box — this covers a bare `-` line inside a list context
  (lazy continuation after a list item), where the box would otherwise sit
  right at the input-method caret and flip the candidate window vertically.
- while an input-method composition is active on a bullet-marker line, the
  hidden separator space behind the marker stops being a zero-width
  *replacement widget* and is rendered as a zero-font inline *mark* instead,
  and task-list checkbox widgets are not emitted. WebKit rebuilds
  `cm-widgetBuffer` nodes around a composition range on every keystroke — even
  when the decoration itself is unchanged (CodeMirror issue 9799 on the
  discuss forum, confirmed by the maintainer) — and the resulting DOM churn
  breaks IME input: swallowed characters, caret artifacts, and occasional
  vertical candidate windows. A mark keeps the exact same zero-width geometry
  without being a widget, so the composition range's DOM stays untouched by
  decoration updates. The bullet marker's hanging box itself is a mark
  decoration and never changes during composition.
- Tab inside a list item nests it instead of turning it into an indented code
  block: indented lines whose text matches a list marker (`Cr`) are rendered
  with list typography in any context (the raw-indented fallback previously
  required list ancestry), and the caret lands on the text column after the
  marker (a caret already past the marker keeps its relative position). This
  applies to ordered and unordered lists alike, so `1. item` + Tab yields a
  nested `    1. item` with the caret before `item`, not a code card with the
  caret stuck in front of the digits.
- the caret is drawn by a small dedicated ViewPlugin (`.cm-cursor` in its own
  `.cm-cursorLayer`, matching the text color) and the native caret is hidden
  (`caret-color: transparent`): WebKit otherwise leaves a stale native caret
  drawn at the previous position after deletions (a phantom fixed caret until
  the next repaint). The plugin positions the caret in content coordinates
  (`coordsAtPos` + scroll offset × scale), so it stays glued to the caret
  while the scroller moves — including typewriter-mode follow scrolling — and
  keeps the last known position when the caret is momentarily outside the
  viewport during scroll animations instead of disappearing.

The patched bundle SHA-256 is:

`fcc0e5113f5ce212db8a03106d9fbaeac8ac0fb1801366ad0124198a7755bdad`

## FloralMD direct patch: ordered markers share the bullet hanging slot

`2026-08-15` — the vendored bundle was patched in place again. Ordered list
markers (`1.`, `10)`) now get a `cm-md-ordered-marker` mark wrapping the
source text **plus its separating whitespace** (mirroring how the bullet
widget covers `- `), styled as an inline-block hanging slot with
`min-width: 1.6em` (matching the bullet widget's fixed slot). Item text
therefore starts at the same column for ordered and unordered lists, and at
the same column the read-only preview uses; the slot only grows for wide
numerals (100+). The mark keeps the digits as real selectable/editable
source text — unlike the unordered bullet widget, no text is replaced.

The patched bundle SHA-256 is:

`52bb9f6db4ecbc7481bb32205e3320f928659759e039df1cadf4ea1e0ad22e9a`

## FloralMD direct patch: composition is line-local for task checkboxes

`2026-08-17` — the vendored bundle was patched in place again. The IME
composition flag was a document-wide boolean (`ko` StateField), so while any
input method composed *anywhere*, the task-checkbox branch (`!s`) suppressed
every task checkbox in the document at once: typing one character with a
Chinese/Japanese IME reverted **all** task lists to raw `- [ ]` until the
composition ended. The suppression was only ever needed on the line being
composed on (WebKit rebuilds `cm-widgetBuffer` nodes around the composition
range), so:

- the `ko` StateField now stores the **composition start position** instead of
  a boolean: `compositionstart` records `selection.main.head`, `compositionend`
  clears it, and the stored position is mapped across subsequent transactions
  (`changes.mapPos`) so edits before it keep the check correct;
- the task-checkbox branch now suppresses the widget only when the composition
  position falls on the item's own line
  (`ql = s != null && lineAt(s).number === itemLine.number`); all other task
  lines keep their rendered checkboxes while you type;
- the test hook `_setCompositionActiveForTesting(active)` mirrors the same
  semantics (`true` → current caret position, `false` → null).

Host-side companions in `CodeMirrorEditorViewController.swift`: the checked
state's check mark is now a centered SVG background overlay (`::after` with
`position: absolute; inset: 0; background-position: center`) instead of a `✓`
text glyph. Measured in the WebKit test harness, the glyph (as the only
inline-grid item) changed the input's internal layout and pulled the **entire
checked box** ~7px below the unchecked one; the absolute overlay takes the
content out of the grid flow entirely so checked and unchecked boxes keep
identical geometry, and the check centers on the box independent of font
metrics, matching the read-only preview's task checkboxes.

The patched bundle SHA-256 is:

`ede4f5403c28ebdda8bbbea4e9c4cda57cecd9e67388374fa76ce401ae17151f` → final `6daaf00510e863e0161c5170241272308f40e93d288cb8a27187e79d34935137`

## FloralMD direct patch: ordered lists renumber from 1 after item deletion

`2026-08-17` — the vendored bundle was patched in place again. A new
`transactionFilter` extension (`Yz`, registered after the markdown language
support in the editor extension array) rewrites ordered-list numbers after a
deletion removes one or more list items:

- trigger: a transaction whose `userEvent` starts with `delete` (Backspace,
  Delete, cut) and whose deleted ranges fully cover the marker line of at
  least one `ListItem` in the syntax tree; the deletion and the renumbering
  land in the same transaction, so a single Undo restores the pre-delete
  document;
- rule: each affected `OrderedList` (the list that lost an item) is renumbered
  as a complete sequence starting at `1` in the new document — `1/2/3`
  deleting `2` yields `1/2`, `3/4/5` deleting `4` yields `1/2`, and even an
  already broken list like `1/3/4` deleting `3` is repaired to `1/2`;
- only the digit run is replaced: the `[.)]` separator, item text, task
  checkboxes, and indentation are untouched; nested lists renumber only their
  own items; blank lines between items do not split the list (loose list),
  while intervening paragraphs/headings/code split it and are never crossed;
- deletions that remove text inside an item (its marker line survives) or that
  only touch the digits themselves do not trigger a renumber.

The patched bundle SHA-256 is:

`6cfd3102f343e71dc10e77ccf29d062bcdbe83e5682edbd813ac0de15b8dad28`

The upstream headless smoke suite covers byte-faithful semantic token and
gutter classification, ATX source collapse/reveal, gallery whitespace, and
logical source-line navigation. FloralMD's WebKit integration suite additionally
uses 14 logical lines, single- and two-image galleries, 52px loading/error and
420px loaded states, unscrolled and scrolled viewports, native left/middle/right
line hit testing, widget/gap clicks, dragging, and every adjacent ArrowUp /
ArrowDown transition without modifying Markdown source. It also verifies forward,
reverse, and full-document selections, complete list/task/heading/inline source
reveal, collapse restoration, raw-source copying, and bounded selection geometry.
It verifies that same-row source fragments paint continuously while rendered
image previews remain outside the text selection layer.
It also drives native single-, double- and Command-click image events, safe
inactive table-cell inline rendering, shared inline-formula rendering,
raw-source focus/blur round trips, ATX-only heading semantics, and the complete
table structure control matrix, including un-intercepted table-cell context
menus and Command-Enter table-body exit, through the combined source and real
`WKWebView` suites. Both suites passed before the generated bundle from unified
upstream commit `0b7206b` was copied into FloralMD.
