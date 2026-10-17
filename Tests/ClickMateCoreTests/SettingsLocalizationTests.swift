import XCTest

@MainActor
final class SettingsLocalizationTests: XCTestCase {
    func testPermissionDiagnosticsUseHumanReadableTextInBothLanguages() {
        let keys = [
            "permissions.temporarySignatureWarning", "permissions.fullDiskAccessManualVerificationStatus",
            "permissions.fullDiskAccessManualVerificationDetail", "permissions.sharedChannelAvailable",
            "permissions.sharedChannelUnavailable", "permissions.monitoredCoverage",
            "permissions.monitoredCoverageUnknown", "permissions.configurationUpdated", "permissions.lastMenuRequest",
            "permissions.bookmarkUnavailable", "permissions.customFolderSyncUnavailable",
            "permissions.directoryAccessDetails", "permissions.directoryAccessSucceeded",
            "permissions.directoryAccessDenied", "permissions.directoryAccessFailed",
            "permissions.directoryAccessUnverified", "guide.finderDefaultInstructions"
        ]
        for language in [AppLanguage.english, .simplifiedChinese] {
            for key in keys {
                XCTAssertNotEqual(L10n.string(key, language: language), key, "Missing \(language) text: \(key)")
            }
        }
        XCTAssertEqual(L10n.string("permissions.fullDiskAccessApplied", language: .english), "Processes refreshed · access unverified")
        XCTAssertEqual(L10n.string("permissions.fullDiskAccessApplied", language: .simplifiedChinese), "进程已刷新 · 权限未验证")
    }

    func testLocalizedLabelsUseLoadedPreferencesWithoutReadingTheSettingsFile() throws {
        let url = try settingsURL()
        var preferences = ClickMatePreferences.defaults
        preferences.language = .english
        try JSONEncoder().encode(preferences).write(to: url)
        let store = PreferencesStore(fileURL: url, allowsWrites: false)
        let previousProvider = L10n.languageProvider
        let observation = AppPreferences.bindLocalization(to: store)
        defer { observation.cancel(); L10n.languageProvider = previousProvider }
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(L10n.string("tab.permissions"), "Permissions")
        store.preferences.language = .simplifiedChinese
        XCTAssertEqual(L10n.string("tab.permissions"), "权限")
        store.replaceLoadedPreferences(preferences)
        XCTAssertEqual(L10n.string("tab.permissions"), "Permissions")
    }

    func testFolderSyncInstructionsDoNotRequireDeveloperSigningOrClaimFinderAppliedChanges() {
        let keys = [
            "permissions.chooseRedirectedFolders", "permissions.redirectedFoldersDescription",
            "permissions.folderSyncRequested", "permissions.folderSyncFailed",
            "permissions.sharedContainerUnavailable", "permissions.customFolderSyncUnavailable",
            "guide.finderDefaultInstructions"
        ]
        for language in [AppLanguage.english, .simplifiedChinese] {
            for key in keys {
                let text = L10n.string(key, language: language)
                XCTAssertNotEqual(text, key)
                XCTAssertFalse(text.contains("Developer ID"))
                XCTAssertFalse(text.contains("Apple Development"))
                XCTAssertFalse(text.contains("描述文件"))
            }
        }
        XCTAssertTrue(L10n.string("permissions.folderSyncRequested", language: .english).contains("not yet verified"))
        XCTAssertTrue(L10n.string("permissions.folderSyncRequested", language: .simplifiedChinese).contains("尚未验证"))
        XCTAssertTrue(L10n.string("permissions.redirectedFoldersDescription", language: .english).contains("not the entire disk"))
        XCTAssertTrue(L10n.string("permissions.redirectedFoldersDescription", language: .simplifiedChinese).contains("不要选择整个磁盘"))
    }

    func testLocalizedLabelsReflectLanguageBeforeAnAsynchronousSaveCompletes() throws {
        let store = PreferencesStore(fileURL: try settingsURL(), allowsWrites: false)
        let previousProvider = L10n.languageProvider
        let observation = AppPreferences.bindLocalization(to: store)
        defer { observation.cancel(); L10n.languageProvider = previousProvider }
        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            store.preferences.language = language
            XCTAssertEqual(L10n.string("tab.quickFeatures"), L10n.string("tab.quickFeatures", language: language))
        }
    }

    func testLanguageProviderCanBeReadFromBackgroundFileTasks() async throws {
        let store = PreferencesStore(fileURL: try settingsURL(), allowsWrites: false)
        store.preferences.language = .english
        let previousProvider = L10n.languageProvider
        let observation = AppPreferences.bindLocalization(to: store)
        defer { observation.cancel(); L10n.languageProvider = previousProvider }
        let provider = L10n.languageProvider
        let box = SendableProvider(value: provider)
        let language = await Task.detached { box.value() }.value
        XCTAssertEqual(language, .english)
    }

    func testRepeatedLabelLookupBenchmark() throws {
        let url = try settingsURL()
        var preferences = ClickMatePreferences.defaults
        preferences.language = .english
        for index in 0..<64 {
            preferences.monitoredFolderBookmarks["/tmp/folder-\(index)"] = Data(repeating: 42, count: 2048)
        }
        try JSONEncoder().encode(preferences).write(to: url)
        let store = PreferencesStore(fileURL: url, allowsWrites: false)
        let previousProvider = L10n.languageProvider
        defer { L10n.languageProvider = previousProvider }
        let clock = ContinuousClock()
        L10n.languageProvider = { PreferencesStore.currentLanguagePreference(fileURL: url) }
        let before = clock.measure {
            for _ in 0..<300 { XCTAssertEqual(L10n.string("tab.permissions"), "Permissions") }
        }
        let observation = AppPreferences.bindLocalization(to: store)
        defer { observation.cancel() }
        let after = clock.measure {
            for _ in 0..<300 { XCTAssertEqual(L10n.string("tab.permissions"), "Permissions") }
        }
        let attachment = XCTAttachment(string: "300 labels, 64 bookmarks: disk=\(before), memory=\(after)")
        attachment.name = "localization-benchmark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settingsURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("settings.json")
    }

    private struct SendableProvider: @unchecked Sendable { let value: () -> AppLanguage }
}
