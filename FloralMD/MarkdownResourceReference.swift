import Foundation

struct MarkdownResourceReference: Equatable, Sendable {
    let sourceURL: URL
    let referencedURL: URL
    let markdown: String
}

enum MarkdownResourceReferenceError: LocalizedError, Equatable {
    case markdownDocumentRequired
    case invalidMarkdownDocument(URL)
    case resourceOutsideWorkspace(URL)
    case resourceUnavailable(URL)
    case directoryUnsupported(URL)
    case symbolicLinkUnsupported(URL)
    case unsupportedResource(URL)
    case drawingExportMissing(URL)
    case drawingExportOutdated(URL)

    var errorDescription: String? {
        switch self {
        case .markdownDocumentRequired:
            "请先在当前工作区选择或新建 Markdown 文件。"
        case .invalidMarkdownDocument(let url):
            "“\(url.lastPathComponent)”不是可编辑的 Markdown 文件。"
        case .resourceOutsideWorkspace(let url):
            "“\(url.lastPathComponent)”不在当前已授权工作区内，无法插入引用。"
        case .resourceUnavailable(let url):
            "找不到“\(url.lastPathComponent)”，请刷新侧边栏后重试。"
        case .directoryUnsupported(let url):
            "暂不支持引用文件夹“\(url.lastPathComponent)”。"
        case .symbolicLinkUnsupported(let url):
            "为避免越过工作区权限边界，暂不支持引用符号链接“\(url.lastPathComponent)”。"
        case .unsupportedResource(let url):
            "暂不支持把“\(url.lastPathComponent)”插入 Markdown。"
        case .drawingExportMissing(let url):
            "“\(url.lastPathComponent)”还没有可引用的 SVG。请先保存绘图并启用对应的 SVG 自动同步，或先手动导出到该绘图的标准 SVG 位置。"
        case .drawingExportOutdated(let url):
            "“\(url.lastPathComponent)”早于绘图源，不能保证内容最新。请打开并保存绘图，或重新导出到标准 SVG 位置后再插入。"
        }
    }
}

struct MarkdownResourceReferenceResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func markdownInsertion(
        for sourceURLs: [URL],
        in session: WorkspaceSession,
        markdownDocumentURL: URL? = nil
    ) throws -> String {
        try sourceURLs.map { sourceURL in
            try resolve(
                sourceURL: sourceURL,
                in: session,
                markdownDocumentURL: markdownDocumentURL
            ).markdown
        }.joined(separator: "\n")
    }

    func resolve(
        sourceURL: URL,
        in session: WorkspaceSession,
        markdownDocumentURL: URL? = nil
    ) throws -> MarkdownResourceReference {
        let source = sourceURL.standardizedFileURL
        let markdownDirectory = try markdownDirectory(
            in: session,
            explicitDocumentURL: markdownDocumentURL
        )
        try validateSource(source, in: session)

        guard let kind = ResourceKind.resolve(url: source) else {
            throw MarkdownResourceReferenceError.unsupportedResource(source)
        }

        switch kind {
        case .image:
            return reference(
                source: source,
                target: source,
                label: source.lastPathComponent,
                image: true,
                markdownDirectory: markdownDirectory
            )
        case .markdown:
            return reference(
                source: source,
                target: source,
                label: stableMarkdownTitle(at: source)
                    ?? source.deletingPathExtension().lastPathComponent,
                image: false,
                markdownDirectory: markdownDirectory
            )
        case .drawing:
            let exportURL = drawingExportURL(for: source, in: session)
            guard fileManager.fileExists(atPath: exportURL.path) else {
                throw MarkdownResourceReferenceError.drawingExportMissing(exportURL)
            }
            let sourceDate = try modificationDate(of: source)
            let exportDate = try modificationDate(of: exportURL)
            guard exportDate >= sourceDate else {
                throw MarkdownResourceReferenceError.drawingExportOutdated(exportURL)
            }
            return reference(
                source: source,
                target: exportURL,
                label: source.deletingPathExtension().lastPathComponent,
                image: true,
                markdownDirectory: markdownDirectory
            )
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        do {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let date = values.contentModificationDate else {
                throw MarkdownResourceReferenceError.resourceUnavailable(url)
            }
            return date
        } catch let error as MarkdownResourceReferenceError {
            throw error
        } catch {
            throw MarkdownResourceReferenceError.resourceUnavailable(url)
        }
    }

    private func markdownDirectory(
        in session: WorkspaceSession,
        explicitDocumentURL: URL?
    ) throws -> URL {
        if let documentURL = explicitDocumentURL ?? session.activeResource.flatMap({
            $0.kind == .markdown ? $0.url : nil
        }) {
            let document = documentURL.standardizedFileURL
            guard ResourceKind.resolve(url: document) == .markdown else {
                throw MarkdownResourceReferenceError.invalidMarkdownDocument(document)
            }
            guard WorkspaceResolver.contains(document, in: session.rootURL) else {
                throw MarkdownResourceReferenceError.resourceOutsideWorkspace(document)
            }
            return document.deletingLastPathComponent()
        }

        guard session.kind == .draft else {
            throw MarkdownResourceReferenceError.markdownDocumentRequired
        }
        return DraftWorkspaceLayout(root: session.rootURL).notesDirectory
    }

    private func validateSource(_ source: URL, in session: WorkspaceSession) throws {
        guard WorkspaceResolver.contains(source, in: session.rootURL) else {
            throw MarkdownResourceReferenceError.resourceOutsideWorkspace(source)
        }

        let resolvedRoot = session.rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard WorkspaceResolver.contains(resolvedSource, in: resolvedRoot) else {
            throw MarkdownResourceReferenceError.resourceOutsideWorkspace(source)
        }

        do {
            let values = try source.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                throw MarkdownResourceReferenceError.symbolicLinkUnsupported(source)
            }
            if values.isDirectory == true {
                throw MarkdownResourceReferenceError.directoryUnsupported(source)
            }
            guard values.isRegularFile == true else {
                throw MarkdownResourceReferenceError.resourceUnavailable(source)
            }
        } catch let error as MarkdownResourceReferenceError {
            throw error
        } catch {
            throw MarkdownResourceReferenceError.resourceUnavailable(source)
        }
    }

    private func drawingExportURL(for source: URL, in session: WorkspaceSession) -> URL {
        switch session.kind {
        case .draft:
            DrawingStorageLayout(root: session.rootURL).svgURL(for: source)
        case .externalFolder, .explicitFolder:
            DrawingStorageLayout.external(root: source.deletingLastPathComponent())
                .svgURL(for: source)
        }
    }

    private func reference(
        source: URL,
        target: URL,
        label: String,
        image: Bool,
        markdownDirectory: URL
    ) -> MarkdownResourceReference {
        let path = MarkdownImageAssetStore.percentEncodedRelativePath(
            from: markdownDirectory,
            to: target
        )
        let escapedLabel = Self.escapeLabel(label)
        let markdown = image
            ? "![\(escapedLabel)](\(path))"
            : "[\(escapedLabel)](\(path))"
        return MarkdownResourceReference(
            sourceURL: source,
            referencedURL: target.standardizedFileURL,
            markdown: markdown
        )
    }

    private func stableMarkdownTitle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let markdown = String(data: data, encoding: .utf8) else { return nil }

        let frontmatter = MarkdownFrontmatter.split(markdown)
        if let raw = frontmatter.raw,
           let title = MarkdownFrontmatter.parse(raw)
            .first(where: { $0.key.caseInsensitiveCompare("title") == .orderedSame })?
            .value,
           let normalizedTitle = Self.normalizedLabel(title) {
            return normalizedTitle
        }

        return MarkdownOutline.headings(in: markdown)
            .first
            .flatMap { Self.normalizedLabel($0.title) }
    }

    static func escapeLabel(_ value: String) -> String {
        let normalized = normalizedLabel(value) ?? "Resource"
        return normalized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func normalizedLabel(_ value: String) -> String? {
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
