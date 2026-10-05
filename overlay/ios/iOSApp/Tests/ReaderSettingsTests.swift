// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import MarkdownRender
import XCTest
@testable import DownrightIOS

final class ReaderSettingsTests: XCTestCase {
    func testTypographyAppliesToTheTheme() {
        var settings = ReaderSettings()
        let base = settings.theme(for: UITraitCollection(userInterfaceStyle: .light)).typography.bodySize
        settings.textSizeAdjustment = 3
        settings.measureCharacters = 90
        let theme = settings.theme(for: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertEqual(theme.typography.bodySize, base + 3)
        XCTAssertEqual(theme.typography.measureCharacters, 90)
    }

    func testOutOfRangeValuesAreClamped() {
        var settings = ReaderSettings()
        settings.textSizeAdjustment = 99
        settings.measureCharacters = 5
        let theme = settings.theme(for: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertLessThanOrEqual(theme.typography.bodySize, 32)
        XCTAssertEqual(theme.typography.measureCharacters, ReadingMeasure.minimumCharacters)
    }

    func testOldMeasureValuesSnapToAChoice() {
        // Values the earlier 60...100 stepper could store.
        XCTAssertEqual(ReaderSettings.nearestMeasure(60), 68)
        XCTAssertEqual(ReaderSettings.nearestMeasure(100), 90)
        XCTAssertEqual(ReaderSettings.nearestMeasure(70), 70)
    }

    func testFullWidthReachesTheRenderer() {
        var settings = ReaderSettings()
        settings.measureCharacters = ReadingMeasure.maximumCharacters
        let theme = settings.theme(for: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertEqual(theme.typography.measureCharacters, ReadingMeasure.maximumCharacters)
        XCTAssertEqual(ReaderSettings.measureTitle(ReadingMeasure.maximumCharacters), "Full width")
    }

    func testAppearanceChoosesTheTheme() {
        var settings = ReaderSettings()
        settings.lightTheme = "Paper Light"
        settings.darkTheme = "Warm Dark"
        XCTAssertEqual(settings.theme(for: UITraitCollection(userInterfaceStyle: .dark)).name, "Warm Dark")
        XCTAssertEqual(settings.theme(for: UITraitCollection(userInterfaceStyle: .light)).name, "Paper Light")
        settings.appearance = .light
        XCTAssertEqual(settings.theme(for: UITraitCollection(userInterfaceStyle: .dark)).name, "Paper Light")
        settings.appearance = .dark
        XCTAssertEqual(settings.resolvedStyle(for: UITraitCollection(userInterfaceStyle: .light)), .dark)
    }

    func testUnknownThemeFallsBackToSystem() {
        var settings = ReaderSettings()
        settings.lightTheme = "No Such Theme"
        XCTAssertEqual(settings.theme(for: UITraitCollection(userInterfaceStyle: .light)).name, "System")
    }

    func testStorePersistsAndNotifies() {
        let suite = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, ReaderSettings())
        let notified = expectation(forNotification: ReaderSettingsStore.didChange, object: store)
        var changed = store.settings
        changed.measureCharacters = 90
        store.settings = changed
        wait(for: [notified], timeout: 1)
        XCTAssertEqual(ReaderSettingsStore(defaults: defaults).settings.measureCharacters, 90)
    }

    func testSettingsAppWritesAreReadAndAnnounced() {
        let suite = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderSettingsStore(defaults: defaults)
        let notified = expectation(forNotification: ReaderSettingsStore.didChange, object: store)
        // What the Settings app stores: plain values under each key.
        defaults.set("dark", forKey: ReaderSettingsStore.Key.appearance)
        defaults.set("Nord", forKey: ReaderSettingsStore.Key.darkTheme)
        defaults.set(4, forKey: ReaderSettingsStore.Key.textSize)
        defaults.set(1000, forKey: ReaderSettingsStore.Key.measure)
        wait(for: [notified], timeout: 2)
        let settings = store.settings
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.darkTheme, "Nord")
        XCTAssertEqual(settings.textSizeAdjustment, 4)
        XCTAssertEqual(settings.measureCharacters, ReadingMeasure.maximumCharacters)
    }

    func testOddStoredValuesSnapToSettingsChoices() {
        let suite = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: ReaderSettingsStore.Key.textSize)
        defaults.set(100, forKey: ReaderSettingsStore.Key.measure)
        defaults.set("sepia", forKey: ReaderSettingsStore.Key.appearance)
        let settings = ReaderSettingsStore(defaults: defaults).settings
        XCTAssertTrue(ReaderSettings.textSizeChoices.contains(settings.textSizeAdjustment))
        XCTAssertEqual(settings.measureCharacters, 90)
        XCTAssertEqual(settings.appearance, .system)
    }

