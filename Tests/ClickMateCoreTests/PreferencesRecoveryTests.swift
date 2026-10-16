import XCTest

final class PreferencesRecoveryTests: XCTestCase {
    func testFirstRunAndLoadedStatesRemainDistinct() throws {
        let url = try preferencesURL()
        let first = PreferencesStore(fileURL: url)
        XCTAssertEqual(first.storageState, .firstRun)
        first.waitForPendingSaves()
        XCTAssertEqual(PreferencesStore(fileURL: url).storageState, .loaded)
    }

    func testCorruptConfigurationIsNotOverwrittenByOrdinaryChanges() throws {
        let url = try preferencesURL()
        let corrupt = Data("broken configuration".utf8)
        try corrupt.write(to: url)
        let store = PreferencesStore(fileURL: url)
        guard case .corrupt = store.storageState else { return XCTFail("Expected corrupt status") }
        store.preferences.language = .english
        store.waitForPendingSaves()
        store.retrySave()
        store.waitForPendingSaves()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testValidBackupSurvivesCorruptionAndCanBeRecovered() throws {
        let url = try preferencesURL()
        let store = PreferencesStore(fileURL: url)
        store.preferences.language = .english
        store.waitForPendingSaves()
        store.preferences.language = .simplifiedChinese
        store.waitForPendingSaves()
        let backup = try Data(contentsOf: store.backupURL)
        XCTAssertEqual(try JSONDecoder().decode(ClickMatePreferences.self, from: backup).language, .english)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: url)
        let reloaded = PreferencesStore(fileURL: url)
        XCTAssertTrue(reloaded.canRestoreBackup)
        reloaded.preferences.backgroundServiceEnabled = false
        reloaded.waitForPendingSaves()
        XCTAssertEqual(try Data(contentsOf: reloaded.backupURL), backup)
        try reloaded.restoreBackup()
        XCTAssertEqual(reloaded.storageState, .loaded)
        XCTAssertEqual(reloaded.preferences.language, .english)
        XCTAssertTrue(try containsPreservedData(corrupt, beside: url))
        XCTAssertEqual(try Data(contentsOf: reloaded.backupURL), backup)
    }

    func testExternalCorruptionDuringOpenSessionCannotReplaceLastValidBackup() throws {
        let url = try preferencesURL()
        let store = PreferencesStore(fileURL: url)
        store.preferences.language = .english
        store.waitForPendingSaves()
        let backup = try Data(contentsOf: store.backupURL)
        let corrupt = Data("external corruption".utf8)
        try corrupt.write(to: url)
        store.preferences.screenshotSettings.savesToDesktop = true
        store.waitForPendingSaves()
        guard case .corrupt = store.storageState else { return XCTFail("Expected corrupt status") }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
    }

