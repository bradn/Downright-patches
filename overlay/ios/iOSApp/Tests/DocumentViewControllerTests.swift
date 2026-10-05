// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import XCTest
@testable import DownrightIOS

@MainActor
final class DocumentViewControllerTests: XCTestCase {
    private var directory: URL!
    private var window: UIWindow!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownrightIOSUI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    }

    override func tearDownWithError() throws {
        window.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private static let long: String = {
        var text = "# Start\n\nIntro.\n"
        for section in 1...12 {
            text += "\n## Section \(section)\n\n"
            text += String(repeating: "A paragraph of reading text that wraps on a phone screen.\n\n", count: 8)
        }
        return text
    }()

    private func show(_ text: String, at offset: Int? = nil) throws -> (DocumentViewController, URL) {
        let url = directory.appendingPathComponent("doc.md")
        try Data(text.utf8).write(to: url)
        let controller = DocumentViewController(document: MarkdownDocument(fileURL: url),
                                                initialSourceOffset: offset)
        let loaded = expectation(description: "loaded")
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        let original = controller.document.onLoad
        controller.document.onLoad = {
            original?()
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        controller.document.onLoad = original
        // The text can arrive before UIDocument has finished opening and
        // registered as the file's presenter; an outside edit made in that
        // window is never reported.  Wait for the open to complete.
        let opened = expectation(for: NSPredicate { _, _ in
            controller.document.documentState == .normal
        }, evaluatedWith: nil)
        wait(for: [opened], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()
        return (controller, url)
    }

    func testHeadingKeysMoveThroughSections() throws {
        let (controller, _) = try show(Self.long)
        let reader = controller.reader
        XCTAssertTrue(reader.scrollToHeading(forward: true, animated: false))
        reader.layoutIfNeeded()
        let first = reader.currentOutlineIndex
        XCTAssertTrue(reader.scrollToHeading(forward: true, animated: false))
        reader.layoutIfNeeded()
        XCTAssertEqual(reader.currentOutlineIndex, (first ?? 0) + 1)
        XCTAssertTrue(reader.scrollToHeading(forward: false, animated: false))
        reader.layoutIfNeeded()
        XCTAssertEqual(reader.currentOutlineIndex, first)
        XCTAssertEqual(controller.keyCommands?.map(\.input), ["n", "p", "o", "f", "w"])
        XCTAssertTrue(reader.isFindInteractionEnabled)
    }

    func testARestoredWindowOpensAtItsPlace() throws {
        let target = (Self.long as NSString).range(of: "## Section 9").location
        let (controller, _) = try show(Self.long, at: target)
        let top = try XCTUnwrap(controller.reader.topVisibleSourceOffset)
        XCTAssertLessThan(abs(top - target), 80, "restored at \(top), wanted \(target)")
        XCTAssertEqual(controller.title, "doc.md".replacingOccurrences(of: ".md", with: ""))
    }

    func testReloadKeepsTheReadingPosition() throws {
        let (controller, url) = try show(Self.long)
        let reader = controller.reader
        let target = try XCTUnwrap(reader.outline.first { $0.title == "Section 7" })
        reader.scroll(toSourceOffset: target.sourceOffset, animated: false)
        reader.layoutIfNeeded()
        let before = try XCTUnwrap(reader.topVisibleSourceOffset)

        let reloaded = expectation(description: "reloaded")
        let original = controller.document.onLoad
        controller.document.onLoad = {
            original?()
            reloaded.fulfill()
        }
        ExternalEdits.replace(self, url, with: Data((Self.long + "\nAppended by another app.\n").utf8))
        wait(for: [reloaded], timeout: 10)
        reader.layoutIfNeeded()
        let after = try XCTUnwrap(reader.topVisibleSourceOffset)
        XCTAssertTrue(controller.document.text.hasSuffix("Appended by another app.\n"))
        XCTAssertLessThan(abs(after - before), 80, "reload jumped from \(before) to \(after)")
    }
}
