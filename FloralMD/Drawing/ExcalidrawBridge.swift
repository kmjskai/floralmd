import Foundation
import WebKit

@MainActor
final class ExcalidrawBridge: NSObject, WKScriptMessageHandler {
    static let readyMessage = "drawingReady"
    static let closeMessage = "drawingClose"
    static let completeMessage = "drawingComplete"
    static let loadedMessage = "drawingLoaded"
    static let loadCompletedMessage = "drawingLoadCompleted"
    static let errorMessage = "drawingError"
    static let imageContextMessage = "drawingImageContext"
    static let messageNames = [
        readyMessage,
        closeMessage,
        completeMessage,
        loadedMessage,
        loadCompletedMessage,
        errorMessage,
        imageContextMessage
    ]

    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var onComplete: ((Result<DrawingExportPayload, Error>) -> Void)?
    var onLoaded: (() -> Void)?
    var onLoadCompleted: ((UUID) -> Void)?
    var onError: ((Error) -> Void)?
    var onImageContext: ((Result<DrawingOriginalImageRequest, Error>) -> Void)?
    private var pendingCompletionRequirements: [Bool] = []

    func expectCompletion(requiresSVG: Bool) {
        pendingCompletionRequirements.append(requiresSVG)
    }

    func cancelExpectedCompletion() {
        guard !pendingCompletionRequirements.isEmpty else { return }
        pendingCompletionRequirements.removeLast()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case Self.readyMessage:
            onReady?()
        case Self.closeMessage:
            onClose?()
        case Self.completeMessage:
            guard let json = message.body as? String else {
                onComplete?(.failure(DrawingExportPayload.ValidationError.invalidEnvelope))
                return
            }
            do {
                let requiresSVG = pendingCompletionRequirements.isEmpty
                    ? true
                    : pendingCompletionRequirements.removeFirst()
                onComplete?(.success(try DrawingExportPayload(
                    messageJSON: json,
                    requiresSVG: requiresSVG
                )))
            } catch {
                onComplete?(.failure(error))
            }
        case Self.loadedMessage:
            onLoaded?()
        case Self.loadCompletedMessage:
            guard let value = message.body as? String,
                  let requestID = UUID(uuidString: value) else { return }
            onLoadCompleted?(requestID)
        case Self.errorMessage:
            let description = message.body as? String ?? "绘图页面发生未知错误。"
            onError?(NSError(
                domain: "FloralMD.Drawing",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: description]
            ))
        case Self.imageContextMessage:
            guard let json = message.body as? String else {
                onImageContext?(.failure(DrawingOriginalImageRequest.ValidationError.invalidEnvelope))
                return
            }
            do {
                onImageContext?(.success(try DrawingOriginalImageRequest(messageJSON: json)))
            } catch {
                onImageContext?(.failure(error))
            }
        default:
            break
        }
    }
}
