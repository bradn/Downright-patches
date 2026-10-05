// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import MarkdownRender
import SwiftUI
import UIKit

/// One open document: the shared reading surface plus the app's chrome.
final class DocumentViewController: UIViewController {
    let document: MarkdownDocument
    let reader: MarkdownReaderView
    private var hasLoaded = false
    /// Where a restored window was reading; applied once, on first load.
    private var initialSourceOffset: Int?
    private let banner = UILabel()
    private let message = UILabel()

    init(document: MarkdownDocument, initialSourceOffset: Int? = nil) {
        self.document = document
        self.initialSourceOffset = initialSourceOffset
        reader = MarkdownReaderView(styleSheet: ReaderSettingsStore.shared.settings
            .styleSheet(for: UITraitCollection.current))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = document.localizedName
        navigationItem.title = document.localizedName
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Outline", image: UIImage(systemName: "list.bullet"),
                            primaryAction: UIAction { [weak self] _ in self?.showOutline() }),
            UIBarButtonItem(title: "Find", image: UIImage(systemName: "magnifyingglass"),
                            primaryAction: UIAction { [weak self] _ in self?.findCommand() }),
        ]
        if UIApplication.shared.supportsMultipleScenes, traitCollection.userInterfaceIdiom == .pad {
            navigationItem.rightBarButtonItems?.append(UIBarButtonItem(
                title: "More", image: UIImage(systemName: "ellipsis"),
                menu: UIMenu(children: [
                    UIAction(title: "Open in New Window", image: UIImage(systemName: "macwindow.badge.plus")) {
                        [weak self] _ in self?.openInNewWindow()
                    },
                ])))
        }

        // Without a keyboard the guide's top is the bottom of the screen, not
        // the safe area, so the page runs under the home indicator as before.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        reader.translatesAutoresizingMaskIntoConstraints = false
        reader.documentURL = document.fileURL
        reader.isFindInteractionEnabled = true
        view.addSubview(reader)

        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = .secondaryLabel
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)

        banner.numberOfLines = 0
        banner.font = .preferredFont(forTextStyle: .footnote)
        banner.textAlignment = .center
        banner.backgroundColor = .secondarySystemBackground
        banner.isHidden = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            reader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.topAnchor.constraint(equalTo: view.topAnchor),
            // Ends at the keyboard (and the find bar riding on it), so a
            // found match is scrolled clear of both rather than behind them.
            reader.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            message.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: ReaderSettingsStore.didChange, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: DocumentViewController, _) in
            self.applySettings()
        }
        applySettings()

        document.onLoad = { [weak self] in self?.documentDidLoad() }
        document.onGone = { [weak self] in self?.documentWasRemoved() }
        document.onMove = { [weak self] in self?.documentDidMove() }
        document.open { [weak self] success in
            guard let self else { return }
            guard success else {
                self.showMessage("Couldn't open “\(self.document.localizedName)”.\n"
                    + (self.document.lastError?.localizedDescription ?? ""))
                return
            }
            self.title = self.document.localizedName
            self.document.reloadIfChangedWhileOpening()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Document events

    /// First load shows the top; a reload after another app's change keeps
    /// the reader on the same source position.
    func documentDidLoad() {
        message.isHidden = true
        if hasLoaded {
            let anchor = reader.topVisibleSourceOffset
            reader.setMarkdown(document.text)
            reader.layoutIfNeeded()
            if let anchor {
                reader.scroll(toSourceOffset: min(anchor, max(0, (document.text as NSString).length - 1)),
                              animated: false)
            }
        } else {
            hasLoaded = true
            reader.setMarkdown(document.text)
            if let offset = initialSourceOffset {
                initialSourceOffset = nil
                reader.layoutIfNeeded()
                reader.scroll(toSourceOffset: min(offset, max(0, (document.text as NSString).length - 1)),
                              animated: false)
            }
        }
    }

    private func documentWasRemoved() {
        showBanner("This file was deleted or moved somewhere Downright can't follow. "
            + "What's shown is the last version read; nothing will be recreated.")
    }

    private func documentDidMove() {
        title = document.localizedName
        reader.documentURL = document.fileURL
    }

    // MARK: - Chrome

    /// Another window on the same document, at the same place.
    private func openInNewWindow() {
        guard let state = ReadingState(url: document.fileURL,
                                       sourceOffset: reader.topVisibleSourceOffset ?? 0) else { return }
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: state.activity, options: nil, errorHandler: nil)
    }

    private func close() {
        document.close { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    private func showOutline() {
        let outline = UINavigationController(rootViewController: ReaderOutlineController(reader: reader))
        outline.modalPresentationStyle = .popover
        if let popover = outline.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
            popover.delegate = PopoverFallback.sheet
        }
        present(outline, animated: true)
    }

    @objc private func settingsChanged() {
        applySettings()
    }

    /// A forced Light or Dark overrides both this screen and its navigation
    /// controller, so the bars match the page; "System" (`.unspecified`)
    /// follows the device.  Turning Load Remote Images off removes the
    /// loader, which puts the shared engine back in the Mac's configuration:
    /// remote images blocked, nothing fetched.
    private func applySettings() {
        let settings = ReaderSettingsStore.shared.settings
        let style: UIUserInterfaceStyle = settings.appearance == .system ? .unspecified
            : settings.resolvedStyle(for: traitCollection)
        navigationController?.overrideUserInterfaceStyle = style
        overrideUserInterfaceStyle = style
        reader.styleSheet = settings.styleSheet(for: traitCollection)
        reader.remoteImageLoader = settings.loadsRemoteImages ? RemoteImageLoader.shared : nil
    }

    private func showMessage(_ text: String) {
        message.text = text
        message.isHidden = false
    }

    private func showBanner(_ text: String) {
        banner.text = text
        banner.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - Keyboard

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Next Heading", action: #selector(nextHeading), input: "n"),
            UIKeyCommand(title: "Previous Heading", action: #selector(previousHeading), input: "p"),
            UIKeyCommand(title: "Outline", action: #selector(outlineCommand), input: "o", modifierFlags: .command),
            UIKeyCommand(title: "Find", action: #selector(findCommand), input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Close", action: #selector(closeCommand), input: "w", modifierFlags: .command),
        ]
    }

    @objc private func nextHeading() { reader.scrollToHeading(forward: true) }
    @objc private func previousHeading() { reader.scrollToHeading(forward: false) }
    @objc private func outlineCommand() { showOutline() }
    @objc private func closeCommand() { close() }
    @objc private func findCommand() {
        reader.findInteraction?.presentFindNavigator(showingReplace: false)
    }
}

/// Keeps popovers as sheets on iPhone and popovers on iPad.
private final class PopoverFallback: NSObject, UIPopoverPresentationControllerDelegate {
    static let sheet = PopoverFallback()

    func adaptivePresentationStyle(
        for controller: UIPresentationController, traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        traitCollection.horizontalSizeClass == .compact ? .pageSheet : .none
    }
}
