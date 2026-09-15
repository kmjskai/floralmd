import Foundation

struct MarkdownImageAsset: Equatable, Sendable {
    let fileURL: URL
    let markdownInsertion: String
}

enum MarkdownImageAssetStoreError: LocalizedError, Equatable {
    case unsupportedMIMEType(String)
    case unsupportedFileType(String)
    case invalidImageData
    case markdownDocumentRequired
    case invalidMarkdownDocument(URL)
    case markdownDocumentOutsideWorkspace(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedMIMEType(let mimeType):
            "不支持的图片类型：\(mimeType)"
        case .unsupportedFileType(let fileExtension):
            "不支持的图片文件扩展名：\(fileExtension)"
        case .invalidImageData:
            "图片数据无效或与声明的类型不符。"
        case .markdownDocumentRequired:
            "外部工作区需要先选中一个 Markdown 文件。"
        case .invalidMarkdownDocument(let url):
            "“\(url.lastPathComponent)”不是受支持的 Markdown 文件。"
        case .markdownDocumentOutsideWorkspace(let url):
            "Markdown 文件不在当前工作区内：\(url.lastPathComponent)"
        }
    }
}

struct MarkdownImageAssetStore {
    private let fileManager: FileManager
    private let clock: () -> Date
    private let calendar: Calendar
    private let timeZone: TimeZone

    init(
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) {
        self.fileManager = fileManager
        self.clock = clock
        self.calendar = calendar
        self.timeZone = timeZone
    }

    func persist(
        data: Data,
        mimeType: String,
        suggestedName: String?,
        in session: WorkspaceSession,
        markdownDocumentURL: URL? = nil
    ) throws -> MarkdownImageAsset {
        let item = MarkdownImagePasteRequest.Item(
            data: data,
            mimeType: mimeType,
            suggestedName: suggestedName
        )
        guard let asset = try persistClipboardItems(
            [item],
            in: session,
            markdownDocumentURL: markdownDocumentURL
        ).first else {
            throw MarkdownImageAssetStoreError.invalidImageData
        }
        return asset
    }

    /// Clipboard data is named from one captured local timestamp. The whole
    /// batch validates before writing and rolls back every created destination
    /// if a later filesystem operation fails.
    func persistClipboardItems(
        _ items: [MarkdownImagePasteRequest.Item],
        in session: WorkspaceSession,
        markdownDocumentURL: URL? = nil
    ) throws -> [MarkdownImageAsset] {
        guard !items.isEmpty else { return [] }
        let validated = try items.map { item in
            let format = try ImageFormat(mimeType: item.mimeType)
            guard format.matches(item.data) else {
                throw MarkdownImageAssetStoreError.invalidImageData
            }
            return ValidatedImage(data: item.data, format: format, originalName: nil)
        }
        return try persistValidated(
            validated,
            baseName: timestampBaseName(for: clock()),
            in: session,
            markdownDocumentURL: markdownDocumentURL
        )
    }

    func persist(
        fileURL: URL,
        in session: WorkspaceSession,
        markdownDocumentURL: URL? = nil
    ) throws -> MarkdownImageAsset {
        let format = try ImageFormat(fileExtension: fileURL.pathExtension)
        let data = try Data(contentsOf: fileURL)
        guard format.matches(data) else {
            throw MarkdownImageAssetStoreError.invalidImageData
        }

        return try persistValidated(
            [ValidatedImage(
                data: data,
                format: format,
                originalName: fileURL.lastPathComponent
            )],
            baseName: Self.safeBaseName(from: fileURL.lastPathComponent),
            in: session,
            markdownDocumentURL: markdownDocumentURL
        )[0]
    }

