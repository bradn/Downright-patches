// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import UIKit

/// One window: the Files browser, with documents presented over it.  iPad
/// windows each get their own scene, so several documents can be open side by
/// side.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let browser = DocumentBrowserViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        if let url = connectionOptions.urlContexts.first?.url {
            browser.open(url)
        } else if let state = ReadingState(activity: connectionOptions.userActivities.first)
                    ?? ReadingState(activity: session.stateRestorationActivity),
                  let url = state.resolve() {
            browser.open(url, at: state.sourceOffset)
        }
    }

    /// The open document and the place in it, for when this window returns.
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let browser = window?.rootViewController as? DocumentBrowserViewController,
              let reading = browser.currentReader,
              let state = ReadingState(url: reading.document.fileURL,
                                       sourceOffset: reading.reader.topVisibleSourceOffset ?? 0)
        else { return nil }
        return state.activity
    }

    /// "Open in Downright" from Files or another app.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url,
              let browser = window?.rootViewController as? DocumentBrowserViewController
        else { return }
        browser.open(url)
    }
}
