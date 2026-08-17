import AppKit
import SwiftUI

@main
struct ClickMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PreferencesStore()
    @StateObject private var updateCoordinator = UpdateCheckCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(updateCoordinator)
                .frame(width: 760, height: 520)
                .fixedSize()
                .onOpenURL { url in
                    URLRouter.handle(url)
                }
                .task {
                    await updateCoordinator.checkAutomaticallyIfNeeded()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quickFeatureCoordinator = QuickFeatureCoordinator()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Every launch begins hidden. A user-originated open event promotes the app later.
        NSApp.setActivationPolicy(.accessory)
        registerAppleEventHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.languageProvider = {
            PreferencesStore.currentLanguagePreference()
        }
        observePendingCommands()
        URLRouter.processPendingCommands()
        quickFeatureCoordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quickFeatureCoordinator.stop()
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

    @objc private func handleOpenApplicationEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        // Login items receive the same open-application event as a user launch, but carry this marker.
        // They must remain an accessory app until the user explicitly reopens ClickMate.
        let launchedInBackground = event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
            || event.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) != nil
        guard !launchedInBackground else {
            return
        }
        showSettingsWindow()
    }

    private func registerAppleEventHandlers() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        manager.setEventHandler(
            self,
            andSelector: #selector(handleOpenApplicationEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
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