    private func persistValidated(
        _ images: [ValidatedImage],
        baseName: String,
        in session: WorkspaceSession,
        markdownDocumentURL: URL?
    ) throws -> [MarkdownImageAsset] {
        let location = try storageLocation(
            for: session,
            markdownDocumentURL: markdownDocumentURL
        )
        try fileManager.createDirectory(
            at: location.assetsDirectory,
            withIntermediateDirectories: true
        )

        var createdURLs: [URL] = []
        var assets: [MarkdownImageAsset] = []
        var nextSuffix = 1
        do {
            for image in images {
                let temporaryURL = location.assetsDirectory
                    .appendingPathComponent(".floralmd-image-\(UUID().uuidString)")
                defer { try? fileManager.removeItem(at: temporaryURL) }
                try image.data.write(to: temporaryURL, options: .atomic)

                let destination: URL
                while true {
                    let numberedBaseName = nextSuffix == 1
                        ? baseName
                        : "\(baseName)-\(nextSuffix)"
                    nextSuffix += 1
                    let candidate = location.assetsDirectory
                        .appendingPathComponent(numberedBaseName)
                        .appendingPathExtension(image.format.outputExtension(
                            forOriginalName: image.originalName
                        ))
                    if try hasExistingBaseName(
                        numberedBaseName,
                        in: location.assetsDirectory
                    ) || fileManager.fileExists(atPath: candidate.path) {
                        continue
                    }
                    do {
                        try fileManager.moveItem(at: temporaryURL, to: candidate)
                        destination = candidate
                        break
                    } catch let error as CocoaError where error.code == .fileWriteFileExists {
                        continue
                    }
                }

                createdURLs.append(destination)
                let relativePath = Self.percentEncodedRelativePath(
                    from: location.markdownDirectory,
                    to: destination
                )
                assets.append(MarkdownImageAsset(
                    fileURL: destination.standardizedFileURL,
                    markdownInsertion: "![](\(relativePath))"
                ))
            }
        } catch {
            for url in createdURLs.reversed() {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
        NotificationCenter.default.post(name: .slateMemoWorkspaceDidChange, object: nil)
        return assets
    }

    private func hasExistingBaseName(_ baseName: String, in directory: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).contains { url in
            (url.lastPathComponent as NSString).deletingPathExtension == baseName
        }
    }

    func timestampBaseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date)
    }

    private func storageLocation(
        for session: WorkspaceSession,
        markdownDocumentURL explicitDocumentURL: URL?
    ) throws -> StorageLocation {
        switch session.kind {
        case .draft:
            let layout = DraftWorkspaceLayout(root: session.rootURL)
            let documentURL = explicitDocumentURL ?? session.activeResource.flatMap {
                $0.kind == .markdown ? $0.url : nil
            }

            if let documentURL {
                try validateMarkdownDocument(documentURL, in: session)
            }

            return StorageLocation(
                assetsDirectory: layout.markdownImagesDirectory,
                markdownDirectory: documentURL?.deletingLastPathComponent() ?? layout.notesDirectory
            )

        case .externalFolder, .explicitFolder:
            guard let documentURL = explicitDocumentURL ?? session.activeResource.flatMap({
                $0.kind == .markdown ? $0.url : nil
            }) else {
                throw MarkdownImageAssetStoreError.markdownDocumentRequired
            }
            try validateMarkdownDocument(documentURL, in: session)
            let documentDirectory = documentURL.deletingLastPathComponent()
            return StorageLocation(
                assetsDirectory: documentDirectory
                    .appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent("images", isDirectory: true),
                markdownDirectory: documentDirectory
            )
        }
    }

    private func validateMarkdownDocument(_ url: URL, in session: WorkspaceSession) throws {
        guard ResourceKind.resolve(url: url) == .markdown else {
            throw MarkdownImageAssetStoreError.invalidMarkdownDocument(url)
        }
        guard WorkspaceResolver.contains(url, in: session.rootURL) else {
            throw MarkdownImageAssetStoreError.markdownDocumentOutsideWorkspace(url)
        }
    }

    static func safeBaseName(from suggestedName: String?) -> String {
        let leafName = ((suggestedName ?? "") as NSString).lastPathComponent
        var baseName = (leafName as NSString).deletingPathExtension
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")
            .union(.controlCharacters)
        baseName = baseName.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "-" : String(scalar)
        }.joined()
        baseName = baseName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        if baseName.isEmpty || baseName == "." || baseName == ".." {
            return "image"
        }
        return String(baseName.prefix(80))
    }

    static func percentEncodedRelativePath(from baseDirectory: URL, to fileURL: URL) -> String {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < min(baseComponents.count, fileComponents.count),
              baseComponents[commonCount] == fileComponents[commonCount] {
            commonCount += 1
        }

        let parentComponents = Array(repeating: "..", count: baseComponents.count - commonCount)
        let targetComponents = Array(fileComponents.dropFirst(commonCount))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return (parentComponents + targetComponents)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
    }

    static func validatedImageResponse(
        for fileURL: URL,
        data: Data
    ) -> (mimeType: String, textEncodingName: String?)? {
        guard let format = try? ImageFormat(fileExtension: fileURL.pathExtension),
              format.matches(data) else {
            return nil
        }

        switch format {
        case .png:
            return ("image/png", nil)
        case .jpeg:
            return ("image/jpeg", nil)
        case .gif:
            return ("image/gif", nil)
        case .webP:
            return ("image/webp", nil)
        case .svg:
            return ("image/svg+xml", "utf-8")
        }
    }
}

