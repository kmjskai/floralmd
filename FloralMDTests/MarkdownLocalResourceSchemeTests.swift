import Foundation
import Testing
import WebKit
@testable import FloralMD

@Suite(.serialized)
struct MarkdownLocalResourceSchemeTests {
    @Test func servesEverySupportedImageFormatWithExactMIME() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let png = try fixture.write(Self.pngData, to: "notes/assets/images/picture.png")
        let jpeg = try fixture.write(Self.jpegData, to: "notes/assets/images/photo.JPEG")
        let gif = try fixture.write(Self.gifData, to: "notes/assets/images/animation.gif")
        let webP = try fixture.write(Self.webPData, to: "notes/assets/images/photo.webp")
        let svg = try fixture.write(Self.svgData, to: "notes/assets/drawing-exports/diagram.svg")
        let registered = try fixture.register(documentPath: "notes/note.md")

        let pngResource = try registered.handler.resolvedResource(
            for: try registered.requestURL(to: png)
        )
        let jpegResource = try registered.handler.resolvedResource(
            for: try registered.requestURL(to: jpeg)
        )
        let gifResource = try registered.handler.resolvedResource(
            for: try registered.requestURL(to: gif)
        )
        let webPResource = try registered.handler.resolvedResource(
            for: try registered.requestURL(to: webP)
        )
        let svgResource = try registered.handler.resolvedResource(
            for: try registered.requestURL(to: svg)
        )

