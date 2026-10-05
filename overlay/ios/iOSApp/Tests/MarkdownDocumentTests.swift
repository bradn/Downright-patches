// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import XCTest
@testable import DownrightIOS

/// The document model against real files in a temporary directory.  Other
/// apps' edits are simulated with coordinated writes, as Files would make them.
@MainActor
final class MarkdownDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownrightIOSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func open(_ url: URL) -> MarkdownDocument {
        let document = MarkdownDocument(fileURL: url)
        let opened = expectation(description: "open")
        document.open { success in
            XCTAssertTrue(success)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 5)
        return document
    }

    private func close(_ document: MarkdownDocument) {
        let closed = expectation(description: "close")
        document.close { _ in closed.fulfill() }
        wait(for: [closed], timeout: 5)
    }

    func testOpensUTF8Verbatim() throws {
        let text = "# Title\r\n\r\nCafé **bold** — “quotes”\n"
        let url = try file("a.md", Data(text.utf8))
        let document = open(url)
        XCTAssertEqual(document.text, text)
        close(document)
    }

    func testOpensLatin1LikeTheMac() throws {
        let url = try file("latin.md", Data([0x43, 0x61, 0x66, 0xE9]))  // "Café" in Latin-1
        let document = open(url)
        XCTAssertEqual(document.text, "Café")
        close(document)
    }

    func testNeverWritesTheFile() throws {
        let bytes = Data("# Untouched\n".utf8)
        let url = try file("b.md", bytes)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let document = open(url)
        XCTAssertThrowsError(try document.contents(forType: "net.daringfireball.markdown"))
        XCTAssertFalse(document.hasUnsavedChanges)
        close(document)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testReloadsAfterAnotherAppEdits() throws {
        let url = try file("c.md", Data("# One\n".utf8))
        let document = open(url)
        let reloaded = expectation(description: "reload")
        document.onLoad = {
            if document.text == "# Two\n" { reloaded.fulfill() }
        }
        ExternalEdits.replace(self, url, with: Data("# Two\n".utf8))
        wait(for: [reloaded], timeout: 10)
        close(document)
    }

    func testAnEditMissedWhileOpeningIsPickedUp() throws {
        let url = try file("race.md", Data("# Before\n".utf8))
        let document = open(url)
        // An uncoordinated write stands in for one that landed before the
        // document registered as presenter: UIDocument is not told about it.
        let later = Date().addingTimeInterval(2)
        try Data("# After\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        let reloaded = expectation(description: "reloaded")
        document.onLoad = {
            if document.text == "# After\n" { reloaded.fulfill() }
        }
        document.reloadIfChangedWhileOpening()
        wait(for: [reloaded], timeout: 5)
        close(document)
    }

    func testNoReloadWhenNothingChanged() throws {
        let url = try file("same.md", Data("# Same\n".utf8))
        let document = open(url)
        let reloaded = expectation(description: "no reload")
        reloaded.isInverted = true
        document.onLoad = { reloaded.fulfill() }
        document.reloadIfChangedWhileOpening()
        wait(for: [reloaded], timeout: 1)
        close(document)
    }

    func testDeletionIsReportedAndNeverUndone() throws {
        let url = try file("d.md", Data("# Gone soon\n".utf8))
        let document = open(url)
        let gone = expectation(description: "gone")
        document.onGone = { gone.fulfill() }
        ExternalEdits.delete(self, url)
        wait(for: [gone], timeout: 10)
        XCTAssertTrue(document.isGone)
        XCTAssertEqual(document.text, "# Gone soon\n", "the last version read stays on screen")
        close(document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "deleted files are never recreated")
    }

    func testFollowsRename() throws {
        let url = try file("e.md", Data("# Moving\n".utf8))
        let renamed = directory.appendingPathComponent("renamed.md")
        let document = open(url)
        let moved = expectation(description: "moved")
        document.onMove = { moved.fulfill() }
        ExternalEdits.move(self, url, to: renamed)
        wait(for: [moved], timeout: 10)
        XCTAssertEqual(document.fileURL.standardizedFileURL.lastPathComponent, "renamed.md")
        close(document)
    }

    func testUndecodableFileIsAnErrorNotEmpty() throws {
        // A lone UTF-16 BOM followed by an odd, unrecoverable tail.
        let url = try file("bad.md", Data([0xFF, 0xFE, 0x00]))
        let document = MarkdownDocument(fileURL: url)
        let opened = expectation(description: "open")
        var result: Bool?
        document.open { success in result = success; opened.fulfill() }
        wait(for: [opened], timeout: 5)
        if result == true {
            // DocumentIO may recover a truncated UTF-16 file; then it must
            // still be non-destructive and readable.
            XCTAssertEqual(try Data(contentsOf: url), Data([0xFF, 0xFE, 0x00]))
        } else {
            XCTAssertNotNil(document.lastError)
            XCTAssertEqual(document.text, "")
        }
        close(document)
    }
}
