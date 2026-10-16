import ServiceManagement
import XCTest

@MainActor
final class SettingsStatusRefreshTests: XCTestCase {
    func testTabEntryReturnsBeforeResultAndCoalescesConcurrentRequests() async {
        let loader = StatusLoader()
        let service = makeService(loader: loader)

        let first = service.refreshStatusesForPresentation()
        service.refreshStatusesForPresentation()
        service.refreshStatusesForPresentation()
        XCTAssertEqual(service.finderExtensionStatus, .unknown)

        await loader.finish()
        await first?.value
        let count = await loader.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(service.finderExtensionStatus, .enabled)
    }

    func testRecentPresentationResultIsReusedButExpiredResultRefreshes() async {
        let loader = StatusLoader()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let service = makeService(loader: loader, now: { now })
        await loader.finish()

        await service.refreshStatusesForPresentation()?.value
        XCTAssertNil(service.refreshStatusesForPresentation())
        let cachedCount = await loader.count
        XCTAssertEqual(cachedCount, 1)

        now = now.addingTimeInterval(3)
        let refresh = service.refreshStatusesForPresentation()
        XCTAssertNotNil(refresh)
        await refresh?.value
        let refreshedCount = await loader.count
        XCTAssertEqual(refreshedCount, 2)
    }

    func testStopDiscardsDelayedPresentationResultAndClearsCache() async {
        let loader = StatusLoader()
        let service = makeService(loader: loader)
        let refresh = service.refreshStatusesForPresentation()

        service.stop()
        await loader.finish()
        await refresh?.value
        XCTAssertEqual(refresh?.isCancelled, true)
        XCTAssertEqual(service.finderExtensionStatus, .unknown)
        let nextRefresh = service.refreshStatusesForPresentation()
        XCTAssertNotNil(nextRefresh)
        await nextRefresh?.value
        XCTAssertEqual(service.finderExtensionStatus, .enabled)
    }

    private func makeService(
        loader: StatusLoader,
        now: @escaping @MainActor () -> Date = { .now }
    ) -> QuickFeatureHelperService {
        QuickFeatureHelperService(
            service: .loginItem(identifier: "com.zxacn.clickmate.tests.\(UUID().uuidString)"),
            mainBundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("ClickMate.app"),
            isFinderRuntimeChannelAvailable: false,
            presentationSnapshotLoader: { await loader.load() },
            presentationRefreshDate: now
        )
    }
}

private actor StatusLoader {
    private(set) var count = 0
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        finished = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func load() async -> QuickFeaturePresentationSnapshot {
        count += 1
        if !finished {
            await withCheckedContinuation { waiters.append($0) }
        }
        return QuickFeaturePresentationSnapshot(
            registrationStatus: .notRegistered,
            runtimeSnapshot: nil,
            finderRuntimeSnapshot: nil,
            finderExtensionStatus: .enabled
        )
    }
}
