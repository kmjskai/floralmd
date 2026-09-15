import Foundation
import WebKit

struct MarkdownLocalResourceContext: Equatable, Sendable {
    let workspaceRootURL: URL
    let documentDirectoryURL: URL

    init?(session: WorkspaceSession, documentURL: URL?) {
        let root = session.rootURL.standardizedFileURL
        let directory: URL

        if let documentURL {
            guard ResourceKind.resolve(url: documentURL) == .markdown,
                  WorkspaceResolver.contains(documentURL, in: root) else {
                return nil
            }
            directory = documentURL.deletingLastPathComponent().standardizedFileURL
        } else {
            guard session.kind == .draft else { return nil }
            directory = DraftWorkspaceLayout(root: root).notesDirectory.standardizedFileURL
        }

        guard WorkspaceResolver.contains(directory, in: root) else { return nil }
        workspaceRootURL = root
        documentDirectoryURL = directory
    }
}

enum MarkdownLocalResourceError: Error, Equatable {
    case invalidRequest
    case outsideWorkspace
    case unavailable
    case symbolicLinkUnsupported
    case directoryUnsupported
    case unsupportedImageType
    case invalidImageData
}

struct MarkdownLocalResource: Equatable {
    let fileURL: URL
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

final class MarkdownLocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "floralmd-resource"

    private struct Scope {
        let rootURL: URL
        let resolvedRootURL: URL
    }

    private let lock = NSLock()
    private var scope: (identifier: String, value: Scope)?

    func register(_ context: MarkdownLocalResourceContext?) -> URL? {
        guard let context else {
            lock.withLock { scope = nil }
            return nil
        }

        let identifier = UUID().uuidString.lowercased()
        let value = Scope(
            rootURL: context.workspaceRootURL.standardizedFileURL,
            resolvedRootURL: context.workspaceRootURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
        )
        lock.withLock { scope = (identifier, value) }
        return Self.baseURL(
            scopeIdentifier: identifier,
            rootURL: value.rootURL,
            documentDirectoryURL: context.documentDirectoryURL
        )
    }

    func resolvedResource(for requestURL: URL) throws -> MarkdownLocalResource {
        let fileURL = try resolvedWorkspaceURL(for: requestURL, requiresRegularFile: true)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw MarkdownLocalResourceError.unavailable
        }

