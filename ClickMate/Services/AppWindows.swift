import AppKit
import SwiftUI

/// Complete idle quits synchronously and reply exactly once to deferred quits.
@MainActor
final class AppTerminationCoordinator {
    private enum State: Equatable {
        case idle
        case preparing(UUID)
        case approved
    }

    private var state = State.idle

    func requestTermination(
        prepare: (@escaping (Bool) -> Void) -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if state == .approved { return .terminateNow }
        guard state == .idle else { return .terminateLater }
        let requestID = UUID()
        state = .preparing(requestID)
        var isSynchronous = true
        var synchronousResult: Bool?
        prepare { [weak self] allowed in
            guard let self, state == .preparing(requestID) else { return }
            state = allowed ? .approved : .idle
            if isSynchronous {
                synchronousResult = allowed
            } else {
                reply(allowed)
            }
        }
        isSynchronous = false
        if let synchronousResult {
            return synchronousResult ? .terminateNow : .terminateCancel
        }
        return .terminateLater
    }

    static func terminateFromEventLoop() {
        // Never enter AppKit's nested termination loop from a main dispatch
        // callback: that queue cannot recursively service MainActor cleanup.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

@MainActor
enum AppWindows {
    static let settingsID = NSUserInterfaceItemIdentifier("com.zxacn.clickmate.settings")
    static let tasksID = NSUserInterfaceItemIdentifier("com.zxacn.clickmate.file-tasks")
    static let archiveID = NSUserInterfaceItemIdentifier("com.zxacn.clickmate.archive-editor")
    private(set) static weak var settingsWindow: NSWindow?

    static func registerSettings(_ window: NSWindow) {
        window.identifier = settingsID
        settingsWindow = window
    }

    static var canHideForBackgroundAction: Bool {
        !NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            if window === settingsWindow { return true }
            guard let identifier = window.identifier else { return false }
            return [settingsID, tasksID, archiveID].contains(identifier)
        }
    }
}

struct SettingsWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MarkerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { AppWindows.registerSettings(window) }
        }
    }
}
