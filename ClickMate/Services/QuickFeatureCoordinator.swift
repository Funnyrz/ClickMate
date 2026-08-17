import AppKit
import Carbon.HIToolbox

@MainActor
final class QuickFeatureCoordinator {
    private let store = PreferencesStore()
    private let hotKeyRegistrar = GlobalHotKeyRegistrar()
    private let finderCutController = FinderCutController()
    private var activationObserver: NSObjectProtocol?
    private var recordingObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private var isStarted = false
    private var isRecordingShortcut = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        ScreenshotCoordinator.shared.errorHandler = { message in
            HUDPresenter.shared.show(message: message)
        }
        ScreenshotCoordinator.shared.completionHandler = {
            HUDPresenter.shared.show(message: L10n.string("screenshot.completed"))
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                QuickFeaturePermissionMonitor.shared.refresh()
                self?.reloadConfiguration()
            }
        }
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .quickFeaturePermissionStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadConfiguration()
            }
        }
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .quickFeatureShortcutRecordingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isRecording = notification.userInfo?["isRecording"] as? Bool
            MainActor.assumeIsolated {
                guard let self,
                      let isRecording
                else { return }
                self.isRecordingShortcut = isRecording
                if isRecording {
                    self.hotKeyRegistrar.unregisterAll()
                } else {
                    self.reloadConfiguration()
                }
            }
        }
        observePreferenceChanges()
        QuickFeaturePermissionMonitor.shared.refresh()
        reloadConfiguration()
    }

    func stop() {
        guard isStarted else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(PreferencesChangeNotifier.name as CFString),
            nil
        )
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
            self.recordingObserver = nil
        }
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        hotKeyRegistrar.invalidate()
        finderCutController.stop()
        ScreenshotCoordinator.shared.cancel()
        isStarted = false
    }

    private func observePreferenceChanges() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                DispatchQueue.main.async {
                    let coordinator = Unmanaged<QuickFeatureCoordinator>
                        .fromOpaque(observer)
                        .takeUnretainedValue()
                    coordinator.reloadConfiguration()
                }
            },
            PreferencesChangeNotifier.name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func reloadConfiguration() {
        store.reload()
        hotKeyRegistrar.unregisterAll()
        finderCutController.stop()

        let settings = QuickFeatureSettings.normalized(store.preferences.quickFeatureSettings)
        let conflicts = QuickFeatureSettings.conflictingFeatureIDs(in: settings)
        var failedIDs = conflicts

        if let finderCut = settings.first(where: { $0.id == .finderCut }),
           finderCut.isEnabled,
           !conflicts.contains(.finderCut),
           QuickFeaturePermissions.hasAccessibilityAccess,
           !finderCutController.start(shortcut: finderCut.shortcut) {
            failedIDs.insert(.finderCut)
        }

        if let screenshot = settings.first(where: { $0.id == .screenshot }),
           screenshot.isEnabled,
           !isRecordingShortcut,
           !conflicts.contains(.screenshot),
           !registerScreenshotShortcut(screenshot.shortcut) {
            failedIDs.insert(.screenshot)
        }

        NotificationCenter.default.post(
            name: .quickFeatureRuntimeStatusChanged,
            object: nil,
            userInfo: ["failedIDs": Array(failedIDs)]
        )
    }

    private func registerScreenshotShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        hotKeyRegistrar.register(
            keyCode: UInt32(shortcut.keyCode),
            modifiers: shortcut.carbonModifiers
        ) { [weak self] in
            self?.captureScreenshot()
        }
    }

    private func captureScreenshot() {
        guard ScreenshotCoordinator.shared.state == .idle else {
            HUDPresenter.shared.show(message: L10n.string("quickFeatures.screenshotInProgress"))
            return
        }
        guard QuickFeaturePermissions.hasScreenRecordingAccess else {
            QuickFeaturePermissions.requestScreenRecordingAccess()
            HUDPresenter.shared.show(message: L10n.string("quickFeatures.screenshotPermissionRequired"))
            return
        }
        ScreenshotCoordinator.shared.capture(.region)
    }

}

private extension KeyboardShortcut {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
