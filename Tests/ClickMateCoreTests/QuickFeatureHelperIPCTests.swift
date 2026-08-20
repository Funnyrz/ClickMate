import XCTest

final class QuickFeatureHelperIPCTests: XCTestCase {
    func testFreshPreferencesDoNotShowMigrationNotice() {
        XCTAssertTrue(ClickMatePreferences.defaults.hasAcknowledgedHelperPermissionMigration)
        XCTAssertTrue(ClickMatePreferences.defaults.hasAcknowledgedFinderMonitoringMigration)
    }

    func testLegacyPreferencesEnableBackgroundServiceByDefault() throws {
        let json = """
        {
          "enabledCommands": ["copyPOSIXPath"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "pinnedApplicationPaths": []
        }
        """

        let preferences = try JSONDecoder().decode(ClickMatePreferences.self, from: Data(json.utf8))

        XCTAssertTrue(preferences.backgroundServiceEnabled)
        XCTAssertFalse(preferences.hasAcknowledgedHelperPermissionMigration)
        XCTAssertFalse(preferences.hasAcknowledgedFinderMonitoringMigration)
    }

    func testPreferencesPersistBackgroundServiceEnabled() throws {
        var preferences = ClickMatePreferences.defaults
        preferences.backgroundServiceEnabled = false
        preferences.hasAcknowledgedHelperPermissionMigration = true
        preferences.hasAcknowledgedFinderMonitoringMigration = true

        let decoded = try JSONDecoder().decode(
            ClickMatePreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertFalse(decoded.backgroundServiceEnabled)
        XCTAssertTrue(decoded.hasAcknowledgedHelperPermissionMigration)
        XCTAssertTrue(decoded.hasAcknowledgedFinderMonitoringMigration)
    }

    func testHelperPolicyRunsWhenBackgroundServiceAndAnyFeatureAreEnabled() {
        var preferences = ClickMatePreferences.defaults
        preferences.quickFeatureSettings[0].isEnabled = true

        XCTAssertTrue(QuickFeatureHelperPolicy.shouldRun(preferences: preferences))
    }

    func testHelperPolicyStopsWhenBackgroundServiceIsDisabled() {
        var preferences = ClickMatePreferences.defaults
        preferences.quickFeatureSettings[0].isEnabled = true
        preferences.backgroundServiceEnabled = false

        XCTAssertFalse(QuickFeatureHelperPolicy.shouldRun(preferences: preferences))
    }

    func testHelperPolicyStopsWhenAllFeaturesAreDisabled() {
        var preferences = ClickMatePreferences.defaults
        preferences.quickFeatureSettings.indices.forEach {
            preferences.quickFeatureSettings[$0].isEnabled = false
        }

        XCTAssertFalse(QuickFeatureHelperPolicy.shouldRun(preferences: preferences))
    }

    func testHelperVersionIncludesMarketingAndBuildVersions() {
        XCTAssertEqual(
            QuickFeatureHelperVersion.identifier(shortVersion: "1.3.2", buildVersion: "42"),
            "1.3.2 (42)"
        )
        XCTAssertEqual(
            QuickFeatureHelperVersion.identifier(shortVersion: "1.3.2", buildVersion: nil),
            "1.3.2"
        )
    }

    func testInstalledBuildFallsBackToDirectSessionForMissingOrMismatchedSigningIdentity() {
        XCTAssertEqual(
            QuickFeatureHelperLaunchModeResolver.resolve(
                mainTeamIdentifier: nil,
                helperTeamIdentifier: nil,
                mainSignatureIsValid: true,
                helperSignatureIsValid: true,
                isInstalledInApplications: true
            ),
            .directSession
        )
        XCTAssertEqual(
            QuickFeatureHelperLaunchModeResolver.resolve(
                mainTeamIdentifier: "TEAM1",
                helperTeamIdentifier: "TEAM2",
                mainSignatureIsValid: true,
                helperSignatureIsValid: true,
                isInstalledInApplications: true
            ),
            .directSession
        )
    }

    func testDevelopmentBuildOutsideApplicationsUsesDirectSession() {
        XCTAssertEqual(
            QuickFeatureHelperLaunchModeResolver.resolve(
                mainTeamIdentifier: "TEAM1",
                helperTeamIdentifier: "TEAM1",
                mainSignatureIsValid: true,
                helperSignatureIsValid: true,
                isInstalledInApplications: false
            ),
            .directSession
        )
    }

    func testLaunchModeUsesManagedLoginItemForMatchingInstalledSignatures() {
        XCTAssertEqual(
            QuickFeatureHelperLaunchModeResolver.resolve(
                mainTeamIdentifier: "TEAM1",
                helperTeamIdentifier: "TEAM1",
                mainSignatureIsValid: true,
                helperSignatureIsValid: true,
                isInstalledInApplications: true
            ),
            .managedLoginItem
        )
    }

    func testCommandsRoundTripAndExposeRecordingSessionTimeout() throws {
        let sessionID = UUID()
        let enqueuedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let command = QuickFeatureHelperCommand(
            action: .beginShortcutRecording(sessionID: sessionID),
            enqueuedAt: enqueuedAt
        )

        let decoded = try JSONDecoder().decode(
            QuickFeatureHelperCommand.self,
            from: JSONEncoder().encode(command)
        )

        XCTAssertEqual(decoded.action, .beginShortcutRecording(sessionID: sessionID))
        XCTAssertEqual(decoded.shortcutRecordingSessionID, sessionID)
        XCTAssertEqual(
            decoded.recordingSessionExpiresAt,
            enqueuedAt.addingTimeInterval(QuickFeatureHelperCommand.shortcutRecordingSessionTimeout)
        )
        XCTAssertFalse(
            decoded.isShortcutRecordingSessionExpired(
                referenceDate: enqueuedAt.addingTimeInterval(30)
            )
        )
        XCTAssertTrue(
            decoded.isShortcutRecordingSessionExpired(
                referenceDate: enqueuedAt.addingTimeInterval(30.001)
            )
        )
    }

    func testCommandQueueDeduplicatesAndConsumesCommandsOnce() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let queue = QuickFeatureHelperCommandQueue(storageDirectoryURL: directoryURL)
        let sessionID = UUID()
        let enqueuedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(queue.enqueue(.refreshStatus, enqueuedAt: enqueuedAt))
        XCTAssertFalse(queue.enqueue(.refreshStatus, enqueuedAt: enqueuedAt))
        XCTAssertTrue(queue.enqueue(.beginShortcutRecording(sessionID: sessionID), enqueuedAt: enqueuedAt))
        XCTAssertTrue(queue.enqueue(.endShortcutRecording(sessionID: sessionID), enqueuedAt: enqueuedAt))
        XCTAssertTrue(queue.enqueue(.shutdown, enqueuedAt: enqueuedAt))

        let commands = queue.consumePending()

        XCTAssertEqual(
            commands.map(\.action),
            [
                .refreshStatus,
                .beginShortcutRecording(sessionID: sessionID),
                .endShortcutRecording(sessionID: sessionID),
                .shutdown
            ]
        )
        XCTAssertTrue(queue.consumePending().isEmpty)
    }

