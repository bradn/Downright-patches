// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Create the store now, not at the first document: it moves settings
        // saved by earlier builds into the keys Settings > Apps > Downright
        // shows, and that page should be right before any file is opened.
        _ = ReaderSettingsStore.shared
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
