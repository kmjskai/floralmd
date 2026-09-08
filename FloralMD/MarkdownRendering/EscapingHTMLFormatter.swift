//
//  EscapingHTMLFormatter.swift
//  md-preview
//
//  Migrated from pluk-inc/markdown-preview at
//  e364421b76df9f650012a270e4b5b6c9d799323f (MIT).
//

import Foundation
import Markdown

/// Supplies the exact source coordinates for rendered preview tables so the
/// DOM can carry unambiguous `data-source-*` attributes.
nonisolated enum MarkdownTableSource {
    private enum Alignment {
        case none, left, center, right
    }

    /// Returns the exact Markdown source for each rendered data cell. The
    /// delimiter row is structural and is omitted so these coordinates match
    /// the table row indices emitted into the preview DOM.
    static func sourceRows(from tableLines: [String]) -> [[String]]? {
        guard tableLines.count >= 2 else { return nil }
        var rows = tableLines.map(splitRow)
        guard !rows[0].isEmpty,
              let alignments = parseAlignments(rows[1]) else { return nil }
        rows.remove(at: 1)
        let columnCount = max(rows.map(\.count).max() ?? 0, alignments.count)
        guard columnCount > 0 else { return nil }
        normalizeRows(&rows, columnCount: columnCount)
        return rows
    }

    private static func splitRow(_ source: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var backslashCount = 0
        var codeFenceLength = 0
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if character == "`" && backslashCount.isMultiple(of: 2) {
                var runEnd = source.index(after: index)
                while runEnd < source.endIndex, source[runEnd] == "`" {
                    runEnd = source.index(after: runEnd)
                }
                let runLength = source.distance(from: index, to: runEnd)
                if codeFenceLength == 0 {
                    codeFenceLength = runLength
                } else if codeFenceLength == runLength {
                    codeFenceLength = 0
                }
                cell.append(contentsOf: source[index..<runEnd])
                index = runEnd
                backslashCount = 0
                continue
            }
            if character == "|", backslashCount.isMultiple(of: 2), codeFenceLength == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            if character == "\\" {
                backslashCount += 1
            } else {
                backslashCount = 0
            }
            index = source.index(after: index)
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        if source.trimmingCharacters(in: .whitespaces).hasPrefix("|"), cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if source.trimmingCharacters(in: .whitespaces).hasSuffix("|"), cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func parseAlignments(_ cells: [String]) -> [Alignment]? {
        guard !cells.isEmpty else { return nil }
        var result: [Alignment] = []
        for cell in cells {
            let token = cell.trimmingCharacters(in: .whitespaces)
            let left = token.hasPrefix(":")
            let right = token.hasSuffix(":")
            let hyphens = token.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard hyphens.count >= 3, hyphens.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return result
    }

    private static func normalizeRows(_ rows: inout [[String]], columnCount: Int) {
        for index in rows.indices {
            if rows[index].count < columnCount {
                rows[index].append(contentsOf: repeatElement("", count: columnCount - rows[index].count))
            } else if rows[index].count > columnCount {
                rows[index] = Array(rows[index].prefix(columnCount))
            }
        }
    }

}

// Mirrors swift-markdown's HTMLFormatter but HTML-escapes text, code, and
// attribute values. Upstream HTMLFormatter emits unescaped content
// (swift-markdown 0.7.x), so characters like `<`, `>`, and `&` either render
// invisibly or get reinterpreted as HTML — see issue #33.
nonisolated struct EscapingHTMLFormatter: MarkupWalker {
    private(set) var result = ""

    let options: HTMLFormatterOptions
    let sourceLineOffset: Int
    private let sourceLines: [String]
    /// The Markdown actually handed to the parser. Math extraction can
    /// substitute single-line placeholders before parsing, so ranges from the
    /// syntax tree must be read back through these lines, not the raw source.
    private let parsedLines: [String]

    private var inTableHead = false
    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var tableSourceRows: [[String]]?
    private var currentTableColumn = 0
    private var currentTableRow = 0
    private var listDepth = 0
    private var sourceListPrefixToStrip: String?
    /// Non-zero while walking heading or link content, whose text must not
    /// gain hashtag capsules (the editor's syntax-tree scanner excludes
    /// headings and links the same way).
    private var hashtagSuppressionDepth = 0

    private struct SourceIndentedListLine {
        let sourceLine: Int
        let extraDepth: Int
        let displayMarker: String
        let prefixToStrip: String
        let taskChecked: Bool?
    }

    init(options: HTMLFormatterOptions = [],
         sourceLineOffset: Int = 0,
         sourceMarkdown: String = "",
         parsedMarkdown: String? = nil) {
        self.options = options
        self.sourceLineOffset = sourceLineOffset
        let source = sourceMarkdown
        self.sourceLines = source.components(separatedBy: "\n")
        self.parsedLines = (parsedMarkdown ?? source).components(separatedBy: "\n")
    }

    static func format(_ markdown: String,
                       options: HTMLFormatterOptions = [],
                       sourceLineOffset: Int = 0,
                       sourceMarkdown: String? = nil) -> String {
        // swift-markdown consumes the backslash of `\#`, so text nodes can
        // no longer tell an escaped hashtag from a real one. Rewrite escaped
        // hashtags in ordinary text into a U+FFFD marker (same character
        // count per line, so source columns stay aligned); the marker is
        // dropped at render time and the `#` shows literally.
        let protected = protectEscapedHashtags(in: markdown)
        let document = Document(parsing: protected)
        var walker = EscapingHTMLFormatter(
            options: options,
            sourceLineOffset: sourceLineOffset,
            sourceMarkdown: sourceMarkdown ?? markdown,
            parsedMarkdown: protected
        )
        walker.visit(document)
        return walker.result
    }

    /// The marker inserted for a backslash-escaped `\#`. Also dropped from
    /// rendered text so it never shows up in the page.
    private static let escapedHashtagMarker = "\u{FFFD}"

    /// The marker inserted before a real hashtag preceded by an even run of
    /// backslashes (`\\#tag`), whose parity the parser would otherwise flip.
    private static let realHashtagMarker = "\u{FFFC}"

    /// Rewrites `\#` (odd run of backslashes) inside ordinary text into
    /// `marker#` so the escape survives parsing. Fenced and indented code,
    /// inline code, HTML spans and link destinations are left untouched —
    /// when in doubt a line is copied verbatim rather than rewritten.
    private static func protectEscapedHashtags(in markdown: String) -> String {
        var inFence: (character: Character, length: Int)?
        var lines: [String] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let leading = line.count - trimmed.count

            if var fence = inFence {
                lines.append(line)
                if leading <= 3,
                   let first = trimmed.first,
                   first == fence.character {
                    let run = trimmed.prefix(while: { $0 == first }).count
                    if run >= fence.length { inFence = nil }
                }
                continue
            }
            if leading <= 3,
               let first = trimmed.first,
               first == "`" || first == "~" {
                let run = trimmed.prefix(while: { $0 == first }).count
                if run >= 3 {
                    inFence = (first, run)
                    lines.append(line)
                    continue
                }
            }
            if leading >= 4 || line.first == "\t" {
                lines.append(line)
                continue
            }
            lines.append(protectEscapedHashtagsInLine(line))
        }
        return lines.joined(separator: "\n")
    }

    private static func protectEscapedHashtagsInLine(_ line: String) -> String {
        let chars = Array(line)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var backslashRun = 0
        var inlineCodeLength = 0
        var inHTML = false
        var inLinkDestination = false

        while i < chars.count {
            let character = chars[i]
            if inlineCodeLength > 0 {
                out.append(character)
                if character == "`" {
                    var run = 0
                    while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                    if run == inlineCodeLength { inlineCodeLength = 0 }
                }
                i += 1
                continue
            }
            if inHTML {
                out.append(character)
                if character == ">" { inHTML = false }
                i += 1
                continue
            }
            if inLinkDestination {
                out.append(character)
                if character == ")" { inLinkDestination = false }
                i += 1
                continue
            }
            if character == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                inlineCodeLength = run
                out.append(contentsOf: chars[i..<(i + run)])
                i += run
                continue
            }
            if character == "<" {
                inHTML = true
                out.append(character)
                i += 1
                continue
            }
            if character == "]",
               i + 1 < chars.count,
               chars[i + 1] == "(" {
                inLinkDestination = true
                out.append(character)
                out.append("(")
                i += 2
                continue
            }
            if character == "\\" {
                backslashRun += 1
                i += 1
                continue
            }
            if character == "#", backslashRun > 0 {
                if backslashRun % 2 == 1 {
                    // Odd run: the `#` is escaped — mark it so the rendered
                    // text keeps the literal `#` without a capsule.
                    out.append(String(repeating: "\\", count: backslashRun - 1))
                    out.append(escapedHashtagMarker)
                    out.append("#")
                } else {
                    // Even run: `\\#tag` is a literal backslash followed by a
                    // real hashtag. The parser halves the run (and flips its
                    // parity), so pin the "real tag" intent with a marker
                    // before parsing; the editor's source-level scan sees
                    // the even run and renders the capsule too.
                    out.append(String(repeating: "\\", count: backslashRun))
                    out.append(realHashtagMarker)
                    out.append("#")
                }
                backslashRun = 0
                i += 1
                continue
            }
            if backslashRun > 0 {
                out.append(String(repeating: "\\", count: backslashRun))
                backslashRun = 0
            }
            out.append(character)
            i += 1
        }
        if backslashRun > 0 {
            out.append(String(repeating: "\\", count: backslashRun))
        }
        return out
    }

    // MARK: Block elements

    private func sourceLineAttribute(_ markup: Markup) -> String {
        guard let range = markup.range else { return "" }
        let start = range.lowerBound.line + sourceLineOffset
        // SourceRange is half-open. A range ending at column 1 belongs to the
        // previous source line, not the new line whose first column it meets.
        let inclusiveEndLine = range.upperBound.column == 1
            && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1
            : range.upperBound.line
        let end = max(start, inclusiveEndLine + sourceLineOffset)
        // Keep data-source-line while callers migrate to the richer range.
        return " data-source-line=\"\(start)\" data-source-start=\"\(start)\" data-source-end=\"\(end)\""
    }

    private func precedingBlankLineCount(for markup: Markup) -> Int {
        guard let line = markup.range?.lowerBound.line else { return 0 }
        var precedingLineIndex = line - 2
        var blankLineCount = 0
        while precedingLineIndex >= 0,
              precedingLineIndex < sourceLines.count,
              sourceLines[precedingLineIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
            blankLineCount += 1
            precedingLineIndex -= 1
        }
        return blankLineCount
    }

    mutating func visitDocument(_ document: Document) {
        for child in document.children {
            // CommonMark discards source blank lines between blocks. Restore
            // every authored line in addition to the blocks' semantic margins.
            for _ in 0..<precedingBlankLineCount(for: child) {
                result += "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n"
            }
            visit(child)
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if renderAlertIfPresent(blockQuote) {
            return
        }
        if options.contains(.parseAsides),
           let aside = Aside(blockQuote, tagRequirement: .requireSingleWordTag) {
            result += "<aside data-kind=\"\(escapeAttribute(aside.kind.rawValue))\">\n"
            for child in aside.content {
                visit(child)
            }
            result += "</aside>\n"
        } else {
            result += "<blockquote\(sourceLineAttribute(blockQuote))>\n"
            descendInto(blockQuote)
            result += "</blockquote>\n"
        }
    }

    // GitHub-style alerts: `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`,
    // `> [!WARNING]`, `> [!CAUTION]`. Tag matching is case-insensitive. Any
    // text on the tag line after the closing `]` is used as a custom title;
    // otherwise the alert's default title is used.
    private mutating func renderAlertIfPresent(_ blockQuote: BlockQuote) -> Bool {
        let blocks = Array(blockQuote.children)
        guard let firstPara = blocks.first as? Paragraph else { return false }
        let inlines = Array(firstPara.children)
        guard let firstText = inlines.first as? Text,
              let (kind, prefixLen) = Self.matchAlertTag(firstText.string) else {
            return false
        }

        var firstTextRest = String(firstText.string.dropFirst(prefixLen))
        if firstTextRest.hasPrefix(" ") {
            firstTextRest.removeFirst()
        }

        var titleInlinesAfter: [Markup] = []
        var firstParaBody: [Markup] = []
        var pastTitle = false
        for inline in inlines.dropFirst() {
            if !pastTitle {
                if inline is SoftBreak || inline is LineBreak {
                    pastTitle = true
                    continue
                }
                titleInlinesAfter.append(inline)
            } else {
                firstParaBody.append(inline)
            }
        }

        let hasCustomTitle = !firstTextRest.trimmingCharacters(in: .whitespaces).isEmpty
            || !titleInlinesAfter.isEmpty

        result += "<div class=\"markdown-alert markdown-alert-\(kind.rawValue)\">\n"
        result += "<p class=\"markdown-alert-title\">"
        result += kind.iconSVG
        result += " "
        if hasCustomTitle {
            if !firstTextRest.isEmpty {
                result += escapeText(firstTextRest)
            }
            for inline in titleInlinesAfter {
                visit(inline)
            }
        } else {
            result += escapeText(kind.defaultTitle)
        }
        result += "</p>\n"

        if !firstParaBody.isEmpty {
            result += "<p>"
            for inline in firstParaBody {
                visit(inline)
            }
            result += "</p>\n"
        }
        for block in blocks.dropFirst() {
            visit(block)
        }
        result += "</div>\n"
        return true
    }

    private enum AlertKind: String {
        case note, tip, important, warning, caution

        // GitHub Octicons (info, light-bulb, report, alert, stop).
        // Stripped to the path data only — the wrapper is built by `iconSVG`.
        private var iconPath: String {
            switch self {
            case .note:
                return "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"
            case .tip:
                return "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"
            case .important:
                return "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
            case .warning:
                return "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
            case .caution:
                return "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"
            }
        }

        var iconSVG: String {
            "<svg class=\"markdown-alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"\(iconPath)\"></path></svg>"
        }

        var defaultTitle: String {
            switch self {
            case .note: return "Note"
            case .tip: return "Tip"
            case .important: return "Important"
            case .warning: return "Warning"
            case .caution: return "Caution"
            }
        }
    }

    private static func matchAlertTag(_ text: String) -> (AlertKind, Int)? {
        let tags: [(String, AlertKind)] = [
            ("[!note]", .note),
            ("[!tip]", .tip),
            ("[!important]", .important),
            ("[!warning]", .warning),
            ("[!caution]", .caution),
        ]
        let lower = text.lowercased()
        for (tag, kind) in tags where lower.hasPrefix(tag) {
            return (kind, tag.count)
        }
        return nil
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let info = CodeFenceInfo(rawInfoString: codeBlock.language)
        let languageAttr = info.language.isEmpty
            ? ""
            : " class=\"language-\(escapeAttribute(info.highlightLanguage))\""
        result += "<pre\(sourceLineAttribute(codeBlock))><code\(languageAttr)>\(escapeText(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        hashtagSuppressionDepth += 1
        defer { hashtagSuppressionDepth -= 1 }
        if let setext = setextSource(for: heading) {
            let paragraphEnd = max(setext.contentStartLine, setext.markerLine - 1)
            result += "<p\(sourceLineAttribute(from: setext.contentStartLine, to: paragraphEnd))>"
            descendInto(heading)
            result += "</p>\n"
            if setext.marker.allSatisfy({ $0 == "-" }), setext.marker.count >= 3 {
                result += "<hr\(sourceLineAttribute(from: setext.markerLine, to: setext.markerLine)) />\n"
            } else {
                result += "<p\(sourceLineAttribute(from: setext.markerLine, to: setext.markerLine))>"
                result += escapeText(setext.marker)
                result += "</p>\n"
            }
            return
        }
        result += "<h\(heading.level)\(sourceLineAttribute(heading))>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    private func sourceLineAttribute(from startLine: Int, to endLine: Int) -> String {
        let start = startLine + sourceLineOffset
        let end = max(start, endLine + sourceLineOffset)
        return " data-source-line=\"\(start)\" data-source-start=\"\(start)\" data-source-end=\"\(end)\""
    }

    private func setextSource(for heading: Heading) -> (
        contentStartLine: Int,
        markerLine: Int,
        marker: String
    )? {
        guard let range = heading.range else { return nil }
        let inclusiveEndLine = range.upperBound.column == 1
            && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1
            : range.upperBound.line
        guard inclusiveEndLine > range.lowerBound.line,
              sourceLines.indices.contains(inclusiveEndLine - 1) else { return nil }
        guard let marker = setextMarker(onSourceLine: inclusiveEndLine) else { return nil }
        return (range.lowerBound.line, inclusiveEndLine, marker)
    }

    /// Reads the Setext underline from the raw source line, stripping the
    /// block-quote prefixes and indentation the block parser consumed and any
    /// trailing CR. Without the prefixes a heading inside `> ...` would fall
    /// through as a real `<h1>`/`<h2>`, and without CR stripping a CRLF file
    /// would too (`\r` is not part of `.whitespaces`).
    private func setextMarker(onSourceLine line: Int) -> String? {
        guard sourceLines.indices.contains(line - 1) else { return nil }
        let marker = strippedSourceLine(sourceLines[line - 1])
        guard !marker.isEmpty,
              marker.allSatisfy({ $0 == "-" || $0 == "=" }),
              Set(marker).count == 1 else { return nil }
        return marker
    }

    /// The editor's dialect keeps a bare `-`/`*`/`+` line (inside or
    /// outside a list) as ordinary text. Returns the marker when the source
    /// line is exactly that — marker with no following whitespace — after
    /// stripping block-quote prefixes, indentation and CR. A marker followed
    /// by whitespace (`- `) is a real list marker and stays an empty list
    /// item with its bullet, in both surfaces.
    private func bareListItemMarker(onSourceLine line: Int) -> String? {
        guard sourceLines.indices.contains(line - 1) else { return nil }
        let lineText = sourceLines[line - 1]
        let stripped = strippedSourceLine(lineText)
        guard stripped.count == 1,
              stripped == "-" || stripped == "*" || stripped == "+" else { return nil }
        var raw = lineText
        while let first = raw.first {
            if first == ">" {
                raw.removeFirst()
                if raw.first == " " { raw.removeFirst() }
            } else if first == " " || first == "\t" {
                raw.removeFirst()
            } else {
                break
            }
        }
        // `- ` / `-\t` are real markers (empty items keep their bullet);
        // trailing `\r` from CRLF files is not a separator.
        guard !raw.dropFirst().contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
        return stripped
    }

    /// Removes repeated `> ` block-quote prefixes and leading indentation,
    /// then trailing whitespace and CR, mirroring how the block parser
    /// consumed the line.
    private func strippedSourceLine(_ line: String) -> String {
        var text = line
        while let first = text.first {
            if first == ">" {
                text.removeFirst()
                if text.first == " " { text.removeFirst() }
            } else if first == " " || first == "\t" {
                text.removeFirst()
            } else {
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr\(sourceLineAttribute(thematicBreak)) />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Raw HTML blocks are passed through per CommonMark.
        result += html.rawHTML
    }

    mutating func visitListItem(_ listItem: ListItem) {
        // The editor keeps a bare unordered marker (`-`, `*`, `+` with no
        // following content) as ordinary text — typing `-` must not enter the
        // rendered list state until a space follows. Mirror that in the
        // read-only preview instead of CommonMark's empty list item, while
        // keeping the list's layout: no bullet, but the same indentation.
        if listItem.childCount == 0,
           let range = listItem.range,
           let marker = bareListItemMarker(onSourceLine: range.lowerBound.line) {
            result += "<li class=\"md-bare-marker\"\(sourceLineAttribute(listItem))>"
            result += escapeText(marker)
            result += "</li>\n"
            return
        }
        if let checkbox = listItem.checkbox {
            result += "<li class=\"task-list-item\"\(sourceLineAttribute(listItem))>"
            result += "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled=\"\""
            if checkbox == .checked {
                result += " checked=\"\""
            }
            result += " /> "
        } else {
            result += "<li\(sourceLineAttribute(listItem))>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start: String
        if orderedList.startIndex != 1 {
            start = " start=\"\(orderedList.startIndex)\""
        } else {
            start = ""
        }
        result += "<ol\(start)\(sourceLineAttribute(orderedList))>\n"
        listDepth += 1
        descendInto(orderedList)
        listDepth -= 1
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        // A bare marker on its own line (not inside a list, and not the
        // trailing line of an existing list) is ordinary body text in the
        // editor — render it as a paragraph so the preview shows no list
        // indentation either.
        if let standalone = standaloneBareMarkerList(unorderedList) {
            result += "<p\(sourceLineAttribute(unorderedList))>"
            result += escapeText(standalone)
            result += "</p>\n"
            return
        }
        result += "<ul\(sourceLineAttribute(unorderedList))>\n"
        listDepth += 1
        descendInto(unorderedList)
        listDepth -= 1
        result += "</ul>\n"
    }

    /// A list that is exactly one empty item whose source line is a bare
    /// `-`/`*`/`+` marker, and that list is not nested inside another list
    /// item. Such a line parses as a one-item list in CommonMark but stays
    /// ordinary text in the editor, so the preview mirrors the editor.
    private func standaloneBareMarkerList(_ list: UnorderedList) -> String? {
        guard list.childCount == 1,
              let item = list.child(at: 0) as? ListItem,
              item.childCount == 0,
              let range = item.range,
              list.parent is Document || list.parent is BlockQuote,
              let marker = bareListItemMarker(onSourceLine: range.lowerBound.line) else {
            return nil
        }
        return marker
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p\(sourceLineAttribute(paragraph))>"
        // Source-indented pseudo-list lines only exist inside a parsed list.
        // Keep the overwhelmingly common top-level paragraph path on the
        // walker's direct traversal instead of materializing all children.
        guard listDepth > 0 else {
            descendInto(paragraph)
            result += "</p>\n"
            return
        }

        let children = Array(paragraph.children)
        var sourceListLineOpen = false
        var sourceListIndentWrappers = 0
        for index in children.indices {
            let child = children[index]
            guard child is SoftBreak || child is LineBreak else {
                visit(child)
                continue
            }

            if sourceListLineOpen {
                result += "</span>"
                result += String(repeating: "</span>", count: sourceListIndentWrappers)
                sourceListLineOpen = false
                sourceListIndentWrappers = 0
                sourceListPrefixToStrip = nil
            }

            let nextChild = children.index(after: index)
            if nextChild < children.endIndex,
               let line = sourceIndentedListLine(startingWith: children[nextChild]) {
                let mappedLine = line.sourceLine + sourceLineOffset
                result += String(
                    repeating: "<span class=\"md-source-list-indent-step\">",
                    count: line.extraDepth
                )
                result += "<span class=\"md-source-list-line\" role=\"listitem\""
                result += " data-source-line=\"\(mappedLine)\" data-source-start=\"\(mappedLine)\" data-source-end=\"\(mappedLine)\""
                result += ">"
                if let checked = line.taskChecked {
                    result += "<span class=\"md-source-list-marker md-source-task-marker\">"
                    result += "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled=\"\""
                    if checked { result += " checked=\"\"" }
                    result += " /></span>"
                } else {
                    result += "<span class=\"md-source-list-marker\" aria-hidden=\"true\">"
                    result += escapeText(line.displayMarker)
                    result += "</span>"
                }
                sourceListPrefixToStrip = line.prefixToStrip
                sourceListLineOpen = true
                sourceListIndentWrappers = line.extraDepth
            } else {
                result += "<br />\n"
            }
        }
        if sourceListLineOpen {
            result += "</span>"
            result += String(repeating: "</span>", count: sourceListIndentWrappers)
            sourceListPrefixToStrip = nil
        }
        result += "</p>\n"
    }

    private func sourceIndentedListLine(startingWith markup: Markup) -> SourceIndentedListLine? {
        guard listDepth > 0,
              let sourceLine = firstSourceLine(in: markup),
              sourceLines.indices.contains(sourceLine - 1) else {
            return nil
        }
        let source = sourceLines[sourceLine - 1]
        let characters = Array(source)
        var index = 0
        var columns = 0
        while index < characters.count {
            if characters[index] == " " {
                columns += 1
            } else if characters[index] == "\t" {
                columns += 4 - (columns % 4)
            } else {
                break
            }
            index += 1
        }

        let desiredDepth = columns / 4 + 1
        guard desiredDepth > listDepth, index < characters.count else { return nil }

        let markerStart = index
        let displayMarker: String
        if ["-", "+", "*"].contains(characters[index]) {
            displayMarker = "•"
            index += 1
        } else {
            let digitStart = index
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
            guard index > digitStart,
                  index < characters.count,
                  characters[index] == "." || characters[index] == ")" else {
                return nil
            }
            index += 1
            displayMarker = String(characters[digitStart..<index])
        }

        guard index == characters.count
                || characters[index] == " "
                || characters[index] == "\t" else {
            return nil
        }
        while index < characters.count,
              characters[index] == " " || characters[index] == "\t" {
            index += 1
        }

        var taskChecked: Bool?
        if displayMarker == "•",
           index + 2 < characters.count,
           characters[index] == "[",
           characters[index + 2] == "]",
           characters[index + 1] == " "
            || characters[index + 1] == "x"
            || characters[index + 1] == "X" {
            taskChecked = characters[index + 1] != " "
            index += 3
            while index < characters.count,
                  characters[index] == " " || characters[index] == "\t" {
                index += 1
            }
        }

        return SourceIndentedListLine(
            sourceLine: sourceLine,
            extraDepth: desiredDepth - listDepth,
            displayMarker: displayMarker,
            prefixToStrip: String(characters[markerStart..<index]),
            taskChecked: taskChecked
        )
    }

    private func firstSourceLine(in markup: Markup) -> Int? {
        if let line = markup.range?.lowerBound.line {
            return line
        }
        for child in markup.children {
            if let line = firstSourceLine(in: child) {
                return line
            }
        }
        return nil
    }

    mutating func visitTable(_ table: Table) {
        result += "<table\(sourceLineAttribute(table))>\n"
        tableColumnAlignments = table.columnAlignments
        tableSourceRows = sourceRows(for: table)
        currentTableRow = 0
        descendInto(table)
        tableColumnAlignments = nil
        tableSourceRows = nil
        result += "</table>\n"
    }

    private func sourceRows(for table: Table) -> [[String]]? {
        guard let range = table.range else { return nil }
        let startIndex = range.lowerBound.line - 1
        let inclusiveEndLine = range.upperBound.column == 1
            && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1
            : range.upperBound.line
        let endIndex = inclusiveEndLine - 1
        guard sourceLines.indices.contains(startIndex),
              sourceLines.indices.contains(endIndex),
              startIndex <= endIndex else { return nil }
        return MarkdownTableSource.sourceRows(
            from: Array(sourceLines[startIndex...endIndex])
        )
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
        currentTableRow = 1
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        if !tableBody.isEmpty {
            result += "<tbody>\n"
            descendInto(tableBody)
            result += "</tbody>\n"
        }
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>\n"
        currentTableColumn = 0
        descendInto(tableRow)
        result += "</tr>\n"
        currentTableRow += 1
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard let alignments = tableColumnAlignments,
              currentTableColumn < alignments.count else { return }
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }

        let element = inTableHead ? "th" : "td"
        result += "<\(element) data-table-row=\"\(currentTableRow)\" data-table-column=\"\(currentTableColumn)\""

        if let rows = tableSourceRows,
           rows.indices.contains(currentTableRow),
           rows[currentTableRow].indices.contains(currentTableColumn) {
            let source = rows[currentTableRow][currentTableColumn]
            result += " data-table-markdown=\"\(escapeAttribute(source))\""
        }

        if let alignment = alignments[currentTableColumn] {
            result += " align=\"\(alignment)\""
        }
        currentTableColumn += 1

        if tableCell.rowspan > 1 {
            result += " rowspan=\"\(tableCell.rowspan)\""
        }
        if tableCell.colspan > 1 {
            result += " colspan=\"\(tableCell.colspan)\""
        }

        result += ">"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    // MARK: Inline elements

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(escapeText(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img"
        if let source = image.source, !source.isEmpty {
            result += " src=\"\(escapeAttribute(source))\""
        }
        if let title = image.title, !title.isEmpty {
            result += " title=\"\(escapeAttribute(title))\""
        }
        result += " />"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br />\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        // Obsidian-style breaks: a single newline in the source is a real
        // line break, not a CommonMark soft-wrap space.
        result += "<br />\n"
    }

    mutating func visitLink(_ link: Link) {
        hashtagSuppressionDepth += 1
        defer { hashtagSuppressionDepth -= 1 }
        result += "<a"
        if let destination = link.destination {
            let escapedDestination = escapeAttribute(destination)
            result += " href=\"\(escapedDestination)\" data-md-href=\"\(escapedDestination)\""
        }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        var string = text.string
        if let prefix = sourceListPrefixToStrip,
           string.hasPrefix(prefix) {
            string = String(string.dropFirst(prefix.count))
            sourceListPrefixToStrip = nil
        }
        guard hashtagSuppressionDepth == 0 else {
            result += escapeTextPreservingInlineTabs(Self.droppingHashtagMarkers(string))
            return
        }
        let nsString = string as NSString
        let matches = Self.hashtagRegex.matches(
            in: string,
            range: NSRange(location: 0, length: nsString.length)
        )
        guard !matches.isEmpty else {
            result += escapeTextPreservingInlineTabs(Self.droppingHashtagMarkers(string))
            return
        }
        var cursor = 0
        for match in matches {
            let tokenRange = match.range(at: 2)
            let tokenStart = tokenRange.location
            let token = nsString.substring(with: tokenRange)
            guard Self.isRenderedHashtag(nsString: nsString, token: token, tokenStart: tokenStart) else {
                continue
            }
            result += escapeTextPreservingInlineTabs(Self.droppingHashtagMarkers(
                nsString.substring(with: NSRange(location: cursor, length: tokenStart - cursor))
            ))
            result += "<span class=\"md-hashtag\" dir=\"auto\">"
            result += escapeTextPreservingInlineTabs(token)
            result += "</span>"
            cursor = tokenRange.location + tokenRange.length
        }
        result += escapeTextPreservingInlineTabs(Self.droppingHashtagMarkers(
            nsString.substring(from: cursor)
        ))
    }

    private static func droppingHashtagMarkers(_ string: String) -> String {
        string
            .replacingOccurrences(of: escapedHashtagMarker, with: "")
            .replacingOccurrences(of: realHashtagMarker, with: "")
    }

    /// Same token rule as the editor bundle's hashtag scanner: a `#` run of
    /// Unicode letters/marks/digits/underscore/hyphen with optional
    /// slash-separated path segments, preceded by anything but an
    /// alphanumeric/`_`/`/`/`#`, not backslash-escaped, no segment purely of
    /// hyphens, and at least one letter or underscore in the whole token.
    private static let hashtagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(^|[^\p{L}\p{M}\p{N}_/#])(#[\p{L}\p{M}\p{N}_-]+(?:/[\p{L}\p{M}\p{N}_-]+)*)"#
        )
    }()

    private static let hashtagSegmentCharRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]"#)
    }()

    private static let hashtagLetterOrUnderscoreRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"[\p{L}\p{M}_]"#)
    }()

    private static func isRenderedHashtag(nsString: NSString,
                                          token: String,
                                          tokenStart: Int) -> Bool {
        // `\#tag` was rewritten to `marker#tag` before parsing; the marker
        // right before the token means the hashtag is backslash-escaped.
        if tokenStart > 0, nsString.character(at: tokenStart - 1) == 0xFFFD {
            return false
        }
        // An odd run of backslashes right before `#` escapes the tag.
        var backslashes = 0
        var index = tokenStart - 1
        while index >= 0, nsString.character(at: index) == 0x5C { // "\"
            backslashes += 1
            index -= 1
        }
        guard backslashes % 2 == 0 else { return false }
        // Every slash-separated segment must contain at least one
        // alphanumeric/underscore character (`#a-` is fine, `#-` is not).
        let segments = token.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            let nsSegment = String(segment) as NSString
            guard Self.hashtagSegmentCharRegex.firstMatch(
                in: String(segment),
                range: NSRange(location: 0, length: nsSegment.length)
            ) != nil else { return false }
        }
        // The token as a whole must contain a letter or underscore, so plain
        // `#123` stays literal.
        let nsToken = token as NSString
        return Self.hashtagLetterOrUnderscoreRegex.firstMatch(
            in: token,
            range: NSRange(location: 0, length: nsToken.length)
        ) != nil
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        // swift-markdown treats both `~x~` and `~~x~~` as GFM strikethrough,
        // but the editor bundle only recognizes `~~`. Obsidian reads `~x~` as
        // subscript, so keep the single-tilde form literal to match both the
        // editor and the target dialect.
        if let range = strikethrough.range,
           parsedLines.indices.contains(range.lowerBound.line - 1) {
            let lineBytes = Array(parsedLines[range.lowerBound.line - 1].utf8)
            let start = max(0, range.lowerBound.column - 1)
            let doubleTilde = start + 1 < lineBytes.count
                && lineBytes[start] == 0x7E
                && lineBytes[start + 1] == 0x7E
            if !doubleTilde {
                result += escapeText("~")
                descendInto(strikethrough)
                result += escapeText("~")
                return
            }
        }
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination {
            result += "<code>\(escapeText(destination))</code>"
        }
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) {
        result += "<span data-attributes=\"\(escapeAttribute(attributes.attributes))\""

        if options.contains(.parseInlineAttributeClass) {
            let wrappedAttributes = "{\(attributes.attributes)}"
            if let attributesData = wrappedAttributes.data(using: .utf8) {
                struct ParsedAttributes: Decodable {
                    var `class`: String
                }
                let decoder = JSONDecoder()
                decoder.allowsJSON5 = true
                if let parsed = try? decoder.decode(ParsedAttributes.self, from: attributesData) {
                    result += " class=\"\(escapeAttribute(parsed.class))\""
                }
            }
        }

        result += ">"
        descendInto(attributes)
        result += "</span>"
    }
}

private nonisolated func escapeText(_ string: String) -> String {
    var out = ""
    out.reserveCapacity(string.count)
    for ch in string {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        default: out.append(ch)
        }
    }
    return out
}

private nonisolated func escapeTextPreservingInlineTabs(_ string: String) -> String {
    guard string.contains("\t") else { return escapeText(string) }
    return string
        .split(separator: "\t", omittingEmptySubsequences: false)
        .map { escapeText(String($0)) }
        .joined(separator: "<span class=\"md-inline-tab\" aria-hidden=\"true\">&#9;</span>")
}

private nonisolated func escapeAttribute(_ string: String) -> String {
    var out = ""
    out.reserveCapacity(string.count)
    for ch in string {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}
