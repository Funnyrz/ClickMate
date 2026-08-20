import AppKit
import Carbon.HIToolbox

@MainActor
final class QuickFeatureCoordinator {
    private let hotKeyRegistrar = GlobalHotKeyRegistrar()
    private let finderCutController = FinderCutController()
    private var activationObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?
    private var isStarted = false
    private var isRecordingShortcut = false
    private let configurationURL: URL
    private let configurationNotificationName: String
    private(set) var failedFeatureIDs: Set<QuickFeatureID> = []
    private(set) var enabledFeatureIDs: Set<QuickFeatureID> = []

    init(
        configurationURL: URL = QuickFeatureHelperConfigurationStore.fileURL,
        configurationNotificationName: String = QuickFeatureHelperConfigurationStore.notificationName
    ) {
        self.configurationURL = configurationURL
        self.configurationNotificationName = configurationNotificationName
    }

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
        observePreferenceChanges()
        QuickFeaturePermissionMonitor.shared.refreshOnce()
        reloadConfiguration()
    }

    func stop() {
        guard isStarted else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(configurationNotificationName as CFString),
            nil
        )
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        hotKeyRegistrar.invalidate()
        finderCutController.stop()
        ScreenshotCoordinator.shared.cancel()
        reloadTask?.cancel()
        reloadTask = nil
        isStarted = false
    }

    func setShortcutRecording(_ isRecording: Bool) {
        guard isRecordingShortcut != isRecording else { return }
        isRecordingShortcut = isRecording
        if isRecording {
            hotKeyRegistrar.unregisterAll()
            finderCutController.stop()
            failedFeatureIDs = []
        } else {
            reloadConfiguration()
        }
    }

    @discardableResult
    func refreshPermissionsAndConfiguration() -> QuickFeaturePermissionSnapshot {
        QuickFeaturePermissionMonitor.shared.refreshOnce()
        reloadConfiguration()
        return QuickFeaturePermissionMonitor.shared.snapshot
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
            configurationNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    func reloadConfiguration() {
        reloadTask?.cancel()
        let fileURL = configurationURL
        reloadTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: fileURL)
            }.value
            guard !Task.isCancelled, let self else { return }
            let configuration = data.flatMap {
                try? JSONDecoder().decode(QuickFeatureHelperConfiguration.self, from: $0)
            } ?? .defaults
            applyConfiguration(configuration.quickFeatureSettings)
        }
    }

    private func applyConfiguration(_ quickFeatureSettings: [QuickFeatureSettings]) {
        hotKeyRegistrar.unregisterAll()
        finderCutController.stop()

        let settings = QuickFeatureSettings.normalized(quickFeatureSettings)
        enabledFeatureIDs = Set(settings.filter(\.isEnabled).map(\.id))
        let conflicts = QuickFeatureSettings.conflictingFeatureIDs(in: settings)
        var failedIDs = conflicts

        if !isRecordingShortcut,
           let finderCut = settings.first(where: { $0.id == .finderCut }),
           finderCut.isEnabled,
           !conflicts.contains(.finderCut),
           QuickFeaturePermissionMonitor.shared.snapshot.accessibilityGranted,
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

        failedFeatureIDs = failedIDs
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
        if ScreenshotCoordinator.shared.state == .previewing {
            ScreenshotCoordinator.shared.bringPreviewToFront()
            return
        }
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

extension Notification.Name {
    static let quickFeatureRuntimeStatusChanged = Notification.Name(
        "ClickMate.quickFeatureRuntimeStatusChanged"
    )
}