        #expect(pngResource.mimeType == "image/png")
        #expect(pngResource.textEncodingName == nil)
        #expect(jpegResource.mimeType == "image/jpeg")
        #expect(jpegResource.textEncodingName == nil)
        #expect(gifResource.mimeType == "image/gif")
        #expect(webPResource.mimeType == "image/webp")
        #expect(svgResource.mimeType == "image/svg+xml")
        #expect(svgResource.textEncodingName == "utf-8")
    }

    @Test func resolvesLegalParentTraversalAndEncodedSpecialCharacters() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parentImage = try fixture.write(
            Self.pngData,
            to: "drawings/images/父 目录(图)#100%.png"
        )
        let registered = try fixture.register(documentPath: "notes/子目录/note.md")
        let relativePath = MarkdownImageAssetStore.percentEncodedRelativePath(
            from: registered.documentDirectory,
            to: parentImage
        )

        #expect(relativePath.contains(".."))
        #expect(relativePath.contains("%20"))
        #expect(relativePath.contains("%23"))
        #expect(relativePath.contains("%25"))
        let requestURL = try #require(URL(string: relativePath, relativeTo: registered.baseURL)?.absoluteURL)
        let resource = try registered.handler.resolvedResource(for: requestURL)

        #expect(resource.fileURL == parentImage.standardizedFileURL)
        #expect(!registered.baseURL.absoluteString.contains(fixture.root.path))
    }

    @Test func untitledDraftUsesNotesAsItsResourceBase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try fixture.write(Self.pngData, to: "notes/assets/images/pasted.png")
        let session = WorkspaceSession(rootURL: fixture.root, kind: .draft, activeResource: nil)
        let context = try #require(MarkdownLocalResourceContext(session: session, documentURL: nil))
        let handler = MarkdownLocalResourceSchemeHandler()
        let baseURL = try #require(handler.register(context))
        let requestURL = try #require(URL(string: "assets/images/pasted.png", relativeTo: baseURL)?.absoluteURL)

        #expect(context.documentDirectoryURL == fixture.root.appendingPathComponent("notes", isDirectory: true))
        #expect(try handler.resolvedResource(for: requestURL).fileURL == image.standardizedFileURL)
    }

    @Test func rejectsMissingDirectorySymlinkEscapeAndPseudoExtension() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registered = try fixture.register(documentPath: "notes/note.md")
        let directory = fixture.root.appendingPathComponent("notes/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fakePNG = try fixture.write(Data("not an image".utf8), to: "notes/fake.png")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloralMD-Outside-\(UUID().uuidString).png")
        try Self.pngData.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let symlink = fixture.root.appendingPathComponent("notes/link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let linkedDirectory = fixture.root.appendingPathComponent("notes/linked-directory")
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: outside.deletingLastPathComponent()
        )

        let missingURL = try #require(URL(string: "missing.png", relativeTo: registered.baseURL)?.absoluteURL)
        let directoryURL = try registered.requestURL(to: directory)
        let symlinkURL = try registered.requestURL(to: symlink)
        let intermediateSymlinkURL = try #require(
            URL(string: "linked-directory/\(outside.lastPathComponent)", relativeTo: registered.baseURL)?.absoluteURL
        )
        let fakeURL = try registered.requestURL(to: fakePNG)
        let ordinaryEscape = try #require(
            URL(string: "../../\(outside.lastPathComponent)", relativeTo: registered.baseURL)?.absoluteURL
        )
        let encodedEscape = try #require(URL(string: "%2E%2E/%2E%2E/\(outside.lastPathComponent)", relativeTo: registered.baseURL)?.absoluteURL)

        #expect(throws: MarkdownLocalResourceError.unavailable) {
            try registered.handler.resolvedResource(for: missingURL)
        }
        #expect(throws: MarkdownLocalResourceError.directoryUnsupported) {
            try registered.handler.resolvedResource(for: directoryURL)
        }
        #expect(throws: MarkdownLocalResourceError.symbolicLinkUnsupported) {
            try registered.handler.resolvedResource(for: symlinkURL)
        }
        #expect(throws: MarkdownLocalResourceError.symbolicLinkUnsupported) {
            try registered.handler.resolvedResource(for: intermediateSymlinkURL)
        }
        #expect(throws: MarkdownLocalResourceError.invalidImageData) {
            try registered.handler.resolvedResource(for: fakeURL)
        }
        #expect(throws: MarkdownLocalResourceError.unavailable) {
            try registered.handler.resolvedResource(for: ordinaryEscape)
        }
        #expect(throws: MarkdownLocalResourceError.invalidRequest) {
            try registered.handler.resolvedResource(for: encodedEscape)
        }
    }

    @Test func rejectsUnsupportedExtensionsRemoteURLsAndStaleScopes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bitmap = try fixture.write(Self.pngData, to: "notes/image.bmp")
        let first = try fixture.register(documentPath: "notes/first.md")
        let firstRequest = try first.requestURL(to: bitmap)

        #expect(throws: MarkdownLocalResourceError.unsupportedImageType) {
            try first.handler.resolvedResource(for: firstRequest)
        }
        #expect(throws: MarkdownLocalResourceError.invalidRequest) {
            try first.handler.resolvedResource(for: URL(string: "https://example.com/image.png")!)
        }

        let secondDocument = try fixture.write(Data(), to: "notes/nested/second.md")
        let secondResource = try #require(ActiveResource(url: secondDocument))
        let secondSession = WorkspaceSession(
            rootURL: fixture.root,
            kind: .draft,
            activeResource: secondResource
        )
        let secondContext = try #require(
            MarkdownLocalResourceContext(session: secondSession, documentURL: secondDocument)
        )
        _ = first.handler.register(secondContext)
        #expect(throws: MarkdownLocalResourceError.invalidRequest) {
            try first.handler.resolvedResource(for: firstRequest)
        }
    }

    @Test func acceptsOnlyTheInternalNumericImageRefreshQuery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try fixture.write(Self.pngData, to: "notes/image.png")
        let registered = try fixture.register(documentPath: "notes/note.md")
        let request = try registered.requestURL(to: image)
        var allowed = try #require(URLComponents(url: request, resolvingAgainstBaseURL: false))
        allowed.queryItems = [URLQueryItem(name: "__floralmd_refresh", value: "2")]
        var rejected = allowed
        rejected.queryItems = [URLQueryItem(name: "token", value: "2")]

        #expect(try registered.handler.resolvedResource(for: #require(allowed.url)).fileURL == image)
        #expect(throws: MarkdownLocalResourceError.invalidRequest) {
            try registered.handler.resolvedResource(for: #require(rejected.url))
        }
    }

    @Test @MainActor func editorAndPreviewInstallTheSameWorkspaceResourceEntry() {
        let editorHandler = MarkdownLocalResourceSchemeHandler()
        let previewHandler = MarkdownLocalResourceSchemeHandler()
        let editorConfiguration = CodeMirrorEditorViewController.makeWebViewConfiguration(
            resourceHandler: editorHandler
        )
        let previewConfiguration = MarkdownPreviewWebView.makeWebViewConfiguration(
            resourceHandler: previewHandler
        )

        #expect(editorConfiguration.urlSchemeHandler(
            forURLScheme: MarkdownLocalResourceSchemeHandler.scheme
        ) === editorHandler)
        #expect(previewConfiguration.urlSchemeHandler(
            forURLScheme: MarkdownLocalResourceSchemeHandler.scheme
        ) === previewHandler)
    }

    @Test @MainActor func editorAndPreviewRenderThroughTheWorkspaceResourceScheme() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(Self.pngData, to: "notes/assets/images/live.png")
        let documentURL = try fixture.write(Data(), to: "notes/note.md")
        let activeResource = try #require(ActiveResource(url: documentURL))
        let session = WorkspaceSession(
            rootURL: fixture.root,
            kind: .draft,
            activeResource: activeResource
        )
        let context = try #require(
            MarkdownLocalResourceContext(session: session, documentURL: documentURL)
        )
        let markdown = "# Note\n\n![live](assets/images/live.png)"

        let editor = CodeMirrorEditorViewController()
        editor.loadViewIfNeeded()
        editor.documentURL = documentURL
        editor.setResourceContext(context)
        editor.load(markdown: markdown)

        let previewHandler = MarkdownLocalResourceSchemeHandler()
        let previewBaseURL = try #require(previewHandler.register(context))
        let preview = TransparentMarkdownWebView(
            frame: .zero,
            configuration: MarkdownPreviewWebView.makeWebViewConfiguration(
                resourceHandler: previewHandler
            )
        )
        preview.loadHTMLString(
            MarkdownHTML.makeHTML(
                from: markdown,
                allowsScroll: true,
                assetBaseHref: previewBaseURL.absoluteString
            ),
            baseURL: previewBaseURL
        )

        var editorLoaded = false
        var previewLoaded = false
        for _ in 0..<100 where !editorLoaded || !previewLoaded {
            editorLoaded = await withCheckedContinuation { continuation in
                editor.evaluateEditorJavaScript(
                    """
                    (() => {
                      if (!window.__mdEditor) return false;
                      let image = document.getElementById('scheme-test-image');
                      if (!image) {
                        image = document.createElement('img');
                        image.id = 'scheme-test-image';
                        image.src = 'assets/images/live.png';
                        document.body.appendChild(image);
                      }
                      return image.complete && image.naturalWidth > 0;
                    })()
                    """
                ) { value in
                    continuation.resume(returning: value as? Bool ?? false)
                }
            }
            previewLoaded = await withCheckedContinuation { continuation in
                preview.evaluateJavaScript(
                    "Array.from(document.images).some(image => image.complete && image.naturalWidth > 0)"
                ) { value, _ in
                    continuation.resume(returning: value as? Bool ?? false)
                }
            }
            if !editorLoaded || !previewLoaded {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        #expect(editorLoaded)
        #expect(previewLoaded)
    }

    @Test @MainActor func editorDecoratesSupportedImagesAndKeepsFailuresEditable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(Self.pngData, to: "notes/assets/images/live.png")
        _ = try fixture.write(Self.gifData, to: "notes/assets/images/animation.gif")
        _ = try fixture.write(Self.webPData, to: "notes/assets/images/photo.webp")
        _ = try fixture.write(Self.svgData, to: "notes/assets/images/diagram.svg")
        let documentURL = try fixture.write(Data(), to: "notes/note.md")
        let activeResource = try #require(ActiveResource(url: documentURL))
        let session = WorkspaceSession(
            rootURL: fixture.root,
            kind: .draft,
            activeResource: activeResource
        )
        let context = try #require(
            MarkdownLocalResourceContext(session: session, documentURL: documentURL)
        )
        let markdown = """
        ![PNG](assets/images/live.png)
        ![GIF](assets/images/animation.gif)
        ![WebP](assets/images/photo.webp)
        ![SVG](assets/images/diagram.svg)
        ![Missing](assets/images/missing.png)
        ![Outside](../../outside.png)
        """
        let editor = CodeMirrorEditorViewController()
        editor.loadViewIfNeeded()
        editor.documentURL = documentURL
        editor.setResourceContext(context)
        editor.load(markdown: markdown)

        var result: [String: Any]?
        for _ in 0..<120 {
            result = await withCheckedContinuation { continuation in
                editor.evaluateEditorJavaScript(
                    """
                    (() => ({
                      ready: !!window.__mdEditor,
                      previews: document.querySelectorAll('.cm-md-image-preview').length,
                      loaded: document.querySelectorAll('.cm-md-image-preview.is-loaded').length,
                      failed: document.querySelectorAll('.cm-md-image-preview.is-error').length,
                      loadedSources: Array.from(document.querySelectorAll(
                        '.cm-md-image-preview.is-loaded'
                      )).map(element => element.dataset.imageSource),
                      failedSources: Array.from(document.querySelectorAll(
                        '.cm-md-image-preview.is-error'
                      )).map(element => element.dataset.imageSource),
                      syntaxVisible: document.querySelector('.cm-content')?.textContent.includes(
                        '![WebP](assets/images/photo.webp)'
                      ) || false,
                      failureText: Array.from(document.querySelectorAll(
                        '.cm-md-image-preview.is-error .cm-md-image-status'
                      )).map(element => element.textContent)
                    }))()
                    """
                ) { value in
                    continuation.resume(returning: value as? [String: Any])
                }
            }
            if result?["loaded"] as? Int == 4, result?["failed"] as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(result?["ready"] as? Bool == true)
        #expect(result?["previews"] as? Int == 6)
        #expect(result?["loaded"] as? Int == 4)
        #expect(result?["failed"] as? Int == 2)
        #expect((result?["loadedSources"] as? [String]) == [
            "assets/images/live.png",
            "assets/images/animation.gif",
            "assets/images/photo.webp",
            "assets/images/diagram.svg"
        ])
        #expect((result?["failedSources"] as? [String]) == [
            "assets/images/missing.png",
            "../../outside.png"
        ])
        #expect(result?["syntaxVisible"] as? Bool == true)
        #expect((result?["failureText"] as? [String]) == ["Image unavailable", "Image unavailable"])
        let storedMarkdown = await withCheckedContinuation { continuation in
            editor.fetchMarkdown { continuation.resume(returning: $0) }
        }
        #expect(storedMarkdown == markdown)
    }

    @Test @MainActor func imagePathEditUndoAndResourceRefreshStayInsideTheEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(Self.pngData, to: "notes/assets/images/live.png")
        _ = try fixture.write(Self.pngData, to: "notes/assets/images/other.png")
        let documentURL = try fixture.write(Data(), to: "notes/note.md")
        let activeResource = try #require(ActiveResource(url: documentURL))
        let session = WorkspaceSession(rootURL: fixture.root, kind: .draft, activeResource: activeResource)
        let context = try #require(
            MarkdownLocalResourceContext(session: session, documentURL: documentURL)
        )
        let markdown = "![Live](assets/images/live.png)"
        let editor = CodeMirrorEditorViewController()
        editor.loadViewIfNeeded()
        editor.documentURL = documentURL
        editor.setResourceContext(context)
        editor.load(markdown: markdown)

        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                editor.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let edit = await withCheckedContinuation { continuation in
            editor.evaluateEditorJavaScript(
                """
                (() => {
                  window.__pageIdentity = 'kept';
                  const source = window.__mdEditor.getMarkdown();
                  const from = source.indexOf('live.png');
                  window.__mdEditor.select(from, from + 'live.png'.length);
                  window.__mdEditor.insert('other.png');
                  return {
                    markdown: window.__mdEditor.getMarkdown(),
                    source: document.querySelector('.cm-md-image-preview')?.dataset.imageSource,
                    selection: window.__mdEditor._selectionForTesting()
                  };
                })()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }
        #expect(edit?["markdown"] as? String == "![Live](assets/images/other.png)")
        #expect(edit?["source"] as? String == "assets/images/other.png")
        let selection = edit?["selection"] as? [String: Any]
        #expect(selection?["from"] as? Int == selection?["to"] as? Int)

        _ = await withCheckedContinuation { continuation in
            editor.evaluateEditorJavaScript(
                "window.__mdEditor._undoForTesting()"
            ) { value in continuation.resume(returning: value) }
        }
        try await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(250))

        let refreshed = await withCheckedContinuation { continuation in
            editor.evaluateEditorJavaScript(
                """
                (() => ({
                  markdown: window.__mdEditor.getMarkdown(),
                  source: document.querySelector('.cm-md-image-preview')?.dataset.imageSource,
                  pageIdentity: window.__pageIdentity,
                  refreshGeneration: document.querySelector(
                    '.cm-md-image-preview'
                  )?.dataset.refreshGeneration
                }))()
                """
            ) { value in
                continuation.resume(returning: value as? [String: Any])
            }
        }
        #expect(refreshed?["markdown"] as? String == markdown)
        #expect(refreshed?["source"] as? String == "assets/images/live.png")
        #expect(refreshed?["pageIdentity"] as? String == "kept")
        let refreshGeneration = Int(refreshed?["refreshGeneration"] as? String ?? "0") ?? 0
        #expect(refreshGeneration >= 1)
    }

    @Test @MainActor func imagePreviewSelectionMatrixUsesNativeHitTestingAndMeasuredGeometry() async throws {
        let markdown = """
        L01 opening ordinary text
        ![L02 start image](missing-start.png)
        L03 ordinary text
        L04 ordinary text
        L05 ordinary text
        ![L06 first](missing-first.png) ![L06 second](missing-second.png)
        L07 ordinary text
        L08 ordinary text
        L09 ordinary text
        L10 ordinary text
        ![L11 end image](missing-end.png)
        L12 ordinary text
        L13 ordinary text
        L14 closing ordinary text
        """
        let editor = CodeMirrorEditorViewController()
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 900, height: 540)
        editor.load(markdown: markdown)

        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                editor.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        func evaluate(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                editor.evaluateEditorJavaScriptWithError(script) { value, error in
                    if let error {
                        continuation.resume(returning: ["__error": error.localizedDescription])
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
        }

        let setup = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const figures = Array.from(document.querySelectorAll('.cm-md-image-preview'));
              figures[0].style.height = '52px';
              figures[0].className = 'cm-md-image-preview is-loading';
              figures[1].style.height = '52px';
              figures[1].className = 'cm-md-image-preview is-error';
              figures[2].style.height = '52px';
              figures[2].className = 'cm-md-image-preview is-error';
              figures[3].style.height = '420px';
              figures[3].className = 'cm-md-image-preview is-loaded';
              view.requestMeasure();
              return { figures: figures.length, lines: view.state.doc.lines };
            })()
            """
        ) as? [String: Any]
        #expect(setup?["figures"] as? Int == 4, Comment(rawValue: String(describing: setup)))
        #expect(setup?["lines"] as? Int == 14, Comment(rawValue: String(describing: setup)))
        try await Task.sleep(for: .milliseconds(200))

        var clickCount = 0
        var clickFailures: [[String: Any]] = []
        for fraction in [0.0, 0.5, 1.0] {
            _ = await evaluate(
                """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  const maximum = Math.max(view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight, 0);
                  view.scrollDOM.scrollTop = maximum * \(fraction);
                  view.scrollDOM.dispatchEvent(new Event('scroll'));
                  view.requestMeasure();
                  return true;
                })()
                """
            )
            try await Task.sleep(for: .milliseconds(100))
            let sweep = await evaluate(
                """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  const source = window.__mdEditor.getMarkdown();
                  const starts = [0];
                  for (let index = 0; index < source.length; index++) {
                    if (source[index] === '\\n') starts.push(index + 1);
                  }
                  const lineAt = position => {
                    let line = 1;
                    for (let index = 1; index < starts.length; index++) {
                      if (starts[index] > position) break;
                      line = index + 1;
                    }
                    return line;
                  };
                  const click = (x, y) => {
                    const target = document.elementFromPoint(x, y);
                    if (!target) return null;
                    target.dispatchEvent(new MouseEvent('mousedown', {
                      clientX: x, clientY: y, button: 0, buttons: 1,
                      bubbles: true, cancelable: true
                    }));
                    target.dispatchEvent(new MouseEvent('mouseup', {
                      clientX: x, clientY: y, button: 0, buttons: 0,
                      bubbles: true, cancelable: true
                    }));
                    return target;
                  };
                  const viewport = view.scrollDOM.getBoundingClientRect();
                  const failures = [];
                  let count = 0;
                  for (const lineDOM of document.querySelectorAll('.cm-line')) {
                    const rect = lineDOM.getBoundingClientRect();
                    if (rect.height <= 0 || rect.bottom <= viewport.top + 1
                        || rect.top >= viewport.bottom - 1) continue;
                    const expected = view.state.doc.lineAt(view.posAtDOM(lineDOM, 0)).number;
                    const left = Math.min(rect.right - 2, rect.left + 2);
                    const right = Math.max(left, rect.right - 2);
                    const y = Math.min(rect.bottom - 1, Math.max(rect.top + 1, (rect.top + rect.bottom) / 2));
                    for (const [zone, x] of [['left', left], ['middle', (left + right) / 2], ['right', right]]) {
                      const target = click(x, y);
                      const actual = lineAt(window.__mdEditor._selectionForTesting().from);
                      count += 1;
                      if (actual !== expected) failures.push({
                        expected, actual, zone, scroll: \(fraction),
                        target: target?.className || target?.nodeName || 'none'
                      });
                    }
                  }
                  return { count, failures };
                })()
                """
            ) as? [String: Any]
            clickCount += sweep?["count"] as? Int ?? 0
            clickFailures.append(contentsOf: sweep?["failures"] as? [[String: Any]] ?? [])
            if let error = sweep?["__error"] {
                clickFailures.append(["phase": "scroll-\(fraction)", "error": error])
            }
        }

        _ = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              view.scrollDOM.scrollTop = 0;
              view.scrollDOM.dispatchEvent(new Event('scroll'));
              view.requestMeasure();
              return true;
            })()
            """
        )
        try await Task.sleep(for: .milliseconds(100))
        let dragSelection = await evaluate(
            """
            (() => {
              const view = window.__mdEditor._viewForTesting;
              const source = window.__mdEditor.getMarkdown();
              const starts = [0];
              for (let index = 0; index < source.length; index++) {
                if (source[index] === '\\n') starts.push(index + 1);
              }
              const lineAt = position => {
                let number = 1;
                for (let index = 1; index < starts.length; index++) {
                  if (starts[index] > position) break;
                  number = index + 1;
                }
                return number;
              };
              const lines = Array.from(document.querySelectorAll('.cm-line'));
              const sourceLine = number => lines.find(element =>
                view.state.doc.lineAt(view.posAtDOM(element, 0)).number === number
              );
              const start = sourceLine(3).getBoundingClientRect();
              const end = sourceLine(4).getBoundingClientRect();
              const startX = start.left + 12;
              const startY = (start.top + start.bottom) / 2;
              const endX = end.left + 36;
              const endY = (end.top + end.bottom) / 2;
              const startTarget = document.elementFromPoint(startX, startY);
              const endTarget = document.elementFromPoint(endX, endY);
              startTarget.dispatchEvent(new MouseEvent('mousedown', {
                clientX: startX, clientY: startY, button: 0, buttons: 1,
                bubbles: true, cancelable: true
              }));
              endTarget.dispatchEvent(new MouseEvent('mousemove', {
                clientX: endX, clientY: endY, button: 0, buttons: 1,
                bubbles: true, cancelable: true
              }));
              endTarget.dispatchEvent(new MouseEvent('mouseup', {
                clientX: endX, clientY: endY, button: 0, buttons: 0,
                bubbles: true, cancelable: true
              }));
              const selection = window.__mdEditor._selectionForTesting();
              return {
                fromLine: lineAt(selection.from),
                toLine: lineAt(selection.to),
                toPosition: selection.to,
                line4From: starts[3],
                line5From: starts[4]
              };
            })()
            """
        ) as? [String: Any]

        var widgetFailures: [[String: Any]] = []
        for index in 0..<5 {
            _ = await evaluate(
                """
                (() => {
                  const figures = document.querySelectorAll('.cm-md-image-preview');
                  const galleries = document.querySelectorAll('.cm-md-image-gallery');
                  const element = \(index) === 4 ? galleries[1] : figures[\(index)];
                  element.scrollIntoView({ block: 'center' });
                  window.__mdEditor._viewForTesting.requestMeasure();
                  return true;
                })()
                """
            )
            try await Task.sleep(for: .milliseconds(100))
            let widget = await evaluate(
                """
                (() => {
                  const source = window.__mdEditor.getMarkdown();
                  const figures = document.querySelectorAll('.cm-md-image-preview');
                  const galleries = document.querySelectorAll('.cm-md-image-gallery');
                  const expected = [
                    source.indexOf('![L02 start image]'),
                    source.indexOf('![L06 first]'),
                    source.indexOf('![L06 second]'),
                    source.indexOf('![L11 end image]'),
                    source.indexOf('![L06 first]')
                  ][\(index)];
                  let x;
                  let y;
                  if (\(index) === 4) {
                    const first = figures[1].getBoundingClientRect();
                    const second = figures[2].getBoundingClientRect();
                    const gallery = galleries[1].getBoundingClientRect();
                    x = gallery.left + Math.min(8, gallery.width / 2);
                    y = (first.bottom + second.top) / 2;
                  } else {
                    const rect = figures[\(index)].getBoundingClientRect();
                    x = (rect.left + rect.right) / 2;
                    y = (rect.top + rect.bottom) / 2;
                  }
                  const target = document.elementFromPoint(x, y);
                  target?.dispatchEvent(new MouseEvent('mousedown', {
                    clientX: x, clientY: y, button: 0, buttons: 1,
                    bubbles: true, cancelable: true
                  }));
                  target?.dispatchEvent(new MouseEvent('mouseup', {
                    clientX: x, clientY: y, button: 0, buttons: 0,
                    bubbles: true, cancelable: true
                  }));
                  return {
                    index: \(index), expected,
                    actual: window.__mdEditor._selectionForTesting().from,
                    target: target?.className || target?.nodeName || 'none'
                  };
                })()
                """
            ) as? [String: Any]
            if widget?["actual"] as? Int != widget?["expected"] as? Int {
                widgetFailures.append(widget ?? ["index": index, "missing": true])
            }
        }

        var arrowFailures: [[String: Any]] = []
        var arrowCount = 0
        let arrowCases = (2...14).map { ($0, "ArrowUp", $0 - 1) }
            + (1..<14).map { ($0, "ArrowDown", $0 + 1) }
        for (line, key, expected) in arrowCases {
            let prepared = await evaluate(
                """
                (() => {
                  const source = window.__mdEditor.getMarkdown();
                  const starts = [0];
                  for (let index = 0; index < source.length; index++) {
                    if (source[index] === '\\n') starts.push(index + 1);
                  }
                  window.__mdEditor.select(starts[\(line - 1)] + 4);
                  window.__mdEditor.focus();
                  window.__mdEditor._viewForTesting.requestMeasure();
                  return true;
                })()
                """
            )
            if let error = (prepared as? [String: Any])?["__error"] {
                arrowFailures.append(["from": line, "key": key, "phase": "prepare", "error": error])
                arrowCount += 1
                continue
            }
            try await Task.sleep(for: .milliseconds(40))
            let moved = await evaluate(
                """
                (() => {
                  const source = window.__mdEditor.getMarkdown();
                  const starts = [0];
                  for (let index = 0; index < source.length; index++) {
                    if (source[index] === '\\n') starts.push(index + 1);
                  }
                  const lineAt = position => {
                    let number = 1;
                    for (let index = 1; index < starts.length; index++) {
                      if (starts[index] > position) break;
                      number = index + 1;
                    }
                    return number;
                  };
                  window.__mdEditor._viewForTesting.contentDOM.dispatchEvent(
                    new KeyboardEvent('keydown', {
                      key: '\(key)', code: '\(key)', bubbles: true, cancelable: true
                    })
                  );
                  const position = window.__mdEditor._selectionForTesting().from;
                  const line = lineAt(position);
                  return { line, column: position - starts[line - 1] };
                })()
                """
            ) as? [String: Any]
            arrowCount += 1
            if moved?["line"] as? Int != expected || moved?["column"] as? Int != 4 {
                arrowFailures.append([
                    "from": line,
                    "key": key,
                    "expected": expected,
                    "actual": moved?["line"] as Any,
                    "column": moved?["column"] as Any,
                ])
            }
        }

        let finalMarkdown = await evaluate("window.__mdEditor.getMarkdown()") as? String
        #expect(clickCount >= 30, Comment(rawValue: "count=\(clickCount) failures=\(clickFailures)"))
        #expect(clickFailures.isEmpty, Comment(rawValue: String(describing: clickFailures)))
        #expect(dragSelection?["fromLine"] as? Int == 3, Comment(rawValue: String(describing: dragSelection)))
        #expect((dragSelection?["toPosition"] as? Int ?? 0) >= (dragSelection?["line4From"] as? Int ?? .max), Comment(rawValue: String(describing: dragSelection)))
        #expect((dragSelection?["toPosition"] as? Int ?? .max) <= (dragSelection?["line5From"] as? Int ?? 0), Comment(rawValue: String(describing: dragSelection)))
        #expect(arrowCount == 26)
        #expect(arrowFailures.isEmpty, Comment(rawValue: String(describing: arrowFailures)))
        #expect(widgetFailures.isEmpty, Comment(rawValue: String(describing: widgetFailures)))
        #expect(finalMarkdown == markdown)
    }
}

private extension MarkdownLocalResourceSchemeTests {
    static let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    static let jpegData = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0xff, 0xd9])
    static let gifData = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
    static let webPData = Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TA8AAAAvAAAAAAcQ/Y/+ByKi/wEA")!
    static let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"1\" height=\"1\"/></svg>".utf8)

    final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FloralMD-Markdown-Resources-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func write(_ data: Data, to relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            return url
        }

        func register(documentPath: String) throws -> RegisteredScope {
            let documentURL = try write(Data(), to: documentPath)
            let activeResource = try #require(ActiveResource(url: documentURL))
            let session = WorkspaceSession(
                rootURL: root,
                kind: .draft,
                activeResource: activeResource
            )
            let context = try #require(
                MarkdownLocalResourceContext(session: session, documentURL: documentURL)
            )
            let handler = MarkdownLocalResourceSchemeHandler()
            let baseURL = try #require(handler.register(context))
            return RegisteredScope(
                handler: handler,
                baseURL: baseURL,
                documentDirectory: documentURL.deletingLastPathComponent()
            )
        }
    }

    struct RegisteredScope {
        let handler: MarkdownLocalResourceSchemeHandler
        let baseURL: URL
        let documentDirectory: URL

        func requestURL(to fileURL: URL) throws -> URL {
            let relativePath = MarkdownImageAssetStore.percentEncodedRelativePath(
                from: documentDirectory,
                to: fileURL
            )
            return try #require(URL(string: relativePath, relativeTo: baseURL)?.absoluteURL)
        }
    }
}
