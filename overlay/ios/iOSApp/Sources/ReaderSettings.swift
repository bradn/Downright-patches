// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import MarkdownRender
import UIKit

/// How documents look.  Edited in Settings > Apps > Downright (Settings.bundle)
/// and stored per app in `UserDefaults`; every open document follows changes.
struct ReaderSettings: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable {
        case system, light, dark
        var title: String { rawValue.capitalized }
    }

    var appearance: Appearance = .system
    /// Theme names, as `ThemeStore` lists them.  "System" follows the
    /// device's own colours.
    var lightTheme = "System"
    var darkTheme = "System"
    /// Points added to the theme's body size.
    var textSizeAdjustment: CGFloat = 0
    /// Characters per line before wrapping, before the window caps it.  One
    /// of `measureChoices`; other stored values snap to the nearest.
    var measureCharacters: CGFloat = 70
    /// Fetch `https:` images.  On by default; each load tells the image's
    /// server your IP address and when you opened the document.
    var loadsRemoteImages = true

    /// What earlier builds saved as JSON; the remote image switch is newer,
    /// so it is not among them and keeps its default on migration.
    private enum CodingKeys: String, CodingKey {
        case appearance, lightTheme, darkTheme, textSizeAdjustment, measureCharacters
    }

    static let textSizeRange: ClosedRange<CGFloat> = -4...10
    /// The text sizes Settings offers, in points added to the theme's size.
    static let textSizeChoices: [CGFloat] = [-4, -2, 0, 2, 4, 6, 8, 10]

    static func nearestTextSize(_ points: CGFloat) -> CGFloat {
        textSizeChoices.min { abs($0 - points) < abs($1 - points) } ?? 0
    }
    /// The Mac's measure presets (`ReaderProfilePickerView`).  The last is
    /// wider than any screen, so the column fills the view.
    static let measureChoices: [CGFloat] = [68, 70, 72, 90, 120, ReadingMeasure.maximumCharacters]

    static func nearestMeasure(_ characters: CGFloat) -> CGFloat {
        measureChoices.min { abs($0 - characters) < abs($1 - characters) } ?? 70
    }

    static func measureTitle(_ characters: CGFloat) -> String {
        characters >= ReadingMeasure.maximumCharacters ? "Full width" : "\(Int(characters)) characters"
    }

    /// The theme for a trait environment, with this app's typography applied.
    func theme(for traits: UITraitCollection) -> Theme {
        let isDark = resolvedStyle(for: traits) == .dark
        let name = isDark ? darkTheme : lightTheme
        var theme = ThemeStore.shared.themes.first { $0.name == name }
            ?? ThemeStore.shared.themes.first { $0.name == "System" }
            ?? .fallback
        let adjustment = min(max(textSizeAdjustment, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
        theme.typography.bodySize = max(10, min(32, theme.typography.bodySize + adjustment))
        theme.typography.measureCharacters = Self.nearestMeasure(measureCharacters)
        return theme
    }

    func resolvedStyle(for traits: UITraitCollection) -> UIUserInterfaceStyle {
        switch appearance {
        case .system: return traits.userInterfaceStyle == .dark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    func styleSheet(for traits: UITraitCollection) -> StyleSheet {
        let style = resolvedStyle(for: traits)
        return StyleSheet(theme: theme(for: traits), appearance: UITraitCollection(userInterfaceStyle: style))
    }
}

/// Persistence and change notification for `ReaderSettings`.
///
/// One `UserDefaults` key per setting, because Settings.bundle (Settings >
/// Apps > Downright) reads and writes them directly.  The Settings app's
/// edits arrive as a defaults change when the app returns to the foreground.
final class ReaderSettingsStore {
    static let shared = ReaderSettingsStore()
    static let didChange = Notification.Name("ReaderSettingsStore.didChange")

    /// The keys in `Resources/Settings.bundle/Root.plist`.
    enum Key {
        static let appearance = "appearance"
        static let lightTheme = "lightTheme"
        static let darkTheme = "darkTheme"
        static let textSize = "textSizeAdjustment"
        static let measure = "measureCharacters"
        static let remoteImages = "loadsRemoteImages"
        static let all = [appearance, lightTheme, darkTheme, textSize, measure, remoteImages]
    }

    /// Where builds before the Settings page kept every setting, as JSON.
    static let legacyKey = "readerSettings"

    private let defaults: UserDefaults
    private var last: ReaderSettings
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacy(in: defaults)
        last = Self.read(defaults)
        let center = NotificationCenter.default
        for name in [UserDefaults.didChangeNotification, UIApplication.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var settings: ReaderSettings {
        get { Self.read(defaults) }
        set {
            Self.write(newValue, to: defaults)
            reload()
        }
    }

    var themeNames: [String] {
        ThemeStore.shared.themes.map(\.name)
    }

    /// Posts `didChange` when what the defaults hold differs from the last
    /// settings seen.  Unrelated defaults changes post nothing.
    private func reload() {
        let current = Self.read(defaults)
        guard current != last else { return }
        last = current
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static func read(_ defaults: UserDefaults) -> ReaderSettings {
        var settings = ReaderSettings()
        if let raw = defaults.string(forKey: Key.appearance),
           let appearance = ReaderSettings.Appearance(rawValue: raw) {
            settings.appearance = appearance
        }
        if let name = defaults.string(forKey: Key.lightTheme) { settings.lightTheme = name }
        if let name = defaults.string(forKey: Key.darkTheme) { settings.darkTheme = name }
        if let points = number(Key.textSize, in: defaults) {
            settings.textSizeAdjustment = ReaderSettings.nearestTextSize(points)
        }
        if let characters = number(Key.measure, in: defaults) {
            settings.measureCharacters = ReaderSettings.nearestMeasure(characters)
        }
        if defaults.object(forKey: Key.remoteImages) != nil {
            settings.loadsRemoteImages = defaults.bool(forKey: Key.remoteImages)
        }
        return settings
    }

    private static func number(_ key: String, in defaults: UserDefaults) -> CGFloat? {
        guard let value = defaults.object(forKey: key) as? NSNumber, value.doubleValue.isFinite else { return nil }
        return CGFloat(value.doubleValue)
    }

    private static func write(_ settings: ReaderSettings, to defaults: UserDefaults) {
        defaults.set(settings.appearance.rawValue, forKey: Key.appearance)
        defaults.set(settings.lightTheme, forKey: Key.lightTheme)
        defaults.set(settings.darkTheme, forKey: Key.darkTheme)
        defaults.set(Double(settings.textSizeAdjustment), forKey: Key.textSize)
        defaults.set(Double(settings.measureCharacters), forKey: Key.measure)
        defaults.set(settings.loadsRemoteImages, forKey: Key.remoteImages)
    }

    /// Moves settings saved by earlier builds into the per-setting keys, once.
    private static func migrateLegacy(in defaults: UserDefaults) {
        guard let data = defaults.data(forKey: legacyKey) else { return }
        if Key.all.allSatisfy({ defaults.object(forKey: $0) == nil }),
           let saved = try? JSONDecoder().decode(ReaderSettings.self, from: data) {
            write(saved, to: defaults)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}
