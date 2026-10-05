// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
#if os(iOS)
import MarkdownCore
import UIKit

/// The read-only UIKit reading surface (iOS port, phase 2).
///
/// One TextKit 2 surface, like the Mac `MarkdownTextView`, built from the same
/// pieces: `MarkdownContentStorage` and `ParagraphSubstitution` present the
/// source through a `DisplayMap`, `DecorationEngine` styles it, and
/// `FragmentProvider` draws code, callouts, tables, math, images and the rest.
/// The storage always holds the raw source; nothing here rewrites it.
///
/// Read mode only: no caret reveal, no editing, no folding.  Source offsets in
/// the layout map equal TextKit offsets because hidden runs become zero-width
/// joiners rather than being removed.
@MainActor
public final class MarkdownReaderView: UITextView {
    public var styleSheet: StyleSheet {
        didSet { styleSheetDidChange() }
    }
    /// The document's file URL; relative images and diagrams resolve against
    /// its directory (as `MarkdownTextView.documentURL`).
    public var documentURL: URL? {
        didSet {
            fragmentContext.documentURL = documentURL
            inlineImages.documentURL = documentURL
            invalidateFragments(in: nil)
        }
    }
    /// Fetches `https:` images (Markdown images on their own line and HTML
    /// `<img>`).  `nil`, the default, keeps them blocked or inert as on the
    /// Mac; the render package itself never touches the network.
    public var remoteImageLoader: RemoteImageLoading? {
        didSet {
            guard remoteImageLoader !== oldValue else { return }
            fragmentContext.remoteImageLoader = remoteImageLoader
            inlineImages.remoteImageLoader = remoteImageLoader
            engine.loadsRemoteImages = remoteImageLoader != nil
            if contentStorage.textStorage?.length ?? 0 > 0 {
                update(document: parsedDocument)
            }
            invalidateFragments(in: nil)
        }
    }
    public var configuration = MarkdownRenderConfiguration()
    public private(set) var parsedDocument: ParsedDocument = MarkdownParser.parse("")
    /// Source ⇄ TextKit map for the current presentation.
    public private(set) var displayMap: DisplayMap = .identity

    let fragmentContext: FragmentContext
    private let engine: DecorationEngine
    private let contentStorage = MarkdownContentStorage()
    private let markdownLayoutManager = NSTextLayoutManager()
    private let substitution = ParagraphSubstitution()
    private let fragmentProvider: FragmentProvider
    private let layoutMapBuilder = LayoutMapBuilder()
    /// Images inside a line of text; see `InlineImageDisplay`.
    private let inlineImages = InlineImageContext()
    private var hasInlineImages = false
    private var inlineImageRefreshPending = false
    /// Live views over animated block images, keyed by the image's source
    /// offset; see `showAnimation`.
    private var animationOverlays: [Int: AnimatedImageView] = [:]
    private var paragraphIndex: ParagraphIndex = .empty
    private var appliedColumn: CGFloat = 0

    public init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        engine = DecorationEngine(styleSheet: styleSheet)
        fragmentContext = FragmentContext(styleSheet: styleSheet)
        fragmentProvider = FragmentProvider(context: fragmentContext)

