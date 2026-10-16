import AppKit
import SwiftUI

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
