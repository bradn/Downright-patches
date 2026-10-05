// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import XCTest
@testable import DownrightIOS

final class ReadingStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsThroughAnActivity() throws {
        let url = directory.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: url)
        let state = try XCTUnwrap(ReadingState(url: url, sourceOffset: 42))
        let restored = try XCTUnwrap(ReadingState(activity: state.activity))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.resolve()?.standardizedFileURL.resolvingSymlinksInPath(),
                       url.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testFollowsARename() throws {
        let url = directory.appendingPathComponent("before.md")
        try Data("# Note\n".utf8).write(to: url)
        let state = try XCTUnwrap(ReadingState(url: url, sourceOffset: 0))
        let renamed = directory.appendingPathComponent("after.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        XCTAssertEqual(state.resolve()?.lastPathComponent, "after.md")
    }

    func testADeletedFileIsNotRestored() throws {
        let url = directory.appendingPathComponent("gone.md")
        try Data("# Note\n".utf8).write(to: url)
        let state = try XCTUnwrap(ReadingState(url: url, sourceOffset: 0))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(state.resolve())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIgnoresOtherActivities() {
        XCTAssertNil(ReadingState(activity: NSUserActivity(activityType: "something.else")))
        XCTAssertNil(ReadingState(activity: nil))
    }
}
