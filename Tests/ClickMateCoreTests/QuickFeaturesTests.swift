import XCTest

final class QuickFeaturesTests: XCTestCase {
    func testDefaultsProvideDisabledFeaturesAndExpectedShortcuts() {
        let preferences = ClickMatePreferences.defaults

        XCTAssertEqual(preferences.quickFeatureSettings.map(\.id), QuickFeatureID.allCases)
        XCTAssertFalse(preferences.quickFeatureSettings(for: .finderCut).isEnabled)
        XCTAssertFalse(preferences.quickFeatureSettings(for: .screenshot).isEnabled)
        XCTAssertEqual(preferences.quickFeatureSettings(for: .finderCut).shortcut, .commandX)
        XCTAssertEqual(preferences.quickFeatureSettings(for: .screenshot).shortcut, .commandControlS)
        XCTAssertEqual(preferences.screenshotSettings, .defaults)
        XCTAssertFalse(preferences.screenshotSettings.savesToDesktop)
    }

    func testLegacyPreferencesDecodeWithQuickFeatureDefaults() throws {
        let json = """
        {
          "enabledCommands": ["copyPOSIXPath"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "pinnedApplicationPaths": []
        }
        """

        let preferences = try JSONDecoder().decode(ClickMatePreferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.quickFeatureSettings, QuickFeatureSettings.defaults)
        XCTAssertEqual(preferences.screenshotSettings, .defaults)
    }

    func testLegacyScreenshotDefaultMigratesFromCommandControlAToS() throws {
        let json = """
        {
          "enabledCommands": ["copyPOSIXPath"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "pinnedApplicationPaths": [],
          "quickFeatureSettings": [
            {"id":"finderCut","isEnabled":true,"shortcut":{"keyCode":7,"modifiers":1}},
            {"id":"screenshot","isEnabled":true,"shortcut":{"keyCode":0,"modifiers":3}}
          ]
        }
        """
        var preferences = try JSONDecoder().decode(ClickMatePreferences.self, from: Data(json.utf8))

        XCTAssertTrue(preferences.migrateQuickFeatureDefaultsIfNeeded())
        XCTAssertEqual(preferences.quickFeatureSettings(for: .screenshot).shortcut, .commandControlS)
        XCTAssertEqual(
            preferences.quickFeatureDefaultsVersion,
            ClickMatePreferences.currentQuickFeatureDefaultsVersion
        )
    }

    func testCurrentVersionPreservesCustomizedCommandControlA() throws {
        var preferences = ClickMatePreferences.defaults
        let screenshotIndex = try XCTUnwrap(
            preferences.quickFeatureSettings.firstIndex(where: { $0.id == .screenshot })
        )
        preferences.quickFeatureSettings[screenshotIndex].shortcut = .legacyScreenshotDefault

        XCTAssertFalse(preferences.migrateQuickFeatureDefaultsIfNeeded())
        XCTAssertEqual(
            preferences.quickFeatureSettings(for: .screenshot).shortcut,
            .legacyScreenshotDefault
        )
    }

    func testQuickFeaturePreferencesRoundTrip() throws {
        var preferences = ClickMatePreferences.defaults
        preferences.quickFeatureSettings = QuickFeatureSettings.normalized([
            QuickFeatureSettings(id: .finderCut, isEnabled: true, shortcut: .commandX),
            QuickFeatureSettings(
                id: .screenshot,
                isEnabled: true,
                shortcut: KeyboardShortcut(keyCode: 1, modifiers: [.command, .option])
            )
        ])
        preferences.screenshotSettings = ScreenshotSettings(copiesToClipboard: false, savesToDesktop: true)

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(ClickMatePreferences.self, from: data)

        XCTAssertEqual(decoded, preferences)
    }

    func testLegacyScreenshotSettingsDecodeWithoutDesktopField() throws {
        let json = """
        {
          "copiesToClipboard": false
        }
        """

        let settings = try JSONDecoder().decode(ScreenshotSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.copiesToClipboard)
        XCTAssertFalse(settings.savesToDesktop)
    }

