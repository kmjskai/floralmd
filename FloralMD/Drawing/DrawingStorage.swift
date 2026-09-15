import AppKit
import Foundation
import UniformTypeIdentifiers

struct DrawingFilePayload: Codable, Equatable, Sendable {
    let id: String
    let mimeType: String
    let dataURL: String
    let created: Double?
    let lastRetrieved: Double?
}

struct DrawingExportPayload: Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case invalidEnvelope
        case invalidSVG
        case externalSVGImage(String)
        case invalidImage(String)
        case sceneFilesMismatch

        var errorDescription: String? {
            switch self {
            case .invalidEnvelope:
                return "绘图导出数据不完整。"
            case .invalidSVG:
                return "Excalidraw 没有生成有效的 SVG。"
            case .externalSVGImage(let reference):
                return "SVG 包含未嵌入的图片引用：\(reference)"
            case .invalidImage(let identifier):
                return "图片 \(identifier) 的数据无法解码。"
            case .sceneFilesMismatch:
                return "绘图源文件没有自包含完整的图片数据。"
            }
        }
    }

    let scene: DrawingScene
    let svg: String?
    let files: [String: DrawingFilePayload]

    init(messageJSON: String, requiresSVG: Bool = true) throws {
        struct Envelope: Decodable {
            let sceneJSON: String
            let svg: String?
            let files: [String: DrawingFilePayload]
        }

        guard let data = messageJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { throw ValidationError.invalidEnvelope }
        if requiresSVG, envelope.svg == nil {
            throw ValidationError.invalidSVG
        }
        try self.init(
            scene: DrawingScene(json: envelope.sceneJSON),
            svg: requiresSVG ? envelope.svg : nil,
            files: envelope.files
        )
    }

    init(scene: DrawingScene, svg: String?, files: [String: DrawingFilePayload]) throws {
        if let svg { try DrawingSVGValidator.validate(svg) }
        for (identifier, file) in files {
            guard file.id == identifier,
                  (try? DrawingBinaryFileData(file: file)) != nil
            else { throw ValidationError.invalidImage(identifier) }
        }
        let requirements = try Self.sceneFileRequirements(in: scene)
        for identifier in requirements.referencedFileIDs {
            guard let sceneFile = requirements.files[identifier],
                  let file = files[identifier],
                  sceneFile.id == identifier,
                  sceneFile.mimeType == file.mimeType,
                  sceneFile.dataURL == file.dataURL
            else { throw ValidationError.sceneFilesMismatch }
        }
        self.scene = scene
        self.svg = svg
        self.files = files
    }

    static func validateScene(_ scene: DrawingScene) throws {
        _ = try sceneFileRequirements(in: scene)
    }

    private static func sceneFileRequirements(
        in scene: DrawingScene
    ) throws -> (files: [String: DrawingFilePayload], referencedFileIDs: Set<String>) {
        guard let data = scene.json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = object["elements"] as? [[String: Any]]
        else { throw ValidationError.sceneFilesMismatch }

        let filesObject: [String: Any]
        if let value = object["files"] {
            guard let decodedFiles = value as? [String: Any] else {
                throw ValidationError.sceneFilesMismatch
            }
            filesObject = decodedFiles
        } else {
            filesObject = [:]
        }
        guard JSONSerialization.isValidJSONObject(filesObject) else {
            throw ValidationError.sceneFilesMismatch
        }
        let filesData = try JSONSerialization.data(withJSONObject: filesObject)
        guard let sceneFiles = try? JSONDecoder().decode(
            [String: DrawingFilePayload].self,
            from: filesData
        ) else { throw ValidationError.sceneFilesMismatch }

        for (identifier, sceneFile) in sceneFiles {
            guard sceneFile.id == identifier,
                  (try? DrawingBinaryFileData(file: sceneFile)) != nil
            else { throw ValidationError.sceneFilesMismatch }
        }

        var referencedFileIDs = Set<String>()
        for element in elements where element["type"] as? String == "image"
            && (element["isDeleted"] as? Bool) != true {
            guard let fileID = element["fileId"] as? String,
                  !fileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sceneFiles[fileID] != nil
            else { throw ValidationError.sceneFilesMismatch }
            referencedFileIDs.insert(fileID)
        }

        return (sceneFiles, referencedFileIDs)
    }
}

