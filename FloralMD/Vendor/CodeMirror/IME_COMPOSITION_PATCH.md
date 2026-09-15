# FloralMD CodeMirror IME composition patch

`mdedit.min.js` is generated from `scripts/editor-bundle/entry-cm.js` in
`pluk-inc/markdown-preview` at commit
`e364421b76df9f650012a270e4b5b6c9d799323f` (MIT).

FloralMD adds one local behavior patch before bundling: `compositionstart`
and `compositionend` update a CodeMirror state field. While composition is
active, a non-empty input-method marked range that intersects a Markdown
construct counts as active source editing. This prevents live preview from
hiding or repositioning Markdown markers underneath the macOS input method.
An active ATX heading keeps its native heading class and displays its `# `
source prefix at the same heading size throughout composition. After the
candidate is committed and the line becomes inactive, live preview hides the
prefix again without changing the stored Markdown.

The generated bundle SHA-256 after this patch is:

`5c24a7f2befc5b8041e7ed28b4983f5e5f517b21686ef3c9e207fe9991468c06`

The upstream headless smoke test was extended with an ATX-heading marked-range
case. It verifies that the heading class remains present, the source prefix is
visible during composition, and inactive live preview returns afterward. The
test passed before the generated bundle was copied into FloralMD.