        let container = NSTextContainer(size: CGSize(width: styleSheet.measureWidth,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        markdownLayoutManager.textContainer = container
        contentStorage.addTextLayoutManager(markdownLayoutManager)
        contentStorage.textStorage = NSTextStorage()
        contentStorage.delegate = substitution

        super.init(frame: .zero, textContainer: container)

        markdownLayoutManager.delegate = fragmentProvider
        fragmentContext.readerView = self
        fragmentContext.mode = .read
        engine.policy = RenderMode.read.policy
        engine.codeCollapseLineCount = configuration.codeCollapseThreshold

        isEditable = false
        isSelectable = true
        alwaysBounceVertical = true
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        textContainerInset = UIEdgeInsets(
            top: RenderMetrics.verticalInset, left: 0,
            bottom: RenderMetrics.verticalInset, right: 0)
        applyChrome()

        // Links arrive through UITextView's own text-item interaction (taps,
        // long-press previews, VoiceOver), routed by the delegate below.
        delegate = self

        // Objects that are not links — a code block's copy control, a
        // footnote reference — get a plain tap alongside UITextView's own.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleObjectTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = objectTapDelegate
        addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    // MARK: - Content

    /// Replaces the document.  The text is held verbatim in the storage.
    public func setMarkdown(_ text: String) {
        let storage = contentStorage.textStorage ?? NSTextStorage()
        // As the Mac view does before any source edit: the maps and element
        // ranges describe the old text, so drop them before it changes, or
        // TextKit lays the new text out against the old document's grouping.
        substitution.displayMap = .identity
        contentStorage.suspendCustomLayout()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        update(document: MarkdownParser.parse(text))
        setContentOffset(CGPoint(x: 0, y: -adjustedContentInset.top), animated: false)
    }

    /// Re-decorates and re-presents the whole document.
    public func update(document: ParsedDocument) {
        guard let storage = contentStorage.textStorage else { return }
        // Overlays describe the previous layout; drawing re-places the ones
        // still needed.
        removeAnimationOverlays()
        parsedDocument = document
        paragraphIndex = ParagraphIndex(text: storage.string as NSString)
        fragmentContext.paragraphIndex = paragraphIndex
        fragmentContext.frontMatterFields = (document.frontMatter?.fields ?? []).map { ($0.key, $0.value) }
        fragmentContext.documentHasH1 = document.headings.contains { $0.level == 1 }
        fragmentContext.invalidateDerivedLayout()

        engine.decorate(storage, document: document, dirty: .wholesale)

        prepareInlineImages()
        let maps = PresentationMaps.base(
            document: document,
            engine: engine,
            styleSheet: styleSheet,
            policy: engine.policy,
            excluding: nil,
            reflowHardWrappedParagraphs: configuration.reflowHardWrappedParagraphs,
            text: storage.string as NSString,
            paragraphIndex: paragraphIndex,
            inlineImages: inlineImages,
            joinsHTMLParagraphs: true
        )
        hasInlineImages = !InlineImageDisplay.items(
            in: document, includesRemoteHTML: remoteImageLoader != nil, joinsHTMLParagraphs: true).isEmpty
        let layoutMap = layoutMapBuilder.layoutDisplayMap(
            from: maps.logical, paragraphs: paragraphIndex, storage: storage)
        substitution.displayMap = maps.logical
        displayMap = layoutMap
        contentStorage.configure(
            paragraphIndex: paragraphIndex,
            reflowRanges: maps.hardWrapRanges,
            displayMap: layoutMap,
            invalidating: nil
        )
        // Mirror the decision on the storage, as the Mac view does, so copy and
        // anything else reading attributes sees what the layout hid.
        PresentationMaps.applyHiddenAttribute(maps.hidden, to: storage, scope: nil)
        invalidateFragments(in: nil)
        if !inlineImages.animatedItems.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.placeInlineAnimations() }
        }
    }

    /// Pictures fit the prose column and most of the screen's height.
    private func prepareInlineImages() {
        let column = appliedColumn > 0 ? appliedColumn - RenderMetrics.codeBleed : styleSheet.measureWidth
        inlineImages.maximumSize = CGSize(width: max(40, column),
                                          height: max(120, bounds.height * 0.7))
        inlineImages.displayScale = traitCollection.displayScale
        inlineImages.imageDidArrive = { [weak self] in self?.scheduleInlineImageRefresh() }
        inlineImages.animatedItems = []
    }