    func testExplicitResetPreservesCorruptOriginal() throws {
        let url = try preferencesURL()
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: url)
        let store = PreferencesStore(fileURL: url)
        store.reset()
        store.waitForPendingSaves()
        XCTAssertEqual(store.storageState, .loaded)
        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertTrue(try containsPreservedData(corrupt, beside: url))
    }

    func testSaveFailureIsObservableAndRetryUsesLatestPreferences() throws {
        let root = try temporaryDirectory()
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let url = blocked.appendingPathComponent("settings.json")
        let store = PreferencesStore(fileURL: url)
        guard case .saveFailure = store.storageState else { return XCTFail("Expected save failure") }
        store.preferences.language = .english
        store.waitForPendingSaves()
        try FileManager.default.removeItem(at: blocked)
        store.retrySave()
        store.waitForPendingSaves()
        XCTAssertEqual(store.storageState, .loaded)
        XCTAssertEqual(PreferencesStore.loadSnapshot(fileURL: url).language, .english)
    }

    func testPortableRoundTripExcludesBookmarksAndRuntimeFlags() throws {
        let source = PreferencesStore(fileURL: try preferencesURL())
        source.preferences.language = .english
        source.preferences.monitoredFolderPaths = ["/Users/example/Documents"]
        source.preferences.monitoredFolderBookmarks = ["/Users/example/Documents": Data("SECRET BOOKMARK".utf8)]
        source.preferences.hasDismissedPermissionGuide = true
        source.preferences.backgroundServiceEnabled = false
        let data = try source.exportConfiguration()
        let text = String(decoding: data, as: UTF8.self)
        for key in ["monitoredFolderBookmarks", "hasDismissedPermissionGuide", "backgroundServiceEnabled", "hasAcknowledgedHelperPermissionMigration", "finderMonitoringPolicyVersion"] {
            XCTAssertFalse(text.contains(key), key)
        }
        XCTAssertFalse(text.contains(Data("SECRET BOOKMARK".utf8).base64EncodedString()))
        let target = PreferencesStore(fileURL: try preferencesURL())
        let portable = try target.previewImport(data)
        try target.importConfiguration(portable)
        XCTAssertEqual(try target.previewImport(target.exportConfiguration()), portable)
        XCTAssertEqual(target.preferences.hasDismissedPermissionGuide, false)
        XCTAssertEqual(target.preferences.backgroundServiceEnabled, true)
    }

    func testImportBacksUpCurrentConfigurationAndRetainsOnlyMatchingLocalBookmarks() throws {
        let target = PreferencesStore(fileURL: try preferencesURL())
        target.preferences.language = .english
        target.preferences.hasDismissedPermissionGuide = true
        target.preferences.monitoredFolderPaths = ["/Users/example/keep", "/Users/example/remove"]
        target.preferences.monitoredFolderBookmarks = ["/Users/example/keep": Data([1]), "/Users/example/remove": Data([2])]
        target.waitForPendingSaves()
        let before = target.preferences
        var imported = PortableConfiguration(preferences: .defaults)
        imported.language = .simplifiedChinese
        imported.monitoredFolderPaths = ["/Users/example/keep", "/Users/example/new"]
        try target.importConfiguration(imported)
        XCTAssertEqual(target.preferences.monitoredFolderBookmarks, ["/Users/example/keep": Data([1])])
        XCTAssertTrue(target.preferences.hasDismissedPermissionGuide)
        XCTAssertEqual(target.preferences.language, .simplifiedChinese)
        XCTAssertEqual(try JSONDecoder().decode(ClickMatePreferences.self, from: Data(contentsOf: target.backupURL)), before)
    }

    func testInvalidVersionImportChangesNeitherMemoryNorDisk() throws {
        let url = try preferencesURL()
        let store = PreferencesStore(fileURL: url)
        let before = store.preferences
        let diskBefore = try Data(contentsOf: url)
        var imported = PortableConfiguration(preferences: .defaults)
        imported.version = 99
        imported.language = .english
        XCTAssertThrowsError(try store.importConfiguration(imported))
        XCTAssertEqual(store.preferences, before)
        XCTAssertEqual(try Data(contentsOf: url), diskBefore)
    }

    func testImportRejectsRawInvalidHotkeysAndConflicts() throws {
        let store = PreferencesStore(fileURL: try preferencesURL())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportConfiguration()) as? [String: Any])
        json["quickFeatureSettings"] = [["id": "finderCut", "isEnabled": true, "shortcut": ["keyCode": 999, "modifiers": 1]], ["id": "screenshot", "isEnabled": true, "shortcut": ["keyCode": 1, "modifiers": 3]]]
        XCTAssertThrowsError(try store.previewImport(JSONSerialization.data(withJSONObject: json)))
        json["quickFeatureSettings"] = [["id": "finderCut", "isEnabled": true, "shortcut": ["keyCode": 1, "modifiers": 3]], ["id": "screenshot", "isEnabled": true, "shortcut": ["keyCode": 1, "modifiers": 3]]]
        XCTAssertThrowsError(try store.previewImport(JSONSerialization.data(withJSONObject: json)))
    }

    func testImportRejectsInvalidPathsAndTemplateAssociations() throws {
        let store = PreferencesStore(fileURL: try preferencesURL())
        var imported = PortableConfiguration(preferences: .defaults)
        imported.monitoredFolderPaths = ["relative/path"]
        XCTAssertThrowsError(try store.importConfiguration(imported))
        imported.monitoredFolderPaths = []
        imported.topLevelShortcutTemplateIDs = ["missing-template"]
        XCTAssertThrowsError(try store.importConfiguration(imported))
        imported.topLevelShortcutTemplateIDs = []
        imported.templates.append(imported.templates[0])
        XCTAssertThrowsError(try store.importConfiguration(imported))
    }

    func testFailedImportDoesNotChangePreferencesOrReplaceBackup() throws {
        let url = try preferencesURL()
        let store = PreferencesStore(fileURL: url)
        store.preferences.language = .english
        store.waitForPendingSaves()
        let before = store.preferences
        let backup = try Data(contentsOf: store.backupURL)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var imported = PortableConfiguration(preferences: .defaults)
        imported.language = .simplifiedChinese
        XCTAssertThrowsError(try store.importConfiguration(imported))
        XCTAssertEqual(store.preferences, before)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
    }

    func testFinderToolsMasterFlagPreservesCustomCommandsAndLegacyDefaults() throws {
        var preferences = ClickMatePreferences.defaults
        preferences.finderToolsEnabled = false
        preferences.enabledCommands = [.copyPOSIXPath, .newFile]
        let portable = PortableConfiguration(preferences: preferences)
        let decoded = try JSONDecoder().decode(PortableConfiguration.self, from: JSONEncoder().encode(portable))
        try decoded.validate()
        let restored = decoded.applying(to: .defaults)
        XCTAssertFalse(restored.finderToolsEnabled)
        XCTAssertEqual(restored.enabledCommands, preferences.enabledCommands)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        legacy.removeValue(forKey: "finderToolsEnabled")
        let old = try JSONDecoder().decode(ClickMatePreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(old.finderToolsEnabled)
        XCTAssertEqual(old.enabledCommands, preferences.enabledCommands)
    }

    private func containsPreservedData(_ data: Data, beside url: URL) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        return files.filter { $0.lastPathComponent.contains(".corrupt-") }.contains { (try? Data(contentsOf: $0)) == data }
    }

    private func preferencesURL() throws -> URL {
        try temporaryDirectory().appendingPathComponent("settings.json")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
