// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
#if os(iOS)
import MarkdownCore
import UIKit

/// One heading in the reader's outline.
public struct ReaderOutlineEntry: Equatable, Sendable {
    public let title: String
    public let level: Int
    /// Source UTF-16 offset of the heading.
    public let sourceOffset: Int
}

extension MarkdownReaderView {
    // MARK: - Outline

    /// The document's headings, in order — the iOS stand-in for the Mac's
    /// hover-driven document map.
    public var outline: [ReaderOutlineEntry] {
        parsedDocument.headings.map {
            ReaderOutlineEntry(title: $0.title, level: $0.level, sourceOffset: $0.range.location)
        }
    }

    /// Source offset of the first text at the top of the visible area.
    public var topVisibleSourceOffset: Int? {
        let y = contentOffset.y + adjustedContentInset.top + textContainerInset.top + 1
        return sourceOffset(at: CGPoint(x: textContainerInset.left + 1, y: max(textContainerInset.top + 1, y)))
    }

    /// The heading whose section is at the top of the screen.
    public var currentOutlineIndex: Int? {
        guard let top = topVisibleSourceOffset else { return nil }
        return outline.lastIndex { $0.sourceOffset <= top }
    }

    /// Scrolls to the next (or previous) heading after the one at the top of
    /// the screen.  Returns false at either end.
    @discardableResult
    public func scrollToHeading(forward: Bool, animated: Bool = true) -> Bool {
        let offsets = outline.map(\.sourceOffset)
        let top = topVisibleSourceOffset ?? 0
        let currentStart = currentOutlineIndex.map { offsets[$0] }
        let target = forward
            ? offsets.first { $0 > top }
            : offsets.last { $0 < (currentStart ?? top) }
        guard let target else { return false }
        scroll(toSourceOffset: target, animated: animated)
        return true
    }

    // MARK: - VoiceOver rotors

    /// Headings and links, so VoiceOver can move between them as it does on
    /// the web.  Targets are text ranges in this view, reached through
    /// `DisplayMap`.
    public override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            [
                rotor(named: "Headings", offsets: { [weak self] in
                    self?.outline.map(\.sourceOffset) ?? []
                }),
                rotor(named: "Links", offsets: { [weak self] in
                    self?.linkOffsets() ?? []
                }),
            ]
        }
        set {}
    }

    func linkOffsets() -> [Int] {
        let storage = textStorage
        guard storage.length > 0 else { return [] }
        var offsets: [Int] = []
        storage.enumerateAttribute(.drLink, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is String { offsets.append(range.location) }
        }
        return offsets
    }

    private func rotor(named name: String, offsets: @escaping () -> [Int]) -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
            guard let self else { return nil }
            let targets = offsets()
            let current = predicate.currentItem.targetRange.map { self.offset(from: self.beginningOfDocument, to: $0.start) }
                .map { self.displayMap.sourceOffset(forTextKit: $0) }
            let next: Int?
            switch predicate.searchDirection {
            case .next:
                next = current.map { c in targets.first { $0 > c } } ?? targets.first
            case .previous:
                next = current.map { c in targets.last { $0 < c } } ?? targets.last
            @unknown default:
                next = nil
            }
            guard let target = next, let range = self.textRange(forSourceOffset: target) else { return nil }
            self.scroll(toSourceOffset: target, animated: false)
            return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: range)
        }
    }

    /// The text range covering the paragraph that starts at a source offset.
    func textRange(forSourceOffset offset: Int) -> UITextRange? {
        let source = textStorage.string as NSString
        guard offset >= 0, offset < source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: offset, length: 0))
        let end = max(offset, line.upperBound - (source.substring(with: line).hasSuffix("\n") ? 1 : 0))
        let start = displayMap.textKitOffset(forSource: offset)
        let stop = displayMap.textKitOffset(forSource: end)
        guard let from = position(from: beginningOfDocument, offset: start),
              let to = position(from: beginningOfDocument, offset: stop) else { return nil }
        return textRange(from: from, to: to)
    }
}

/// Lists the document's headings; choosing one scrolls the reader to it.
/// Present it as a popover (iPad) or sheet (iPhone).
@MainActor
public final class ReaderOutlineController: UITableViewController {
    private weak var reader: MarkdownReaderView?
    private let entries: [ReaderOutlineEntry]
    private let current: Int?

    public init(reader: MarkdownReaderView) {
        self.reader = reader
        entries = reader.outline
        current = reader.currentOutlineIndex
        super.init(style: .plain)
        title = "Outline"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "heading")
        if entries.isEmpty {
            let empty = UILabel()
            empty.text = "No headings"
            empty.textColor = .secondaryLabel
            empty.textAlignment = .center
            tableView.backgroundView = empty
        }
        let height = min(CGFloat(max(entries.count, 3)) * 44, 480)
        preferredContentSize = CGSize(width: 320, height: height)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let current, current < entries.count {
            tableView.scrollToRow(at: IndexPath(row: current, section: 0), at: .middle, animated: false)
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "heading", for: indexPath)
        let entry = entries[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.title
        content.textProperties.numberOfLines = 2
        content.textProperties.font = entry.level <= 2
            ? .preferredFont(forTextStyle: .headline)
            : .preferredFont(forTextStyle: .body)
        content.directionalLayoutMargins.leading = CGFloat(max(0, entry.level - 1)) * 16
        cell.contentConfiguration = content
        cell.accessoryType = indexPath.row == current ? .checkmark : .none
        cell.accessibilityTraits.insert(.header)
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = entries[indexPath.row]
        reader?.scroll(toSourceOffset: entry.sourceOffset, animated: false)
        dismiss(animated: true)
    }
}
#endif
