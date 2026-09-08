import Foundation

enum MarkdownLinkNavigation: Equatable {
    case fragment(String)
    case markdown(URL, fragment: String?)
    case external(URL)
    case unchanged
}

enum MarkdownLinkNavigationError: LocalizedError, Equatable {
    case documentRequired
    case unsupportedScheme(String)
    case unsupportedResource(URL)
    case authorizationCancelled(URL)
    case unavailable(URL)
    case directory(URL)
    case symbolicLink(URL)

    var errorDescription: String? {
        switch self {
        case .documentRequired:
            "当前文档尚不能解析相对链接。"
        case .unsupportedScheme(let scheme):
            "不支持打开“\(scheme)”链接。"
        case .unsupportedResource(let url):
            "不支持打开“\(url.lastPathComponent)”。"
        case .authorizationCancelled(let url):
            "未授权访问“\(url.lastPathComponent)”。"
        case .unavailable(let url):
            "找不到“\(url.lastPathComponent)”。"
        case .directory(let url):
            "“\(url.lastPathComponent)”是文件夹，不能作为 Markdown 文档打开。"
        case .symbolicLink(let url):
            "不能通过符号链接打开“\(url.lastPathComponent)”。"
        }
    }
}

struct MarkdownLinkNavigationResolver {
    private static let markdownExtensions = Set(["md", "markdown", "mdown"])
    private static let unchangedResourceExtensions = Set([
        "png", "jpg", "jpeg", "gif", "webp", "svg", "excalidraw"
    ])
    private static let externalSchemes = Set(["http", "https", "mailto"])

    func resolve(
        _ destination: String,
        documentURL: URL?,
        validatesTarget: Bool = true,
        workspaceRootURL: URL? = nil
    ) throws -> MarkdownLinkNavigation {
        guard !destination.isEmpty else { return .unchanged }
        if destination.hasPrefix("#") {
            return .fragment(Self.decodeFragment(String(destination.dropFirst())))
        }

        guard let components = URLComponents(string: destination) else {
            throw MarkdownLinkNavigationError.unavailable(URL(fileURLWithPath: destination))
        }
        let scheme = components.scheme?.lowercased()
        if let scheme, Self.externalSchemes.contains(scheme), let url = components.url {
            return .external(url)
        }
        if let scheme, scheme != "file" {
            throw MarkdownLinkNavigationError.unsupportedScheme(scheme)
        }

        let target: URL
        if scheme == "file", let absolute = components.url {
            target = absolute
        } else {
            guard let documentURL else {
                throw MarkdownLinkNavigationError.documentRequired
            }
            let encodedPath = components.percentEncodedPath
            guard let decodedPath = encodedPath.removingPercentEncoding else {
                throw MarkdownLinkNavigationError.unavailable(documentURL)
            }
            target = URL(
                fileURLWithPath: decodedPath,
                relativeTo: documentURL.deletingLastPathComponent()
            ).absoluteURL
        }

        var fileComponents = URLComponents(
            url: target,
            resolvingAgainstBaseURL: false
        )
        fileComponents?.fragment = nil
        guard let fileURL = fileComponents?.url else {
            throw MarkdownLinkNavigationError.unavailable(target)
        }
        let standardized = fileURL.standardizedFileURL
        let pathExtension = standardized.pathExtension.lowercased()
        if Self.unchangedResourceExtensions.contains(pathExtension) {
            return .unchanged
        }
        guard Self.markdownExtensions.contains(pathExtension) else {
            throw MarkdownLinkNavigationError.unsupportedResource(standardized)
        }
        if validatesTarget {
            try validateMarkdownURL(standardized, allowedRootURL: workspaceRootURL)
        }
        return .markdown(
            standardized,
            fragment: components.percentEncodedFragment.map(Self.decodeFragment)
        )
    }

    func validateMarkdownURL(_ url: URL, allowedRootURL: URL? = nil) throws {
        let standardized = url.standardizedFileURL
        let root = allowedRootURL?.standardizedFileURL
        if let root, !WorkspaceResolver.contains(standardized, in: root) {
            throw MarkdownLinkNavigationError.symbolicLink(standardized)
        }

        var candidate = root ?? standardized.deletingLastPathComponent()
        let relativeComponents: ArraySlice<String>
        if let root {
            let rootComponents = root.pathComponents
            relativeComponents = standardized.pathComponents.dropFirst(rootComponents.count)
            do {
                if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw MarkdownLinkNavigationError.symbolicLink(standardized)
                }
            } catch let error as MarkdownLinkNavigationError {
                throw error
            } catch {
                throw MarkdownLinkNavigationError.unavailable(standardized)
            }
        } else {
            relativeComponents = standardized.pathComponents.suffix(1)
        }

        for component in relativeComponents {
            candidate.appendPathComponent(component)
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
            } catch {
                throw MarkdownLinkNavigationError.unavailable(standardized)
            }
            if values.isSymbolicLink == true {
                throw MarkdownLinkNavigationError.symbolicLink(standardized)
            }
        }
        let values = try standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey
        ])
        if values.isDirectory == true {
            throw MarkdownLinkNavigationError.directory(standardized)
        }
        guard values.isRegularFile == true else {
            throw MarkdownLinkNavigationError.unavailable(standardized)
        }
        if let root {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let resolvedTarget = standardized.resolvingSymlinksInPath().standardizedFileURL
            guard WorkspaceResolver.contains(resolvedTarget, in: resolvedRoot) else {
                throw MarkdownLinkNavigationError.symbolicLink(standardized)
            }
        }
    }

    nonisolated private static func decodeFragment(_ fragment: String) -> String {
        fragment.removingPercentEncoding ?? fragment
    }
}

extension MarkdownOutline {
    static func heading(matchingFragment fragment: String, in markdown: String) -> MarkdownHeading? {
        let target = normalizedFragment(fragment)
        guard !target.isEmpty else { return nil }
        return headings(in: markdown).first {
            normalizedFragment($0.title) == target || "md-heading-\($0.id)" == target
        }
    }

    private static func normalizedFragment(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s_-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s_]+"#, with: "-", options: .regularExpression)
    }
}