enum DrawingSVGValidator {
    static func validate(_ svg: String) throws {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<svg"), trimmed.contains("</svg>") else {
            throw DrawingExportPayload.ValidationError.invalidSVG
        }

        let expression = try NSRegularExpression(
            pattern: #"<image\b[^>]*?(?:href|xlink:href)\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in expression.matches(in: trimmed, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let value = String(trimmed[valueRange])
            guard value.hasPrefix("data:") || value.hasPrefix("#") else {
                throw DrawingExportPayload.ValidationError.externalSVGImage(value)
            }
        }
    }
}

struct DrawingStorageLayout: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case draft
        case externalFolder
    }

    let root: URL
    let scope: Scope
    private let sourceDirectory: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        scope = .draft
        sourceDirectory = DraftWorkspaceLayout(root: root).drawingsDirectory.standardizedFileURL
    }

    static func external(root: URL) -> DrawingStorageLayout {
        DrawingStorageLayout(
            root: root.standardizedFileURL,
            scope: .externalFolder,
            sourceDirectory: root.standardizedFileURL
        )
    }

    static func forSource(_ sourceURL: URL, configuredDraftRoot: URL?) -> DrawingStorageLayout {
        let sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        if let configuredDraftRoot {
            let draftRoot = configuredDraftRoot.standardizedFileURL
            let resolvedDraftRoot = resolvedPathForContainment(draftRoot)
            let resolvedSourceDirectory = resolvedPathForContainment(sourceDirectory)
            if WorkspaceResolver.contains(sourceDirectory, in: draftRoot),
               WorkspaceResolver.contains(resolvedSourceDirectory, in: resolvedDraftRoot) {
                return DrawingStorageLayout(
                    root: draftRoot,
                    scope: .draft,
                    sourceDirectory: sourceDirectory
                )
            }
        }
        return .external(root: sourceDirectory)
    }

    private static func resolvedPathForContainment(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> URL {
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existing.path),
              existing.pathComponents.count > 1 {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missingComponents.reduce(
            existing.resolvingSymlinksInPath().standardizedFileURL
        ) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
    }

    private init(root: URL, scope: Scope, sourceDirectory: URL) {
        self.root = root
        self.scope = scope
        self.sourceDirectory = sourceDirectory
    }

    var excalidrawDirectory: URL {
        sourceDirectory
    }

    var svgDirectory: URL {
        excalidrawDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    var readableSourceDirectories: [URL] {
        [excalidrawDirectory]
    }

    func containsReadableSource(_ sourceURL: URL) -> Bool {
        readableSourceDirectories.contains(sourceURL.deletingLastPathComponent().standardizedFileURL)
    }

    func svgURL(for sourceURL: URL) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(stem).svg")
    }

}

enum DrawingLayoutSelection {
    static func resolve(
        embedded: Bool,
        current: DrawingStorageLayout?,
        configured: DrawingStorageLayout?
    ) -> DrawingStorageLayout? {
        if embedded, let current { return current }
        return configured
    }
}

struct DrawingDocumentIdentity: Equatable, Sendable {
    let name: String
    let sourceURL: URL
    let svgURL: URL
}

struct DrawingContentFingerprint: Equatable, Sendable {
    let data: Data

    init(scene: DrawingScene) throws {
        guard let source = scene.json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: source) as? [String: Any],
              let elements = object["elements"] as? [Any],
              let appState = object["appState"] as? [String: Any]
        else { throw DrawingScene.ValidationError.missingSceneData }
        let files = object["files"] as? [String: Any] ?? [:]

