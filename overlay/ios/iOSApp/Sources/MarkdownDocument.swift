// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import MarkdownCore
import UIKit

/// A Markdown file, read-only.
///
/// UIDocument is the file presenter: it coordinates reads, follows renames and
/// moves, and reloads when another app changes the file.  This subclass only
/// decodes — with the same rules as the Mac app (`DocumentIO`) — and refuses
/// to produce contents, so nothing in this app can ever write the file.
final class MarkdownDocument: UIDocument {
    enum ReadOnlyError: LocalizedError {
        case readOnly
        var errorDescription: String? { "Downright for iOS only reads documents." }
    }

    private(set) var text = ""
    private(set) var fidelity: ByteFidelity?
    /// Set when the file was deleted (or moved somewhere this app cannot
    /// follow) while open.  The last text stays on screen; the file is never
    /// recreated.
    private(set) var isGone = false

    /// Called on the main thread after every successful load, including
    /// reloads caused by another app changing the file.
    var onLoad: (() -> Void)?
    /// Called on the main thread when the file disappears while open.
    var onGone: (() -> Void)?
    /// Called on the main thread when the file is renamed or moved.
    var onMove: (() -> Void)?
    /// The last read failure, kept so the screen can say why it is empty.
    private(set) var lastError: Error?

    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        let callback = onMove
        DispatchQueue.main.async { callback?() }
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        lastError = error
        finishedHandlingError(error, recovered: false)
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else {
            throw DocumentIOError.undecodable(fileURL)
        }
        // An undecodable file is an error, never an empty document.
        let decoded = try DocumentIO.decodeSnapshot(data, sourceURL: fileURL)
        text = decoded.text
        fidelity = decoded.fidelity
        isGone = false
        let callback = onLoad
        DispatchQueue.main.async { callback?() }
    }

    override func contents(forType typeName: String) throws -> Any {
        throw ReadOnlyError.readOnly
    }

    override func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        isGone = true
        let callback = onGone
        DispatchQueue.main.async { callback?() }
        super.accommodatePresentedItemDeletion(completionHandler: completionHandler)
    }

    /// The file's modification date when its contents were last read.
    private var loadedModificationDate: Date?

    override func read(from url: URL) throws {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try super.read(from: url)
        loadedModificationDate = modified
    }

    /// UIDocument can hand over the text before it has registered as the
    /// file's presenter; an edit landing in that window is never reported.
    /// Called once the open has completed: if the file is newer than what was
    /// read, read it again.
    func reloadIfChangedWhileOpening() {
        let current = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let current, let loaded = loadedModificationDate, current > loaded else { return }
        revert(toContentsOf: fileURL) { _ in }
    }

    /// Never autosave: there is nothing of ours to write.
    override var hasUnsavedChanges: Bool { false }
}
