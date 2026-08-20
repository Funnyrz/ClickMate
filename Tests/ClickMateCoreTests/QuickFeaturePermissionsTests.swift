import XCTest

final class QuickFeaturePermissionsTests: XCTestCase {
    func testPermissionRequestTrackerAllowsOnlyOneActiveRequest() {
        var tracker = QuickFeaturePermissionRequestTracker()
        let first = tracker.begin(kind: .accessibility)

        XCTAssertNotNil(first)
        XCTAssertNil(tracker.begin(kind: .screenRecording))
        XCTAssertEqual(tracker.context?.kind, .accessibility)
    }

    func testPermissionRequestTrackerAssociatesCommandAndRecoveryWithCurrentRequest() {
        var tracker = QuickFeaturePermissionRequestTracker()
        let request = tracker.begin(kind: .screenRecording)!
        let commandID = UUID()

        XCTAssertTrue(tracker.assignCommandID(commandID, requestID: request.id))
        XCTAssertEqual(tracker.context?.commandID, commandID)
        XCTAssertTrue(tracker.markRecoveryAttempted(requestID: request.id))
        XCTAssertFalse(tracker.markRecoveryAttempted(requestID: request.id))
        XCTAssertTrue(tracker.context?.didAttemptRecovery == true)
    }

    func testPermissionRequestContextExpiresAtConfiguredTimeout() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let request = QuickFeaturePermissionRequestContext(
            kind: .accessibility,
            startedAt: startedAt
        )

        XCTAssertFalse(request.isExpired(
            referenceDate: startedAt.addingTimeInterval(QuickFeaturePermissionRequestContext.timeout)
        ))
        XCTAssertTrue(request.isExpired(
            referenceDate: startedAt.addingTimeInterval(
                QuickFeaturePermissionRequestContext.timeout + 0.001
            )
        ))
    }

    func testAccessibilityNeverRestartsHelperAfterReturningToApp() {
        var tracker = QuickFeaturePermissionRequestTracker()
        let request = tracker.begin(kind: .accessibility)!

        XCTAssertFalse(tracker.context?.shouldAttemptRecoveryAfterActivation == true)
        XCTAssertTrue(tracker.markRecoveryAttempted(requestID: request.id))
        XCTAssertTrue(tracker.context?.shouldAttemptRecoveryAfterActivation == false)
        XCTAssertFalse(tracker.markRecoveryAttempted(requestID: request.id))
    }

    func testAccessibilityPollingUsesFiniteBackoff() {
        XCTAssertEqual(QuickFeaturePermissionPollingPolicy.refreshDelays.first, 0)
        XCTAssertEqual(QuickFeaturePermissionPollingPolicy.refreshDelays.last, 5)
        XCTAssertLessThanOrEqual(
            QuickFeaturePermissionPollingPolicy.refreshDelays.reduce(0, +),
            QuickFeaturePermissionRequestContext.timeout
        )
    }

    func testPermissionRefreshTracksCommandSnapshotAndGeneration() {
        var tracker = QuickFeaturePermissionRequestTracker()
        let request = tracker.begin(kind: .accessibility)!
        let firstCommandID = UUID()
        let secondCommandID = UUID()
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            tracker.beginRefresh(
                commandID: firstCommandID,
                observedSnapshotUpdatedAt: updatedAt,
                requestID: request.id
            ),
            1
        )
        XCTAssertEqual(tracker.context?.lastRefreshCommandID, firstCommandID)
        XCTAssertEqual(tracker.context?.lastObservedSnapshotUpdatedAt, updatedAt)
        XCTAssertEqual(
            tracker.beginRefresh(
                commandID: secondCommandID,
                observedSnapshotUpdatedAt: updatedAt.addingTimeInterval(1),
                requestID: request.id
            ),
            2
        )
        XCTAssertEqual(tracker.context?.lastRefreshCommandID, secondCommandID)
        XCTAssertNil(tracker.beginRefresh(
            commandID: UUID(),
            observedSnapshotUpdatedAt: nil,
            requestID: UUID()
        ))
    }

    func testScreenRecordingRecoveryWaitsUntilSettingsWereOpened() {
        var tracker = QuickFeaturePermissionRequestTracker()
        let request = tracker.begin(kind: .screenRecording)!

        XCTAssertFalse(tracker.context?.shouldAttemptRecoveryAfterActivation == true)
        XCTAssertTrue(tracker.markSettingsOpened(requestID: request.id))
        XCTAssertTrue(tracker.context?.shouldAttemptRecoveryAfterActivation == true)
    }

    @MainActor
    func testUnavailableFinderRuntimeChannelClearsRecoveryWithoutSchedulingRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recoveryStore = FullDiskAccessRecoveryStore(
            fileURL: directory.appendingPathComponent("full-disk-access.json")
        )
        XCTAssertTrue(recoveryStore.write(FullDiskAccessRecoveryRequest(
            previousApplicationPID: 42,
            previousFinderExtensionPID: 84
        )))

        let service = QuickFeatureHelperService(
            service: .loginItem(identifier: "com.zxacn.clickmate.tests.\(UUID().uuidString)"),
            mainBundleURL: directory.appendingPathComponent("ClickMate.app", isDirectory: true),
            fullDiskAccessRecoveryStore: recoveryStore,
            isFinderRuntimeChannelAvailable: false
        )

        service.applyFullDiskAccessChanges()

        XCTAssertNil(recoveryStore.load())
        XCTAssertNil(service.fullDiskAccessRecoveryPhase)
        XCTAssertFalse(service.diskAccessNeedsRelaunch)
        XCTAssertFalse(service.isApplyingDiskAccessChanges)
        XCTAssertNil(service.diskAccessRecoveryMessage)
    }

    @MainActor
    func testPermissionMonitorRetriesWhenTCCStatusArrivesLater() async throws {
        var readCount = 0
        let monitor = QuickFeaturePermissionMonitor(
            snapshotProvider: {
                readCount += 1
                return QuickFeaturePermissionSnapshot(
                    accessibilityGranted: readCount >= 3,
                    screenRecordingGranted: false
                )
            },
            retryDelays: [.milliseconds(5), .milliseconds(5)]
        )

        XCTAssertFalse(monitor.snapshot.accessibilityGranted)

        monitor.refresh()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(monitor.snapshot.accessibilityGranted)
        XCTAssertGreaterThanOrEqual(readCount, 3)
    }

    @MainActor
    func testPermissionMonitorStopsRetryingAfterAllPermissionsAreGranted() async throws {
        var readCount = 0
        let monitor = QuickFeaturePermissionMonitor(
            snapshotProvider: {
                readCount += 1
                return QuickFeaturePermissionSnapshot(
                    accessibilityGranted: readCount >= 2,
                    screenRecordingGranted: readCount >= 2
                )
            },
            retryDelays: [.milliseconds(5), .milliseconds(5), .milliseconds(5)]
        )

        monitor.refresh()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(monitor.snapshot.accessibilityGranted)
        XCTAssertTrue(monitor.snapshot.screenRecordingGranted)
        XCTAssertEqual(readCount, 2)
    }
}