    /// An arriving picture changes what the display map substitutes, so the
    /// presentation is rebuilt.  A badge row lands in a burst: one rebuild on
    /// the next turn covers all of it, and the reader stays where they were.
    private func scheduleInlineImageRefresh() {
        guard !inlineImageRefreshPending else { return }
        inlineImageRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            inlineImageRefreshPending = false
            guard contentStorage.textStorage?.length ?? 0 > 0 else { return }
            let offset = contentOffset
            update(document: parsedDocument)
            layoutIfNeeded()
            setContentOffset(offset, animated: false)
        }
    }

    // MARK: - Animated block images

    /// Places (or moves) the live view for an animated block image.
    /// `ImageFragment` calls this while drawing, so the view change waits for
    /// the next turn rather than altering the hierarchy mid-draw.
    nonisolated func showAnimation(_ image: UIImage, animation: AnimatedImageSource, key: Int,
                                   containerRect: CGRect, cornerRadius: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.placeAnimation(image, animation: animation, key: key,
                                                            containerRect: containerRect, cornerRadius: cornerRadius) }
        }
    }

    private func placeAnimation(_ image: UIImage, animation: AnimatedImageSource, key: Int,
                                containerRect: CGRect, cornerRadius: CGFloat) {
        let frame = containerRect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        if let view = animationOverlays[key], view.animation === animation {
            if view.frame != frame { view.frame = frame }
            return
        }
        animationOverlays[key]?.removeFromSuperview()
        let view = AnimatedImageView(animation: animation, still: image.cgImage)
        view.layer.cornerRadius = cornerRadius
        view.layer.masksToBounds = true
        view.frame = frame
        addSubview(view)
        animationOverlays[key] = view
    }

    /// Overlays for animated inline pictures, over the frame TextKit laid
    /// each attachment out in.
    private func placeInlineAnimations() {
        let origin = contentStorage.documentRange.location
        for item in inlineImages.animatedItems {
            guard let animation = item.image.animatedSource else { continue }
            let textKit = displayMap.textKitOffset(forSource: item.sourceLocation)
            guard let location = contentStorage.location(origin, offsetBy: textKit),
                  let through = contentStorage.location(location, offsetBy: 1) else { continue }
            markdownLayoutManager.ensureLayout(for: NSTextRange(
                location: markdownLayoutManager.documentRange.location, end: through)
                ?? markdownLayoutManager.documentRange)
            guard let fragment = markdownLayoutManager.textLayoutFragment(for: location) else { continue }
            let attachment = fragment.frameForTextAttachment(at: location)
            guard attachment.width > 0, attachment.height > 0 else { continue }
            let frame = fragment.layoutFragmentFrame
            placeAnimation(item.image, animation: animation, key: item.sourceLocation,
                           containerRect: attachment.offsetBy(dx: frame.minX, dy: frame.minY),
                           cornerRadius: 0)
        }
    }

    private func removeAnimationOverlays() {
        animationOverlays.values.forEach { $0.removeFromSuperview() }
        animationOverlays.removeAll()
    }

    /// Reduce Motion decides between live and still pictures when the
    /// presentation is built, so rebuild when it changes.
    @objc private func reduceMotionChanged() {
        guard contentStorage.textStorage?.length ?? 0 > 0 else { return }
        update(document: parsedDocument)
    }

    /// Scoped layout invalidation, in source coordinates.
    func invalidateFragments(in sourceRange: NSRange?) {
        setContentHeightNeedsUpdate()
        guard let sourceRange, sourceRange.length > 0 else {
            markdownLayoutManager.invalidateLayout(for: markdownLayoutManager.documentRange)
            setNeedsDisplay()
            return
        }
        let textKit = displayMap.textKitRange(forSource: sourceRange)
        let origin = contentStorage.documentRange.location
        guard let start = contentStorage.location(origin, offsetBy: textKit.location),
              let end = contentStorage.location(origin, offsetBy: textKit.upperBound),
              let range = NSTextRange(location: start, end: end) else {
            markdownLayoutManager.invalidateLayout(for: markdownLayoutManager.documentRange)
            setNeedsDisplay()
            return
        }
        // A scoped invalidation (an image arriving, a copy confirmation) must
        // not move the page; UITextView otherwise resets to the top.
        let offset = contentOffset
        markdownLayoutManager.invalidateLayout(for: range)
        markdownLayoutManager.textViewportLayoutController.layoutViewport()
        if contentOffset != offset { setContentOffset(offset, animated: false) }
        setNeedsDisplay()
    }

    // MARK: - Accessibility

    /// The document as it reads: hidden syntax omitted, inline math and
    /// footnote references replaced by what is shown.  The storage itself is
    /// the raw source, which would have VoiceOver read `**` and `#` aloud.
    public var renderedText: String {
        guard let storage = contentStorage.textStorage, storage.length > 0 else { return "" }
        let whole = NSRange(location: 0, length: storage.length)
        let shown = substitution.displayMap.displayString(forSourceRange: whole, in: storage)?.string
            ?? storage.string
        return shown
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
    }

    public override var accessibilityValue: String? {
        get { renderedText }
        set {}
    }

    // MARK: - Hit testing and navigation

    /// Called with a link's destination and source range when a link is
    /// tapped.  Return `true` if the host handled it.  Unhandled `#anchor`
    /// links scroll to the matching heading and absolute URLs open in the
    /// system handler; anything else (a relative path) is left alone.
    public var linkHandler: ((_ destination: String, _ sourceRange: NSRange) -> Bool)?

    /// Source UTF-16 offset of the character under `point` (view coordinates),
    /// or nil off the text.  Goes through `DisplayMap`, never a raw TextKit
    /// offset.
    public func sourceOffset(at point: CGPoint) -> Int? {
        let inset = textContainerInset
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        guard let fragment = markdownLayoutManager.textLayoutFragment(for: local),
              let elementStart = fragment.textElement?.elementRange?.location
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        let inFragment = CGPoint(x: local.x - frame.minX, y: local.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: {
            inFragment.y >= $0.typographicBounds.minY && inFragment.y < $0.typographicBounds.maxY
        }) ?? fragment.textLineFragments.last else { return nil }
        let inLine = CGPoint(x: inFragment.x - line.typographicBounds.minX,
                             y: inFragment.y - line.typographicBounds.minY)
        let index = line.characterIndex(for: inLine)
        guard index != NSNotFound else { return nil }
        let base = contentStorage.offset(from: contentStorage.documentRange.location, to: elementStart)
        // `characterIndex(for:)` answers in the element's string, the same
        // coordinates as `characterRange`, so it is an offset from the element.
        let textKit = base + index
        let length = contentStorage.textStorage?.length ?? 0
        guard length > 0 else { return nil }
        return min(length - 1, displayMap.sourceOffset(forTextKit: textKit))
    }

    /// Rectangle of the character at a source offset, in view coordinates.
    public func rect(forSourceOffset offset: Int) -> CGRect? {
        let textKit = displayMap.textKitOffset(forSource: offset)
        let origin = contentStorage.documentRange.location
        guard let location = contentStorage.location(origin, offsetBy: textKit) else { return nil }
        markdownLayoutManager.ensureLayout(for: NSTextRange(
            location: markdownLayoutManager.documentRange.location, end: location)
            ?? markdownLayoutManager.documentRange)
        guard let fragment = markdownLayoutManager.textLayoutFragment(for: location),
              let elementStart = fragment.textElement?.elementRange?.location else { return nil }
        let index = textKit - contentStorage.offset(from: origin, to: elementStart)
        guard let line = fragment.textLineFragments.first(where: {
            NSLocationInRange(index, $0.characterRange) || index == $0.characterRange.upperBound
        }) else { return nil }
        let x = line.locationForCharacter(at: index).x
        let frame = fragment.layoutFragmentFrame
        let bounds = line.typographicBounds
        return CGRect(
            x: textContainerInset.left + frame.minX + bounds.minX + x,
            y: textContainerInset.top + frame.minY + bounds.minY,
            width: 1,
            height: bounds.height)
    }

    /// The link under `point`, if any, as its destination and source range.
    public func link(at point: CGPoint) -> (destination: String, range: NSRange)? {
        guard let storage = contentStorage.textStorage,
              let offset = sourceOffset(at: point) else { return nil }
        var range = NSRange()
        guard let destination = storage.attribute(
            .drLink, at: offset, longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)) as? String
        else { return nil }
        return (destination, range)
    }

    /// Scrolls so the source offset sits at the top of the visible area.
    public func scroll(toSourceOffset offset: Int, animated: Bool) {
        let textKit = displayMap.textKitOffset(forSource: offset)
        guard let location = contentStorage.location(
                contentStorage.documentRange.location, offsetBy: textKit) else { return }
        markdownLayoutManager.ensureLayout(for: NSTextRange(
            location: markdownLayoutManager.documentRange.location, end: location)
            ?? markdownLayoutManager.documentRange)
        guard let fragment = markdownLayoutManager.textLayoutFragment(for: location) else { return }
        let top = fragment.layoutFragmentFrame.minY + textContainerInset.top - adjustedContentInset.top
        let maxY = max(-adjustedContentInset.top,
                       contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: 0, y: min(max(-adjustedContentInset.top, top), maxY)),
                         animated: animated)
    }

    /// Scrolls to the heading whose slug matches `slug` (without the `#`).
    @discardableResult
    public func scroll(toHeadingSlug slug: String, animated: Bool) -> Bool {
        let wanted = slug.removingPercentEncoding ?? slug
        guard let heading = parsedDocument.headings.first(where: { $0.slug == wanted }) else {
            return false
        }
        scroll(toSourceOffset: heading.range.location, animated: animated)
        return true
    }

    /// The `.drLink` destination covering a TextKit range, if any.
    private func link(inTextKitRange range: NSRange) -> (destination: String, range: NSRange)? {
        guard let storage = contentStorage.textStorage, storage.length > 0 else { return nil }
        let offset = min(storage.length - 1, displayMap.sourceOffset(forTextKit: range.location))
        var linkRange = NSRange()
        guard let destination = storage.attribute(
            .drLink, at: offset, longestEffectiveRange: &linkRange,
            in: NSRange(location: 0, length: storage.length)) as? String
        else { return nil }
        return (destination, linkRange)
    }

    /// Called with a footnote's identifier, its definition text and the
    /// reference's rectangle when a footnote reference is tapped.  Return
    /// `true` if the host handled it; otherwise a popover shows the text.
    public var footnoteHandler: ((_ identifier: String, _ text: String, _ rect: CGRect) -> Bool)?

    private var copiedFeedback: DispatchWorkItem?
    /// Kept separate from the view: a UIScrollView is the delegate of its own
    /// gestures, so answering here would change UITextView's behaviour too.
    private let objectTapDelegate = SimultaneousGestureDelegate()
    /// Where copies go.  A seam for tests, which may not read the general one.
    var pasteboard: UIPasteboard = .general

    @objc private func handleObjectTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)
        if let payload = codeCopyTarget(at: point) {
            copyCode(payload)
        } else if let footnote = footnote(at: point) {
            showFootnote(footnote.identifier, at: footnote.rect)
        }
    }

    /// The code block whose copy control is under `point`, using the same
    /// geometry the fragment draws with.
    func codeCopyTarget(at point: CGPoint) -> FragmentPayload? {
        let inset = textContainerInset
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        guard let fragment = markdownLayoutManager.textLayoutFragment(for: local) as? CodeBlockFragment,
              fragment.role == .openChrome
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        let band = fragment.bandRect(at: CGPoint(x: inset.left + frame.minX, y: inset.top + frame.minY))
        let copy = CodeBlockFragment.copyButtonRect(
            in: band, style: styleSheet, language: fragment.payload.detail)
        // Grown to a 44pt touch target around the 28pt control.
        let target = copy.insetBy(dx: -max(0, (44 - copy.width) / 2), dy: -max(0, (44 - copy.height) / 2))
        return target.contains(point) ? fragment.payload : nil
    }

    /// Copies a code block's text, without its fences, and briefly shows the
    /// control's confirmation state.
    public func copyCode(_ payload: FragmentPayload) {
        guard let storage = contentStorage.textStorage else { return }
        let code = CodeBlockFragment.codeText(of: payload, in: storage)
        guard !code.isEmpty else { return }
        pasteboard.string = code
        fragmentContext.copiedCodeRange = payload.sourceRange
        invalidateFragments(in: payload.sourceRange)
        copiedFeedback?.cancel()
        let range = payload.sourceRange
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fragmentContext.copiedCodeRange == range else { return }
            self.fragmentContext.copiedCodeRange = nil
            self.invalidateFragments(in: range)
        }
        copiedFeedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// The footnote reference under `point`, if any.
    public func footnote(at point: CGPoint) -> (identifier: String, rect: CGRect)? {
        guard let storage = contentStorage.textStorage,
              let offset = sourceOffset(at: point) else { return nil }
        // A superscript is a few points wide; a finger lands beside it as
        // often as on it, so the neighbouring characters count too.
        var range = NSRange()
        var found: String?
        for candidate in [offset, offset - 1, offset + 1, offset - 2, offset + 2]
        where candidate >= 0 && candidate < storage.length {
            if let identifier = storage.attribute(
                .drReference, at: candidate, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length)) as? String {
                found = identifier
                break
            }
        }
        guard let identifier = found else { return nil }
        let rect = rect(forSourceOffset: range.location) ?? CGRect(origin: point, size: .zero)
        return (identifier, rect.insetBy(dx: -4, dy: 0))
    }

    /// A footnote's definition, as plain text.
    public func footnoteText(_ identifier: String) -> String? {
        guard let definition = parsedDocument.footnotes[identifier] else { return nil }
        let body = (contentStorage.textStorage?.string as NSString?)?
            .substring(with: definition.contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body?.isEmpty == false ? body : nil
    }

    private func showFootnote(_ identifier: String, at rect: CGRect) {
        guard let text = footnoteText(identifier) else { return }
        if footnoteHandler?(identifier, text, rect) == true { return }
        guard let presenter = nearestViewController() else { return }
        let note = FootnotePopoverController(text: text, styleSheet: styleSheet)
        note.modalPresentationStyle = .popover
        if let popover = note.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = rect
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = note
        }
        presenter.present(note, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = current.next
        }
        return nil
    }

    /// Host first, then the reader's own defaults.
    public func activateLink(_ destination: String, range: NSRange) {
        if linkHandler?(destination, range) == true { return }
        if destination.hasPrefix("#") {
            scroll(toHeadingSlug: String(destination.dropFirst()), animated: true)
        } else if let url = URL(string: destination), url.scheme != nil {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Measure

    public override func layoutSubviews() {
        applyMeasure()
        super.layoutSubviews()
        applyContentHeight()
    }

    // MARK: - Content height

    /// Above this many paragraphs the height is estimated rather than laid out
    /// in full, as `MarkdownTextView` does.
    private static let eagerLayoutParagraphLimit = 4_000
    private var contentHeight: CGFloat = 0
    private var contentHeightIsStale = true

    private var exceedsEagerLayoutBudget: Bool {
        if let storage = contentStorage.textStorage,
           storage.length > configuration.largeFileThresholdMegabytes * 1024 * 1024 {
            return true
        }
        return paragraphIndex.starts.count > Self.eagerLayoutParagraphLimit
    }

    /// UITextView sizes its scroll content from TextKit's own estimate, which
    /// does not account for this surface's custom elements and fragments; the
    /// page then springs back to the top after every scroll.  Size it the way
    /// the Mac view sizes its frame: full layout within the budget, otherwise
    /// an estimate that only grows as real layout arrives.
    private func applyContentHeight() {
        let inset = textContainerInset
        // Room past the last line, as on the Mac, so the end of a document can
        // be read at a comfortable height rather than pinned to the bottom edge.
        let overscroll = bounds.height * 0.40
        if contentHeightIsStale {
            // Content or width changed: start again from the real figure.
            contentHeightIsStale = false
            if exceedsEagerLayoutBudget {
                contentHeight = CGFloat(max(1, paragraphIndex.starts.count)) * styleSheet.lineHeight
                    + inset.top + inset.bottom + overscroll
            } else {
                markdownLayoutManager.ensureLayout(for: markdownLayoutManager.documentRange)
                contentHeight = 0
            }
        }
        // Otherwise only grow.  Viewport layout settles a line or so away from
        // the full pass; shrinking for that would clamp a reader at the end.
        // The last fragment's frame, not `usageBoundsForTextContainer`, which
        // keeps its old extent after a relayout to a wider column.
        let used = lastFragmentMaxY() + inset.top + inset.bottom + overscroll
        contentHeight = max(contentHeight, used)
        let wanted = CGSize(width: bounds.width, height: max(contentHeight, 1))
        if abs(contentSize.height - wanted.height) > 0.5 || abs(contentSize.width - wanted.width) > 0.5 {
            contentSize = wanted
        }
    }

    /// UITextView rewrites its content size during its own viewport layout,
    /// from TextKit's estimate, which can be far off in either direction.
    /// After a full layout the reader's figure is exact and wins outright;
    /// while estimating it is a floor under UITextView's.
    public override var contentSize: CGSize {
        get { super.contentSize }
        set {
            let height: CGFloat
            if contentHeight <= 0 {
                height = newValue.height
            } else if exceedsEagerLayoutBudget {
                height = max(newValue.height, contentHeight)
            } else {
                height = contentHeight
            }
            super.contentSize = CGSize(width: newValue.width, height: height)
        }
    }

    /// Bottom of the fragment holding the document's last character.
    ///
    /// Not `usageBoundsForTextContainer`, and not a walk over every fragment:
    /// after a width change both still report fragments placed for the old
    /// width, which made a rotated page far taller than the same document
    /// opened at the new width.  The lookup by location is what `rect(forSourceOffset:)`
    /// uses, and it answers for the current layout.
    private func lastFragmentMaxY() -> CGFloat {
        let documentRange = markdownLayoutManager.documentRange
        if !exceedsEagerLayoutBudget {
            markdownLayoutManager.ensureLayout(for: documentRange)
        }
        let length = contentStorage.offset(from: documentRange.location, to: documentRange.endLocation)
        guard length > 0,
              let last = contentStorage.location(documentRange.location, offsetBy: length - 1),
              let fragment = markdownLayoutManager.textLayoutFragment(for: last)
        else { return markdownLayoutManager.usageBoundsForTextContainer.maxY }
        return fragment.layoutFragmentFrame.maxY
    }

    /// Marks the height for recomputation on the next layout pass.
    private func setContentHeightNeedsUpdate() {
        contentHeightIsStale = true
        setNeedsLayout()
    }

    /// The Mac rule (`MarkdownContainerView`): a column of the reading measure
    /// plus the trailing bleed lane, never wider than the view, centred on the
    /// prose measure.
    private func applyMeasure() {
        let width = bounds.width - safeAreaInsets.left - safeAreaInsets.right
        guard width > 100 else { return }
        let target = ReadingMeasure.clamped(styleSheet.theme.typography.measureCharacters)
        let characters: CGFloat = (width < 900 && target <= 72) ? 66 : target
        let preferredMeasure = styleSheet.averageCharacterWidth * characters
        let bleed = RenderMetrics.codeBleed
        let sideMargin: CGFloat = traitCollection.horizontalSizeClass == .compact ? 16 : 32
        let available = max(RenderMetrics.minimumProseWidth + bleed, width - sideMargin * 2)
        let column = min(preferredMeasure + bleed, available)
        let measure = column - bleed
        // Centred on the prose measure, but never pushing the bleed lane off
        // the trailing edge.
        let centred = (width - measure) / 2
        let left = safeAreaInsets.left + max(sideMargin, min(centred, width - sideMargin - column))
        // UITextView sizes its container to the bounds minus these insets
        // whatever `textContainer.size` says, so the right inset must leave
        // exactly the column.
        let right = max(0, bounds.width - left - column)
        let inset = textContainerInset
        if abs(inset.left - left) > 0.5 || abs(inset.right - right) > 0.5 {
            textContainerInset = UIEdgeInsets(top: inset.top, left: left, bottom: inset.bottom, right: right)
        }
        guard abs(column - appliedColumn) > 0.5 else { return }
        appliedColumn = column
        textContainer.size = CGSize(width: column, height: CGFloat.greatestFiniteMagnitude)
        fragmentContext.contentWidth = column
        fragmentContext.invalidateDerivedLayout()
        invalidateFragments(in: nil)
        // Inline pictures were fitted to the old column.
        if hasInlineImages { scheduleInlineImageRefresh() }
    }

    // MARK: - Style

    private func styleSheetDidChange() {
        engine.styleSheet = styleSheet
        fragmentContext.styleSheet = styleSheet
        applyChrome()
        appliedColumn = 0
        setNeedsLayout()
        if contentStorage.textStorage?.length ?? 0 > 0 {
            update(document: parsedDocument)
        }
    }

    private func applyChrome() {
        backgroundColor = styleSheet.background
        tintColor = styleSheet.accent
        linkTextAttributes = [.foregroundColor: styleSheet.link]
    }
}
extension MarkdownReaderView: UITextViewDelegate {

    /// Every link goes through `activateLink`, so `#anchor` and relative
    /// links behave and the host's handler always gets the first say.
    public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .link = textItem.content,
              let hit = link(inTextKitRange: textItem.range) else { return defaultAction }
        return UIAction { [weak self] _ in
            self?.activateLink(hit.destination, range: hit.range)
        }
    }
}
/// Lets the object tap ride alongside UITextView's own gestures.
final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// A footnote's text in a compact popover, kept a popover on iPhone too.
@MainActor
final class FootnotePopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    private let text: String
    private let styleSheet: StyleSheet

    init(text: String, styleSheet: StyleSheet) {
        self.text = text
        self.styleSheet = styleSheet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let label = UILabel()
        label.numberOfLines = 0
        label.text = text
        label.font = styleSheet.bodyFont().withSize(styleSheet.bodyFont().pointSize * 0.9)
        label.textColor = styleSheet.text
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        let width = min(320, max(160, (text as NSString).size(withAttributes: [.font: label.font!]).width + 32))
        let fitting = label.sizeThatFits(CGSize(width: width - 32, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: width, height: fitting.height + 24)
        label.accessibilityLabel = "Footnote: \(text)"
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController, traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle { .none }
}
#endif
