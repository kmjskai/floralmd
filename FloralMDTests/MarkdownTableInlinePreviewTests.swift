import AppKit
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
struct MarkdownTableInlinePreviewTests {
    @Test @MainActor func inactiveCellsRenderInlineMarkdownAndFocusRevealsSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMDTableInlinePreview-\(UUID().uuidString)", isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let assets = notes.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let documentURL = notes.appendingPathComponent("table.md")
        try Data().write(to: documentURL)
        try Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\" fill=\"red\"/></svg>".utf8
        ).write(to: assets.appendingPathComponent("diagram.svg"))

        let markdown = [
            "| Kind | Value |",
            "| --- | --- |",
            "| Style | **粗体** *斜体* ~~删除~~ `代码` |",
            "| Link | [文档](notes/doc.md) |",
            "| Image | ![示意](assets/diagram.svg) |",
            "| Math | 行内 $E = mc^2$ 结束 |",
            "| Tags | #issue #项目 #issue/bug # #123 abc#no https://example.com/#raw \\#escaped `#inline` [链接](https://example.com/#anchor) |",
            "| Escape | \\*普通\\* A \\| B <img src=x onerror=alert(1)> |",
        ].joined(separator: "\n")
        let session = WorkspaceSession(
            rootURL: root,
            kind: .draft,
            activeResource: ActiveResource(url: documentURL)
        )
        let context = try #require(
            MarkdownLocalResourceContext(session: session, documentURL: documentURL)
        )
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        controller.documentURL = documentURL
        controller.setResourceContext(context)
        controller.load(markdown: markdown)
        try await waitUntilReady(controller)

        let rendered = await evaluate(
            """
            (() => {
              const style = document.querySelector(
                '[data-table-row="1"][data-table-column="1"]'
              );
              const escaped = document.querySelector(
                '[data-table-row="6"][data-table-column="1"]'
              );
              const tags = document.querySelector(
                '[data-table-row="5"][data-table-column="1"]'
              );
              const image = document.querySelector('.cm-md-table-inline-image');
              return {
                hasKaTeX: !!window.katex,
                strong: style?.querySelector('.cm-md-strong')?.textContent || null,
                emphasis: style?.querySelector('.cm-md-emphasis')?.textContent || null,
                strike: style?.querySelector('.cm-md-strikethrough')?.textContent || null,
                code: style?.querySelector('.cm-md-inline-code')?.textContent || null,
                link: document.querySelector(
                  '.cm-md-table-cell .cm-md-link[data-md-href="notes/doc.md"]'
                )?.textContent || null,
                imageScheme: image ? new URL(image.src).protocol : null,
                imageAlt: image?.getAttribute('alt') || null,
                inlineMath: document.querySelector(
                  '[data-table-row="4"][data-table-column="1"] .cm-md-math-inline .katex'
                )?.textContent || null,
                tags: Array.from(tags?.querySelectorAll('.cm-md-tag') || [])
                  .map(element => element.textContent),
                tagText: tags?.textContent || null,
                tagInlineCode: tags?.querySelector('.cm-md-inline-code')?.textContent || null,
                tagLink: tags?.querySelector(
                  '.cm-md-link[data-md-href="https://example.com/#anchor"]'
                )?.textContent || null,
                escaped: escaped?.textContent || null,
                unsafeHTML: !!document.querySelector('.cm-md-table-cell [onerror]'),
                source: window.__mdEditor.getMarkdown()
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(rendered?["hasKaTeX"] as? Bool == true)
        #expect(rendered?["strong"] as? String == "粗体")
        #expect(rendered?["emphasis"] as? String == "斜体")
        #expect(rendered?["strike"] as? String == "删除")
        #expect(rendered?["code"] as? String == "代码")
        #expect(rendered?["link"] as? String == "文档")
        #expect(rendered?["imageScheme"] as? String == "floralmd-resource:")
        #expect(rendered?["imageAlt"] as? String == "示意")
        #expect((rendered?["inlineMath"] as? String)?.contains("E=mc2") == true)
        #expect(rendered?["tags"] as? [String] == ["#issue", "#项目", "#issue/bug"])
        #expect((rendered?["tagText"] as? String)?.contains("#123 abc#no") == true)
        #expect((rendered?["tagText"] as? String)?.contains("https://example.com/#raw") == true)
        #expect((rendered?["tagText"] as? String)?.contains("#escaped") == true)
        #expect(rendered?["tagInlineCode"] as? String == "#inline")
        #expect(rendered?["tagLink"] as? String == "链接")
        #expect(rendered?["escaped"] as? String == "*普通* A | B <img src=x onerror=alert(1)>")
        #expect(rendered?["unsafeHTML"] as? Bool == false)
        #expect(rendered?["source"] as? String == markdown)

        let mathEditing = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="4"][data-table-column="1"]'
              );
              cell.focus();
              const source = cell.textContent;
              const renderedMath = !!cell.querySelector('.cm-md-math-inline');
              cell.blur();
              return {
                source,
                renderedMath,
                rerenderedMath: !!cell.querySelector('.cm-md-math-inline .katex')
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(mathEditing?["source"] as? String == "行内 $E = mc^2$ 结束")
        #expect(mathEditing?["renderedMath"] as? Bool == false)
        #expect(mathEditing?["rerenderedMath"] as? Bool == true)

        let tagEditing = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="5"][data-table-column="1"]'
              );
              cell.focus();
              const source = cell.textContent;
              const renderedTag = !!cell.querySelector('.cm-md-tag');
              cell.blur();
              return {
                source,
                renderedTag,
                rerenderedTags: Array.from(cell.querySelectorAll('.cm-md-tag'))
                  .map(element => element.textContent),
                markdown: window.__mdEditor.getMarkdown()
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect((tagEditing?["source"] as? String)?.contains("#issue #项目 #issue/bug") == true)
        #expect(tagEditing?["renderedTag"] as? Bool == false)
        #expect(tagEditing?["rerenderedTags"] as? [String] == ["#issue", "#项目", "#issue/bug"])
        #expect(tagEditing?["markdown"] as? String == markdown)

        let editing = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="1"][data-table-column="1"]'
              );
              cell.focus();
              return {
                source: cell.textContent,
                renderedStrong: !!cell.querySelector('.cm-md-strong')
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(editing?["source"] as? String == "**粗体** *斜体* ~~删除~~ `代码`")
        #expect(editing?["renderedStrong"] as? Bool == false)

        let afterBlur = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="1"][data-table-column="1"]'
              );
              cell.blur();
              return {
                strong: cell.querySelector('.cm-md-strong')?.textContent || null,
                source: window.__mdEditor.getMarkdown()
              };
            })()
            """,
            in: controller
        ) as? [String: Any]
        #expect(afterBlur?["strong"] as? String == "粗体")
        #expect(afterBlur?["source"] as? String == markdown)

        _ = await evaluate(
            """
            (() => {
              const cell = document.querySelector(
                '[data-table-row="1"][data-table-column="1"]'
              );
              cell.focus();
              cell.innerText = '**更新中文**';
              cell.blur();
              return true;
            })()
            """,
            in: controller
        )
        let updated = try #require(
            await waitForMarkdownContaining("**更新中文**", in: controller)
        )
        let updatedStrong = await evaluate(
            "document.querySelector('[data-table-row=\"1\"][data-table-column=\"1\"] .cm-md-strong')?.textContent",
            in: controller
        ) as? String
        #expect(updatedStrong == "更新中文")

        _ = await evaluate("window.__mdEditor._undoForTesting()", in: controller)
        #expect(await waitForMarkdown(markdown, in: controller))
        _ = await evaluate("window.__mdEditor._redoForTesting()", in: controller)
        #expect(await waitForMarkdown(updated, in: controller))
    }

    @MainActor
    private func waitUntilReady(_ controller: CodeMirrorEditorViewController) async throws {
        for _ in 0..<120 {
            if await evaluate("window.__mdEditor != null", in: controller) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("CodeMirror did not become ready")
    }

    @MainActor
    private func evaluate(_ script: String, in controller: CodeMirrorEditorViewController) async -> Any? {
        await withCheckedContinuation { continuation in
            controller.evaluateEditorJavaScript(script) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private func waitForMarkdownContaining(
        _ fragment: String,
        in controller: CodeMirrorEditorViewController
    ) async -> String? {
        for _ in 0..<100 {
            if let source = await markdown(in: controller), source.contains(fragment) { return source }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    @MainActor
    private func waitForMarkdown(
        _ expected: String,
        in controller: CodeMirrorEditorViewController
    ) async -> Bool {
        for _ in 0..<100 {
            if await markdown(in: controller) == expected { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @MainActor
    private func markdown(in controller: CodeMirrorEditorViewController) async -> String? {
        await withCheckedContinuation { continuation in
            controller.fetchMarkdown { continuation.resume(returning: $0) }
        }
    }
}
