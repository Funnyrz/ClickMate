import AppKit
import Combine
import OSLog
import Security
import ServiceManagement

@MainActor
final class QuickFeatureHelperService: ObservableObject {
    static let shared = QuickFeatureHelperService()
    static let helperBundleIdentifier = "com.zxacn.clickmate.Helper"

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "PermissionService")

    @Published private(set) var registrationStatus: SMAppService.Status
    @Published private(set) var runtimeSnapshot: QuickFeatureRuntimeSnapshot?
    @Published private(set) var launchMode: QuickFeatureHelperLaunchMode
    private(set) var hasStableInstalledIdentity: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var diagnosticMessage: String?
    @Published private(set) var isRepairing = false
    @Published private(set) var permissionStates: [QuickFeaturePermissionKind: QuickFeaturePermissionState] = [
        .accessibility: .unknown,
        .screenRecording: .unknown
    ]
    @Published private(set) var permissionFailureMessages: [QuickFeaturePermissionKind: String] = [:]
    @Published private(set) var mainDiskAccessStatus: DiskAccessStatus
    @Published private(set) var finderDiskAccessStatus: DiskAccessStatus = .unknown
    @Published private(set) var finderExtensionStatus: FinderExtensionStatus = .unknown
    @Published private(set) var finderExtensionRuntimeSnapshot: FinderExtensionRuntimeSnapshot?
    @Published private(set) var finderExtensionNeedsPolicyReload = false
    @Published private(set) var finderExtensionPolicyMessage: String?
    @Published private(set) var isReloadingFinderExtension = false
    @Published private(set) var diskAccessNeedsRelaunch = false
    @Published private(set) var isApplyingDiskAccessChanges = false
    @Published private(set) var diskAccessChangesApplied = false
    @Published private(set) var diskAccessRecoveryMessage: String?
    @Published private(set) var fullDiskAccessRecoveryPhase: FullDiskAccessRecoveryPhase?
    private(set) var isFinderRuntimeChannelAvailable: Bool

    private let service: SMAppService
    private let mainBundleURL: URL
    private let helperBundleURL: URL
    private let finderExtensionBundleURL: URL
    private let fullDiskAccessRecoveryStore: FullDiskAccessRecoveryStore
    private var refreshTimer: Timer?
    private var legacyMigrationRetryTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleNeedsResynchronization = false
    private var permissionTask: Task<Void, Never>?
    private var permissionActivationTask: Task<Void, Never>?
    private var standalonePermissionRefreshTask: Task<Void, Never>?
    private var applicationActivationObserver: NSObjectProtocol?
    private var finderExtensionRefreshTask: Task<Void, Never>?
    private var finderExtensionPolicyTask: Task<Void, Never>?
    private var diskAccessRecoveryTask: Task<Void, Never>?
    private var isStarted = false
    private var startedAt: Date?
    private var shouldRun = false
    private var attemptedAutomaticRepair = false
    private var permissionRequestTracker = QuickFeaturePermissionRequestTracker()
    private var fullDiskAccessSettingsOpenedAt: Date?
    private var finderExtensionPolicyRecoveryTracker = FinderExtensionPolicyRecoveryTracker()

    init(
        service: SMAppService = .loginItem(identifier: helperBundleIdentifier),
        mainBundleURL: URL = Bundle.main.bundleURL,
        fullDiskAccessRecoveryStore: FullDiskAccessRecoveryStore = FullDiskAccessRecoveryStore(),
        isFinderRuntimeChannelAvailable: Bool = FinderExtensionRuntimeSnapshotStore.isAvailable
    ) {
        self.service = service
        self.mainBundleURL = mainBundleURL.standardizedFileURL
        self.fullDiskAccessRecoveryStore = fullDiskAccessRecoveryStore
        self.isFinderRuntimeChannelAvailable = isFinderRuntimeChannelAvailable
        helperBundleURL = mainBundleURL
            .appendingPathComponent("Contents/Library/LoginItems/ClickMateHelper.app", isDirectory: true)
            .standardizedFileURL
        finderExtensionBundleURL = mainBundleURL
            .appendingPathComponent("Contents/PlugIns/ClickMateFinderExtension.appex", isDirectory: true)
            .standardizedFileURL
        registrationStatus = service.status
        mainDiskAccessStatus = .unknown
        let resolvedLaunchMode = QuickFeatureCodeSignatureInspector.launchMode(
            mainBundleURL: mainBundleURL,
            helperBundleURL: helperBundleURL
        )
        launchMode = resolvedLaunchMode
        hasStableInstalledIdentity = resolvedLaunchMode == .managedLoginItem
        runtimeSnapshot = nil
        refreshSnapshot()
        synchronizePermissionStates()
        refreshDiskAccessStatuses()
    }

    var isRuntimeRunning: Bool {
        validatedSnapshot(runtimeSnapshot) != nil
    }

    var permissions: QuickFeatureRuntimePermissions {
        validatedSnapshot(runtimeSnapshot)?.permissions ?? QuickFeatureRuntimePermissions(
            accessibilityGranted: false,
            screenRecordingGranted: false
        )
    }

    var failedFeatureIDs: Set<QuickFeatureID> {
        validatedSnapshot(runtimeSnapshot)?.failedFeatures ?? []
    }

    var runtimePID: Int32? {
        validatedSnapshot(runtimeSnapshot)?.pid
    }

    var runtimeVersion: String? {
        validatedSnapshot(runtimeSnapshot)?.version
    }

    var lastHeartbeat: Date? {
        validatedSnapshot(runtimeSnapshot)?.updatedAt
    }

    func permissionState(for kind: QuickFeaturePermissionKind) -> QuickFeaturePermissionState {
        permissionStates[kind] ?? .unknown
    }

    func permissionFailureMessage(for kind: QuickFeaturePermissionKind) -> String? {
        permissionFailureMessages[kind]
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startedAt = .now
        observeDarwinNotifications()
        observeApplicationActivation()
        if launchMode == .managedLoginItem {
            migrateLegacyMainAppLoginItem()
        }
        synchronize(preferences: PreferencesStore.loadSnapshot())
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        resumePendingFullDiskAccessRecoveryIfNeeded()
        refreshAllStatuses()
    }

    func stop() {
        guard isStarted else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        legacyMigrationRetryTask?.cancel()
        legacyMigrationRetryTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        permissionActivationTask?.cancel()
        permissionActivationTask = nil
        standalonePermissionRefreshTask?.cancel()
        standalonePermissionRefreshTask = nil
        finderExtensionRefreshTask?.cancel()
        finderExtensionRefreshTask = nil
        finderExtensionPolicyTask?.cancel()
        finderExtensionPolicyTask = nil
        diskAccessRecoveryTask?.cancel()
        diskAccessRecoveryTask = nil
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
        isStarted = false
        startedAt = nil
    }

    func synchronize(preferences: ClickMatePreferences) {
        guard QuickFeatureHelperConfigurationStore.write(preferences) else {
            lastError = L10n.string("permissions.backgroundServiceConfigurationFailed")
            return
        }
        shouldRun = QuickFeatureHelperPolicy.shouldRun(preferences: preferences)
        registrationStatus = service.status
        guard shouldRun else {
            scheduleLifecycle { service in
                await service.disableHelper()
            }
            return
        }

        switch launchMode {
        case .managedLoginItem:
            switch registrationStatus {
            case .notRegistered:
                scheduleLifecycle { service in
                    await service.registerManagedHelper()
                }
            case .enabled:
                scheduleLifecycle { service in
                    _ = await service.ensureHelperRunning()
                }
            case .requiresApproval:
                diagnosticMessage = L10n.string("permissions.backgroundServiceRequiresApproval")
            case .notFound:
                fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
            @unknown default:
                fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
            }
        case .directSession:
            scheduleLifecycle { service in
                _ = await service.ensureHelperRunning()
            }
        }
        refresh()
    }

    func requestAccessibilityAccess() {
        requestPermission(.accessibility)
    }

    func requestScreenRecordingAccess() {
        requestPermission(.screenRecording)
    }

    func openPermissionSettings(_ kind: QuickFeaturePermissionKind) {
        if let activeRequest = permissionRequestTracker.context {
            if activeRequest.kind == kind {
                _ = permissionRequestTracker.markSettingsOpened(requestID: activeRequest.id)
            }
        } else if let request = permissionRequestTracker.begin(kind: kind, settingsOpened: true) {
            setPermissionState(.waitingForUser, for: kind)
            startPermissionPolling(requestID: request.id)
        }
        switch kind {
        case .accessibility:
            QuickFeaturePermissions.openAccessibilitySettings()
        case .screenRecording:
            QuickFeaturePermissions.openScreenRecordingSettings()
        }
    }

    func openFullDiskAccessSettings() {
        fullDiskAccessSettingsOpenedAt = .now
        if isFinderRuntimeChannelAvailable {
            diskAccessChangesApplied = false
            diskAccessRecoveryMessage = nil
            diskAccessNeedsRelaunch = false
            fullDiskAccessRecoveryPhase = .waitingForReturn
            let request = FullDiskAccessRecoveryRequest(
                previousApplicationPID: ProcessInfo.processInfo.processIdentifier,
                previousFinderExtensionPID: currentFinderExtensionRuntimeSnapshot()?.pid
            )
            _ = fullDiskAccessRecoveryStore.write(request)
        } else {
            resetFullDiskAccessRecoveryForUnavailableChannel()
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func applyFullDiskAccessChanges() {
        guard isFinderRuntimeChannelAvailable else {
            resetFullDiskAccessRecoveryForUnavailableChannel()
            return
        }
        scheduleFullDiskAccessRelaunch()
    }

    func refreshAllStatuses() {
        refreshRuntimeStatus()
        refreshDiskAccessStatuses()
        refreshFinderExtensionStatus()
        if let request = permissionRequestTracker.context {
            startPermissionPolling(requestID: request.id)
        }
    }

    func reloadFinderExtension() {
        startFinderExtensionPolicyReload(isAutomatic: false)
    }

    func handleApplicationDidBecomeActive() {
        permissionActivationTask?.cancel()
        logger.debug("Application activation scheduled permission refresh")
        permissionActivationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            refreshRuntimeStatus()
            refreshDiskAccessStatuses()
            refreshFinderExtensionStatus()
            if let request = permissionRequestTracker.context {
                startPermissionPolling(requestID: request.id)
            }
            if fullDiskAccessSettingsOpenedAt != nil {
                fullDiskAccessSettingsOpenedAt = nil
                if isFinderRuntimeChannelAvailable {
                    scheduleFullDiskAccessRelaunch()
                } else {
                    resetFullDiskAccessRecoveryForUnavailableChannel()
                }
            }
        }
    }

    private func observeApplicationActivation() {
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleApplicationDidBecomeActive()
            }
        }
    }

    private func startPermissionPolling(requestID: UUID) {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            guard let self else { return }
            await pollPendingPermission(requestID: requestID)
        }
    }

    func refreshRuntimeStatus() {
        refreshSnapshot()
        if isRuntimeRunning, permissionRequestTracker.context == nil {
            startStandalonePermissionRefresh()
        } else if shouldRun, permissionRequestTracker.context == nil {
            scheduleLifecycle { service in
                _ = await service.ensureHelperRunning()
            }
        }
        refresh()
    }

    private func refreshDiskAccessStatuses() {
        mainDiskAccessStatus = .unknown
        guard isFinderRuntimeChannelAvailable else {
            finderExtensionRuntimeSnapshot = nil
            finderDiskAccessStatus = .unknown
            return
        }
        if let snapshot = currentFinderExtensionRuntimeSnapshot() {
            finderExtensionRuntimeSnapshot = snapshot
            finderDiskAccessStatus = snapshot.diskAccessStatus
            finderExtensionNeedsPolicyReload = false
            finderExtensionPolicyMessage = nil
        } else {
            finderExtensionRuntimeSnapshot = nil
            finderDiskAccessStatus = .unknown
        }
    }

    private func startFinderExtensionPolicyReload(isAutomatic: Bool) {
        guard finderExtensionPolicyTask == nil, diskAccessRecoveryTask == nil else { return }
        guard finderExtensionPolicyRecoveryTracker.begin(isAutomatic: isAutomatic) else { return }

        let previousPID = finderExtensionRuntimeSnapshot?.pid
            ?? currentFinderExtensionProcessIdentifier()
        isReloadingFinderExtension = true
        finderExtensionPolicyMessage = nil
        logger.info(
            "Finder Extension policy reload started automatic=\(isAutomatic, privacy: .public) previousPID=\(previousPID ?? 0, privacy: .public)"
        )
        finderExtensionPolicyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isReloadingFinderExtension = false
                finderExtensionPolicyTask = nil
            }

            let reloaded = await reloadFinderExtensionProcess(
                previousPID: previousPID,
                timeout: 10
            )
            guard finderExtensionStatus == .enabled else {
                finderExtensionNeedsPolicyReload = true
                finderExtensionPolicyMessage = L10n.string("permissions.finderPolicyReloadFailed")
                logger.error("Finder Extension policy reload could not enable extension")
                return
            }

            refreshDiskAccessStatuses()
            if reloaded {
                finderExtensionNeedsPolicyReload = false
                finderExtensionPolicyMessage = nil
                if var request = fullDiskAccessRecoveryStore.load(),
                   request.phase == .failed || request.phase == .reloadingExtension {
                    request.markCompleted()
                    _ = fullDiskAccessRecoveryStore.write(request)
                    fullDiskAccessRecoveryStore.remove()
                    fullDiskAccessRecoveryPhase = .completed
                    diskAccessChangesApplied = true
                    diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessAppliedDetail")
                }
                logger.info("Finder Extension policy reload completed")
            } else {
                finderExtensionNeedsPolicyReload = true
                finderExtensionPolicyMessage = L10n.string("permissions.finderPolicyReloadTimedOut")
                logger.error("Finder Extension policy reload timed out")
            }
        }
    }

    private func resumePendingFullDiskAccessRecoveryIfNeeded() {
        guard isFinderRuntimeChannelAvailable else {
            resetFullDiskAccessRecoveryForUnavailableChannel()
            return
        }
        guard diskAccessRecoveryTask == nil,
              var request = fullDiskAccessRecoveryStore.load()
        else { return }

        fullDiskAccessRecoveryPhase = request.phase
        switch request.phase {
        case .waitingForReturn:
            diskAccessNeedsRelaunch = true
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessRestartRequired")
            return
        case .relaunchScheduled:
            guard request.markExtensionReloadStarted(
                currentApplicationPID: ProcessInfo.processInfo.processIdentifier
            ) else { return }
            guard fullDiskAccessRecoveryStore.write(request) else {
                diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessApplyFailed")
                fullDiskAccessRecoveryPhase = .failed
                return
            }
        case .reloadingExtension:
            request.markFailed()
            _ = fullDiskAccessRecoveryStore.write(request)
            fullDiskAccessRecoveryPhase = .failed
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessApplyFailed")
            finderExtensionNeedsPolicyReload = true
            return
        case .completed:
            fullDiskAccessRecoveryStore.remove()
            diskAccessChangesApplied = true
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessAppliedDetail")
            return
        case .failed:
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessApplyFailed")
            finderExtensionNeedsPolicyReload = true
            return
        }

        let previousPID = request.previousFinderExtensionPID
        diskAccessNeedsRelaunch = false
        diskAccessChangesApplied = false
        diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessReloadingExtension")
        fullDiskAccessRecoveryPhase = .reloadingExtension
        isApplyingDiskAccessChanges = true
        logger.info(
            "Full Disk Access recovery started request=\(request.id.uuidString, privacy: .public) previousPID=\(previousPID ?? 0, privacy: .public)"
        )
        diskAccessRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isApplyingDiskAccessChanges = false
                diskAccessRecoveryTask = nil
            }

            let reloaded = await reloadFinderExtensionProcess(
                previousPID: previousPID,
                timeout: 10
            )
            refreshDiskAccessStatuses()
            guard reloaded else {
                request.markFailed()
                _ = fullDiskAccessRecoveryStore.write(request)
                fullDiskAccessRecoveryPhase = .failed
                diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessApplyFailed")
                finderExtensionNeedsPolicyReload = true
                logger.error(
                    "Full Disk Access recovery failed request=\(request.id.uuidString, privacy: .public)"
                )
                return
            }

            request.markCompleted()
            _ = fullDiskAccessRecoveryStore.write(request)
            fullDiskAccessRecoveryStore.remove()
            fullDiskAccessRecoveryPhase = .completed
            diskAccessChangesApplied = true
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessAppliedDetail")
            logger.info(
                "Full Disk Access recovery completed request=\(request.id.uuidString, privacy: .public)"
            )
        }
    }

    private func scheduleFullDiskAccessRelaunch() {
        guard isFinderRuntimeChannelAvailable else {
            resetFullDiskAccessRecoveryForUnavailableChannel()
            return
        }
        guard !isApplyingDiskAccessChanges else { return }
        var request = fullDiskAccessRecoveryStore.load() ?? FullDiskAccessRecoveryRequest(
            previousApplicationPID: ProcessInfo.processInfo.processIdentifier,
            previousFinderExtensionPID: currentFinderExtensionRuntimeSnapshot()?.pid
        )
        guard request.markRelaunchScheduled() else { return }
        guard fullDiskAccessRecoveryStore.write(request) else {
            fullDiskAccessRecoveryPhase = .failed
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessApplyFailed")
            return
        }
        diskAccessNeedsRelaunch = false
        diskAccessChangesApplied = false
        isApplyingDiskAccessChanges = true
        fullDiskAccessRecoveryPhase = .relaunchScheduled
        diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessRelaunching")
        logger.info(
            "Full Disk Access relaunch scheduled request=\(request.id.uuidString, privacy: .public) previousPID=\(request.previousApplicationPID ?? 0, privacy: .public)"
        )
        guard QuickFeaturePermissions.relaunchApplication() else {
            request.markFailed()
            _ = fullDiskAccessRecoveryStore.write(request)
            isApplyingDiskAccessChanges = false
            fullDiskAccessRecoveryPhase = .failed
            diskAccessRecoveryMessage = L10n.string("permissions.fullDiskAccessApplyFailed")
            return
        }
    }

    private func reloadFinderExtensionProcess(
        previousPID: Int32?,
        timeout: TimeInterval
    ) async -> Bool {
        let reloadStartedAt = Date.now
        await terminateFinderExtensionProcesses()
        let status = await FinderExtensionPolicy.reloadBundledExtension()
        finderExtensionStatus = status
        guard status == .enabled else { return false }
        guard isFinderRuntimeChannelAvailable else {
            return await waitForCurrentFinderExtensionProcess(
                previousPID: previousPID,
                timeout: timeout
            )
        }
        return await waitForCurrentFinderMonitoringPolicy(
            previousPID: previousPID,
            updatedAfter: reloadStartedAt,
            timeout: timeout
        )
    }

    private func terminateFinderExtensionProcesses() async {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: AppConstants.finderExtensionBundleIdentifier
        )
        applications.forEach { $0.terminate() }
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            guard !Task.isCancelled else { return }
            if NSRunningApplication.runningApplications(
                withBundleIdentifier: AppConstants.finderExtensionBundleIdentifier
            ).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        NSRunningApplication.runningApplications(
            withBundleIdentifier: AppConstants.finderExtensionBundleIdentifier
        ).forEach { $0.forceTerminate() }
    }

    private func waitForCurrentFinderMonitoringPolicy(
        previousPID: Int32?,
        updatedAfter: Date,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            if let snapshot = currentFinderExtensionRuntimeSnapshot(
                previousPID: previousPID,
                updatedAfter: updatedAfter
            ) {
                finderExtensionRuntimeSnapshot = snapshot
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func waitForCurrentFinderExtensionProcess(
        previousPID: Int32?,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            if currentFinderExtensionProcessIdentifier(excluding: previousPID) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func currentFinderExtensionRuntimeSnapshot(
        previousPID: Int32? = nil,
        updatedAfter: Date? = nil
    ) -> FinderExtensionRuntimeSnapshot? {
        guard isFinderRuntimeChannelAvailable,
              let snapshot = FinderExtensionRuntimeSnapshotStore.load(),
              FinderExtensionRuntimeSnapshotPolicy.accepts(
                  snapshot,
                  currentVersion: currentAppVersion,
                  previousPID: previousPID,
                  updatedAfter: updatedAfter,
                  isExpectedRunningProcess: isExpectedFinderExtensionProcess
              )
        else { return nil }
        return snapshot
    }

    private func isExpectedFinderExtensionProcess(_ processIdentifier: Int32) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }
        return application.bundleIdentifier == AppConstants.finderExtensionBundleIdentifier
            && application.bundleURL?.standardizedFileURL == finderExtensionBundleURL
    }

    private func currentFinderExtensionProcessIdentifier(excluding excludedPID: Int32? = nil) -> Int32? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: AppConstants.finderExtensionBundleIdentifier
        ).first { application in
            application.processIdentifier != excludedPID
                && application.bundleURL?.standardizedFileURL == finderExtensionBundleURL
        }?.processIdentifier
    }

    private func resetFullDiskAccessRecoveryForUnavailableChannel() {
        fullDiskAccessRecoveryStore.remove()
        fullDiskAccessRecoveryPhase = nil
        diskAccessNeedsRelaunch = false
        isApplyingDiskAccessChanges = false
        diskAccessChangesApplied = false
        diskAccessRecoveryMessage = nil
        finderExtensionNeedsPolicyReload = false
        finderExtensionPolicyMessage = nil
    }

    private func refreshFinderExtensionStatus() {
        finderExtensionRefreshTask?.cancel()
        finderExtensionRefreshTask = Task { [weak self] in
            let status = await FinderExtensionPolicy.status()
            guard !Task.isCancelled, let self else { return }
            finderExtensionStatus = status
        }
    }

    @discardableResult
    func beginShortcutRecording(sessionID: UUID) -> Bool {
        enqueue(.beginShortcutRecording(sessionID: sessionID)) != nil
    }

    func endShortcutRecording(sessionID: UUID) {
        _ = enqueue(.endShortcutRecording(sessionID: sessionID))
    }

    func restart() {
        scheduleLifecycle { service in
            _ = await service.restartHelperProcess()
        }
    }

    func repair() {
        guard !isRepairing, lifecycleTask == nil else { return }
        isRepairing = true
        lastError = nil
        scheduleLifecycle { service in
            defer { service.isRepairing = false }
            switch service.launchMode {
            case .managedLoginItem:
                await service.repairManagedHelper()
            case .directSession:
                _ = await service.restartHelperProcess()
            }
        }
    }

    func refresh() {
        registrationStatus = service.status
        refreshSnapshot()
        synchronizePermissionStates()
        if shouldRun,
           launchMode == .managedLoginItem,
           registrationStatus == .enabled,
           !isRuntimeRunning,
           !attemptedAutomaticRepair,
           !isRepairing,
           permissionRequestTracker.context == nil,
           lifecycleTask == nil,
           let startedAt,
           Date.now.timeIntervalSince(startedAt) >= 4 {
            attemptedAutomaticRepair = true
            repair()
        }
        NotificationCenter.default.post(name: .quickFeatureHelperStatusChanged, object: self)
    }

    private func requestPermission(_ kind: QuickFeaturePermissionKind) {
        guard let request = permissionRequestTracker.begin(kind: kind) else { return }
        permissionFailureMessages[kind] = nil
        setPermissionState(.checking, for: kind)
        logger.info("Permission request started kind=\(kind.rawValue, privacy: .public) request=\(request.id.uuidString, privacy: .public)")
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let isRunning = await ensureHelperRunning()
            guard isRunning else {
                failPermissionRequest(
                    requestID: request.id,
                    messageKey: "permissions.permissionHelperUnavailable"
                )
                return
            }
            let action: QuickFeatureHelperCommand.Action = switch kind {
            case .accessibility: .requestAccessibility
            case .screenRecording: .requestScreenRecording
            }
            guard let command = enqueue(action) else {
                failPermissionRequest(
                    requestID: request.id,
                    messageKey: "permissions.permissionRequestFailed"
                )
                return
            }
            guard permissionRequestTracker.assignCommandID(command.id, requestID: request.id) else {
                return
            }
            setPermissionState(.waitingForUser, for: kind)
            let acknowledged = await waitForCommandAcknowledgement(command.id, timeout: 3)
            logger.info("Permission command acknowledgement kind=\(kind.rawValue, privacy: .public) command=\(command.id.uuidString, privacy: .public) acknowledged=\(acknowledged, privacy: .public)")
            guard acknowledged else {
                failPermissionRequest(
                    requestID: request.id,
                    messageKey: "permissions.permissionRequestFailed"
                )
                return
            }
            await pollPendingPermission(requestID: request.id)
        }
    }

    private func pollPendingPermission(requestID: UUID) async {
        for delay in QuickFeaturePermissionPollingPolicy.refreshDelays {
            guard let request = permissionRequestTracker.context, request.id == requestID else {
                return
            }
            guard !Task.isCancelled else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            _ = await refreshPermissionSnapshot(requestID: requestID)
            if permissionIsGranted(request.kind) {
                completePermissionRequest(requestID: requestID)
                return
            }
            if request.kind == .screenRecording,
               permissionRequestDiagnosticIndicatesGrant(for: request) {
                await attemptPermissionRecoveryIfNeeded(requestID: requestID)
            }
            guard let currentRequest = permissionRequestTracker.context,
                  currentRequest.id == requestID,
                  !currentRequest.isExpired()
            else { break }
        }
        failPermissionRequest(
            requestID: requestID,
            messageKey: permissionRequestTracker.context?.kind == .accessibility
                ? "permissions.accessibilityAuthorizationNotDetected"
                : "permissions.permissionRequestTimedOut"
        )
    }

    private func startStandalonePermissionRefresh() {
        guard standalonePermissionRefreshTask == nil,
              permissionRequestTracker.context == nil
        else { return }
        standalonePermissionRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { standalonePermissionRefreshTask = nil }
            guard await ensureHelperRunning() else { return }
            let refreshed = await refreshPermissionSnapshot(requestID: nil)
            logger.debug(
                "Standalone permission refresh completed refreshed=\(refreshed, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func refreshPermissionSnapshot(requestID: UUID?) async -> Bool {
        refreshSnapshot()
        let previousUpdatedAt = validatedSnapshot(runtimeSnapshot)?.updatedAt
        guard let command = enqueue(.refreshStatus) else { return false }
        logger.debug(
            "Permission refresh command enqueued command=\(command.id.uuidString, privacy: .public) activeRequest=\(requestID?.uuidString ?? "none", privacy: .public)"
        )
        if let requestID {
            guard let generation = permissionRequestTracker.beginRefresh(
                commandID: command.id,
                observedSnapshotUpdatedAt: previousUpdatedAt,
                requestID: requestID
            ) else { return false }
            logger.debug(
                "Permission refresh requested request=\(requestID.uuidString, privacy: .public) command=\(command.id.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
        }
        let refreshed = await waitForRefreshedPermissionSnapshot(
            commandID: command.id,
            after: previousUpdatedAt,
            timeout: 1.5
        )
        refreshSnapshot()
        synchronizePermissionStates()
        return refreshed
    }

    private func waitForRefreshedPermissionSnapshot(
        commandID: UUID,
        after previousUpdatedAt: Date?,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            refreshSnapshot()
            if let snapshot = validatedSnapshot(runtimeSnapshot),
               snapshot.lastProcessedCommandID == commandID {
                let isNewSnapshot = previousUpdatedAt.map { snapshot.updatedAt > $0 } ?? true
                if isNewSnapshot {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func permissionIsGranted(_ kind: QuickFeaturePermissionKind) -> Bool {
        guard let snapshot = validatedSnapshot(runtimeSnapshot) else { return false }
        switch kind {
        case .accessibility:
            return snapshot.permissions.accessibilityGranted
        case .screenRecording:
            return snapshot.permissions.screenRecordingGranted
        }
    }

    private func permissionRequestDiagnosticIndicatesGrant(
        for request: QuickFeaturePermissionRequestContext
    ) -> Bool {
        guard let commandID = request.commandID,
              let diagnostic = validatedSnapshot(runtimeSnapshot)?.lastPermissionRequest,
              diagnostic.commandID == commandID,
              diagnostic.kind == .screenRecording
        else { return false }
        return diagnostic.requestReturnedGranted || diagnostic.observedPermissionGranted
    }

    private func attemptPermissionRecoveryIfNeeded(requestID: UUID) async {
        guard let request = permissionRequestTracker.context,
              request.id == requestID,
              request.kind == .screenRecording,
              permissionRequestTracker.markRecoveryAttempted(requestID: requestID)
        else { return }
        setPermissionState(.restartRequired, for: request.kind)
        logger.info("Permission recovery restarting helper kind=\(request.kind.rawValue, privacy: .public) request=\(requestID.uuidString, privacy: .public)")
        guard await restartHelperProcess() else {
            failPermissionRequest(
                requestID: requestID,
                messageKey: "permissions.permissionRestartFailed"
            )
            return
        }
        if await waitForPermissionGrantAfterRecovery(request.kind, timeout: 4) {
            completePermissionRequest(requestID: requestID)
            return
        }
        failPermissionRequest(
            requestID: requestID,
            messageKey: request.kind == .accessibility
                ? "permissions.accessibilityAuthorizationNotDetected"
                : "permissions.permissionAuthorizationNotDetected"
        )
    }

    private func waitForPermissionGrantAfterRecovery(
        _ kind: QuickFeaturePermissionKind,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            _ = enqueue(.refreshStatus)
            try? await Task.sleep(for: .milliseconds(250))
            refreshSnapshot()
            synchronizePermissionStates()
            if permissionIsGranted(kind) {
                return true
            }
        }
        return false
    }

    private func completePermissionRequest(requestID: UUID) {
        guard let request = permissionRequestTracker.context, request.id == requestID else { return }
        permissionRequestTracker.clear(requestID: requestID)
        permissionFailureMessages[request.kind] = nil
        setPermissionState(.granted, for: request.kind)
        permissionTask = nil
        permissionActivationTask?.cancel()
        permissionActivationTask = nil
        logger.info("Permission request completed kind=\(request.kind.rawValue, privacy: .public) request=\(requestID.uuidString, privacy: .public)")
    }

    private func failPermissionRequest(requestID: UUID, messageKey: String) {
        guard let request = permissionRequestTracker.context, request.id == requestID else { return }
        permissionRequestTracker.clear(requestID: requestID)
        permissionFailureMessages[request.kind] = L10n.string(messageKey)
        setPermissionState(.failed, for: request.kind)
        permissionTask = nil
        permissionActivationTask?.cancel()
        permissionActivationTask = nil
        logger.error("Permission request failed kind=\(request.kind.rawValue, privacy: .public) request=\(requestID.uuidString, privacy: .public) reason=\(messageKey, privacy: .public)")
    }

    private func setPermissionState(
        _ state: QuickFeaturePermissionState,
        for kind: QuickFeaturePermissionKind
    ) {
        guard permissionStates[kind] != state else { return }
        permissionStates[kind] = state
    }

    private func synchronizePermissionStates() {
        let activeKind = permissionRequestTracker.context?.kind
        guard let snapshot = validatedSnapshot(runtimeSnapshot) else {
            for kind in QuickFeaturePermissionKind.allCases where kind != activeKind {
                setPermissionState(.unknown, for: kind)
            }
            return
        }
        for kind in QuickFeaturePermissionKind.allCases {
            let granted = switch kind {
            case .accessibility: snapshot.permissions.accessibilityGranted
            case .screenRecording: snapshot.permissions.screenRecordingGranted
            }
            if granted {
                permissionFailureMessages[kind] = nil
                setPermissionState(.granted, for: kind)
            } else if kind != activeKind {
                setPermissionState(
                    permissionFailureMessages[kind] == nil ? .notGranted : .failed,
                    for: kind
                )
            }
        }
    }

    private func registerManagedHelper() async {
        do {
            try service.register()
            registrationStatus = service.status
            if registrationStatus == .requiresApproval {
                diagnosticMessage = L10n.string("permissions.backgroundServiceRequiresApproval")
                return
            }
            guard registrationStatus == .enabled else {
                fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
                _ = await ensureHelperRunning()
                return
            }
            diagnosticMessage = nil
            if !(await ensureHelperRunning()) {
                fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
                _ = await ensureHelperRunning()
            }
        } catch {
            fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
            _ = await ensureHelperRunning()
        }
    }

    private func repairManagedHelper() async {
        if isRuntimeRunning, await restartHelperProcess() {
            return
        }

        do {
            if service.status != .notRegistered {
                try await service.unregister()
                guard await waitForRegistrationStatus(.notRegistered, timeout: 5) else {
                    fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
                    _ = await ensureHelperRunning()
                    return
                }
            }
            try service.register()
            registrationStatus = service.status
            if registrationStatus == .requiresApproval {
                diagnosticMessage = L10n.string("permissions.backgroundServiceRequiresApproval")
                return
            }
            guard registrationStatus == .enabled,
                  await ensureHelperRunning()
            else {
                fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
                _ = await ensureHelperRunning()
                return
            }
            lastError = nil
            diagnosticMessage = nil
        } catch {
            fallbackToDirectSession(reasonKey: "permissions.backgroundServiceManagedFallback")
            if !(await ensureHelperRunning()) {
                lastError = L10n.string("permissions.backgroundServiceDirectLaunchFailed")
            }
        }
    }

    private func disableHelper() async {
        _ = enqueue(.shutdown)
        await waitForHelperToExit(timeout: 3)
        if !matchingHelperApplications().isEmpty {
            await terminateMatchingHelpers()
        }
        if launchMode != .directSession, service.status != .notRegistered {
            do {
                try await service.unregister()
            } catch {
                diagnosticMessage = L10n.string("permissions.backgroundServiceCleanupDeferred")
            }
        }
        refreshSnapshot()
    }

    private func ensureHelperRunning(forceRelaunch: Bool = false) async -> Bool {
        refreshSnapshot()
        if isRuntimeRunning, !forceRelaunch {
            return true
        }
        if forceRelaunch || !matchingHelperApplications().isEmpty {
            await terminateMatchingHelpers()
        }
        guard FileManager.default.fileExists(atPath: helperBundleURL.path) else {
            lastError = L10n.string("permissions.backgroundServiceUnavailable")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let launched = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: helperBundleURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        guard launched, await waitForRuntime(timeout: 5) else {
            lastError = L10n.string("permissions.backgroundServiceDirectLaunchFailed")
            return false
        }
        lastError = nil
        if launchMode == .directSession {
            diagnosticMessage = L10n.string("permissions.backgroundServiceDirectSession")
        }
        return true
    }

    private func restartHelperProcess() async -> Bool {
        _ = enqueue(.shutdown)
        await waitForHelperToExit(timeout: 3)
        return await ensureHelperRunning(forceRelaunch: true)
    }

    private func terminateMatchingHelpers() async {
        for application in matchingHelperApplications() {
            application.terminate()
        }
        await waitForHelperToExit(timeout: 2)
        for application in matchingHelperApplications() {
            application.forceTerminate()
        }
        await waitForHelperToExit(timeout: 1)
    }

    private func matchingHelperApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperBundleIdentifier)
    }

    private func waitForRuntime(timeout: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            refreshSnapshot()
            if isRuntimeRunning { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        refreshSnapshot()
        return isRuntimeRunning
    }

    private func waitForHelperToExit(timeout: TimeInterval) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return }
            if matchingHelperApplications().isEmpty {
                QuickFeatureRuntimeSnapshotStore.remove()
                refreshSnapshot()
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        refreshSnapshot()
    }

    private func waitForRegistrationStatus(
        _ expectedStatus: SMAppService.Status,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            registrationStatus = service.status
            if registrationStatus == expectedStatus { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        registrationStatus = service.status
        return registrationStatus == expectedStatus
    }

    private func waitForCommandAcknowledgement(_ commandID: UUID, timeout: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard !Task.isCancelled else { return false }
            refreshSnapshot()
            if validatedSnapshot(runtimeSnapshot)?.lastProcessedCommandID == commandID {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @discardableResult
    private func enqueue(_ action: QuickFeatureHelperCommand.Action) -> QuickFeatureHelperCommand? {
        guard isRuntimeRunning else { return nil }
        return QuickFeatureHelperCommandQueue.enqueueCommand(action)
    }

    private func fallbackToDirectSession(reasonKey: String) {
        launchMode = .directSession
        diagnosticMessage = L10n.string(reasonKey)
        lastError = nil
    }

    private func refreshSnapshot() {
        guard let snapshot = QuickFeatureRuntimeSnapshotStore.load() else {
            runtimeSnapshot = nil
            return
        }
        guard snapshotIdentityIsValid(snapshot) else {
            runtimeSnapshot = nil
            QuickFeatureRuntimeSnapshotStore.remove()
            return
        }
        runtimeSnapshot = snapshot
    }

    private func validatedSnapshot(
        _ snapshot: QuickFeatureRuntimeSnapshot?
    ) -> QuickFeatureRuntimeSnapshot? {
        guard let snapshot,
              !snapshot.isStale(),
              snapshot.version == currentAppVersion,
              let application = NSRunningApplication(processIdentifier: snapshot.pid),
              application.bundleIdentifier == Self.helperBundleIdentifier,
              application.bundleURL?.standardizedFileURL == helperBundleURL
        else {
            return nil
        }
        return snapshot
    }

    private func snapshotIdentityIsValid(_ snapshot: QuickFeatureRuntimeSnapshot) -> Bool {
        guard snapshot.version == currentAppVersion,
              let application = NSRunningApplication(processIdentifier: snapshot.pid),
              application.bundleIdentifier == Self.helperBundleIdentifier,
              application.bundleURL?.standardizedFileURL == helperBundleURL
        else { return false }
        return true
    }

    private func scheduleLifecycle(
        _ operation: @escaping @MainActor (QuickFeatureHelperService) async -> Void
    ) {
        guard lifecycleTask == nil else {
            lifecycleNeedsResynchronization = true
            return
        }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            lifecycleTask = nil
            if lifecycleNeedsResynchronization {
                lifecycleNeedsResynchronization = false
                synchronize(preferences: PreferencesStore.loadSnapshot())
            } else {
                refresh()
                if isRuntimeRunning, permissionRequestTracker.context == nil {
                    startStandalonePermissionRefresh()
                }
            }
        }
    }

    private func migrateLegacyMainAppLoginItem(allowRetry: Bool = true) {
        let legacyService = SMAppService.mainApp
        guard legacyService.status != .notRegistered else { return }
        do {
            try legacyService.unregister()
        } catch {
            guard allowRetry else {
                diagnosticMessage = L10n.string("permissions.backgroundServiceCleanupDeferred")
                return
            }
            legacyMigrationRetryTask?.cancel()
            legacyMigrationRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.migrateLegacyMainAppLoginItem(allowRetry: false)
            }
        }
    }

    private func observeDarwinNotifications() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer else { return }
            let address = Int(bitPattern: observer)
            let notificationName = name?.rawValue as String?
            DispatchQueue.main.async {
                let service = Unmanaged<QuickFeatureHelperService>
                    .fromOpaque(UnsafeRawPointer(bitPattern: address)!)
                    .takeUnretainedValue()
                service.handleDarwinNotification(name: notificationName)
            }
        }
        for name in [
            PreferencesChangeNotifier.name,
            QuickFeatureRuntimeSnapshotStore.notificationName,
            FinderExtensionRuntimeSnapshotStore.notificationName
        ] {
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

    private func handleDarwinNotification(name: String?) {
        switch name {
        case PreferencesChangeNotifier.name:
            synchronize(preferences: PreferencesStore.loadSnapshot())
        case QuickFeatureRuntimeSnapshotStore.notificationName:
            refreshSnapshot()
            synchronizePermissionStates()
            NotificationCenter.default.post(name: .quickFeatureHelperStatusChanged, object: self)
        case FinderExtensionRuntimeSnapshotStore.notificationName:
            refreshDiskAccessStatuses()
            NotificationCenter.default.post(name: .quickFeatureHelperStatusChanged, object: self)
        default:
            refreshAllStatuses()
        }
    }

    private var currentAppVersion: String {
        QuickFeatureHelperVersion.identifier(for: .main)
    }
}

private enum QuickFeatureCodeSignatureInspector {
    private struct SignatureInformation {
        var isValid: Bool
        var teamIdentifier: String?
    }

    static func launchMode(
        mainBundleURL: URL,
        helperBundleURL: URL
    ) -> QuickFeatureHelperLaunchMode {
        let mainSignature = signatureInformation(at: mainBundleURL)
        let helperSignature = signatureInformation(at: helperBundleURL)
        return QuickFeatureHelperLaunchModeResolver.resolve(
            mainTeamIdentifier: mainSignature.teamIdentifier,
            helperTeamIdentifier: helperSignature.teamIdentifier,
            mainSignatureIsValid: mainSignature.isValid,
            helperSignatureIsValid: helperSignature.isValid,
            isInstalledInApplications: isInstalledInApplications(mainBundleURL)
        )
    }

    private static func signatureInformation(at url: URL) -> SignatureInformation {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        else {
            return SignatureInformation(isValid: false, teamIdentifier: nil)
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
            return SignatureInformation(isValid: true, teamIdentifier: nil)
        }
        return SignatureInformation(
            isValid: true,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }

    private static func isInstalledInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true).path + "/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path + "/"
        return path.hasPrefix(systemApplications) || path.hasPrefix(userApplications)
    }
}

extension Notification.Name {
    static let quickFeatureHelperStatusChanged = Notification.Name(
        "ClickMate.quickFeatureHelperStatusChanged"
    )
}
