import ServiceManagement
import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @ObservedObject private var helperService: QuickFeatureHelperService
    @State private var statusMessage = L10n.string("permissions.extensionStatusUnknown")
    @State private var trials: [FeatureGuideFeature: FeatureTrialState] = [:]
    @State private var trialDetails: [FeatureGuideFeature: String] = [:]
    @State private var cutTrial: FeatureTrialFiles?
    @State private var screenshotTrialStarting = false

    init(helperService: QuickFeatureHelperService = .shared) {
        self.helperService = helperService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack {
                Picker(L10n.string("settings.language"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FeaturePermissionGuideView(
                        readiness: Dictionary(uniqueKeysWithValues: FeatureGuideFeature.allCases.map { ($0, readinessSnapshot.status(for: $0)) }),
                        selectedFeatures: FeatureGuideFeature.selectedFeatures(in: store.preferences),
                        trials: trials,
                        trialDetails: trialDetails,
                        trialAllowedFeatures: allowedTrials,
                        onSelect: selectFeature,
                        onConfigure: configureFeature,
                        onTrial: startTrial,
                        onTrialResult: recordTrialResult,
                        onOpenTrialDestination: openCutTrialDestination
                    )
                    DisclosureGroup(L10n.string("guide.diagnostics")) {
                    VStack(alignment: .leading, spacing: 12) {
                    permissionStep(
                        number: 1,
                        titleKey: "permissions.stepInstallTitle",
                        systemImage: "app.badge",
                        statusText: isRunningFromApplications
                            ? L10n.string("permissions.installedInApplications")
                            : L10n.string("permissions.notInApplications"),
                        statusIsGood: isRunningFromApplications
                    ) {
                        Text(L10n.string("permissions.stepInstallDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    permissionStep(
                        number: 2,
                        titleKey: "permissions.stepBackgroundServiceTitle",
                        systemImage: "power",
                        statusText: backgroundServiceStatusTitle,
                        statusIsGood: helperService.isRuntimeRunning
                    ) {
                        Text(L10n.string("permissions.backgroundServiceDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle(
                            L10n.string("permissions.backgroundServiceToggle"),
                            isOn: backgroundServiceBinding
                        )
                            .toggleStyle(.switch)
                        HStack {
                            if helperService.launchMode == .managedLoginItem,
                               helperService.registrationStatus == .requiresApproval {
                                Button(L10n.string("permissions.openLoginItems")) {
                                    SMAppService.openSystemSettingsLoginItems()
                                }
                            }
                            if helperService.isRuntimeRunning {
                                Button(L10n.string("permissions.restartBackgroundService")) {
                                    helperService.restart()
                                }
                            }
                            if !helperService.isRuntimeRunning || helperService.lastError != nil {
                                Button(L10n.string("permissions.repairBackgroundService")) {
                                    helperService.repair()
                                }
                                .disabled(helperService.isRepairing)
                            }
                        }
                        if let diagnostic = helperService.diagnosticMessage {
                            Text(diagnostic)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if helperService.launchMode == .directSession,
                           !helperService.hasStableInstalledIdentity {
                            Text(L10n.string("permissions.temporarySignatureWarning"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let pid = helperService.runtimePID,
                           let version = helperService.runtimeVersion,
                           let heartbeat = helperService.lastHeartbeat {
                            Text(
                                String(
                                    format: L10n.string("permissions.backgroundServiceRuntimeDetails"),
                                    pid,
                                    version,
                                    heartbeat.formatted(date: .omitted, time: .standard)
                                )
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        if let error = helperService.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if !store.preferences.hasAcknowledgedHelperPermissionMigration {
                            HStack(alignment: .top) {
                                Text(L10n.string("permissions.helperPermissionMigration"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button(L10n.string("button.gotIt")) {
                                    store.preferences.hasAcknowledgedHelperPermissionMigration = true
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }

                    permissionStep(
                        number: 3,
                        titleKey: "permissions.stepExtensionTitle",
                        systemImage: "puzzlepiece.extension",
                        statusText: finderExtensionStatusTitle,
                        statusIsGood: finderExtensionStatusIsGood
                    ) {
                        Text(L10n.string("permissions.stepExtensionDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.openExtensions")) {
                                openExtensionsSettings()
                            }
                            Button(L10n.string("permissions.reloadExtension")) {
                                reloadFinderExtension()
                            }
                            .disabled(helperService.isReloadingFinderExtension)
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                        }
                        if helperService.isFinderRuntimeChannelAvailable,
                           let message = helperService.finderExtensionPolicyMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !helperService.isFinderRuntimeChannelAvailable {
                            Text(L10n.string("permissions.sharedContainerUnavailable"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !store.preferences.hasAcknowledgedFinderMonitoringMigration {
                            HStack(alignment: .top) {
                                Text(L10n.string("permissions.finderMonitoringMigration"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button(L10n.string("button.gotIt")) {
                                    store.preferences.hasAcknowledgedFinderMonitoringMigration = true
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }

                    permissionStep(
                        number: 4,
                        titleKey: "permissions.stepDiskAccessTitle",
                        systemImage: "externaldrive.badge.checkmark",
                        statusText: diskAccessStatusTitle,
                        statusIsGood: diskAccessStatusIsGood
                    ) {
                        Text(L10n.string("permissions.fullDiskAccessDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(L10n.string("permissions.fullDiskAccessManualAdd"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.openFullDiskAccess")) {
                                helperService.openFullDiskAccessSettings()
                            }
                            .disabled(helperService.isApplyingDiskAccessChanges)
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                            .disabled(helperService.isApplyingDiskAccessChanges)
                            if helperService.diskAccessNeedsRelaunch,
                               helperService.isFinderRuntimeChannelAvailable {
                                Button(L10n.string("permissions.restartApplication")) {
                                    helperService.applyFullDiskAccessChanges()
                                }
                            }
                            if helperService.isApplyingDiskAccessChanges {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        Text(diskAccessDetailTitle)
                            .font(.caption)
                            .foregroundColor(
                                helperService.diskAccessRecoveryMessage != nil
                                    && !helperService.diskAccessChangesApplied
                                    ? Color.orange
                                    : Color.secondary
                            )
                    }

                    permissionStep(
                        number: 5,
                        titleKey: "permissions.stepAccessibilityTitle",
                        systemImage: "keyboard.badge.ellipsis",
                        statusText: permissionStatusTitle(for: .accessibility),
                        statusIsGood: helperService.permissionState(for: .accessibility) == .granted
                    ) {
                        Text(L10n.string("permissions.accessibilityDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.requestAccess")) {
                                requestAccessibilityAccess()
                            }
                            .disabled(permissionRequestIsActive(for: .accessibility))
                            Button(L10n.string("permissions.openAccessibility")) {
                                helperService.openPermissionSettings(.accessibility)
                            }
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                        }
                        permissionFailureText(for: .accessibility)
                    }

                    permissionStep(
                        number: 6,
                        titleKey: "permissions.stepScreenRecordingTitle",
                        systemImage: "rectangle.dashed.badge.record",
                        statusText: permissionStatusTitle(for: .screenRecording),
                        statusIsGood: helperService.permissionState(for: .screenRecording) == .granted
                    ) {
                        Text(L10n.string("permissions.screenRecordingDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.requestAccess")) {
                                requestScreenRecordingAccess()
                            }
                            .disabled(permissionRequestIsActive(for: .screenRecording))
                            Button(L10n.string("permissions.openScreenRecording")) {
                                helperService.openPermissionSettings(.screenRecording)
                            }
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                            if helperService.permissionState(for: .screenRecording) != .granted {
                                Button(L10n.string("permissions.restartBackgroundService")) {
                                    helperService.restart()
                                }
                                .disabled(permissionRequestIsActive(for: .screenRecording))
                            }
                        }
                        if helperService.permissionState(for: .screenRecording) != .granted {
                            Text(L10n.string("permissions.restartHint"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        permissionFailureText(for: .screenRecording)
                    }

                    permissionStep(
                        number: 7,
                        titleKey: "permissions.stepManualFoldersTitle",
                        systemImage: "folder.badge.plus",
                        statusText: L10n.string("permissions.manualFoldersStatus", store.preferences.monitoredFolderPaths.count),
                        statusIsGood: !store.preferences.monitoredFolderPaths.isEmpty
                    ) {
                        Text(L10n.string("permissions.manualFoldersDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(L10n.string("permissions.addFolder")) {
                            addFolder()
                        }
                    }

                    folderList

                    Text(L10n.string("permissions.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    }
                }
            }
        }
        .task {
            guard !store.storageState.isCorrupt else { return }
            helperService.refreshStatusesForPresentation()
        }
        .onDisappear {
            if cutTrial != nil { trials[.finderCut] = .cancelled }
            cleanUpCutTrial()
        }
    }

    private var readinessSnapshot: FeatureReadinessSnapshot {
        FeatureReadinessSnapshot(
            finderStatus: helperService.finderExtensionStatus,
            finderNeedsRestart: helperService.finderExtensionNeedsPolicyReload || helperService.diskAccessNeedsRelaunch,
            finderAccess: helperService.finderExtensionRuntimeSnapshot?.lastAccessResult,
            backgroundServiceEnabled: store.preferences.backgroundServiceEnabled,
            helperRunning: helperService.isRuntimeRunning,
            helperFailed: helperService.lastError != nil,
            accessibility: helperService.permissionState(for: .accessibility),
            screenRecording: helperService.permissionState(for: .screenRecording),
            activeFeatures: helperService.runtimeSnapshot?.activeFeatures ?? [],
            failedFeatures: helperService.failedFeatureIDs.union(store.preferences.conflictingQuickFeatureIDs())
        )
    }

    private var allowedTrials: Set<FeatureGuideFeature> {
        Set(FeatureGuideFeature.allCases.filter {
            $0 == .finderTools || (readinessSnapshot.status(for: $0) == .available && !($0 == .screenshot && screenshotTrialStarting))
        })
    }

    private func selectFeature(_ feature: FeatureGuideFeature, enabled: Bool) {
        if feature == .finderTools {
            store.preferences.finderToolsEnabled = enabled
        } else if let id = feature.quickFeatureID,
                  let index = store.preferences.quickFeatureSettings.firstIndex(where: { $0.id == id }) {
            store.preferences.quickFeatureSettings[index].isEnabled = enabled
            if enabled { store.preferences.backgroundServiceEnabled = true }
            store.waitForPendingSaves()
            helperService.synchronize(preferences: store.preferences)
        }
        trials[feature] = .notTested
        trialDetails[feature] = nil
        if feature == .finderCut { cleanUpCutTrial() }
    }

    private func configureFeature(_ feature: FeatureGuideFeature) {
        switch feature {
        case .finderTools:
            if helperService.finderExtensionNeedsPolicyReload {
                reloadFinderExtension()
            } else if helperService.diskAccessNeedsRelaunch {
                helperService.applyFullDiskAccessChanges()
            } else if helperService.finderExtensionRuntimeSnapshot?.lastAccessResult == .permissionDenied {
                helperService.openFullDiskAccessSettings()
            } else {
                openExtensionsSettings()
            }
        case .finderCut, .screenshot:
            if !helperService.isRuntimeRunning {
                helperService.repair()
                return
            }
            let kind: QuickFeaturePermissionKind = feature == .finderCut ? .accessibility : .screenRecording
            switch helperService.permissionState(for: kind) {
            case .restartRequired:
                helperService.restart()
            case .granted:
                if let id = feature.quickFeatureID,
                   helperService.failedFeatureIDs.contains(id) || store.preferences.conflictingQuickFeatureIDs().contains(id) {
                    statusMessage = L10n.string("guide.shortcutFailure")
                } else {
                    helperService.restart()
                }
            default:
                if kind == .accessibility { helperService.requestAccessibilityAccess() }
                else { helperService.requestScreenRecordingAccess() }
            }
        }
    }

    private func startTrial(_ feature: FeatureGuideFeature) {
        trialDetails[feature] = nil
        switch feature {
        case .finderTools:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = L10n.string("guide.chooseFolder")
            guard panel.runModal() == .OK, let url = panel.url else {
                trials[feature] = .cancelled
                return
            }
            let accepted = MonitoredFolderPolicy.acceptedAndRejectedPaths(from: [url]).accepted
            guard let path = accepted.first else {
                trials[feature] = .failed
                trialDetails[feature] = L10n.string("permissions.blockedFolder")
                return
            }
            store.preferences.monitoredFolderPaths = appendUniquePaths([path], to: store.preferences.monitoredFolderPaths)
            if let bookmark = try? SecurityScopedFolderAccess.bookmarkData(for: url) {
                store.preferences.monitoredFolderBookmarks[path] = bookmark
            }
            store.waitForPendingSaves()
            trials[feature] = NSWorkspace.shared.open(url) ? .instructions : .failed
            trialDetails[feature] = L10n.string("guide.finderInstructions", url.lastPathComponent)
        case .finderCut:
            cleanUpCutTrial()
            do {
                let files = try FeatureTrialFiles.create()
                cutTrial = files
                trials[feature] = .instructions
                trialDetails[feature] = L10n.string("guide.cutInstructions", store.preferences.quickFeatureSettings(for: .finderCut).shortcut.displayString)
                NSWorkspace.shared.activateFileViewerSelecting([files.sourceURL])
            } catch {
                trials[feature] = .failed
                trialDetails[feature] = error.localizedDescription
            }
        case .screenshot:
            screenshotTrialStarting = true
            trials[feature] = .instructions
            trialDetails[feature] = L10n.string("guide.screenshotInstructions")
            Task {
                let received = await helperService.testScreenshot()
                screenshotTrialStarting = false
                trials[feature] = received ? .awaitingConfirmation : .failed
                if !received { trialDetails[feature] = L10n.string("guide.screenshotUnavailable") }
            }
        }
    }

    private func openCutTrialDestination() {
        guard let trial = cutTrial else { return }
        NSWorkspace.shared.open(trial.destinationDirectory)
        trials[.finderCut] = .awaitingConfirmation
    }

    private func recordTrialResult(_ feature: FeatureGuideFeature, result: FeatureTrialState) {
        if result == .passed, feature == .finderCut, cutTrial?.hasCompletedMove != true {
            trials[feature] = .failed
            trialDetails[feature] = L10n.string("guide.cutNotMoved")
            return
        }
        trials[feature] = result
        if feature == .finderCut { cleanUpCutTrial() }
    }

    private func cleanUpCutTrial() {
        if let retained = cutTrial?.cleanup() {
            let message = L10n.string("guide.trialFilesRetained", retained.path)
            trialDetails[.finderCut] = message
            statusMessage = message
            HUDPresenter.shared.show(message: message, duration: 5)
        }
        cutTrial = nil
    }

    private var header: some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("permissions.title"))
                        .font(.title2.bold())
                    Text(L10n.string("permissions.description"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.preferences.hasDismissedPermissionGuide {
                    Button(L10n.string("permissions.completeGuide")) {
                        store.preferences.hasDismissedPermissionGuide = true
                    }
                }
            }
            Label(statusMessage, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var folderList: some View {
        List {
            Section(L10n.string("permissions.monitoredFolders")) {
                ForEach(Array(store.preferences.monitoredFolderPaths.enumerated()), id: \.element) { index, path in
                    SortableSettingsRow(index: index + 1) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MonitoredFolderPolicy.displayName(for: path))
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if store.preferences.monitoredFolderBookmarks[path] == nil {
                                Text(L10n.string("permissions.bookmarkMissing"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button(L10n.string("permissions.removeFolder")) {
                            removeFolder(path)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { offsets in
                    removeFolders(at: offsets)
                }
                .onMove { source, destination in
                    store.preferences.monitoredFolderPaths.move(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .frame(height: 150)
    }

    private var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private func permissionStep<Content: View>(
        number: Int,
        titleKey: String,
        systemImage: String,
        statusText: String,
        statusIsGood: Bool?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let statusSystemImage: String
        let statusColor: Color
        switch statusIsGood {
        case true:
            statusSystemImage = "checkmark.circle.fill"
            statusColor = .green
        case false:
            statusSystemImage = "exclamationmark.circle"
            statusColor = .orange
        case nil:
            statusSystemImage = "info.circle"
            statusColor = .secondary
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(statusIsGood == true ? Color.green : Color.accentColor))
                Label(L10n.string(titleKey), systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Label(statusText, systemImage: statusSystemImage)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            content()
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            store.preferences.language
        } set: { language in
            store.preferences.language = language
        }
    }

    private var backgroundServiceBinding: Binding<Bool> {
        Binding {
            store.preferences.backgroundServiceEnabled
        } set: { enabled in
            store.preferences.backgroundServiceEnabled = enabled
            store.waitForPendingSaves()
            helperService.synchronize(preferences: store.preferences)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let result = MonitoredFolderPolicy.acceptedAndRejectedPaths(from: panel.urls)
            store.preferences.monitoredFolderPaths = appendUniquePaths(
                result.accepted,
                to: store.preferences.monitoredFolderPaths
            )
            for url in panel.urls {
                let path = MonitoredFolderPolicy.canonicalPath(for: url)
                guard result.accepted.contains(path),
                      let bookmarkData = try? SecurityScopedFolderAccess.bookmarkData(for: url)
                else { continue }
                store.preferences.monitoredFolderBookmarks[path] = bookmarkData
            }
            store.preferences.monitoredFolderBookmarks = store.preferences.monitoredFolderBookmarks.filter {
                store.preferences.monitoredFolderPaths.contains($0.key)
            }

            if result.accepted.isEmpty, !result.rejected.isEmpty {
                statusMessage = L10n.string("permissions.blockedFolder")
            } else if result.rejected.isEmpty {
                statusMessage = L10n.string("permissions.monitoringUpdated")
            } else {
                statusMessage = L10n.string("permissions.monitoringUpdatedWithSkipped", result.rejected.count)
            }
        }
    }

    private func appendUniquePaths(_ newPaths: [String], to existingPaths: [String]) -> [String] {
        var seen = Set(existingPaths)
        var result = existingPaths
        for path in newPaths where !seen.contains(path) {
            result.append(path)
            seen.insert(path)
        }
        return result
    }

    private func removeFolder(_ path: String) {
        store.preferences.monitoredFolderPaths.removeAll { $0 == path }
        store.preferences.monitoredFolderBookmarks.removeValue(forKey: path)
        statusMessage = L10n.string("permissions.monitoringUpdated")
    }

    private func removeFolders(at offsets: IndexSet) {
        let paths = offsets.map { store.preferences.monitoredFolderPaths[$0] }
        store.preferences.monitoredFolderPaths.remove(atOffsets: offsets)
        for path in paths {
            store.preferences.monitoredFolderBookmarks.removeValue(forKey: path)
        }
        statusMessage = L10n.string("permissions.monitoringUpdated")
    }

    private func reloadFinderExtension() {
        statusMessage = L10n.string("permissions.reloadRequested")
        helperService.reloadFinderExtension()
    }

    private func openExtensionsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!
        NSWorkspace.shared.open(url)
    }

    private func refreshPermissionStatuses() {
        helperService.refreshAllStatuses()
    }

    private func requestAccessibilityAccess() {
        helperService.requestAccessibilityAccess()
    }

    private func requestScreenRecordingAccess() {
        helperService.requestScreenRecordingAccess()
    }

    private var backgroundServiceStatusTitle: String {
        if helperService.isRuntimeRunning {
            return L10n.string(
                helperService.launchMode == .managedLoginItem
                    ? "permissions.backgroundServiceRunning"
                    : "permissions.backgroundServiceRunningDirect"
            )
        }
        if helperService.launchMode == .managedLoginItem,
           helperService.registrationStatus == .requiresApproval {
            return L10n.string("permissions.backgroundServiceRequiresApproval")
        }
        return store.preferences.backgroundServiceEnabled
            ? L10n.string("permissions.backgroundServiceNotRunning")
            : L10n.string("permissions.backgroundServiceDisabled")
    }

    private func permissionStatusTitle(for kind: QuickFeaturePermissionKind) -> String {
        switch helperService.permissionState(for: kind) {
        case .unknown:
            return L10n.string("permissions.helperPermissionUnknown")
        case .checking:
            return L10n.string("permissions.helperPermissionRefreshing")
        case .waitingForUser:
            return L10n.string("permissions.helperPermissionWaiting")
        case .restartRequired:
            return L10n.string("permissions.helperPermissionRestarting")
        case .granted:
            return L10n.string(
                kind == .accessibility
                    ? "permissions.accessibilityGranted"
                    : "permissions.screenRecordingGranted"
            )
        case .notGranted:
            return L10n.string(
                kind == .accessibility
                    ? "permissions.accessibilityMissing"
                    : "permissions.screenRecordingMissing"
            )
        case .failed:
            return L10n.string("permissions.helperPermissionFailed")
        }
    }

    private func permissionRequestIsActive(for kind: QuickFeaturePermissionKind) -> Bool {
        switch helperService.permissionState(for: kind) {
        case .checking, .waitingForUser, .restartRequired:
            return true
        case .unknown, .notGranted, .granted, .failed:
            return false
        }
    }

    @ViewBuilder
    private func permissionFailureText(for kind: QuickFeaturePermissionKind) -> some View {
        if let message = helperService.permissionFailureMessage(for: kind) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var diskAccessStatusTitle: String {
        guard helperService.isFinderRuntimeChannelAvailable else {
            return L10n.string("permissions.fullDiskAccessManualVerificationStatus")
        }
        switch helperService.fullDiskAccessRecoveryPhase {
        case .waitingForReturn:
            return L10n.string("permissions.fullDiskAccessWaitingForReturn")
        case .relaunchScheduled:
            return L10n.string("permissions.fullDiskAccessRelaunching")
        case .reloadingExtension:
            return L10n.string("permissions.fullDiskAccessReloadingExtension")
        case .completed:
            return L10n.string("permissions.fullDiskAccessApplied")
        case .failed:
            return L10n.string("permissions.fullDiskAccessApplyFailedStatus")
        case nil:
            return helperService.diskAccessNeedsRelaunch
                ? L10n.string("permissions.fullDiskAccessRestartRequired")
                : L10n.string("permissions.fullDiskAccessSystemManaged")
        }
    }

    private var diskAccessStatusIsGood: Bool? {
        guard helperService.isFinderRuntimeChannelAvailable else { return nil }
        switch helperService.fullDiskAccessRecoveryPhase {
        case .completed:
            return true
        case .failed:
            return false
        case .waitingForReturn, .relaunchScheduled, .reloadingExtension, nil:
            return nil
        }
    }

    private var finderExtensionStatusTitle: String {
        if helperService.isReloadingFinderExtension {
            return L10n.string("permissions.finderPolicyReloading")
        }
        if helperService.isFinderRuntimeChannelAvailable,
           helperService.finderExtensionNeedsPolicyReload {
            return L10n.string("permissions.finderPolicyUpdateRequired")
        }
        if !helperService.isFinderRuntimeChannelAvailable,
           helperService.finderExtensionStatus == .unknown {
            return L10n.string("permissions.finderRuntimeUnavailableStatus")
        }
        return helperService.finderExtensionStatus.localizedTitle
    }

    private var finderExtensionStatusIsGood: Bool? {
        if helperService.isReloadingFinderExtension {
            return nil
        }
        if helperService.isFinderRuntimeChannelAvailable,
           helperService.finderExtensionNeedsPolicyReload {
            return false
        }
        switch helperService.finderExtensionStatus {
        case .enabled:
            return true
        case .disabled, .notRegistered:
            return false
        case .unknown:
            return nil
        }
    }

    private var diskAccessDetailTitle: String {
        guard helperService.isFinderRuntimeChannelAvailable else {
            return L10n.string("permissions.fullDiskAccessManualVerificationDetail")
        }
        if let message = helperService.diskAccessRecoveryMessage {
            return message
        }
        guard let snapshot = helperService.finderExtensionRuntimeSnapshot else {
            return L10n.string("permissions.fullDiskAccessExtensionNotReporting")
        }
        switch snapshot.lastAccessResult {
        case .success:
            return L10n.string("permissions.fullDiskAccessLastOperationSucceeded")
        case .permissionDenied:
            return L10n.string("permissions.fullDiskAccessLastOperationDenied")
        case .failed:
            return L10n.string("permissions.fullDiskAccessLastOperationFailed")
        case nil:
            return L10n.string("permissions.fullDiskAccessExtensionRunning")
        }
    }
}

/// A side-effect-free guide surface; runtime actions are supplied by PermissionsView.
struct FeaturePermissionGuideView: View {
    var readiness: [FeatureGuideFeature: FeatureReadiness] = [:]
    var selectedFeatures: Set<FeatureGuideFeature> = []
    var trials: [FeatureGuideFeature: FeatureTrialState] = [:]
    var trialDetails: [FeatureGuideFeature: String] = [:]
    var trialAllowedFeatures: Set<FeatureGuideFeature> = [.finderTools]
    var onSelect: (FeatureGuideFeature, Bool) -> Void = { _, _ in }
    var onConfigure: (FeatureGuideFeature) -> Void = { _ in }
    var onTrial: (FeatureGuideFeature) -> Void = { _ in }
    var onTrialResult: (FeatureGuideFeature, FeatureTrialState) -> Void = { _, _ in }
    var onOpenTrialDestination: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("guide.title")).font(.title3.bold())
            Text(L10n.string("guide.description"))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(FeatureGuideFeature.allCases) { feature in
                featureCard(feature)
            }
        }
    }

    private func featureCard(_ feature: FeatureGuideFeature) -> some View {
        let selected = selectedFeatures.contains(feature)
        let status = readiness[feature] ?? .needsPermission
        let trial = trials[feature] ?? .notTested
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                Toggle(isOn: Binding(get: { selected }, set: { onSelect(feature, $0) })) {
                    Label(L10n.string("guide.feature.\(feature.rawValue)"), systemImage: symbol(for: feature))
                        .font(.headline)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("guide-feature-\(feature.rawValue)")
                Spacer()
                Label(L10n.string(selected ? "guide.readiness.\(status.rawValue)" : "guide.disabled"), systemImage: selected && status == .available ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(selected && status == .available ? Color.green : Color.secondary)
            }
            Text(L10n.string("guide.purpose.\(feature.rawValue)"))
                .font(.callout).foregroundStyle(.secondary)
            if selected {
                HStack(spacing: 10) {
                    if status != .available {
                        Button(L10n.string("guide.configure")) { onConfigure(feature) }
                    }
                    Button(L10n.string("guide.try")) { onTrial(feature) }
                        .disabled(!trialAllowedFeatures.contains(feature))
                    Text(L10n.string("guide.trial.\(trial.rawValue)"))
                        .font(.caption)
                        .foregroundStyle(trial == .passed ? Color.green : Color.secondary)
                    Spacer()
                }
                if let detail = trialDetails[feature] {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if trial == .instructions || trial == .awaitingConfirmation {
                    if feature == .finderCut {
                        Button(L10n.string("guide.openDestination"), action: onOpenTrialDestination)
                    }
                    if trial == .awaitingConfirmation || feature != .screenshot {
                        HStack {
                            Button(L10n.string("guide.confirmPassed")) { onTrialResult(feature, .passed) }
                            Button(L10n.string("guide.confirmFailed")) { onTrialResult(feature, .failed) }
                            Button(L10n.string("guide.confirmCancelled")) { onTrialResult(feature, .cancelled) }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(for feature: FeatureGuideFeature) -> String {
        switch feature {
        case .finderTools: "cursorarrow.click"
        case .finderCut: "scissors"
        case .screenshot: "camera.viewfinder"
        }
    }
}

private extension FinderExtensionStatus {
    var localizedTitle: String {
        switch self {
        case .enabled:
            return L10n.string("permissions.extensionEnabled")
        case .disabled:
            return L10n.string("permissions.extensionDisabled")
        case .notRegistered:
            return L10n.string("permissions.extensionNotRegistered")
        case .unknown:
            return L10n.string("permissions.extensionUnknown")
        }
    }
}