        guard let response = MarkdownImageAssetStore.validatedImageResponse(
            for: fileURL,
            data: data
        ) else {
            if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                throw MarkdownLocalResourceError.invalidImageData
            }
            throw MarkdownLocalResourceError.unsupportedImageType
        }

        return MarkdownLocalResource(
            fileURL: fileURL,
            data: data,
            mimeType: response.mimeType,
            textEncodingName: response.textEncodingName
        )
    }

    func resolvedResource(
        destination: String,
        relativeTo baseURL: URL
    ) throws -> MarkdownLocalResource {
        guard !destination.isEmpty,
              let requestURL = URL(string: destination, relativeTo: baseURL)?.absoluteURL,
              requestURL.scheme?.lowercased() == Self.scheme else {
            throw MarkdownLocalResourceError.invalidRequest
        }
        return try resolvedResource(for: requestURL)
    }

    func resolvedLinkURL(for requestURL: URL) throws -> URL {
        try resolvedWorkspaceURL(for: requestURL, requiresRegularFile: false)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        do {
            let resource = try resolvedResource(for: requestURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: resource.mimeType,
                expectedContentLength: resource.data.count,
                textEncodingName: resource.textEncodingName
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        } catch let error as MarkdownLocalResourceError {
            urlSchemeTask.didFailWithError(Self.urlError(for: error))
        } catch {
            urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func resolvedWorkspaceURL(
        for requestURL: URL,
        requiresRegularFile: Bool
    ) throws -> URL {
        guard requestURL.scheme?.lowercased() == Self.scheme,
              requestURL.user == nil,
              requestURL.password == nil,
              requestURL.port == nil,
              let identifier = requestURL.host?.lowercased(),
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              Self.hasAllowedRefreshQuery(components) else {
            throw MarkdownLocalResourceError.invalidRequest
        }

        let activeScope = lock.withLock { scope }
        guard activeScope?.identifier == identifier, let scope = activeScope?.value else {
            throw MarkdownLocalResourceError.invalidRequest
        }

        let pathComponents = try Self.decodedPathComponents(components.percentEncodedPath)
        guard !pathComponents.isEmpty else {
            throw MarkdownLocalResourceError.directoryUnsupported
        }

        var candidate = scope.rootURL
        for (index, component) in pathComponents.enumerated() {
            candidate.appendPathComponent(component, isDirectory: false)
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
            } catch {
                throw MarkdownLocalResourceError.unavailable
            }

            if values.isSymbolicLink == true {
                throw MarkdownLocalResourceError.symbolicLinkUnsupported
            }
            if index < pathComponents.count - 1, values.isDirectory != true {
                throw MarkdownLocalResourceError.unavailable
            }
        }

        candidate = candidate.standardizedFileURL
        guard WorkspaceResolver.contains(candidate, in: scope.rootURL) else {
            throw MarkdownLocalResourceError.outsideWorkspace
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard WorkspaceResolver.contains(resolvedCandidate, in: scope.resolvedRootURL) else {
            throw MarkdownLocalResourceError.outsideWorkspace
        }

        let finalValues: URLResourceValues
        do {
            finalValues = try candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
        } catch {
            throw MarkdownLocalResourceError.unavailable
        }
        if finalValues.isSymbolicLink == true {
            throw MarkdownLocalResourceError.symbolicLinkUnsupported
        }
        if finalValues.isDirectory == true {
            throw MarkdownLocalResourceError.directoryUnsupported
        }
        if requiresRegularFile, finalValues.isRegularFile != true {
            throw MarkdownLocalResourceError.unavailable
        }
        return candidate
    }

    private static func baseURL(
        scopeIdentifier: String,
        rootURL: URL,
        documentDirectoryURL: URL
    ) -> URL? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let directoryComponents = documentDirectoryURL.standardizedFileURL.pathComponents
        guard directoryComponents.starts(with: rootComponents) else { return nil }

        let relativeComponents = directoryComponents.dropFirst(rootComponents.count)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = relativeComponents.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        guard encoded.allSatisfy({ !$0.isEmpty }) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = scopeIdentifier
        components.percentEncodedPath = "/" + encoded.joined(separator: "/") + (encoded.isEmpty ? "" : "/")
        return components.url
    }

    private static func decodedPathComponents(_ percentEncodedPath: String) throws -> [String] {
        try percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map { raw in
            guard let component = String(raw).removingPercentEncoding,
                  !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/"),
                  !component.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw MarkdownLocalResourceError.invalidRequest
            }
            return component
        }
    }

    private static let supportedExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "svg"])

    private static func hasAllowedRefreshQuery(_ components: URLComponents) -> Bool {
        guard let queryItems = components.queryItems, !queryItems.isEmpty else { return true }
        guard queryItems.count == 1,
              queryItems[0].name == "__floralmd_refresh",
              let value = queryItems[0].value,
              !value.isEmpty,
              value.allSatisfy(\.isNumber) else {
            return false
        }
        return true
    }

    private static func urlError(for error: MarkdownLocalResourceError) -> URLError {
        switch error {
        case .outsideWorkspace, .symbolicLinkUnsupported:
            URLError(.noPermissionsToReadFile)
        case .unsupportedImageType:
            URLError(.unsupportedURL)
        case .invalidImageData:
            URLError(.cannotDecodeContentData)
        case .invalidRequest:
            URLError(.badURL)
        case .unavailable, .directoryUnsupported:
            URLError(.fileDoesNotExist)
        }
    }
}

enum MarkdownLocalResourceWebViewConfiguration {
    static func install(
        _ handler: MarkdownLocalResourceSchemeHandler,
        on configuration: WKWebViewConfiguration
    ) {
        configuration.setURLSchemeHandler(
            handler,
            forURLScheme: MarkdownLocalResourceSchemeHandler.scheme
        )
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
