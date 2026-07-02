import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var statusMessage = L10n.string("permissions.extensionStatusUnknown")
    @State private var hasFullDiskAccess = DiskAccessPolicy.hasFullDiskAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("permissions.title"))
                .font(.title2.bold())
            Text(L10n.string("permissions.description"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(statusMessage, systemImage: "puzzlepiece.extension")
                Text(L10n.string("permissions.wideCoverageDescription"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    hasFullDiskAccess
                        ? L10n.string("permissions.fullDiskAccessGranted")
                        : L10n.string("permissions.fullDiskAccessMissing"),
                    systemImage: hasFullDiskAccess ? "checkmark.shield" : "shield"
                )
                Text(L10n.string("permissions.fullDiskAccessDescription"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(L10n.string("permissions.openFullDiskAccess")) {
                        openFullDiskAccessSettings()
                    }
                    Button(L10n.string("button.refresh")) {
                        refreshFullDiskAccessStatus()
                    }
                }
            }

            HStack {
                Picker(L10n.string("settings.language"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }

            HStack {
                Button(L10n.string("permissions.openExtensions")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
                }
                Button(L10n.string("permissions.reloadExtension")) {
                    reloadFinderExtension()
                }
                Spacer()
            }

            HStack {
                Button(L10n.string("permissions.addFolder")) {
                    addFolder()
                }
                Text(L10n.string("permissions.manualFoldersDescription"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

            Text(L10n.string("permissions.footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            refreshFullDiskAccessStatus()
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            store.preferences.language
        } set: { language in
            store.preferences.language = language
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
        PreferencesChangeNotifier.post()
        statusMessage = L10n.string("permissions.reloadRequested")
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    private func refreshFullDiskAccessStatus() {
        hasFullDiskAccess = DiskAccessPolicy.hasFullDiskAccess()
    }
}
