import AppKit
import XCTest

@MainActor
final class AppWindowTests: XCTestCase {
    func testIdleTerminationReturnsImmediatelyWithoutSchedulingAnotherQuit() {
        let coordinator = AppTerminationCoordinator()
        var quitCount = 0
        let reply = coordinator.requestTermination(prepare: { $0(true) }, reply: { _ in quitCount += 1 })
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(quitCount, 0)
    }

    func testPendingTerminationRetainsSystemQuitAndRepliesOnceAfterCleanup() {
        let coordinator = AppTerminationCoordinator()
        var complete: ((Bool) -> Void)?
        var quitCount = 0
        XCTAssertEqual(coordinator.requestTermination(prepare: { complete = $0 }, reply: { allowed in
            XCTAssertTrue(allowed)
            quitCount += 1
        }), .terminateLater)
        XCTAssertEqual(coordinator.requestTermination(prepare: { _ in XCTFail("Duplicate preparation") },
                                                      reply: { _ in XCTFail("Duplicate quit") }), .terminateLater)
        complete?(true)
        complete?(true)
        XCTAssertEqual(quitCount, 1)
        XCTAssertEqual(coordinator.requestTermination(prepare: { _ in XCTFail("Already prepared") },
                                                      reply: { _ in XCTFail("Recursive quit") }), .terminateNow)
    }

    func testCancelledPreparationCanBeRetriedAndIgnoresOldCompletion() {
        let coordinator = AppTerminationCoordinator()
        var firstCompletion: ((Bool) -> Void)?
        var secondCompletion: ((Bool) -> Void)?
        var replies: [Bool] = []
        XCTAssertEqual(coordinator.requestTermination(prepare: { firstCompletion = $0 },
                                                      reply: { replies.append($0) }), .terminateLater)
        firstCompletion?(false)
        XCTAssertEqual(coordinator.requestTermination(prepare: { secondCompletion = $0 },
                                                      reply: { replies.append($0) }), .terminateLater)
        firstCompletion?(true)
        XCTAssertEqual(replies, [false])
        secondCompletion?(true)
        XCTAssertEqual(replies, [false, true])
    }

    func testSynchronousVetoDoesNotQuit() {
        let coordinator = AppTerminationCoordinator()
        XCTAssertEqual(coordinator.requestTermination(prepare: { $0(false) },
                                                      reply: { _ in XCTFail("Vetoed quit") }), .terminateCancel)
    }

    func testBackgroundActionsPreserveEachVisibleUserWindow() {
        _ = NSApplication.shared
        for id in [AppWindows.settingsID, AppWindows.tasksID, AppWindows.archiveID] {
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.identifier = id
            window.orderFront(nil)
            XCTAssertFalse(AppWindows.canHideForBackgroundAction)
            window.orderOut(nil)
        }
        XCTAssertTrue(AppWindows.canHideForBackgroundAction)
    }

    func testSettingsRegistrationDoesNotUseTheFirstTaskWindow() {
        _ = NSApplication.shared
        let task = NSWindow()
        task.identifier = AppWindows.tasksID
        let settings = NSWindow()
        AppWindows.registerSettings(settings)
        XCTAssertTrue(AppWindows.settingsWindow === settings)
        XCTAssertEqual(settings.identifier, AppWindows.settingsID)
        XCTAssertFalse(AppWindows.settingsWindow === task)
    }
}