private extension MarkdownImageAssetStore {
    struct ValidatedImage {
        let data: Data
        let format: ImageFormat
        let originalName: String?
    }

    struct StorageLocation {
        let assetsDirectory: URL
        let markdownDirectory: URL
    }

    enum ImageFormat {
        case png
        case jpeg
        case gif
        case webP
        case svg

        init(mimeType: String) throws {
            let normalized = mimeType
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            switch normalized {
            case "image/png": self = .png
            case "image/jpeg", "image/jpg": self = .jpeg
            case "image/gif": self = .gif
            case "image/webp": self = .webP
            case "image/svg+xml": self = .svg
            default: throw MarkdownImageAssetStoreError.unsupportedMIMEType(mimeType)
            }
        }

        init(fileExtension: String) throws {
            switch fileExtension.lowercased() {
            case "png": self = .png
            case "jpg", "jpeg": self = .jpeg
            case "gif": self = .gif
            case "webp": self = .webP
            case "svg": self = .svg
            default: throw MarkdownImageAssetStoreError.unsupportedFileType(fileExtension)
            }
        }

        func outputExtension(forOriginalName originalName: String?) -> String {
            switch self {
            case .png: "png"
            case .jpeg:
                (originalName as NSString?)?.pathExtension.lowercased() == "jpeg" ? "jpeg" : "jpg"
            case .gif: "gif"
            case .webP: "webp"
            case .svg: "svg"
            }
        }

        func matches(_ data: Data) -> Bool {
            switch self {
            case .png:
                return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            case .jpeg:
                return data.count >= 5
                    && data.starts(with: [0xff, 0xd8, 0xff])
                    && data.suffix(2).elementsEqual([0xff, 0xd9])
            case .gif:
                guard data.count >= 13,
                      data.starts(with: Data("GIF87a".utf8))
                        || data.starts(with: Data("GIF89a".utf8)) else {
                    return false
                }
                let width = UInt16(data[6]) | (UInt16(data[7]) << 8)
                let height = UInt16(data[8]) | (UInt16(data[9]) << 8)
                return width > 0 && height > 0
            case .webP:
                return data.count >= 16
                    && data.prefix(4).elementsEqual(Data("RIFF".utf8))
                    && data.dropFirst(8).prefix(4).elementsEqual(Data("WEBP".utf8))
                    && ["VP8 ", "VP8L", "VP8X"].contains(
                        String(decoding: data.dropFirst(12).prefix(4), as: UTF8.self)
                    )
            case .svg:
                return SVGRootValidator.hasSVGRoot(in: data)
            }
        }
    }
}

private final class SVGRootValidator: NSObject, XMLParserDelegate {
    private var rootElementName: String?

    static func hasSVGRoot(in data: Data) -> Bool {
        let validator = SVGRootValidator()
        let parser = XMLParser(data: data)
        parser.delegate = validator
        parser.shouldResolveExternalEntities = false
        return parser.parse() && validator.rootElementName?.lowercased() == "svg"
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if rootElementName == nil {
            rootElementName = elementName
        }
    }
}
