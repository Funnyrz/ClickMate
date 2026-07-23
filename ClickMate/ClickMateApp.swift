import AppKit
import SwiftUI

@main
struct ClickMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PreferencesStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(width: 760, height: 520)
                .fixedSize()
                .onOpenURL { url in
                    URLRouter.handle(url)
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Start as an accessory app so Finder-triggered work never creates a Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.languageProvider = {
            PreferencesStore.currentLanguagePreference()
        }
        observePendingCommands()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        let launchedForBackgroundWork = PendingCommandQueue.hasPendingCommands()
        URLRouter.processPendingCommands()
        if !launchedForBackgroundWork {
            showSettingsWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(URLRouter.handle)
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else {
            return
        }
        Task { @MainActor in
            URLRouter.handle(url)
        }
    }

    private func showSettingsWindow() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func observePendingCommands() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    URLRouter.processPendingCommands()
                }
            },
            PendingCommandQueue.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

}
