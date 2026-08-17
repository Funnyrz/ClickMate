import ServiceManagement
import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @ObservedObject private var quickPermissionMonitor = QuickFeaturePermissionMonitor.shared
    @State private var statusMessage = L10n.string("permissions.extensionStatusUnknown")
    @State private var hasFullDiskAccess = DiskAccessPolicy.hasFullDiskAccess()
    @State private var finderExtensionStatus: FinderExtensionStatus = .unknown
    @State private var launchAtLoginStatus = SMAppService.mainApp.status

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
                        titleKey: "permissions.stepLaunchAtLoginTitle",
                        systemImage: "power",
                        statusText: launchAtLoginStatus.localizedTitle,
                        statusIsGood: launchAtLoginStatus == .enabled
                    ) {
                        Text(L10n.string("permissions.launchAtLoginDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle(L10n.string("permissions.launchAtLoginToggle"), isOn: launchAtLoginBinding)
                            .toggleStyle(.switch)
                            .disabled(!isRunningFromApplications)
                        if launchAtLoginStatus == .requiresApproval {
                            Button(L10n.string("permissions.openLoginItems")) {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }

                    permissionStep(
                        number: 3,
                        titleKey: "permissions.stepExtensionTitle",
                        systemImage: "puzzlepiece.extension",
                        statusText: finderExtensionStatus.localizedTitle,
                        statusIsGood: finderExtensionStatus == .enabled
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
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                            if !hasFullDiskAccess {
                                Button(L10n.string("permissions.restartApplication")) {
                                    QuickFeaturePermissions.relaunchApplication()
                                }
                            }
                        }
                        if !hasFullDiskAccess {
                            Text(L10n.string("permissions.restartHint"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    permissionStep(
                        number: 4,
                        titleKey: "permissions.stepDiskAccessTitle",
                        systemImage: "externaldrive.badge.checkmark",
                        statusText: hasFullDiskAccess
                            ? L10n.string("permissions.fullDiskAccessGranted")
                            : L10n.string("permissions.fullDiskAccessMissing"),
                        statusIsGood: hasFullDiskAccess
                    ) {
                        Text(L10n.string("permissions.fullDiskAccessDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(L10n.string("permissions.fullDiskAccessManualAdd"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.openFullDiskAccess")) {
                                openFullDiskAccessSettings()
                            }
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                        }
                    }

                    permissionStep(
                        number: 5,
                        titleKey: "permissions.stepAccessibilityTitle",
                        systemImage: "keyboard.badge.ellipsis",
                        statusText: quickPermissionMonitor.snapshot.accessibilityGranted
                            ? L10n.string("permissions.accessibilityGranted")
                            : L10n.string("permissions.accessibilityMissing"),
                        statusIsGood: quickPermissionMonitor.snapshot.accessibilityGranted
                    ) {
                        Text(L10n.string("permissions.accessibilityDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.requestAccess")) {
                                QuickFeaturePermissions.requestAccessibilityAccess()
                                quickPermissionMonitor.refresh()
                            }
                            Button(L10n.string("permissions.openAccessibility")) {
                                QuickFeaturePermissions.openAccessibilitySettings()
                            }
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                        }
                    }

                    permissionStep(
                        number: 6,
                        titleKey: "permissions.stepScreenRecordingTitle",
                        systemImage: "rectangle.dashed.badge.record",
                        statusText: quickPermissionMonitor.snapshot.screenRecordingGranted
                            ? L10n.string("permissions.screenRecordingGranted")
                            : L10n.string("permissions.screenRecordingMissing"),
                        statusIsGood: quickPermissionMonitor.snapshot.screenRecordingGranted
                    ) {
                        Text(L10n.string("permissions.screenRecordingDescription"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.string("permissions.requestAccess")) {
                                QuickFeaturePermissions.requestScreenRecordingAccess()
                                quickPermissionMonitor.refresh()
                            }
                            Button(L10n.string("permissions.openScreenRecording")) {
                                QuickFeaturePermissions.openScreenRecordingSettings()
                            }
                            Button(L10n.string("button.refresh")) {
                                refreshPermissionStatuses()
                            }
                            if !quickPermissionMonitor.snapshot.screenRecordingGranted {
                                Button(L10n.string("permissions.restartApplication")) {
                                    QuickFeaturePermissions.relaunchApplication()
                                }
                            }
                        }
                        if !quickPermissionMonitor.snapshot.screenRecordingGranted {
                            Text(L10n.string("permissions.restartHint"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatuses()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        statusIsGood: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(statusIsGood ? Color.green : Color.accentColor))
                Label(L10n.string(titleKey), systemImage: systemImage)
                    .font(.headline)
                Spacer()
                Label(statusText, systemImage: statusIsGood ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(statusIsGood ? .green : .orange)
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        } set: { enabled in
            updateLaunchAtLogin(enabled: enabled)
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
        Task {
            let status = await FinderExtensionPolicy.reloadBundledExtension()
            PreferencesChangeNotifier.post()
            await MainActor.run {
                finderExtensionStatus = status
                statusMessage = status == .enabled
                    ? L10n.string("permissions.extensionEnabledHint")
                    : L10n.string("permissions.extensionStatusUnknown")
            }
        }
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    private func openExtensionsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!
        NSWorkspace.shared.open(url)
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = L10n.string("permissions.launchAtLoginUpdateFailed")
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private func refreshPermissionStatuses() {
        hasFullDiskAccess = DiskAccessPolicy.hasFullDiskAccess()
        quickPermissionMonitor.refresh()
        launchAtLoginStatus = SMAppService.mainApp.status
        Task {
            let status = await FinderExtensionPolicy.status()
            await MainActor.run {
                finderExtensionStatus = status
                statusMessage = status == .enabled
                    ? L10n.string("permissions.extensionEnabledHint")
                    : L10n.string("permissions.extensionStatusUnknown")
            }
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

private extension SMAppService.Status {
    var localizedTitle: String {
        switch self {
        case .enabled:
            return L10n.string("permissions.launchAtLoginEnabled")
        case .notRegistered:
            return L10n.string("permissions.launchAtLoginDisabled")
        case .requiresApproval:
            return L10n.string("permissions.launchAtLoginRequiresApproval")
        case .notFound:
            return L10n.string("permissions.launchAtLoginUnavailable")
        @unknown default:
            return L10n.string("permissions.launchAtLoginUnavailable")
        }
    }
}
