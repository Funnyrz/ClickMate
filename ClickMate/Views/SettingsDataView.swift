import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsDataView: View {
    @EnvironmentObject private var store: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: PortableConfiguration?
    @State private var candidateName = ""
    @State private var dialog: SettingsDataDialog?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.string("settingsData.title")).font(.title2.bold())
                Spacer()
                Button(L10n.string("settingsData.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.string("settingsData.description")).foregroundStyle(.secondary)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(storageTitle, systemImage: store.storageState.message == nil ? "checkmark.shield" : "exclamationmark.triangle")
                                .font(.headline)
                            if let message = store.storageState.message {
                                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            HStack {
                                if case .saveFailure = store.storageState {
                                    Button(L10n.string("settingsData.retry")) { store.retrySave() }
                                }
                                Button(L10n.string("settingsData.restoreBackup")) { dialog = .restore }
                                    .disabled(!store.canRestoreBackup)
                                Button(L10n.string("settingsData.reset")) { dialog = .reset }
                            }
                            Text(L10n.string("settingsData.recoveryDescription"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.string("settingsData.transferTitle")).font(.headline)
                            Text(L10n.string("settingsData.transferDescription")).foregroundStyle(.secondary)
                            HStack {
                                Button(L10n.string("settingsData.export"), systemImage: "square.and.arrow.up") { exportSettings() }
                                Button(L10n.string("settingsData.chooseImport"), systemImage: "square.and.arrow.down") { chooseImport() }
                            }.disabled(store.storageState.isCorrupt)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if let candidate {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.string("settingsData.previewTitle", candidateName)).font(.headline)
                                Text(L10n.string("settingsData.previewDescription")).font(.callout).foregroundStyle(.secondary)
                                previewRow("settingsData.menuCount", before: store.preferences.enabledCommands.count, after: candidate.enabledCommands.count)
                                previewRow("settingsData.templateCount", before: store.preferences.templates.count, after: candidate.templates.count)
                                previewRow("settingsData.hotkeyCount", before: store.preferences.quickFeatureSettings.filter(\.isEnabled).count, after: candidate.quickFeatureSettings.filter(\.isEnabled).count)
                                previewRow("settingsData.applicationCount", before: store.preferences.pinnedApplicationPaths.count, after: candidate.pinnedApplicationPaths.count)
                                previewRow("settingsData.folderCount", before: store.preferences.monitoredFolderPaths.count, after: candidate.monitoredFolderPaths.count)
                                Text(L10n.string("settingsData.reauthorizeDescription", candidate.monitoredFolderPaths.filter { store.preferences.monitoredFolderBookmarks[$0] == nil }.count))
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button(L10n.string("settingsData.replace")) { dialog = .importSettings }
                                        .buttonStyle(.borderedProminent)
                                    Button(L10n.string("settingsData.cancel")) { self.candidate = nil }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 660, height: 570)
        .alert(item: $dialog, content: makeAlert)
    }

    private var storageTitle: String {
        switch store.storageState {
        case .firstRun: L10n.string("settingsData.firstRun")
        case .loaded: L10n.string("settingsData.loaded")
        case .corrupt: L10n.string("settingsData.corrupt")
        case .saveFailure: L10n.string("settingsData.saveFailed")
        }
    }

    private func previewRow(_ key: String, before: Int, after: Int) -> some View {
        HStack {
            Text(L10n.string(key))
            Spacer()
            Text("\(before) → \(after)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func chooseImport() {
        candidate = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            candidate = try store.previewImport(Data(contentsOf: url))
            candidateName = url.lastPathComponent
        } catch { dialog = .failure(error.localizedDescription) }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ClickMate-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try store.exportConfiguration().write(to: url, options: .atomic)
            dialog = .completed(L10n.string("settingsData.exported"))
        } catch { dialog = .failure(error.localizedDescription) }
    }

    private func makeAlert(_ dialog: SettingsDataDialog) -> Alert {
        let cancel = Alert.Button.cancel(Text(L10n.string("settingsData.cancel")))
        switch dialog {
        case .importSettings:
            return Alert(title: Text(L10n.string("settingsData.confirmImportTitle")), message: Text(L10n.string("settingsData.confirmImportDescription")), primaryButton: .default(Text(L10n.string("settingsData.replace"))) {
                guard let candidate else { return }
                do {
                    try store.importConfiguration(candidate)
                    self.candidate = nil
                    dismiss()
                } catch { self.dialog = .failure(error.localizedDescription) }
            }, secondaryButton: cancel)
        case .restore:
            return Alert(title: Text(L10n.string("settingsData.restoreBackup")), message: Text(L10n.string("settingsData.confirmRestoreDescription")), primaryButton: .default(Text(L10n.string("settingsData.restoreBackup"))) {
                do { try store.restoreBackup(); candidate = nil }
                catch { self.dialog = .failure(error.localizedDescription) }
            }, secondaryButton: cancel)
        case .reset:
            return Alert(title: Text(L10n.string("settingsData.reset")), message: Text(L10n.string("settingsData.confirmResetDescription")), primaryButton: .destructive(Text(L10n.string("settingsData.reset"))) {
                store.reset()
                candidate = nil
            }, secondaryButton: cancel)
        case let .failure(message):
            return Alert(title: Text(L10n.string("settingsData.failed")), message: Text(message), dismissButton: .default(Text(L10n.string("settingsData.close"))))
        case let .completed(message):
            return Alert(title: Text(L10n.string("settingsData.title")), message: Text(message), dismissButton: .default(Text(L10n.string("settingsData.close"))))
        }
    }
}

private enum SettingsDataDialog: Identifiable {
    case importSettings, restore, reset, failure(String), completed(String)
    var id: String {
        switch self {
        case .importSettings: "import"
        case .restore: "restore"
        case .reset: "reset"
        case let .failure(message): "failure-" + message
        case let .completed(message): "completed-" + message
        }
    }
}