    func testKeyboardShortcutDisplayAndValidity() {
        XCTAssertEqual(KeyboardShortcut.commandX.displayString, "⌘X")
        XCTAssertEqual(KeyboardShortcut.commandControlS.displayString, "⌃⌘S")
        XCTAssertTrue(KeyboardShortcut.commandX.isValid)
        XCTAssertTrue(KeyboardShortcut.commandControlS.isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 7, modifiers: []).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 7, modifiers: .shift).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 7, modifiers: .option).isValid)
        XCTAssertTrue(KeyboardShortcut(keyCode: 7, modifiers: [.command, .option]).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 55, modifiers: .command).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 128, modifiers: .command).isValid)
    }

    func testKeyboardShortcutModifiersAreCodable() throws {
        let shortcut = KeyboardShortcut(keyCode: 8, modifiers: [.command, .control, .shift])

        let decoded = try JSONDecoder().decode(
            KeyboardShortcut.self,
            from: JSONEncoder().encode(shortcut)
        )

        XCTAssertEqual(decoded, shortcut)
    }

    func testConflictHelpersIgnoreDisabledAndInvalidShortcuts() {
        let duplicate = KeyboardShortcut.commandX
        let settings = [
            QuickFeatureSettings(id: .finderCut, isEnabled: true, shortcut: duplicate),
            QuickFeatureSettings(id: .screenshot, isEnabled: true, shortcut: duplicate)
        ]

        XCTAssertTrue(duplicate.conflicts(with: .commandX))
        XCTAssertEqual(
            QuickFeatureSettings.conflictingFeatureIDs(in: settings),
            Set(QuickFeatureID.allCases)
        )

        var disabledSettings = settings
        disabledSettings[1].isEnabled = false
        XCTAssertTrue(QuickFeatureSettings.conflictingFeatureIDs(in: disabledSettings).isEmpty)

        var invalidSettings = settings
        invalidSettings[1].shortcut = KeyboardShortcut(keyCode: 7, modifiers: [])
        XCTAssertTrue(QuickFeatureSettings.conflictingFeatureIDs(in: invalidSettings).isEmpty)
    }

    func testNormalizationFillsMissingFeaturesAndDropsDuplicates() {
        let customFinderCut = QuickFeatureSettings(id: .finderCut, isEnabled: true)
        let normalized = QuickFeatureSettings.normalized([customFinderCut, QuickFeatureSettings(id: .finderCut)])

        XCTAssertEqual(normalized.map(\.id), QuickFeatureID.allCases)
        XCTAssertEqual(normalized.first, customFinderCut)
        XCTAssertEqual(normalized.last, QuickFeatureSettings(id: .screenshot))
    }

    func testUnknownFeatureEntriesAreSkippedWithoutResettingPreferences() throws {
        let json = """
        {
          "enabledCommands": ["copyPOSIXPath"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "pinnedApplicationPaths": [],
          "quickFeatureSettings": [
            {"id":"futureFeature","isEnabled":true,"shortcut":{"keyCode":3,"modifiers":1}},
            {"id":"screenshot","isEnabled":true,"shortcut":{"keyCode":1,"modifiers":1}}
          ]
        }
        """

        let preferences = try JSONDecoder().decode(ClickMatePreferences.self, from: Data(json.utf8))

        XCTAssertFalse(preferences.quickFeatureSettings(for: .finderCut).isEnabled)
        XCTAssertTrue(preferences.quickFeatureSettings(for: .screenshot).isEnabled)
        XCTAssertEqual(
            preferences.quickFeatureSettings(for: .screenshot).shortcut,
            KeyboardShortcut(keyCode: 1, modifiers: .command)
        )
    }

    func testInvalidPersistedShortcutFallsBackToFeatureDefault() throws {
        let data = Data("{\"id\":\"finderCut\",\"isEnabled\":true,\"shortcut\":{\"keyCode\":7,\"modifiers\":8}}".utf8)

        let settings = try JSONDecoder().decode(QuickFeatureSettings.self, from: data)

        XCTAssertEqual(settings.shortcut, .finderCutDefault)
    }
}
