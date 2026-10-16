import AppKit
import XCTest

@MainActor
final class AppWindowTests: XCTestCase {
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
