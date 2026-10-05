// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
// The UIKit reading surface (iOS port, phase 2).  iOS only.
#if os(iOS)
import MarkdownCore
import Testing
import UIKit

@testable import MarkdownRender

@MainActor
@Suite("UIKit reading surface")
struct ReaderViewTests {
    nonisolated static let sample = """
    ---
    title: Reader
    ---

    # Reader title

    Some **bold** text, `code`, and [a link](https://example.com) plus [jump](#math).

    - A plain bullet
    - A bullet with `inline code`
      - A nested bullet
    1. First
    2. Second

    - [x] done
    - [ ] open

    > [!NOTE]
    > A callout.

    ```swift
    let x = 1
    ```

    | A | B |
    |---|---|
    | 1 | 2 |

    ## Math

    $$
    x^2
    $$

    A claim[^n].

    [^n]: The footnote body.
    """

    private func makeView(_ text: String = Self.sample) -> MarkdownReaderView {
        let sheet = StyleSheet(theme: .fallback, appearance: UITraitCollection(userInterfaceStyle: .light))
        let view = MarkdownReaderView(styleSheet: sheet)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        view.setMarkdown(text)
        view.layoutIfNeeded()
        return view
    }

    private func offset(of needle: String, in text: String = Self.sample) -> Int {
        (text as NSString).range(of: needle).location
    }

    @Test("The storage holds the source verbatim")
    func storageIsSource() {
        let view = makeView()
        #expect(view.textStorage.string == Self.sample)
    }

    @Test("Inline markers are hidden through the display map")
    func markersHidden() {
        let view = makeView()
        let bold = offset(of: "**bold**")
        let hidden = view.displayMap.hiddenRanges(inParagraphContaining: bold)
        #expect(hidden.contains(NSRange(location: bold, length: 2)))
        #expect(view.textStorage.attribute(.drHidden, at: bold, effectiveRange: nil) as? Bool == true)
    }

    @Test("Hit-testing a link's own rectangle finds that link")
    func linkHitTest() throws {
        let view = makeView()
        let start = offset(of: "a link")
        let rect = try #require(view.rect(forSourceOffset: start + 2))
        let hit = try #require(view.link(at: CGPoint(x: rect.minX + 1, y: rect.midY)))
        #expect(hit.destination == "https://example.com")
        #expect(view.sourceOffset(at: CGPoint(x: rect.minX + 1, y: rect.midY)) == start + 2)
    }

    @Test("Anchor navigation scrolls to the heading")
    func anchorScroll() throws {
        let view = makeView(Self.sample + String(repeating: "\n\nFiller paragraph.", count: 80))
        let before = view.contentOffset.y
        #expect(view.scroll(toHeadingSlug: "math", animated: false))
        #expect(view.contentOffset.y > before + 100)
        let heading = try #require(view.parsedDocument.headings.first { $0.slug == "math" })
        let rect = try #require(view.rect(forSourceOffset: heading.contentRange.location))
        #expect(abs(rect.minY - (view.contentOffset.y + view.adjustedContentInset.top)) < 80)
    }

