import AppKit
import OSLog

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "PermissionHelper")

    private lazy var quickFeatureCoordinator = QuickFeatureCoordinator(
        configurationURL: QuickFeatureHelperConfigurationStore.fileURL,
        configurationNotificationName: QuickFeatureHelperConfigurationStore.notificationName
    )
    private var heartbeatTimer: Timer?
    private var recordingSessionID: UUID?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var lastProcessedCommandID: UUID?
    private var lastPermissionRequest: QuickFeaturePermissionRequestDiagnostic?
    private var lastPermissions = QuickFeatureRuntimePermissions(
        accessibilityGranted: false,
        screenRecordingGranted: false
    )

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        L10n.languageProvider = {
            QuickFeatureHelperConfigurationStore.load()?.language ?? .system
        }
        observeRuntimeNotifications()
        quickFeatureCoordinator.start()
        refreshPermissionsAndPublish()
        processPendingCommands()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.heartbeat()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        recordingTimeoutTask?.cancel()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
        quickFeatureCoordinator.stop()
        if QuickFeatureRuntimeSnapshotStore.load()?.pid == ProcessInfo.processInfo.processIdentifier {
            QuickFeatureRuntimeSnapshotStore.remove()
        }
    }

    private func observeRuntimeNotifications() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let address = Int(bitPattern: observer)
            DispatchQueue.main.async {
                let delegate = Unmanaged<AppDelegate>
                    .fromOpaque(UnsafeRawPointer(bitPattern: address)!)
                    .takeUnretainedValue()
                delegate.handleRuntimeNotification()
            }
        }
        for name in [QuickFeatureHelperCommandQueue.notificationName] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func handleRuntimeNotification() {
        processPendingCommands()
    }

    private func processPendingCommands() {
        for command in QuickFeatureHelperCommandQueue.consumePending() {
            handle(command)
            lastProcessedCommandID = command.id
            publishSnapshot()
        }
    }

    private func handle(_ command: QuickFeatureHelperCommand) {
        switch command.action {
        case .requestAccessibility:
            let requestedAt = Date.now
            let returnedGranted = QuickFeaturePermissions.requestAccessibilityAccess()
            updateCachedPermission(.accessibility, granted: returnedGranted)
            recordPermissionRequest(
                command: command,
                kind: .accessibility,
                requestedAt: requestedAt,
                requestReturnedGranted: returnedGranted
            )
        case .requestScreenRecording:
            let requestedAt = Date.now
            let returnedGranted = QuickFeaturePermissions.requestScreenRecordingAccess()
            updateCachedPermission(.screenRecording, granted: returnedGranted)
            recordPermissionRequest(
                command: command,
                kind: .screenRecording,
                requestedAt: requestedAt,
                requestReturnedGranted: returnedGranted
            )
        case .refreshStatus:
            refreshPermissionsAndPublish()
        case let .beginShortcutRecording(sessionID):
            guard !command.isShortcutRecordingSessionExpired() else { return }
            recordingSessionID = sessionID
            quickFeatureCoordinator.setShortcutRecording(true)
            scheduleRecordingTimeout(for: command)
        case let .endShortcutRecording(sessionID):
            guard recordingSessionID == sessionID else { return }
            finishShortcutRecording()
        case .restart:
            restartHelper()
        case .shutdown:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func heartbeat() {
        publishSnapshot(permissions: lastPermissions)
    }

    private func publishSnapshot(
        permissions providedPermissions: QuickFeatureRuntimePermissions? = nil,
        error: String? = nil
    ) {
        var activeFeatures = quickFeatureCoordinator.enabledFeatureIDs
            .subtracting(quickFeatureCoordinator.failedFeatureIDs)
        let permissions = providedPermissions ?? lastPermissions
        if !permissions.accessibilityGranted {
            activeFeatures.remove(.finderCut)
        }
        if !permissions.screenRecordingGranted {
            activeFeatures.remove(.screenshot)
        }
        if recordingSessionID != nil {
            activeFeatures.removeAll()
        }
        QuickFeatureRuntimeSnapshotStore.write(QuickFeatureRuntimeSnapshot(
            pid: ProcessInfo.processInfo.processIdentifier,
            version: QuickFeatureHelperVersion.identifier(for: .main),
            permissions: permissions,
            activeFeatures: activeFeatures,
            failedFeatures: quickFeatureCoordinator.failedFeatureIDs,
            error: error,
            lastProcessedCommandID: lastProcessedCommandID,
            lastPermissionRequest: lastPermissionRequest
        ))
    }

    private func recordPermissionRequest(
        command: QuickFeatureHelperCommand,
        kind: QuickFeatureRuntimePermissionKind,
        requestedAt: Date,
        requestReturnedGranted: Bool
    ) {
        let permissions = lastPermissions
        let observedGranted = switch kind {
        case .accessibility: permissions.accessibilityGranted
        case .screenRecording: permissions.screenRecordingGranted
        }
        lastPermissionRequest = QuickFeaturePermissionRequestDiagnostic(
            commandID: command.id,
            kind: kind,
            requestedAt: requestedAt,
            completedAt: .now,
            requestReturnedGranted: requestReturnedGranted,
            observedPermissionGranted: observedGranted,
            processBundleIdentifier: Bundle.main.bundleIdentifier
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        logger.info(
            "Permission request completed kind=\(kind.rawValue, privacy: .public) command=\(command.id.uuidString, privacy: .public) returned=\(requestReturnedGranted, privacy: .public) observed=\(observedGranted, privacy: .public) bundle=\(bundleIdentifier, privacy: .public)"
        )
    }

    private func updateCachedPermission(
        _ kind: QuickFeatureRuntimePermissionKind,
        granted: Bool
    ) {
        switch kind {
        case .accessibility:
            lastPermissions.accessibilityGranted = granted
        case .screenRecording:
            lastPermissions.screenRecordingGranted = granted
        }
        publishSnapshot(permissions: lastPermissions)
    }

    private func refreshPermissionsAndPublish() {
        let snapshot = quickFeatureCoordinator.refreshPermissionsAndConfiguration()
        let permissions = QuickFeatureRuntimePermissions(
            accessibilityGranted: snapshot.accessibilityGranted,
            screenRecordingGranted: snapshot.screenRecordingGranted
        )
        if permissions != lastPermissions {
            lastPermissions = permissions
            logger.info(
                "Permission state changed accessibility=\(permissions.accessibilityGranted, privacy: .public) screenRecording=\(permissions.screenRecordingGranted, privacy: .public)"
            )
        }
        publishSnapshot(permissions: permissions)
    }

    private func scheduleRecordingTimeout(for command: QuickFeatureHelperCommand) {
        recordingTimeoutTask?.cancel()
        guard let expiresAt = command.recordingSessionExpiresAt else { return }
        let delay = max(expiresAt.timeIntervalSinceNow, 0)
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.recordingSessionID == command.shortcutRecordingSessionID else { return }
                self?.finishShortcutRecording()
            }
        }
    }

    private func finishShortcutRecording() {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        recordingSessionID = nil
        quickFeatureCoordinator.setShortcutRecording(false)
        publishSnapshot()
    }

    private func restartHelper() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        } catch {
            publishSnapshot(error: error.localizedDescription)
        }
    }
}