    func testRuntimeSnapshotStoreRoundTripsAndDetectsStaleSnapshots() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = QuickFeatureRuntimeSnapshotStore(storageDirectoryURL: directoryURL)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = QuickFeatureRuntimeSnapshot(
            pid: 123,
            version: "1.2.3",
            updatedAt: updatedAt,
            permissions: QuickFeatureRuntimePermissions(
                accessibilityGranted: true,
                screenRecordingGranted: false
            ),
            activeFeatures: [.finderCut],
            failedFeatures: [.screenshot],
            error: "Screen recording permission is required.",
            lastProcessedCommandID: UUID(),
            lastPermissionRequest: QuickFeaturePermissionRequestDiagnostic(
                commandID: UUID(),
                kind: .screenRecording,
                requestedAt: updatedAt.addingTimeInterval(-1),
                completedAt: updatedAt,
                requestReturnedGranted: true,
                observedPermissionGranted: false,
                processBundleIdentifier: "com.zxacn.clickmate.Helper"
            )
        )

        XCTAssertNil(store.load())
        XCTAssertTrue(store.write(snapshot))
        XCTAssertEqual(store.load(), snapshot)
        XCTAssertFalse(snapshot.isStale(referenceDate: updatedAt.addingTimeInterval(5)))
        XCTAssertTrue(snapshot.isStale(referenceDate: updatedAt.addingTimeInterval(5.001)))
        store.remove()
        XCTAssertNil(store.load())
    }

    func testRuntimeSnapshotDecodesLegacyPayloadWithoutPermissionDiagnostic() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let payload = """
        {
          "pid": 123,
          "version": "1.2.3",
          "updatedAt": 1000,
          "permissions": {
            "accessibilityGranted": false,
            "screenRecordingGranted": true
          },
          "activeFeatures": ["screenshot"],
          "failedFeatures": []
        }
        """
        try Data(payload.utf8).write(
            to: directoryURL.appendingPathComponent("runtime-snapshot.json")
        )

        let snapshot = QuickFeatureRuntimeSnapshotStore(
            storageDirectoryURL: directoryURL
        ).load()

        XCTAssertEqual(snapshot?.permissions.screenRecordingGranted, true)
        XCTAssertNil(snapshot?.lastPermissionRequest)
    }

    func testHelperConfigurationStoreRoundTripsOutsideAppGroupContainer() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = QuickFeatureHelperConfigurationStore(storageDirectoryURL: directoryURL)
        var settings = ClickMatePreferences.defaults.quickFeatureSettings
        settings[0].isEnabled = false
        let configuration = QuickFeatureHelperConfiguration(
            language: .simplifiedChinese,
            quickFeatureSettings: settings
        )

        XCTAssertNil(store.load())
        XCTAssertTrue(store.write(configuration))
        XCTAssertEqual(store.load(), configuration)
        XCTAssertFalse(QuickFeatureHelperConfigurationStore.fileURL.path.contains("Group Containers"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
