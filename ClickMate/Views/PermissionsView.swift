import ServiceManagement
import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @ObservedObject private var helperService = QuickFeatureHelperService.shared
    @State private var statusMessage = L10n.string("permissions.extensionStatusUnknown")

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
            }
        }
        .task {
            refreshPermissionStatuses()
        }
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
