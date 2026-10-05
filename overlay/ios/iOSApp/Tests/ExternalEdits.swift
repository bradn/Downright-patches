// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import Foundation
import XCTest

/// Another app touching a file, as Files would: a coordinated write on its own
/// queue.  Coordinating on the main thread would deadlock against the open
/// document, which relinquishes the file on the main queue — a real other app
/// is a different process and never blocks ours.
enum ExternalEdits {
    static func perform(
        _ test: XCTestCase,
        timeout: TimeInterval = 10,
        _ body: @escaping @Sendable (NSFileCoordinator, inout NSError?) -> Void
    ) {
        let done = test.expectation(description: "coordinated edit")
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            body(NSFileCoordinator(filePresenter: nil), &error)
            XCTAssertNil(error)
            done.fulfill()
        }
        test.wait(for: [done], timeout: timeout)
    }

    static func replace(_ test: XCTestCase, _ url: URL, with data: Data) {
        perform(test) { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    static func delete(_ test: XCTestCase, _ url: URL) {
        perform(test) { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }
    }

    static func move(_ test: XCTestCase, _ url: URL, to destination: URL) {
        perform(test) { coordinator, error in
            coordinator.coordinate(
                writingItemAt: url, options: .forMoving,
                writingItemAt: destination, options: .forReplacing, error: &error
            ) { source, target in
                try? FileManager.default.moveItem(at: source, to: target)
            }
        }
    }
}
