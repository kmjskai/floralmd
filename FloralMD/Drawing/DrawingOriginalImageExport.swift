import Foundation

struct DrawingOriginalImageRequest: Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case invalidEnvelope
        case invalidFileID
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidEnvelope: "图片导出请求不完整。"
            case .invalidFileID: "图片元素没有有效的文件标识。"
            case .invalidImage: "原始图片数据无效，无法导出。"
            }
        }
    }

    let fileID: String
    let mimeType: String
    let dataURL: String
    let clientX: Double
    let clientY: Double
    let binary: DrawingBinaryFileData

    init(messageJSON: String) throws {
        struct Envelope: Decodable {
            let fileId: String
            let mimeType: String
            let dataURL: String
            let clientX: Double
            let clientY: Double
        }

        guard let data = messageJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { throw ValidationError.invalidEnvelope }
        let fileID = envelope.fileId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty else { throw ValidationError.invalidFileID }
        let file = DrawingFilePayload(
            id: fileID,
            mimeType: envelope.mimeType,
            dataURL: envelope.dataURL,
            created: nil,
            lastRetrieved: nil
        )
        guard let binary = try? DrawingBinaryFileData(file: file) else {
            throw ValidationError.invalidImage
        }
        self.fileID = fileID
        self.mimeType = envelope.mimeType
        self.dataURL = envelope.dataURL
        self.clientX = envelope.clientX
        self.clientY = envelope.clientY
        self.binary = binary
    }
}

enum DrawingOriginalImageExporter {
    static func defaultFileName(drawingName: String, request: DrawingOriginalImageRequest) -> String {
        let drawing = DrawingNamePolicy.normalizedStem(drawingName)
        let prefix = request.fileID.filter { $0.isLetter || $0.isNumber }.prefix(8)
        let stableID = prefix.isEmpty ? "image" : String(prefix)
        return "\(drawing)--\(stableID).\(request.binary.fileExtension)"
    }

    @discardableResult
    static func export(
        _ request: DrawingOriginalImageRequest,
        drawingName: String,
        chooseDestination: (_ defaultFileName: String, _ fileExtension: String) -> URL?
    ) throws -> URL? {
        let fileName = defaultFileName(drawingName: drawingName, request: request)
        guard let destination = chooseDestination(fileName, request.binary.fileExtension) else {
            return nil
        }
        try request.binary.data.write(to: destination, options: .atomic)
        return destination
    }
}
