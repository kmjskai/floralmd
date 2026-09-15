import Foundation

struct DrawingScene: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case invalidUTF8
        case invalidJSON
        case unsupportedType
        case missingSceneData
    }

    let json: String
    let elementCount: Int

    init(json: String) throws {
        guard let data = json.data(using: .utf8) else { throw ValidationError.invalidUTF8 }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { throw ValidationError.invalidJSON }
        guard dictionary["type"] as? String == "excalidraw" else {
            throw ValidationError.unsupportedType
        }
        guard let elements = dictionary["elements"] as? [[String: Any]],
              dictionary["appState"] is [String: Any],
              dictionary["files"] == nil || dictionary["files"] is [String: Any]
        else { throw ValidationError.missingSceneData }

        self.json = json
        elementCount = elements.filter { ($0["isDeleted"] as? Bool) != true }.count
    }
}
