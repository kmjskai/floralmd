//
//  RenderPipelineStageTests.swift
//  FloralMDTests
//
//  Focused stage tests for the MarkdownHTML render pipeline's internal seams
//  (see .scratch/markdown-preview-refactor/issues/03). Each stage is verified
//  in isolation so a stage bug no longer hides behind full-document render
//  tests. The external makeHTML/render interface is not exercised here.
//

import Foundation
import Testing
@testable import FloralMD

@Suite("渲染流水线 stage：标题与 RTL", .serialized)
struct RenderPipelineHeadingStageTests {

    @Test func headingIDsAreInjectedInDocumentOrder() {
        let html = MarkdownHTML.injectHeadingIDs(in: "<h1>A</h1>\n<h2>B</h2>")
        #expect(html == "<h1 id=\"md-heading-0\">A</h1>\n<h2 id=\"md-heading-1\">B</h2>")
    }

    @Test func rtlDirectionIsInjectedForRTLParagraphsOnly() {
        let rtl = MarkdownHTML.injectRTLDirection(in: "<p>שלום עולם</p>")
        #expect(rtl.contains("<p dir=\"rtl\">"))

        let ltr = MarkdownHTML.injectRTLDirection(in: "<p>hello world</p>")
        #expect(!ltr.contains("dir="))
    }

    @Test func rtlSourceIsDetectedBeforeTheSlowPath() {
        #expect(MarkdownHTML.sourceMayNeedRTLDirection("שלום"))
        #expect(MarkdownHTML.sourceMayNeedRTLDirection("a &amp; b שלום"))
        #expect(!MarkdownHTML.sourceMayNeedRTLDirection("hello"))
    }
}

@Suite("渲染流水线 stage：脚注", .serialized)
struct RenderPipelineFootnoteStageTests {

    @Test func footnotesAreExtractedWithKeysAndReferences() {
        let extraction = MarkdownHTML.extractFootnotes(from: "text[^1] and [^two]\n\n[^1]: note body\n[^two]: another")
        #expect(extraction.definitions.count == 2)
        #expect(extraction.definitions[0].key == "1")
        #expect(extraction.definitions[0].content == "note body")
        #expect(extraction.references.count == 2)
        #expect(extraction.references[0].number == 1)
        #expect(extraction.references[1].number == 2)
        // Definition lines are lifted out of the body so the parser never
        // sees them as paragraphs.
        #expect(!extraction.markdown.contains("[^1]: note body"))
    }

    @Test func definitionsInsideCodeFencesAreNotFootnotes() {
        let extraction = MarkdownHTML.extractFootnotes(from: "```\n[^1]: not a footnote\n```")
        #expect(extraction.definitions.isEmpty)
        #expect(extraction.references.isEmpty)
    }
}

@Suite("渲染流水线 stage：数学", .serialized)
struct RenderPipelineMathStageTests {

    @Test func mathIsExtractedAndRenderedBack() {
        let extraction = MarkdownHTML.extractMath(from: "inline $x$ and block\n\n$$\ny = 1\n$$")
        #expect(extraction.inlines.count == 1)
        #expect(extraction.blocks.count == 1)
        #expect(!extraction.processedMarkdown.contains("$$"))

        let rendered = MarkdownHTML.renderMathBlocks(in: extraction.processedMarkdown, with: extraction)
        #expect(rendered.containsMath)
        #expect(rendered.html.contains("y = 1"))
        #expect(rendered.html.contains("x"))
    }

    @Test func mathInsideCodeFencesIsNotExtracted() {
        let extraction = MarkdownHTML.extractMath(from: "```swift\nlet x = $5\n```")
        #expect(extraction.inlines.isEmpty)
        #expect(extraction.blocks.isEmpty)
    }

    @Test func renderMathWithoutExtractionIsAPassThrough() {
        let extraction = MarkdownHTML.extractMath(from: "plain")
        let rendered = MarkdownHTML.renderMathBlocks(in: "<p>plain</p>", with: extraction)
        #expect(!rendered.containsMath)
        #expect(rendered.html == "<p>plain</p>")
    }
}

@Suite("渲染流水线 stage：mermaid 与代码高亮", .serialized)
struct RenderPipelineBlockStageTests {

    @Test func mermaidBlocksBecomeFigures() {
        let html = "<pre><code class=\"language-mermaid\">graph TD\nA-->B</code></pre>"
        let result = MarkdownHTML.renderMermaidBlocks(in: html)
        #expect(result.containsMermaid)
        #expect(result.html.contains("mermaid-figure"))
        #expect(!result.html.contains("language-mermaid"))
    }

    @Test func highlightableCodeIsDetectedButMermaidIsNot() {
        #expect(MarkdownHTML.detectHighlightableCode(
            in: "<pre><code class=\"language-swift\">let x = 1</code></pre>"
        ))
        #expect(!MarkdownHTML.detectHighlightableCode(
            in: "<figure class=\"mermaid-figure\"><div class=\"mermaid\"></div></figure>"
        ))
    }
}
