// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import Foundation

/// What a window was reading, so it can reopen at the same place after the
/// system discards it.  The file is remembered by bookmark, which survives
/// renames and moves within its provider; the place by source offset.
struct ReadingState: Equatable {
    /// The app's bundle ID + ".reading", the type Info.plist declares under
    /// NSUserActivityTypes; derived so each builder's own prefix works.
    static let activityType = (Bundle.main.bundleIdentifier ?? "downright.ios") + ".reading"

    var bookmark: Data
    var sourceOffset: Int

    init(bookmark: Data, sourceOffset: Int) {
        self.bookmark = bookmark
        self.sourceOffset = sourceOffset
    }

    init?(url: URL, sourceOffset: Int) {
        guard let bookmark = try? url.bookmarkData() else { return nil }
        self.init(bookmark: bookmark, sourceOffset: sourceOffset)
    }

    init?(activity: NSUserActivity?) {
        guard let activity, activity.activityType == Self.activityType,
              let bookmark = activity.userInfo?["bookmark"] as? Data
        else { return nil }
        self.init(bookmark: bookmark, sourceOffset: activity.userInfo?["offset"] as? Int ?? 0)
    }

    var activity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.userInfo = ["bookmark": bookmark, "offset": sourceOffset]
        return activity
    }

    /// The file, if it can still be found.  A deleted file resolves to nil:
    /// restoration never recreates anything.
    func resolve() -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