    func testEarlierBuildsSettingsMigrateOnce() throws {
        let suite = "ReaderSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = ReaderSettings()
        saved.appearance = .light
        saved.lightTheme = "Paper Light"
        saved.measureCharacters = 120
        defaults.set(try JSONEncoder().encode(saved), forKey: ReaderSettingsStore.legacyKey)
        XCTAssertEqual(ReaderSettingsStore(defaults: defaults).settings, saved)
        XCTAssertNil(defaults.object(forKey: ReaderSettingsStore.legacyKey))
        XCTAssertEqual(defaults.string(forKey: ReaderSettingsStore.Key.lightTheme), "Paper Light")
    }

    /// Settings.bundle is a static plist; this keeps it in step with the code.
    func testSettingsBundleMatchesTheApp() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Root", withExtension: "plist",
                                                subdirectory: "Settings.bundle"))
        let root = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        let specifiers = try XCTUnwrap(root["PreferenceSpecifiers"] as? [[String: Any]])
        var byKey: [String: [String: Any]] = [:]
        for specifier in specifiers { if let key = specifier["Key"] as? String { byKey[key] = specifier } }
        XCTAssertEqual(Set(byKey.keys), Set(ReaderSettingsStore.Key.all))

        func values<T>(_ key: String, as _: T.Type) throws -> [T] {
            try XCTUnwrap(byKey[key]?["Values"] as? [T], key)
        }
        XCTAssertEqual(try values(ReaderSettingsStore.Key.appearance, as: String.self),
                       ReaderSettings.Appearance.allCases.map(\.rawValue))
        let themes = Set(ThemeStore.shared.themes.map(\.name))
        XCTAssertEqual(Set(try values(ReaderSettingsStore.Key.lightTheme, as: String.self)), themes)
        XCTAssertEqual(Set(try values(ReaderSettingsStore.Key.darkTheme, as: String.self)), themes)
        XCTAssertEqual(try values(ReaderSettingsStore.Key.textSize, as: NSNumber.self).map { CGFloat($0.doubleValue) },
                       ReaderSettings.textSizeChoices)
        XCTAssertEqual(try values(ReaderSettingsStore.Key.measure, as: NSNumber.self).map { CGFloat($0.doubleValue) },
                       ReaderSettings.measureChoices)

        let defaults = ReaderSettings()
        XCTAssertEqual(byKey[ReaderSettingsStore.Key.appearance]?["DefaultValue"] as? String, defaults.appearance.rawValue)
        XCTAssertEqual(byKey[ReaderSettingsStore.Key.lightTheme]?["DefaultValue"] as? String, defaults.lightTheme)
        XCTAssertEqual(byKey[ReaderSettingsStore.Key.darkTheme]?["DefaultValue"] as? String, defaults.darkTheme)
        XCTAssertEqual((byKey[ReaderSettingsStore.Key.textSize]?["DefaultValue"] as? NSNumber)?.doubleValue,
                       Double(defaults.textSizeAdjustment))
        XCTAssertEqual((byKey[ReaderSettingsStore.Key.measure]?["DefaultValue"] as? NSNumber)?.doubleValue,
                       Double(defaults.measureCharacters))
        XCTAssertEqual(byKey[ReaderSettingsStore.Key.remoteImages]?["DefaultValue"] as? Bool,
                       defaults.loadsRemoteImages)
    }
}