        var content: [String: Any] = [
            "elements": elements,
            "files": files
        ]
        if let viewBackgroundColor = appState["viewBackgroundColor"] {
            content["viewBackgroundColor"] = viewBackgroundColor
        }
        data = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
    }
}

struct DrawingWorkspaceSession: Equatable, Sendable {
    private(set) var document: DrawingDocumentIdentity?
    private(set) var baseline: DrawingContentFingerprint?

    mutating func markOpened(_ opened: OpenedDrawing) throws {
        document = opened.identity
        baseline = try DrawingContentFingerprint(scene: opened.scene)
    }

    mutating func markSaved(
        _ identity: DrawingDocumentIdentity,
        payload: DrawingExportPayload
    ) throws {
        document = identity
        baseline = try DrawingContentFingerprint(scene: payload.scene)
    }

    mutating func beginNewDrawing() {
        document = nil
        baseline = nil
    }

    mutating func establishBaseline(from payload: DrawingExportPayload) throws {
        baseline = try DrawingContentFingerprint(scene: payload.scene)
    }

    func hasUnsavedChanges(in payload: DrawingExportPayload) throws -> Bool {
        guard let baseline else { return true }
        return try DrawingContentFingerprint(scene: payload.scene) != baseline
    }

    func isCurrent(_ entry: DrawingFileEntry) -> Bool {
        document?.sourceURL.standardizedFileURL == entry.sourceURL.standardizedFileURL
    }
}

struct DrawingFileEntry: Identifiable, Equatable, Sendable {
    let sourceURL: URL

    var id: URL { sourceURL.standardizedFileURL }
    var name: String { sourceURL.deletingPathExtension().lastPathComponent }
}

struct DrawingFileCatalog: Sendable {
    let layout: DrawingStorageLayout

    func entries(fileManager: FileManager = .default) throws -> [DrawingFileEntry] {
        let entries = try layout.readableSourceDirectories.flatMap { directory -> [DrawingFileEntry] in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return [] }

            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .compactMap { url in
                guard url.pathExtension.lowercased() == "excalidraw" else { return nil }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values.isDirectory != true, values.isRegularFile != false else { return nil }
                return DrawingFileEntry(sourceURL: url)
            }
        }

        return entries
        .sorted { lhs, rhs in
            let comparison = lhs.name.compare(
                rhs.name,
                options: [.caseInsensitive, .numeric, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if comparison == .orderedSame {
                return lhs.sourceURL.lastPathComponent < rhs.sourceURL.lastPathComponent
            }
            return comparison == .orderedAscending
        }
    }
}

struct OpenedDrawing: Equatable, Sendable {
    let identity: DrawingDocumentIdentity
    let scene: DrawingScene
}

enum DrawingWorkspaceOpenPath {
    static func open(_ entry: DrawingFileEntry, in layout: DrawingStorageLayout) throws -> OpenedDrawing {
        try DrawingStore(layout: layout).open(entry.sourceURL)
    }
}

enum DrawingNamePolicy {
    static func normalizedStem(_ proposedName: String) -> String {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".excalidraw") {
            name.removeLast(".excalidraw".count)
        }
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        name = name.components(separatedBy: forbidden).joined(separator: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "未命名绘图" }
        return String(name.prefix(120))
    }

    static func availableStem(
        proposedName: String,
        layout: DrawingStorageLayout,
        reservingSVG: Bool = true,
        fileManager: FileManager = .default
    ) -> String {
        let base = normalizedStem(proposedName)
        var candidate = base
        var suffix = 2
        while fileManager.fileExists(
            atPath: layout.excalidrawDirectory.appendingPathComponent("\(candidate).excalidraw").path
        ) || (reservingSVG && fileManager.fileExists(
            atPath: layout.svgDirectory.appendingPathComponent("\(candidate).svg").path
        )) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}

struct DrawingStore: Sendable {
    enum StoreError: LocalizedError, Equatable {
        case invalidLocation
        case invalidSourceEncoding