    @Test("A previous document does not change the next one's paragraph styles")
    func decorationDoesNotLeakAcrossDocuments() throws {
        let readme = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8)
        func styles(_ view: MarkdownReaderView) -> [String] {
            let storage = view.textStorage
            var out: [String] = []
            (storage.string as NSString).enumerateSubstrings(
                in: NSRange(location: 0, length: storage.length), options: .byParagraphs
            ) { _, range, _, _ in
                guard range.length > 0,
                      let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                        as? NSParagraphStyle else { return }
                out.append("\(range.location): before=\(style.paragraphSpacingBefore) after=\(style.paragraphSpacing) head=\(style.headIndent) first=\(style.firstLineHeadIndent) min=\(style.minimumLineHeight)")
            }
            return out
        }
        let fresh = styles(makeView())
        let reused = makeView(readme)
        reused.setMarkdown(Self.sample)
        let after = styles(reused)
        #expect(fresh.count == after.count)
        for (a, b) in zip(fresh, after) where a != b {
            Issue.record("fresh \(a)\nreused \(b)")
        }
    }

    @Test("The scroll content covers the whole document")
    func contentHeightCoversDocument() throws {
        let long = Self.sample + String(repeating: "\n\nFiller paragraph that wraps across a line or two on a phone.", count: 60)
        let view = makeView(long)
        let last = try #require(view.rect(forSourceOffset: long.utf16.count - 1))
        #expect(view.contentSize.height >= last.maxY)
        #expect(view.contentSize.height > view.bounds.height * 2)
        // Scrolling to the end stays there: nothing clamps it back.
        let bottom = view.contentSize.height - view.bounds.height
        view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        view.layoutIfNeeded()
        #expect(abs(view.contentOffset.y - bottom) < 1,
                "offset \(view.contentOffset.y) bottom \(bottom) size \(view.contentSize.height) bounds \(view.bounds.height) adjusted \(view.adjustedContentInset)")
    }

    @Test("Accessibility reads the rendered text, not the Markdown syntax")
    func accessibilityReadsRenderedText() {
        let view = makeView()
        let spoken = view.accessibilityValue ?? ""
        #expect(spoken.contains("Some bold text"))
        #expect(!spoken.contains("**"))
        #expect(!spoken.contains("](https://"))
        #expect(view.textStorage.string == Self.sample)
    }

    @Test("Rotating lays out exactly as opening in that orientation")
    func rotationMatchesFreshLayout() throws {
        let long = Self.sample + String(repeating: "\n\nFiller paragraph that wraps across a line or two on a phone.", count: 30)
        let rotated = makeView(long)
        let portraitColumn = rotated.textContainer.size.width
        rotated.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        rotated.layoutIfNeeded()

        let sheet = StyleSheet(theme: .fallback, appearance: UITraitCollection(userInterfaceStyle: .light))
        let fresh = MarkdownReaderView(styleSheet: sheet)
        fresh.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        fresh.setMarkdown(long)
        fresh.layoutIfNeeded()

        #expect(rotated.textContainer.size.width > portraitColumn)
        #expect(rotated.textContainer.size.width == fresh.textContainer.size.width)
        #expect(abs(rotated.contentSize.height - fresh.contentSize.height) < 1,
                "rotated \(rotated.contentSize.height) fresh \(fresh.contentSize.height)")
        let last = try #require(rotated.rect(forSourceOffset: long.utf16.count - 1))
        #expect(last.maxX <= rotated.textContainerInset.left + rotated.textContainer.size.width + 1)
        #expect(rotated.contentSize.height >= last.maxY)
    }

    @Test("The outline lists headings and tracks the section on screen")
    func outlineTracksPosition() throws {
        let long = Self.sample + String(repeating: "\n\nFiller paragraph.", count: 60)
        let view = makeView(long)
        #expect(view.outline.map(\.title) == ["Reader title", "Math"])
        #expect(view.outline.map(\.level) == [1, 2])
        // The front matter card sits above the first heading.
        #expect(view.currentOutlineIndex == nil)
        view.scroll(toSourceOffset: view.outline[0].sourceOffset, animated: false)
        view.layoutIfNeeded()
        #expect(view.currentOutlineIndex == 0)
        view.scroll(toSourceOffset: view.outline[1].sourceOffset, animated: false)
        view.layoutIfNeeded()
        #expect(view.currentOutlineIndex == 1)
    }

    @Test("VoiceOver rotors step through headings and links")
    func rotors() throws {
        let view = makeView()
        let rotors = try #require(view.accessibilityCustomRotors)
        let headings = try #require(rotors.first { $0.name == "Headings" })
        let links = try #require(rotors.first { $0.name == "Links" })

        func step(_ rotor: UIAccessibilityCustomRotor, from item: UIAccessibilityCustomRotorItemResult?) -> UIAccessibilityCustomRotorItemResult? {
            let predicate = UIAccessibilityCustomRotorSearchPredicate()
            predicate.searchDirection = .next
            predicate.currentItem = item ?? UIAccessibilityCustomRotorItemResult(targetElement: view, targetRange: nil)
            return rotor.itemSearchBlock(predicate)
        }
        func start(_ item: UIAccessibilityCustomRotorItemResult?) -> Int? {
            item?.targetRange.map { view.offset(from: view.beginningOfDocument, to: $0.start) }
        }
        let first = step(headings, from: nil)
        #expect(start(first) == offset(of: "# Reader title"))
        let second = step(headings, from: first)
        #expect(start(second) == offset(of: "## Math"))
        #expect(step(headings, from: second) == nil)
        // The link's text, not its opening bracket, which is hidden.
        #expect(start(step(links, from: nil)) == offset(of: "a link]"))
    }

    @Test("Split View and Slide Over widths keep text inside the column")
    func splitWidths() throws {
        let long = Self.sample + String(repeating: "\n\nA paragraph long enough to wrap at every one of these widths, more or less.", count: 10)
        for width in [320.0, 507, 694, 1032] as [CGFloat] {
            let sheet = StyleSheet(theme: .fallback, appearance: UITraitCollection(userInterfaceStyle: .light))
            let view = MarkdownReaderView(styleSheet: sheet)
            view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
            view.setMarkdown(long)
            view.layoutIfNeeded()
            let inset = view.textContainerInset
            let column = view.textContainer.size.width
            #expect(inset.left >= 16 && inset.left + column <= width - 15, "width \(width): \(inset) column \(column)")
            for offset in stride(from: 0, to: long.utf16.count, by: 53) {
                guard let rect = view.rect(forSourceOffset: offset) else { continue }
                #expect(rect.maxX <= inset.left + column + 1, "width \(width) offset \(offset)")
            }
            let last = try #require(view.rect(forSourceOffset: long.utf16.count - 1))
            #expect(view.contentSize.height >= last.maxY, "width \(width)")
        }
    }

    /// Timings are printed, not asserted: simulator numbers say nothing about
    /// a device.  What is asserted is that the end of the document is reachable.
    private func exerciseLargeDocument(copies: Int, label: String) throws {
        let text = String(repeating: Self.sample + "\n\n", count: copies)
        let paragraphs = text.components(separatedBy: "\n").count
        let sheet = StyleSheet(theme: .fallback, appearance: UITraitCollection(userInterfaceStyle: .light))
        let view = MarkdownReaderView(styleSheet: sheet)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
        let clock = ContinuousClock()
        let open = clock.measure {
            view.setMarkdown(text)
            view.layoutIfNeeded()
        }
        var scrolls: [Duration] = []
        for step in 1...8 {
            let target = (view.contentSize.height - view.bounds.height) * CGFloat(step) / 8
            scrolls.append(clock.measure {
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                view.layoutIfNeeded()
            })
        }
        // Keep going to the end until the height stops growing.
        for _ in 0..<20 {
            let bottom = view.contentSize.height - view.bounds.height
            view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            view.layoutIfNeeded()
            if abs(view.contentSize.height - view.bounds.height - bottom) < 1 { break }
        }
        let last = try #require(view.rect(forSourceOffset: text.utf16.count - 1))
        let visible = CGRect(origin: view.contentOffset, size: view.bounds.size)
        print("PERF \(label): \(text.utf16.count) chars, \(paragraphs) lines, open \(open), scroll steps max \(scrolls.max()!), height \(Int(view.contentSize.height))")
        #expect(view.contentSize.height >= last.maxY, "\(label): end beyond content")
        #expect(visible.maxY >= last.minY, "\(label): end not reachable")
    }

    @Test("A large document within the full-layout budget opens and scrolls to its end")
    func largeEagerDocument() throws {
        try exerciseLargeDocument(copies: 60, label: "eager")
    }

    @Test("A document over the full-layout budget still scrolls to its end")
    func largeEstimatedDocument() throws {
        try exerciseLargeDocument(copies: 140, label: "estimated")
    }

    @Test("Tapping a code block's copy control copies the code without fences")
    func copyControl() throws {
        let view = makeView()
        let fence = try #require(view.rect(forSourceOffset: offset(of: "```swift")))
        let x = view.textContainerInset.left + view.textContainer.size.width - 22
        let payload = try #require(view.codeCopyTarget(at: CGPoint(x: x, y: fence.midY)))
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        view.pasteboard = pasteboard
        view.copyCode(payload)
        #expect(pasteboard.string == "let x = 1")
        #expect(view.codeCopyTarget(at: CGPoint(x: view.textContainerInset.left + 4, y: fence.midY + 40)) == nil)
    }

    @Test("A footnote reference resolves to its definition text")
    func footnoteTap() throws {
        let view = makeView()
        let reference = offset(of: "[^n].")
        let rect = try #require(view.rect(forSourceOffset: reference))
        let hit = try #require(view.footnote(at: CGPoint(x: rect.minX + 2, y: rect.midY)))
        #expect(hit.identifier == "n")
        #expect(view.footnoteText("n") == "The footnote body.")
    }

    @Test("Text wraps inside the reading column on a wide view")
    func columnHoldsOnWideView() throws {
        let long = String(repeating: "word ", count: 120)
        let sheet = StyleSheet(theme: .fallback, appearance: UITraitCollection(userInterfaceStyle: .light))
        let view = MarkdownReaderView(styleSheet: sheet)
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        view.setMarkdown(long)
        view.layoutIfNeeded()
        let column = view.textContainer.size.width
        #expect(column < 700)
        let inset = view.textContainerInset
        #expect(abs((view.bounds.width - inset.left - inset.right) - column) < 1)
        for offset in stride(from: 0, to: long.utf16.count, by: 37) {
            let rect = try #require(view.rect(forSourceOffset: offset))
            #expect(rect.maxX <= inset.left + column + 1)
        }
    }

    @Test("A full-width measure fills a wide view, inside the margins")
    func fullWidthFillsWideView() throws {
        let long = String(repeating: "word ", count: 400)
        var theme = Theme.fallback
        theme.typography.measureCharacters = ReadingMeasure.maximumCharacters
        let sheet = StyleSheet(theme: theme, appearance: UITraitCollection(userInterfaceStyle: .light))
        let view = MarkdownReaderView(styleSheet: sheet)
        // iPad Air 11-inch, landscape.
        view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        view.setMarkdown(long)
        view.layoutIfNeeded()
        let column = view.textContainer.size.width
        let inset = view.textContainerInset
        #expect(column > 1000, "column \(column)")
        #expect(inset.left >= 16 && inset.left + column <= view.bounds.width - 15)
        var widest: CGFloat = 0
        for offset in stride(from: 0, to: long.utf16.count, by: 37) {
            let rect = try #require(view.rect(forSourceOffset: offset))
            #expect(rect.maxX <= inset.left + column + 1)
            widest = max(widest, rect.maxX)
        }
        #expect(widest > 900, "text reached \(widest)")
    }

    // Images that start their own line.  An image inside a paragraph or a
    // link (`<p><img></p>`, a badge) is not drawn as a picture yet, local or
    // remote: fragments are found at the start of a paragraph.
    @Test("Remote images are requested only when the host installs a loader")
    func remoteImagesNeedALoader() throws {
        let markdown = """
            ![shot](https://img.example/shot.png)

            <img src="https://img.example/badge.svg" alt="badge" width="90">
            """
        let view = makeView(markdown)
        #expect(view.remoteImageLoader == nil)

        let loader = StubRemoteImageLoader()
        view.remoteImageLoader = loader
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        view.layoutIfNeeded()
        // Fragments ask while drawing; render the view once to drive that.
        _ = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        #expect(Set(loader.requested.map(\.absoluteString))
                == ["https://img.example/shot.png", "https://img.example/badge.svg"])
    }

    @Test("Images inside a line become attachments; the source is untouched")
    func inlineImagesBecomeAttachments() throws {
        let markdown = """
            Look ![b](https://img.example/b.png) here.

            <p align="center"><a href="https://example.com"><img src="https://img.example/c.png" alt="c"></a></p>
            """
        let view = makeView(markdown)
        // No loader: Markdown shows its alt text, remote HTML stays inert.
        #expect(!view.renderedText.contains("\u{FFFC}"))
        #expect(view.renderedText.contains("Look b here."))
        #expect(view.renderedText.contains("<img"))

        let loader = StubRemoteImageLoader()
        loader.image = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 20)).image { _ in }
        view.remoteImageLoader = loader
        #expect(view.renderedText.components(separatedBy: "\u{FFFC}").count - 1 == 2)
        #expect(!view.renderedText.contains("<img"))
        #expect(view.textStorage.string == markdown)
    }

    @Test("A picture that arrives later replaces its alt text")
    func inlineImageArrivalRefreshes() async throws {
        let view = makeView("Badge ![ok](https://img.example/ok.png) inline.")
        let loader = StubRemoteImageLoader()
        view.remoteImageLoader = loader
        #expect(view.renderedText.contains("Badge ok inline."))
        #expect(loader.requested.map(\.absoluteString) == ["https://img.example/ok.png"])

        loader.image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in }
        loader.finishAll()
        for _ in 0..<20 where !view.renderedText.contains("\u{FFFC}") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.renderedText.contains("Badge \u{FFFC} inline."))
    }

    @Test("An HTML paragraph written one element per line reads as one line")
    func htmlParagraphLinesJoin() {
        let markdown = """
            <p align="center">
              <a href="https://example.com/a">Website</a> ·
              <a href="https://example.com/b">Releases</a>
            </p>
            """
        let view = makeView(markdown)
        let shown = view.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(shown == "Website · Releases", "\(shown.debugDescription)")
        #expect(view.textStorage.string == markdown)
    }

    @Test("A tall inline image opens its line instead of overflowing it")
    func tallInlineImageGrowsItsLine() throws {
        let markdown = """
            <p align="center">
              <a href="https://example.com"><img src="https://img.example/logo.png" width="96" alt="logo"></a>
            </p>

            After.
            """
        let view = makeView(markdown)
        let loader = StubRemoteImageLoader()
        loader.image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { _ in }
        view.remoteImageLoader = loader
        view.layoutIfNeeded()
        var first: CGRect?
        let manager = try #require(view.textLayoutManager)
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            guard fragment.layoutFragmentFrame.width > 1 else { return true }
            first = fragment.layoutFragmentFrame
            return false
        }
        let frame = try #require(first)
        // `width="96"` sizes the 512-point picture; the line holds all of it.
        #expect(abs(frame.width - 96) < 1, "\(frame)")
        #expect(frame.height >= 96, "\(frame)")
    }

    @Test("width and height attributes are read from the tag")
    func inlineImageDimensions() {
        #expect(InlineImageDisplay.dimension("width", in: #"<img src="a.png" width="128" alt="x">"#) == 128)
        #expect(InlineImageDisplay.dimension("width", in: "<img src=a.png width=64>") == 64)
        #expect(InlineImageDisplay.dimension("height", in: #"<img height='20px' src="a.png">"#) == 20)
        #expect(InlineImageDisplay.dimension("width", in: #"<img width="50%" src="a.png">"#) == nil)
        #expect(InlineImageDisplay.dimension("width", in: #"<img src="a.png">"#) == nil)
        let natural = CGSize(width: 400, height: 100)
        #expect(InlineImageDisplay.requested(natural, width: 200, height: nil) == CGSize(width: 200, height: 50))
        #expect(InlineImageDisplay.requested(natural, width: nil, height: 20) == CGSize(width: 80, height: 20))
        #expect(InlineImageDisplay.requested(natural, width: nil, height: nil) == natural)
    }

    @Test("Presenting the same document twice lays it out identically")
    func presentationIsDeterministic() {
        let view = makeView()
        let probes = ["Reader title", "A plain bullet", "A bullet with", "A nested", "First", "Second", "done", "open", "A callout", "let x", "Math"].map { offset(of: $0) }
        let first = probes.map { view.rect(forSourceOffset: $0)?.minY }
        view.setMarkdown("# Something else\n\nEntirely.")
        view.layoutIfNeeded()
        view.setMarkdown(Self.sample)
        view.layoutIfNeeded()
        let second = probes.map { view.rect(forSourceOffset: $0)?.minY }
        #expect(first == second, "first \(first) second \(second)")
    }
}
/// Records requests and answers only when told, so nothing touches the
/// network.  `image`, once set, is what every URL is cached as.
private final class StubRemoteImageLoader: RemoteImageLoading {
    var requested: [URL] = []
    var image: PlatformImage?
    private var waiting: [@MainActor (PlatformImage?) -> Void] = []
    func cachedImage(for url: URL, maxPixelDimension: Int) -> PlatformImage? { image }
    func hasFailed(_ url: URL) -> Bool { false }
    func loadImage(for url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (PlatformImage?) -> Void) {
        if !requested.contains(url) { requested.append(url) }
        waiting.append(completion)
    }
    @MainActor func finishAll() {
        let completions = waiting
        waiting.removeAll()
        completions.forEach { $0(image) }
    }
}
#endif
