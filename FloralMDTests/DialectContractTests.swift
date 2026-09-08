//
//  DialectContractTests.swift
//  FloralMDTests
//
//  Dialect-contract corpus (see docs/dialect-contract.md): pins the read-only
//  preview's Markdown dialect to the documented semantics shared with the
//  editor bundle. Every assertion crosses the `MarkdownHTML.render` seam only —
//  no product behavior is changed by these tests.
//

import Foundation
import Testing
@testable import FloralMD

/// Renders markdown to the preview article body via the single external seam.
private func previewArticle(_ markdown: String) -> String {
    MarkdownHTML.render(markdown: markdown).articleHTML
}

@Suite("方言契约：hashtag", .serialized)
struct DialectContractHashtagTests {

    @Test func hashtagTokenRendersCapsule() {
        let html = previewArticle("#tag1 #path/segment #标签")
        #expect(html.contains(#"<span class="md-hashtag" dir="auto">#tag1</span>"#))
        #expect(html.contains(#"<span class="md-hashtag" dir="auto">#path/segment</span>"#))
        #expect(html.contains(#"<span class="md-hashtag" dir="auto">#标签</span>"#))
    }

    @Test func wordAdjacentHashtagStaysPlain() {
        let html = previewArticle("a#tag")
        #expect(!html.contains("md-hashtag"))
    }

    @Test func pureNumberHashtagStaysPlain() {
        let html = previewArticle("#123")
        #expect(!html.contains("md-hashtag"))
    }

    @Test func allHyphenSegmentStaysPlain() {
        let html = previewArticle("#---")
        #expect(!html.contains("md-hashtag"))
    }

    @Test func headingAndLinkTextNeverRenderHashtagCapsules() {
        let heading = previewArticle("# 标题 #tag")
        #expect(heading.contains("<h1"))
        #expect(!heading.contains("md-hashtag"))

        let link = previewArticle("[text #tag](https://example.com)")
        #expect(!link.contains("md-hashtag"))
    }

    @Test func escapedHashtagStaysLiteral() {
        let html = previewArticle("转义 \\#tag 保留")
        #expect(html.contains("#tag 保留"))
        #expect(!html.contains("md-hashtag"))
    }

    @Test func evenBackslashHashtagRendersCapsule() {
        let html = previewArticle("双重 \\\\#tag 保留")
        #expect(html.contains("\\<span class=\"md-hashtag\" dir=\"auto\">#tag</span> 保留"))
    }

    @Test func hashtagRendersInsideTableAndBlockQuote() {
        let table = previewArticle("| 列 |\n| --- |\n| #tag |")
        #expect(table.contains("md-hashtag"))

        let quote = previewArticle("> #tag")
        #expect(quote.contains("md-hashtag"))
    }
}

@Suite("方言契约：裸 marker", .serialized)
struct DialectContractBareMarkerTests {

    @Test func bareMarkerLineStaysParagraph() {
        let html = previewArticle("-")
        #expect(html.contains(#"<p data-source-line="1" data-source-start="1" data-source-end="1">-</p>"#))
        #expect(!html.contains("<ul"))
    }

    @Test func bareStarStaysParagraph() {
        let html = previewArticle("*")
        #expect(html.contains(#"<p data-source-line="1" data-source-start="1" data-source-end="1">*</p>"#))
    }

    @Test func markerWithSpaceIsARealListMarker() {
        let html = previewArticle("- ")
        #expect(html.contains("<ul"))
        #expect(html.contains(#"<li data-source-line="1""#))
        #expect(!html.contains("md-bare-marker"))
    }

    @Test func markerWithTabIsARealListMarker() {
        let html = previewArticle("-\titem")
        #expect(html.contains("<ul"))
        #expect(!html.contains("md-bare-marker"))
    }

    @Test func bareMarkerAfterListItemKeepsListLayout() {
        let html = previewArticle("- item\n-")
        #expect(html.contains(#"<li class="md-bare-marker""#))
        #expect(html.contains(">-</li>")) // marker text in its own list item
    }

    @Test func crlfBareMarkerStaysPlain() {
        let html = previewArticle("-\r\n")
        #expect(html.contains(#"<p data-source-line="1" data-source-start="1" data-source-end="1">-</p>"#))
        #expect(!html.contains("<ul"))
    }

    @Test func blockQuoteBareMarkerStaysPlain() {
        let html = previewArticle("> -")
        #expect(!html.contains("<ul"))
        #expect(html.contains("-"))
    }
}

@Suite("方言契约：删除线", .serialized)
struct DialectContractStrikethroughTests {

    @Test func singleTildeStaysLiteral() {
        let html = previewArticle("~x~")
        #expect(html.contains("~x~"))
        #expect(!html.contains("<del>"))
    }

    @Test func doubleTildeRendersStrikethrough() {
        let html = previewArticle("~~x~~")
        #expect(html.contains("<del>x</del>"))
    }
}

@Suite("方言契约：任务 marker", .serialized)
struct DialectContractTaskTests {

    @Test func uncheckedTaskRendersDisabledCheckbox() {
        let html = previewArticle("- [ ] todo")
        #expect(html.contains(#"<li class="task-list-item""#))
        #expect(html.contains(#"<input type="checkbox" class="task-list-item-checkbox" disabled="" />"#))
        #expect(!html.contains("checked=\"\""))
    }

    @Test func checkedTaskRendersCheckedCheckbox() {
        let html = previewArticle("- [x] done")
        #expect(html.contains(#"<input type="checkbox" class="task-list-item-checkbox" disabled="" checked="" />"#))
    }
}

@Suite("方言契约：Setext", .serialized)
struct DialectContractSetextTests {

    @Test func setextHyphensRenderHorizontalRuleNotHeading() {
        let html = previewArticle("标题\n---")
        #expect(!html.contains("<h2"))
        #expect(html.contains("<hr"))
        #expect(html.contains("<p"))
    }

    @Test func setextEqualsRenderParagraphNotHeading() {
        let html = previewArticle("标题\n===")
        #expect(!html.contains("<h2"))
        #expect(html.contains("===</p>"))
    }

    @Test func setextInsideBlockQuoteNeverBecomesHeading() {
        let html = previewArticle("> 标题\n> ---")
        #expect(!html.contains("<h2"))
        #expect(html.contains("<hr"))
    }

    @Test func crlfSetextNeverBecomesHeading() {
        let html = previewArticle("标题\r\n---\r\n")
        #expect(!html.contains("<h2"))
    }
}

@Suite("方言契约：frontmatter", .serialized)
struct DialectContractFrontmatterTests {

    @Test func yamlFrontmatterRendersAsSection() {
        let html = previewArticle("---\ntitle: 测试\n---\n\n# H")
        #expect(html.contains("md-frontmatter"))
        #expect(html.contains(">H</h1>"))
    }

    @Test func tomlFrontmatterStaysBodyText() {
        let html = previewArticle("+++\nfoo: bar\n+++\n\n# H")
        #expect(!html.contains("md-frontmatter"))
        #expect(html.contains("+++"))
        #expect(html.contains(">H</h1>"))
    }
}

@Suite("方言契约：列表", .serialized)
struct DialectContractListTests {

    @Test func orderedListRendersAsOl() {
        let html = previewArticle("1. a\n2. b")
        #expect(html.contains("<ol"))
        #expect(html.contains("<li"))
    }
}
