// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist as an imported type, so it resolves even where
    /// the system has not registered it.
    static let markdown = UTType("net.daringfireball.markdown") ?? .plainText
}

/// The Files-app browser.  Downright reads documents in place; it never
/// creates, moves or copies them.
final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    /// The document this window is showing, if any.
    private(set) weak var currentReader: DocumentViewController?

    init() {
        super.init(forOpening: [.markdown])
        allowsDocumentCreation = false
        allowsPickingMultipleItems = false
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        present(url)
    }

    /// A URL handed to the app from outside, e.g. "Open in Downright", or a
    /// restored window's document.
    func open(_ url: URL, at sourceOffset: Int? = nil) {
        guard url.isFileURL else { return }
        // Reveal so the browser shows where the file lives.  Revealing can
        // fail for a file that is still perfectly readable (one in this app's
        // own folder, for example); open it anyway.  Never import: that would
        // copy the file, and Downright does not create files.
        revealDocument(at: url, importIfNeeded: false) { [weak self] revealed, error in
            guard let self else { return }
            if error == nil || Self.canRead(url) {
                self.present(revealed ?? url, at: sourceOffset)
            } else if let error {
                self.showError("Couldn't open the document", error.localizedDescription)
            }
        }
    }

    private func present(_ url: URL, at sourceOffset: Int? = nil) {
        // Replace whatever is showing: one document per window.
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        let document = MarkdownDocument(fileURL: url)
        let reader = DocumentViewController(document: document, initialSourceOffset: sourceOffset)
        currentReader = reader
        let navigation = UINavigationController(rootViewController: reader)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    static func canRead(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private func showError(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
