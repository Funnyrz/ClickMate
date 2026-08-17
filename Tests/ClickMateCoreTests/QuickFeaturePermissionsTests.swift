import XCTest

final class QuickFeaturePermissionsTests: XCTestCase {
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