        var errorDescription: String? {
            switch self {
            case .invalidLocation:
                return "只能在当前工作区的绘图源目录中打开或保存绘图。"
            case .invalidSourceEncoding:
                return "绘图源文件无法编码为 UTF-8。"
            }
        }
    }

    let layout: DrawingStorageLayout

    func save(
        _ payload: DrawingExportPayload,
        proposedName: String,
        replacing existing: DrawingDocumentIdentity? = nil,
        syncSVG: Bool = true
    ) throws -> DrawingDocumentIdentity {
        let fileManager = FileManager.default
        let identity: DrawingDocumentIdentity
        if let existing {
            guard layout.containsReadableSource(existing.sourceURL),
                  existing.svgURL.standardizedFileURL
                    == layout.svgURL(for: existing.sourceURL).standardizedFileURL
            else { throw StoreError.invalidLocation }
            identity = existing
        } else {
            let stem = DrawingNamePolicy.availableStem(
                proposedName: proposedName,
                layout: layout,
                reservingSVG: syncSVG,
                fileManager: fileManager
            )
            identity = DrawingDocumentIdentity(
                name: stem,
                sourceURL: layout.excalidrawDirectory.appendingPathComponent("\(stem).excalidraw"),
                svgURL: layout.svgDirectory.appendingPathComponent("\(stem).svg")
            )
        }

        guard let sceneData = payload.scene.json.data(using: .utf8) else {
            throw StoreError.invalidSourceEncoding
        }
        let svgData: Data?
        if syncSVG {
            guard let svg = payload.svg,
                  let encodedSVG = svg.data(using: .utf8) else {
                throw DrawingExportPayload.ValidationError.invalidSVG
            }
            svgData = encodedSVG
        } else {
            svgData = nil
        }

        let staging = layout.root.appendingPathComponent(".floralmd-drawing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let stagedSource = staging.appendingPathComponent("source.excalidraw")
        let stagedSVG = staging.appendingPathComponent("drawing.svg")
        try sceneData.write(to: stagedSource)
        if let svgData { try svgData.write(to: stagedSVG) }

        let backupSource = staging.appendingPathComponent("previous.excalidraw")
        let backupSVG = staging.appendingPathComponent("previous.svg")
        let hadSource = fileManager.fileExists(atPath: identity.sourceURL.path)
        let hadSVG = syncSVG && fileManager.fileExists(atPath: identity.svgURL.path)
        var installedSource = false
        let sourceDirectory = identity.sourceURL.deletingLastPathComponent()
        let svgDirectory = identity.svgURL.deletingLastPathComponent()
        let createdSVGDirectory = syncSVG && !fileManager.fileExists(atPath: svgDirectory.path)

        do {
            try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            if syncSVG {
                try fileManager.createDirectory(at: svgDirectory, withIntermediateDirectories: true)
            }
            if existing == nil, hadSource || hadSVG {
                throw CocoaError(.fileWriteFileExists)
            }
            if hadSource { try fileManager.moveItem(at: identity.sourceURL, to: backupSource) }
            if hadSVG { try fileManager.moveItem(at: identity.svgURL, to: backupSVG) }
            try fileManager.moveItem(at: stagedSource, to: identity.sourceURL)
            installedSource = true
            if syncSVG { try fileManager.moveItem(at: stagedSVG, to: identity.svgURL) }
        } catch {
            if installedSource { try? fileManager.removeItem(at: identity.sourceURL) }
            if hadSource { try? fileManager.moveItem(at: backupSource, to: identity.sourceURL) }
            if hadSVG { try? fileManager.moveItem(at: backupSVG, to: identity.svgURL) }
            if createdSVGDirectory,
               (try? fileManager.contentsOfDirectory(atPath: svgDirectory.path).isEmpty) == true {
                try? fileManager.removeItem(at: svgDirectory)
            }
            throw error
        }

        return identity
    }

    static func exportSVG(_ payload: DrawingExportPayload, to destinationURL: URL) throws {
        guard let svg = payload.svg,
              let data = svg.data(using: .utf8) else {
            throw DrawingExportPayload.ValidationError.invalidSVG
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    func open(_ sourceURL: URL) throws -> OpenedDrawing {
        guard layout.containsReadableSource(sourceURL),
              sourceURL.pathExtension.lowercased() == "excalidraw"
        else { throw StoreError.invalidLocation }
        let json = try String(contentsOf: sourceURL, encoding: .utf8)
        let scene = try DrawingScene(json: json)
        try DrawingExportPayload.validateScene(scene)
        let name = sourceURL.deletingPathExtension().lastPathComponent
        return OpenedDrawing(
            identity: DrawingDocumentIdentity(
                name: name,
                sourceURL: sourceURL,
                svgURL: layout.svgURL(for: sourceURL)
            ),
            scene: scene
        )
    }
}

struct DrawingBinaryFileData: Equatable, Sendable {
    let data: Data
    let fileExtension: String

    init(file: DrawingFilePayload) throws {
        guard file.dataURL.hasPrefix("data:"),
              let comma = file.dataURL.firstIndex(of: ",")
        else { throw DrawingExportPayload.ValidationError.invalidImage(file.id) }
        let header = String(file.dataURL[file.dataURL.index(file.dataURL.startIndex, offsetBy: 5)..<comma])
        let encoded = String(file.dataURL[file.dataURL.index(after: comma)...])
        if header.lowercased().contains(";base64") {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw DrawingExportPayload.ValidationError.invalidImage(file.id)
            }
            data = decoded
        } else {
            guard let decoded = encoded.removingPercentEncoding?.data(using: .utf8) else {
                throw DrawingExportPayload.ValidationError.invalidImage(file.id)
            }
            data = decoded
        }
        guard !data.isEmpty else { throw DrawingExportPayload.ValidationError.invalidImage(file.id) }

        let mime = header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? file.mimeType
        guard mime.caseInsensitiveCompare(file.mimeType) == .orderedSame else {
            throw DrawingExportPayload.ValidationError.invalidImage(file.id)
        }
        switch mime.lowercased() {
        case "image/png": fileExtension = "png"
        case "image/jpeg": fileExtension = "jpg"
        case "image/gif": fileExtension = "gif"
        case "image/webp": fileExtension = "webp"
        case "image/bmp": fileExtension = "bmp"
        case "image/x-icon": fileExtension = "ico"
        case "image/svg+xml": fileExtension = "svg"
        case "image/avif": fileExtension = "avif"
        case "image/jfif": fileExtension = "jfif"
        default: throw DrawingExportPayload.ValidationError.invalidImage(file.id)
        }
    }
}

@MainActor
final class DrawingStorageService {
    static let shared = DrawingStorageService()

    func configuredLayout(promptingIfNeeded: Bool) throws -> DrawingStorageLayout? {
        guard let root = try QuickCaptureService.shared.defaultDocumentFolder(
            promptingIfNeeded: promptingIfNeeded
        ) else { return nil }
        return DrawingStorageLayout(root: root)
    }

    func chooseDrawingToOpen() throws -> (DrawingStorageLayout, URL)? {
        guard let layout = try configuredLayout(promptingIfNeeded: true) else { return nil }
        try FileManager.default.createDirectory(
            at: layout.excalidrawDirectory,
            withIntermediateDirectories: true
        )

        let panel = NSOpenPanel()
        panel.title = "打开 Excalidraw 绘图"
        panel.message = "选择 Draft 工作区 drawings 目录中的绘图源文件。"
        panel.prompt = "打开"
        panel.directoryURL = layout.excalidrawDirectory
        panel.allowedContentTypes = [.init(filenameExtension: "excalidraw")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (layout, url)
    }
}
