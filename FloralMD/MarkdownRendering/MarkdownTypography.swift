import Foundation

nonisolated struct MarkdownTypography: Equatable, Sendable {
    static let defaultFontName = ""
    static let defaultFontSize = 15.0
    static let defaultLineHeight = 1.52
    static let fontSizeRange = 11.0...28.0
    static let lineHeightRange = 1.3...1.8

    let fontName: String
    let fontSize: Double
    let lineHeight: Double

    init(fontName: String, fontSize: Double, lineHeight: Double) {
        self.fontName = fontName
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.lineHeight = min(
            max(lineHeight, Self.lineHeightRange.lowerBound),
            Self.lineHeightRange.upperBound
        )
    }

    static let `default` = MarkdownTypography(
        fontName: defaultFontName,
        fontSize: defaultFontSize,
        lineHeight: defaultLineHeight
    )

    var cssFontFamily: String {
        guard !fontName.isEmpty else { return Self.systemFontFamily }
        return "\"\(Self.escapeCSSString(fontName))\", \(Self.systemFontFamily)"
    }

    var cssVariableDeclarations: String {
        """
        --floralmd-body-font-family: \(cssFontFamily);
        --floralmd-body-font-size: \(Self.cssNumber(fontSize))px;
        --floralmd-body-line-height: \(Self.cssNumber(lineHeight));
        """
    }

    var previewOverrideCSS: String {
        """
        :root {
            \(cssVariableDeclarations)
        }
        body {
            font-family: var(--floralmd-body-font-family);
            font-size: var(--floralmd-body-font-size);
            line-height: var(--floralmd-body-line-height);
        }
        .md-source-blank-line {
            height: calc(var(--floralmd-body-font-size) * var(--floralmd-body-line-height));
        }
        p { margin-top: 0.8em; }
        .md-source-list-line { margin-top: 0.4em; }
        """
    }

    private static let systemFontFamily =
        "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, sans-serif"

    private static func escapeCSSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func cssNumber(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

nonisolated enum MarkdownFontSizeAdjustment: Equatable, Sendable {
    case increase
    case decrease
    case reset

    func apply(to currentSize: Double) -> Double {
        let proposedSize = switch self {
        case .increase:
            currentSize + 1
        case .decrease:
            currentSize - 1
        case .reset:
            MarkdownTypography.defaultFontSize
        }
        return min(
            max(proposedSize, MarkdownTypography.fontSizeRange.lowerBound),
            MarkdownTypography.fontSizeRange.upperBound
        )
    }

    func isAvailable(at currentSize: Double) -> Bool {
        apply(to: currentSize) != currentSize
    }
}
