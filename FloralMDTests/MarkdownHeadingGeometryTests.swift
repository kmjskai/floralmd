import Cocoa
import Testing

@testable import FloralMD

@Suite(.serialized)
struct MarkdownHeadingGeometryTests {
    @Test @MainActor func setextSourceNeverCreatesHeadingsAndDashSpaceKeepsListGeometry() async throws {
        let controller = try await makeController(markdown: "普通正文\n-", width: 520)
        try await Task.sleep(for: .milliseconds(50))

        let pending = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const paragraph = view.dom.querySelectorAll('.cm-line')[0];
          const marker = view.dom.querySelectorAll('.cm-line')[1];
          return {
            markdown: view.state.doc.toString(),
            paragraphH2: paragraph?.classList.contains('cm-md-h2') ?? false,
            markerCollapsed: marker?.classList.contains('cm-md-setext-marker-line') ?? false,
            semanticLabels: window.__mdEditor._semanticLabelsForTesting()
          };
        })()
        """)

        _ = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          view.focus();
          const end = view.state.doc.length;
          view.dispatch({
            changes: { from: end, insert: ' 项目' },
            selection: { anchor: end + 3 },
            userEvent: 'input.type'
          });
          return { markdown: view.state.doc.toString() };
        })()
        """)
        try await Task.sleep(for: .milliseconds(50))

        let completed = try await evaluateDictionary(controller, script: """
        (() => {
          const view = window.__mdEditor._viewForTesting;
          const listLine = view.dom.querySelectorAll('.cm-line')[1];
          const paragraphLeft = view.coordsAtPos(0, 1)?.left;
          const bodyLeft = view.coordsAtPos(view.state.doc.line(2).from + 2, 1)?.left;
          const fontSize = parseFloat(getComputedStyle(listLine).fontSize);
          return {
            markdown: view.state.doc.toString(),
            depth1: listLine?.classList.contains('cm-md-list-depth-1') ?? false,
            indent: bodyLeft - paragraphLeft,
            expectedIndent: fontSize * 1.6
          };
        })()
        """)

        let details = "pending=\(pending), completed=\(completed)"
        #expect(pending["markdown"] as? String == "普通正文\n-", Comment(rawValue: details))
        #expect(pending["paragraphH2"] as? Bool == false, Comment(rawValue: details))
        #expect(pending["markerCollapsed"] as? Bool == false, Comment(rawValue: details))
        #expect((pending["semanticLabels"] as? [[String: Any]])?.isEmpty == true,
                Comment(rawValue: details))
        #expect(completed["markdown"] as? String == "普通正文\n- 项目",
                Comment(rawValue: details))
        #expect(completed["depth1"] as? Bool == true, Comment(rawValue: details))
        #expect(abs((completed["indent"] as? Double ?? .infinity)
                    - (completed["expectedIndent"] as? Double ?? 0)) < 0.75,
                Comment(rawValue: details))

        let explicitSetext = try await makeController(markdown: "明确标题\n---", width: 520)
        let heading = try await evaluateDictionary(explicitSetext, script: """
        ({
          h2: document.querySelector('.cm-md-h2') != null,
          rule: document.querySelector('.cm-md-hr') != null,
          markerCollapsed: document.querySelector('.cm-md-setext-marker-line') != null,
          semanticLabels: window.__mdEditor._semanticLabelsForTesting()
        })
        """)
        let headingDetails = "\(heading)"
        #expect(heading["h2"] as? Bool == false, Comment(rawValue: headingDetails))
        #expect(heading["rule"] as? Bool == true, Comment(rawValue: headingDetails))
        #expect(heading["markerCollapsed"] as? Bool == false,
                Comment(rawValue: headingDetails))
        #expect((heading["semanticLabels"] as? [[String: Any]])?.isEmpty == true,
                Comment(rawValue: headingDetails))
    }

    @Test @MainActor func activeHeadingSourceHasNoSyntheticGapAtBodyBoundary() async throws {
        for level in 1...6 {
            for fontSize in [11.0, 15.0, 28.0] {
                let marker = String(repeating: "#", count: level) + " "
                let body = "正文Mixed"
                let controller = try await makeController(
                    markdown: marker + body,
                    width: 720
                )
                controller.applyTypography(
                    MarkdownTypography(fontName: "", fontSize: fontSize, lineHeight: 1.6)
                )
                _ = try await evaluate(controller, script: """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  view.focus();
                  view.dom.classList.add('cm-focused');
                  view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
                  view.dispatch({ selection: { anchor: \(marker.utf16.count) } });
                  view.contentDOM.dispatchEvent(new KeyboardEvent(
                    'keyup', { key: 'ArrowRight', bubbles: true }
                  ));
                  view.requestMeasure();
                  return true;
                })()
                """)
                try await settle()

                let result = try await evaluateDictionary(controller, script: """
                (() => {
                  const view = window.__mdEditor._viewForTesting;
                  const line = document.querySelector('.cm-md-h\(level)');
                  const source = line.querySelector('.cm-md-syntax');
                  const sourceWalker = document.createTreeWalker(source, NodeFilter.SHOW_TEXT);
                  const sourceNodes = [];
                  let sourceNode;
                  while ((sourceNode = sourceWalker.nextNode())) sourceNodes.push(sourceNode);
                  const sourceRange = document.createRange();
                  if (sourceNodes.length) {
                    sourceRange.setStart(sourceNodes[0], 0);
                    const last = sourceNodes[sourceNodes.length - 1];
                    sourceRange.setEnd(last, last.nodeValue.length);
                  } else {
                    sourceRange.selectNode(source);
                  }
                  const sourceTextRect = sourceRange.getBoundingClientRect();
                  const sourceBoxRect = source.getBoundingClientRect();
                  const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
                  let bodyNode;
                  while ((bodyNode = walker.nextNode()) && !bodyNode.nodeValue.includes(\(jsString(body)))) {}
                  const bodyOffset = bodyNode.nodeValue.indexOf(\(jsString(body)));
                  const bodyRange = document.createRange();
                  bodyRange.setStart(bodyNode, bodyOffset);
                  bodyRange.setEnd(bodyNode, bodyOffset + 1);
                  const bodyRect = bodyRange.getBoundingClientRect();
                  const boundary = \(marker.utf16.count);
                  const before = view.coordsAtPos(boundary, -1);
                  const after = view.coordsAtPos(boundary, 1);

                  const key = direction => view.contentDOM.dispatchEvent(new KeyboardEvent(
                    'keydown', { key: direction, bubbles: true, cancelable: true }
                  ));
                  view.dispatch({ selection: { anchor: 0 } });
                  const right = [0];
                  for (let index = 0; index < boundary + 1; index++) {
                    key('ArrowRight');
                    right.push(view.state.selection.main.head);
                  }
                  view.dispatch({ selection: { anchor: boundary + 1 } });
                  const left = [boundary + 1];
                  for (let index = 0; index < boundary + 1; index++) {
                    key('ArrowLeft');
                    left.push(view.state.selection.main.head);
                  }
                  return {
                    sourceTextWidth: sourceTextRect.width,
                    sourceBoxWidth: sourceBoxRect.width,
                    syntheticGap: sourceBoxRect.width - sourceTextRect.width,
                    bodyGap: bodyRect.left - sourceBoxRect.right,
                    boundarySplit: Math.abs((before?.left ?? Infinity) - (after?.left ?? Infinity)),
                    right: JSON.stringify(right),
                    left: JSON.stringify(left),
                    rightOffsetsCorrect: right.every((position, index) => position === index),
                    leftOffsetsCorrect: left.every((position, index) =>
                      position === boundary + 1 - index),
                    measuredWidth: getComputedStyle(line).getPropertyValue(
                      '--cm-md-heading-source-width'),
                    dom: line.innerHTML
                  };
                })()
                """)

                let details = "H\(level) \(fontSize)pt: "
                    + "text=\(result["sourceTextWidth"] ?? "?") "
                    + "box=\(result["sourceBoxWidth"] ?? "?") "
                    + "gap=\(result["syntheticGap"] ?? "?") "
                    + "bodyGap=\(result["bodyGap"] ?? "?") "
                    + "split=\(result["boundarySplit"] ?? "?") "
                    + "right=\(result["right"] ?? "?") left=\(result["left"] ?? "?") "
                    + "measured=\(result["measuredWidth"] ?? "?") "
                    + "dom=\(result["dom"] ?? "?")"
                #expect(abs(result["syntheticGap"] as? Double ?? .infinity) <= 1,
                        Comment(rawValue: details))
                #expect(abs(result["bodyGap"] as? Double ?? .infinity) <= 1,
                        Comment(rawValue: details))
                #expect(abs(result["boundarySplit"] as? Double ?? .infinity) <= 1,
                        Comment(rawValue: details))
                #expect(result["rightOffsetsCorrect"] as? Bool == true,
                        Comment(rawValue: details))
                #expect(result["leftOffsetsCorrect"] as? Bool == true,
                        Comment(rawValue: details))
            }
        }
    }

    @Test @MainActor func inactiveHeadingsReleaseIndentAndSelectedSourceKeepsGeometry() async throws {
        let labels = (1...6).map { "Level\($0)标题" }
        let markdown = labels.enumerated().map { index, label in
            String(repeating: "#", count: index + 1) + " " + label
        }.joined(separator: "\n\n") + "\n\nParagraph baseline"

        for fontSize in [11.0, 15.0, 28.0] {
            let controller = try await makeController(markdown: markdown, width: 720)
            controller.applyTypography(
                MarkdownTypography(fontName: "", fontSize: fontSize, lineHeight: 1.6)
            )
            try await settle()

            let inactive = try await evaluateDictionary(controller, script: """
            (() => {
              const labels = \(jsArray(labels));
              const paragraph = Array.from(document.querySelectorAll('.cm-line'))
                .find(line => line.textContent.includes('Paragraph baseline'));
              const paragraphLeft = paragraph.getBoundingClientRect().left;
              const lefts = labels.map((label, index) => {
                const line = document.querySelector(`.cm-md-h${index + 1}`);
                const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode()) && !node.nodeValue.includes(label)) {}
                const offset = node.nodeValue.indexOf(label);
                const range = document.createRange();
                range.setStart(node, offset);
                range.setEnd(node, offset + 1);
                return range.getBoundingClientRect().left;
              });
              return {
                allInactive: labels.every((_, index) =>
                  document.querySelector(`.cm-md-h${index + 1}`)
                    .classList.contains('cm-md-heading-inactive')),
                lefts: JSON.stringify(lefts),
                maxDelta: Math.max(...lefts.map(left => Math.abs(left - lefts[0]))),
                allAtBodyEdge: lefts.every(left => Math.abs(left - paragraphLeft) <= 1)
              };
            })()
            """)

            #expect(inactive["allInactive"] as? Bool == true)
            #expect(abs(inactive["maxDelta"] as? Double ?? .infinity) <= 1,
                    Comment(rawValue: inactive["lefts"] as? String
                            ?? "missing inactive heading columns"))
            #expect(inactive["allAtBodyEdge"] as? Bool == true)

            _ = try await evaluate(controller, script: """
            (() => {
              const editor = window.__mdEditor;
              const view = editor._viewForTesting;
              const source = editor.getMarkdown();
              const first = source.indexOf(\(jsString(labels[0])));
              const last = source.indexOf(\(jsString(labels[5]))) + \(labels[5].utf16.count);
              view.focus();
              view.dom.classList.add('cm-focused');
              view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
              view.dispatch({ selection: { anchor: first, head: last } });
              view.requestMeasure();
              return true;
            })()
            """)
            try await settle()

            let active = try await evaluateDictionary(controller, script: """
            (() => {
              const labels = \(jsArray(labels));
              const paragraph = Array.from(document.querySelectorAll('.cm-line'))
                .find(line => line.textContent.includes('Paragraph baseline'));
              const paragraphLeft = paragraph.getBoundingClientRect().left;
              const rows = labels.map((label, index) => {
                const line = Array.from(document.querySelectorAll('.cm-line'))
                  .find(candidate => candidate.textContent.includes(label));
                const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode()) && !node.nodeValue.includes(label)) {}
                const offset = node.nodeValue.indexOf(label);
                const body = document.createRange();
                body.setStart(node, offset);
                body.setEnd(node, offset + 1);
                const bodyLeft = body.getBoundingClientRect().left;
                return {
                  bodyLeft,
                  text: line.textContent,
                  preview: line.classList.contains(`cm-md-h${index + 1}`),
                  previewChildren: line.querySelectorAll('.cm-md-syntax').length,
                  sourceGeometry: line.querySelectorAll('.cm-md-heading-source-visible').length
                };
              });
              return {
                allGeometryPreservedSource: rows.every((row, index) =>
                  row.preview && row.previewChildren === 0 && row.sourceGeometry === 1
                    && row.text === `${'#'.repeat(index + 1)} ${labels[index]}`),
                bodiesFollowSource: rows.every(row => row.bodyLeft > paragraphLeft)
              };
            })()
            """)

            #expect(active["allGeometryPreservedSource"] as? Bool == true)
            #expect(active["bodiesFollowSource"] as? Bool == true)
        }
    }

    @Test @MainActor func selectedH1ThroughH6RevealSourceAndShareSelectionCoordinates() async throws {
        for level in 1...6 {
            for fontSize in [11.0, 15.0, 28.0] {
                let scale = [2.0, 1.88, 1.65, 1.41, 1.29, 1.0][level - 1]
                let repeatedCharacters = max(6, Int(360 / (fontSize * scale)))
                let needle = "标题"
                    + String(repeating: "测", count: repeatedCharacters)
                let markdown = String(repeating: "#", count: level)
                    + " \(needle)\n\nParagraph anchor"
                let controller = try await makeController(markdown: markdown, width: 420)
                controller.applyTypography(
                    MarkdownTypography(fontName: "", fontSize: fontSize, lineHeight: 1.6)
                )
                try await settle()

                let inactive = try await evaluateDictionary(
                    controller,
                    script: wrappedHeadingGeometryScript(needle: needle, level: level)
                )

                _ = try await evaluate(
                    controller,
                    script: prepareRangeSelectionScript(needle: needle)
                )
                try await settle()
                let result = try await evaluateDictionary(
                    controller,
                    script: selectedGeometryScript(needle: needle, level: level)
                )

                #expect(result["markdown"] as? String == markdown)
                #expect(result["previewHeading"] as? Bool == true)
                #expect(result["sourceGeometry"] as? Int == 1)
                #expect(result["prefixHidden"] as? Bool == false)
                #expect(result["visibleText"] as? String
                        == String(repeating: "#", count: level) + " \(needle)")
                #expect(inactive["inactive"] as? Bool == true)
                #expect(inactive["prefixHidden"] as? Bool == true)
                #expect((inactive["visualRows"] as? Int ?? 0) >= 2)
                #expect((inactive["visualRows"] as? Int ?? .max) <= 5)
                #expect(abs(inactive["maxRowLeftDelta"] as? Double ?? .infinity) < 1,
                        Comment(rawValue: inactive["rowLefts"] as? String
                                ?? "missing inactive visual rows"))
                #expect((result["visualRows"] as? Int ?? 0) >= 2)
                #expect((result["visualRows"] as? Int ?? .max) <= 5)
                #expect(abs(result["maxRowLeftDelta"] as? Double ?? .infinity) < 1,
                        Comment(rawValue: result["rowLefts"] as? String
                                ?? "missing selected visual rows"))
                #expect(result["hit"] as? Int == result["from"] as? Int)
                #expect(abs(result["coordsDelta"] as? Double ?? .infinity) < 1)
                #expect(abs(result["selectionDelta"] as? Double ?? .infinity) < 1)
                #expect(result["selectionOverlapsText"] as? Bool == true)
                #expect(result["customSelectionLayerCount"] as? Int == 1)
                #expect(result["selectionCount"] as? Int == 1,
                        Comment(rawValue: result["selectionWidths"] as? String
                                ?? "missing selection rectangles"))
                #expect(abs(result["selectionRightDelta"] as? Double ?? .infinity) <= 1)
            }
        }
    }

    @Test @MainActor func narrowWrappedChineseAndEnglishHeadingKeepsEverySelectionRowAligned() async throws {
        let body = "中文EnglishMixedHeading第二视觉行继续换行测试"
        let markdown = "## \(body)\n\nParagraph anchor"
        let controller = try await makeController(markdown: markdown, width: 520)
        controller.applyTypography(
            MarkdownTypography(fontName: "", fontSize: 28, lineHeight: 1.6)
        )

        let setup = """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const from = editor.getMarkdown().indexOf(\(jsString(body)));
          const line = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes(\(jsString(body))));
          const paragraph = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes('Paragraph anchor'));
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode()) && !node.nodeValue.includes(\(jsString(body)))) {}
          const offset = node.nodeValue.indexOf(\(jsString(body)));
          const bodyRange = document.createRange();
          bodyRange.setStart(node, offset);
          bodyRange.setEnd(node, offset + \(body.utf16.count));
          const rows = Array.from(bodyRange.getClientRects())
            .filter(rect => rect.width > 0)
            .map(rect => ({ top: rect.top, left: rect.left }));
          window.__inactiveWrappedHeading = {
            rows,
            height: line.getBoundingClientRect().height,
            paragraphTop: paragraph.getBoundingClientRect().top
          };
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          view.dispatch({ selection: { anchor: from, head: from + \(body.utf16.count) } });
          view.requestMeasure();
          return true;
        })()
        """
        _ = try await evaluate(controller, script: setup)
        try await settle()

        let result = try await evaluateDictionary(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const line = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes(\(jsString(body))));
          const paragraph = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes('Paragraph anchor'));
          const inactive = window.__inactiveWrappedHeading;
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode()) && !node.nodeValue.includes(\(jsString(body)))) {}
          const offset = node.nodeValue.indexOf(\(jsString(body)));
          const textRange = document.createRange();
          textRange.setStart(node, offset);
          textRange.setEnd(node, offset + \(body.utf16.count));
          const textRects = Array.from(textRange.getClientRects());
          const rowStarts = [];
          for (let index = 0; index < \(body.utf16.count); index++) {
            if (/\\s/.test(node.nodeValue[offset + index])) continue;
            const character = document.createRange();
            character.setStart(node, offset + index);
            character.setEnd(node, offset + index + 1);
            const rect = character.getBoundingClientRect();
            const existing = rowStarts.find(row => Math.abs(row.rect.top - rect.top) < 1);
            if (!existing) {
              rowStarts.push({ index, rect });
            } else if (rect.left < existing.rect.left) {
              existing.index = index;
              existing.rect = rect;
            }
          }
          const rowChecks = rowStarts.map(row => {
            const position = editor.getMarkdown().indexOf(\(jsString(body))) + row.index;
            const coordsBefore = view.coordsAtPos(position, -1);
            const coordsAfter = view.coordsAtPos(position, 1);
            const hit = view.posAtCoords({
              x: row.rect.left + 1,
              y: row.rect.top + row.rect.height / 2
            }, true);
            const coordsDelta = Math.min(
              Math.abs((coordsBefore?.left ?? Infinity) - row.rect.left),
              Math.abs((coordsAfter?.left ?? Infinity) - row.rect.left)
            );
            const hitBefore = view.coordsAtPos(hit, -1);
            const hitAfter = view.coordsAtPos(hit, 1);
            const hitCoordsDelta = Math.min(
              Math.abs((hitBefore?.left ?? Infinity) - row.rect.left),
              Math.abs((hitAfter?.left ?? Infinity) - row.rect.left)
            );
            return { position, hit, coordsDelta, hitCoordsDelta };
          });
          return {
            markdown: editor.getMarkdown(),
            previewHeading: line.classList.contains('cm-md-h2'),
            sourceGeometry: line.querySelectorAll('.cm-md-heading-source-visible').length,
            prefixHidden: !!line.querySelector('.cm-md-heading-source-hidden'),
            visibleText: line.textContent,
            textRows: textRects.length,
            measuredRows: rowStarts.length,
            inactiveRows: inactive.rows.length,
            inactiveLefts: JSON.stringify(inactive.rows.map(row => row.left)),
            activeLefts: JSON.stringify(textRects.map(rect => rect.left)),
            inactiveMaxLeftDelta: Math.max(...inactive.rows.map(row =>
              Math.abs(row.left - inactive.rows[0].left))),
            activeMaxLeftDelta: Math.max(...textRects.map(rect =>
              Math.abs(rect.left - textRects[0].left))),
            inactiveSecondRowDelta: inactive.rows[1].left - inactive.rows[0].left,
            activeSecondRowDelta: textRects[1].left - textRects[0].left,
            plainSourceWrap: textRects[0].left > paragraph.getBoundingClientRect().left
              && textRects.slice(1).every(rect =>
                Math.abs(rect.left - paragraph.getBoundingClientRect().left) < 1),
            rowCountStable: textRects.length === inactive.rows.length,
            headingHeightDelta: line.getBoundingClientRect().height - inactive.height,
            paragraphTopDelta: paragraph.getBoundingClientRect().top - inactive.paragraphTop,
            coordsAligned: rowChecks.every(row => row.coordsDelta < 1),
            hitsAligned: rowChecks.every(row => row.hitCoordsDelta < 1),
            hitDetails: JSON.stringify(rowChecks)
          };
        })()
        """)

        #expect(result["markdown"] as? String == markdown)
        #expect(result["previewHeading"] as? Bool == true)
        #expect(result["sourceGeometry"] as? Int == 1)
        #expect(result["prefixHidden"] as? Bool == false)
        #expect(result["visibleText"] as? String == "## \(body)")
        #expect((result["textRows"] as? Int ?? 0) >= 2)
        #expect((result["measuredRows"] as? Int ?? 0) >= 2)
        #expect(abs(result["inactiveMaxLeftDelta"] as? Double ?? .infinity) < 1,
                Comment(rawValue: result["inactiveLefts"] as? String ?? "missing inactive rows"))
        #expect(abs(result["activeMaxLeftDelta"] as? Double ?? .infinity) < 1,
                Comment(rawValue: result["activeLefts"] as? String ?? "missing selected rows"))
        #expect(abs(result["inactiveSecondRowDelta"] as? Double ?? .infinity) < 1)
        #expect(abs(result["activeSecondRowDelta"] as? Double ?? .infinity) < 1)
        #expect(result["coordsAligned"] as? Bool == true)
        #expect(result["hitsAligned"] as? Bool == true,
                Comment(rawValue: result["hitDetails"] as? String ?? "missing hit details"))
    }

    @Test @MainActor func reverseRangeRevealsHeadingsAndRestoresLayoutAndOffsets() async throws {
        let first = "First 中文 heading wraps across the narrow viewport with stable geometry"
        let second = "Second 标题"
        let markdown = "## \(first)\n\nParagraph between\n\n#### \(second)\n\nParagraph anchor"
        let controller = try await makeController(markdown: markdown, width: 720)
        controller.applyTypography(
            MarkdownTypography(fontName: "", fontSize: 15, lineHeight: 1.6)
        )
        try await settle()

        _ = try await evaluate(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const markdown = editor.getMarkdown();
          const firstFrom = markdown.indexOf(\(jsString(first)));
          const secondFrom = markdown.indexOf(\(jsString(second)));
          const paragraphFrom = markdown.indexOf('Paragraph between');
          const headings = () => [\(jsString(first)), \(jsString(second))].map(label =>
            Array.from(document.querySelectorAll('.cm-line'))
              .find(line => line.textContent.includes(label)));
          const paragraphLine = () => Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Paragraph between'));
          const before = headings().map(line => line.getBoundingClientRect().height);
          const paragraphTopBefore = paragraphLine().getBoundingClientRect().top;

          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          const anchor = secondFrom + \(second.utf16.count);
          const head = firstFrom + 3;
          window.__headingRangeBaseline = {
            anchor, head, before, paragraphTopBefore
          };
          view.dispatch({ selection: { anchor, head }, scrollIntoView: true });
          view.requestMeasure();
          return true;
        })()
        """)
        try await settle()

        let result = try await evaluateDictionary(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const headings = () => [\(jsString(first)), \(jsString(second))].map(label =>
            Array.from(document.querySelectorAll('.cm-line'))
              .find(line => line.textContent.includes(label)));
          const paragraphLine = () => Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Paragraph between'));
          const baseline = window.__headingRangeBaseline;

          const activeHeadings = headings();
          const selection = view.state.selection.main;
          const after = activeHeadings.map(line => line.getBoundingClientRect().height);
          const paragraphTopAfter = paragraphLine().getBoundingClientRect().top;
          const active = activeHeadings.every(line =>
            (line.classList.contains('cm-md-h2')
              || line.classList.contains('cm-md-h4'))
              && !line.querySelector('.cm-md-heading-source-hidden')
              && !line.querySelector('.cm-md-syntax')
              && !!line.querySelector('.cm-md-heading-source-visible'));
          const visible = activeHeadings.map(line => line.textContent);

          return {
            markdown: editor.getMarkdown(), anchor: selection.anchor, head: selection.head,
            expectedAnchor: baseline.anchor, expectedHead: baseline.head, active,
            visible: JSON.stringify(visible),
            heightDeltas: JSON.stringify(after.map((height, index) => height - baseline.before[index])),
            heightsStable: after.every((height, index) =>
              Math.abs(height - baseline.before[index]) < 1),
            paragraphTopDelta: paragraphTopAfter - baseline.paragraphTopBefore
          };
        })()
        """)

        _ = try await evaluate(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const paragraphFrom = editor.getMarkdown().indexOf('Paragraph between');
          view.dispatch({ selection: { anchor: paragraphFrom } });
          view.requestMeasure();
          return true;
        })()
        """)
        try await settle()
        let hiddenAfterLeaving = try await evaluateDictionary(controller, script: """
        (() => {
          const headings = Array.from(document.querySelectorAll('.cm-md-h2, .cm-md-h4'));
          const paragraph = Array.from(document.querySelectorAll('.cm-line'))
            .find(line => line.textContent.includes('Paragraph between'));
          const baseline = window.__headingRangeBaseline;
          const heights = headings.map(line => line.getBoundingClientRect().height);
          return {
            hidden: headings.length === 2 && headings.every(line =>
              line.classList.contains('cm-md-heading-inactive')
                && !!line.querySelector('.cm-md-heading-source-hidden')),
            heightsRestored: heights.every((height, index) =>
              Math.abs(height - baseline.before[index]) < 1),
            paragraphTopRestored: Math.abs(
              paragraph.getBoundingClientRect().top - baseline.paragraphTopBefore
            ) < 1
          };
        })()
        """)

        #expect(result["markdown"] as? String == markdown)
        #expect(result["anchor"] as? Int == result["expectedAnchor"] as? Int)
        #expect(result["head"] as? Int == result["expectedHead"] as? Int)
        #expect(result["active"] as? Bool == true,
                Comment(rawValue: result["visible"] as? String ?? "missing headings"))
        #expect(result["heightsStable"] as? Bool == true,
                Comment(rawValue: result["heightDeltas"] as? String ?? "missing heights"))
        #expect(abs(result["paragraphTopDelta"] as? Double ?? .infinity) < 1)
        #expect(hiddenAfterLeaving["hidden"] as? Bool == true)
        #expect(hiddenAfterLeaving["heightsRestored"] as? Bool == true)
        #expect(hiddenAfterLeaving["paragraphTopRestored"] as? Bool == true)
    }

    @Test @MainActor func clickActivationCaretKeyboardAndUndoPreserveSourceOffsets() async throws {
        let markdown = "## Click target 标题\n\nParagraph anchor"
        let body = "Click target 标题"
        let controller = try await makeController(markdown: markdown, width: 360)

        let hit = try await evaluateDictionary(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const from = editor.getMarkdown().indexOf(\(jsString(body)));
          const line = document.querySelector('.cm-md-h2');
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode()) && !node.nodeValue.includes(\(jsString(body)))) {}
          const offset = node.nodeValue.indexOf(\(jsString(body)));
          const range = document.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + 1);
          const rect = range.getBoundingClientRect();
          return {
            from,
            hit: view.posAtCoords({ x: rect.left + 1, y: rect.top + rect.height / 2 }, true),
            inactive: line.classList.contains('cm-md-heading-inactive')
          };
        })()
        """)
        #expect(hit["inactive"] as? Bool == true)
        #expect(hit["hit"] as? Int == hit["from"] as? Int)

        let from = try #require(hit["from"] as? Int)
        _ = try await evaluate(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = window.__mdEditor._viewForTesting;
          editor._setCompositionActiveForTesting(true);
          view.focus();
          view.dispatch({ selection: { anchor: \(from) }, scrollIntoView: true });
          view.requestMeasure();
          return true;
        })()
        """)
        try await settle()

        let active = try await evaluateDictionary(controller, script: """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const line = document.querySelector('.cm-md-h2');
          const coords = view.coordsAtPos(\(from), 1);
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode()) && !node.nodeValue.includes(\(jsString(body)))) {}
          const offset = node.nodeValue.indexOf(\(jsString(body)));
          const range = document.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + 1);
          const bodyRect = range.getBoundingClientRect();
          view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'ArrowRight', code: 'ArrowRight', shiftKey: true,
            bubbles: true, cancelable: true
          }));
          const selection = view.state.selection.main;
          return {
            markdown: editor.getMarkdown(),
            active: !line.classList.contains('cm-md-heading-inactive'),
            visibleText: line.textContent,
            caretCoordsDelta: coords ? coords.left - bodyRect.left : null,
            selectionFrom: selection.from,
            selectionTo: selection.to
          };
        })()
        """)
        #expect(active["markdown"] as? String == markdown)
        #expect(active["active"] as? Bool == true)
        #expect(active["visibleText"] as? String == "## \(body)")
        #expect(abs(active["caretCoordsDelta"] as? Double ?? .infinity) < 1)
        #expect(active["selectionFrom"] as? Int == from)
        #expect(active["selectionTo"] as? Int == from + 1)

        _ = try await evaluate(
            controller,
            script: "window.__mdEditor._setCompositionActiveForTesting(false)"
        )
        _ = try await evaluate(controller, script: "window.__mdEditor.insert('X')")
        _ = try await evaluate(controller, script: "window.__mdEditor._undoForTesting()")
        try await settle()
        let restored = try await currentMarkdown(in: controller)
        #expect(restored == markdown)
    }

    @MainActor
    private func makeController(markdown: String, width: CGFloat) async throws
        -> CodeMirrorEditorViewController {
        let controller = CodeMirrorEditorViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        controller.load(markdown: markdown)
        for _ in 0..<100 {
            let ready = await withCheckedContinuation { continuation in
                controller.inspectEditorState { continuation.resume(returning: $0.isReady) }
            }
            if ready { return controller }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("CodeMirror did not become ready")
        return controller
    }

    private func prepareRangeSelectionScript(needle: String) -> String {
        """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const needle = \(Self.jsString(needle));
          const from = editor.getMarkdown().indexOf(needle);
          view.focus();
          view.dom.classList.add('cm-focused');
          view.contentDOM.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
          view.dispatch({ selection: { anchor: from, head: from + 1 }, scrollIntoView: true });
          view.requestMeasure();
          return true;
        })()
        """
    }

    private func selectedGeometryScript(needle: String, level: Int) -> String {
        """
        (() => {
          const editor = window.__mdEditor;
          const view = editor._viewForTesting;
          const needle = \(Self.jsString(needle));
          const from = editor.getMarkdown().indexOf(needle);
          const line = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes(needle));
          const paragraph = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes('Paragraph anchor'));
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode()) && !node.nodeValue.includes(needle)) {}
          const offset = node.nodeValue.indexOf(needle);
          const range = document.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + 1);
          const textRect = range.getBoundingClientRect();
          const bodyRange = document.createRange();
          bodyRange.setStart(node, offset);
          bodyRange.setEnd(node, offset + needle.length);
          const visualRows = Array.from(bodyRange.getClientRects())
            .filter(rect => rect.width > 0);
          const coords = view.coordsAtPos(from, 1);
          const hit = view.posAtCoords({
            x: textRect.left + 1,
            y: textRect.top + textRect.height / 2
          }, true);
          const selections = Array.from(document.querySelectorAll('.cm-selectionBackground'))
            .map(element => element.getBoundingClientRect())
            .filter(rect => rect.width > 0
              && rect.bottom > textRect.top && rect.top < textRect.bottom);
          const selection = selections.find(rect =>
            rect.right > textRect.left && rect.left < textRect.right
          );
          return {
            markdown: editor.getMarkdown(), from, hit,
            previewHeading: line.classList.contains('cm-md-h\(level)'),
            sourceGeometry: line.querySelectorAll('.cm-md-heading-source-visible').length,
            prefixHidden: !!line.querySelector('.cm-md-heading-source-hidden'),
            visibleText: line.textContent,
            visualRows: visualRows.length,
            rowLefts: JSON.stringify(visualRows.map(rect => rect.left)),
            maxRowLeftDelta: Math.max(...visualRows.map(rect =>
              Math.abs(rect.left - visualRows[0].left))),
            plainSourceWrap: visualRows.length <= 1
              || (visualRows[0].left > paragraph.getBoundingClientRect().left
                && visualRows.slice(1).every(rect =>
                  Math.abs(rect.left - paragraph.getBoundingClientRect().left) < 1)),
            lineHeight: line.getBoundingClientRect().height,
            paragraphTop: paragraph.getBoundingClientRect().top,
            coordsDelta: coords ? coords.left - textRect.left : null,
            selectionDelta: selection ? selection.left - textRect.left : null,
            selectionCount: selections.length,
            selectionRightDelta: selection ? selection.right - textRect.right : null,
            selectionWidths: JSON.stringify(selections.map(rect => rect.width)),
            customSelectionLayerCount: document.querySelectorAll('.cm-selectionLayer').length,
            selectionOverlapsText: !!selection
              && selection.right > textRect.left && selection.left < textRect.right
          };
        })()
        """
    }

    private func wrappedHeadingGeometryScript(needle: String, level: Int) -> String {
        """
        (() => {
          const needle = \(Self.jsString(needle));
          const line = document.querySelector('.cm-md-h\(level)');
          const paragraph = Array.from(document.querySelectorAll('.cm-line'))
            .find(candidate => candidate.textContent.includes('Paragraph anchor'));
          const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode()) && !node.nodeValue.includes(needle)) {}
          const offset = node.nodeValue.indexOf(needle);
          const bodyRange = document.createRange();
          bodyRange.setStart(node, offset);
          bodyRange.setEnd(node, offset + needle.length);
          const visualRows = Array.from(bodyRange.getClientRects())
            .filter(rect => rect.width > 0);
          return {
            inactive: line.classList.contains('cm-md-heading-inactive'),
            prefixHidden: !!line.querySelector('.cm-md-heading-source-hidden'),
            visualRows: visualRows.length,
            rowLefts: JSON.stringify(visualRows.map(rect => rect.left)),
            maxRowLeftDelta: Math.max(...visualRows.map(rect =>
              Math.abs(rect.left - visualRows[0].left))),
            lineHeight: line.getBoundingClientRect().height,
            paragraphTop: paragraph.getBoundingClientRect().top
          };
        })()
        """
    }

    @MainActor
    private func currentMarkdown(in controller: CodeMirrorEditorViewController) async throws -> String {
        let value = try await evaluate(controller, script: "window.__mdEditor.getMarkdown()")
        return try #require(value as? String)
    }

    @MainActor
    private func evaluateDictionary(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> [String: Any] {
        let value = try await evaluate(controller, script: script)
        return try #require(value as? [String: Any])
    }

    @MainActor
    private func evaluate(
        _ controller: CodeMirrorEditorViewController,
        script: String
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            controller.evaluateEditorJavaScriptWithError(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private func jsString(_ value: String) -> String { Self.jsString(value) }

    private func jsArray(_ values: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: values)
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
