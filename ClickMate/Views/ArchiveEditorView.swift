import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ArchiveEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ArchiveEditorWindowController()

    private let preferencesStore = AppPreferences.store
    private let model = ArchiveEditorModel()
    private var window: NSWindow?

    func openArchive(at url: URL) {
        let window = makeWindowIfNeeded()
        hideSettingsWindows(excluding: window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.requestOpen(url)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.requestClose { allowed in
            guard allowed else { return }
            sender.orderOut(nil)
            if AppWindows.canHideForBackgroundAction { NSApp.setActivationPolicy(.accessory) }
        }
        return false
    }

    func requestTermination(completion: @escaping (Bool) -> Void) {
        if let window, model.isDirty {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        model.requestTermination(completion: completion)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }

        let rootView = ArchiveEditorView(model: model)
            .environmentObject(preferencesStore)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = L10n.string("archive.windowTitle")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 900, height: 580)
        window.isReleasedWhenClosed = false
        window.identifier = AppWindows.archiveID
        window.delegate = self
        self.window = window
        return window
    }

    private func hideSettingsWindows(excluding editorWindow: NSWindow) {
        for window in NSApp.windows where window !== editorWindow && (window === AppWindows.settingsWindow || window.identifier == AppWindows.settingsID) {
            window.orderOut(nil)
        }
    }
}

struct ArchiveEditorView: View {
    @EnvironmentObject private var store: PreferencesStore
    @ObservedObject var model: ArchiveEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            if let archive = model.archive {
                archiveContents(archive)
            } else {
                ContentUnavailableView(
                    L10n.string("archive.emptyTitle"),
                    systemImage: "shippingbox",
                    description: Text(L10n.string("archive.emptyDescription"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(L10n.string("archive.signedTitle"), isPresented: $model.showSignatureWarning) {
            Button(L10n.string("archive.cancel"), role: .cancel) { model.cancelSignatureWarning() }
            Button(L10n.string("archive.continue")) { model.saveAfterSignatureWarning(createBackup: store.preferences.archiveEditorCreatesBackup) }
        } message: {
            Text(L10n.string("archive.signedMessage"))
        }
        .confirmationDialog(
            L10n.string("archive.unsavedTitle"),
            isPresented: pendingActionBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.string("archive.save")) {
                model.savePendingAction(createBackup: store.preferences.archiveEditorCreatesBackup)
            }
            Button(L10n.string("archive.discard"), role: .destructive) {
                model.discardPendingAction()
            }
            Button(L10n.string("archive.cancel"), role: .cancel) {
                model.cancelPendingAction()
            }
        } message: {
            Text(L10n.string("archive.unsavedMessage"))
        }
        .alert(L10n.string("archive.errorTitle"), isPresented: errorBinding) {
            Button(L10n.string("archive.ok"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                openArchive()
            } label: {
                Label(L10n.string("archive.open"), systemImage: "folder")
            }
            .accessibilityIdentifier("archive-open-button")

            if let archive = model.archive {
                Text(archive.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityLabel(L10n.string("archive.currentFile", archive.url.lastPathComponent))
                if archive.hasSignatureFiles {
                    Label(L10n.string("archive.signed"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(L10n.string("archive.windowTitle"))
                    .font(.headline)
            }

            Spacer(minLength: 16)

            Toggle(L10n.string("archive.autoBackup"), isOn: $store.preferences.archiveEditorCreatesBackup)
                .toggleStyle(.switch)
                .font(.caption)
                .accessibilityIdentifier("archive-auto-backup-toggle")

            if model.archive != nil {
                TextField(L10n.string("archive.search"), text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityIdentifier("archive-search-field")
            }
        }
    }

    private func archiveContents(_ archive: ZipArchiveEditor.Archive) -> some View {
        HSplitView {
            archiveTree
                .frame(minWidth: 320, idealWidth: 390, maxWidth: 520)

            editorPane
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var archiveTree: some View {
        Group {
            if model.searchText.isEmpty {
                List(selection: entrySelectionBinding) {
                    OutlineGroup(model.tree, children: \.children) { node in
                        ArchiveTreeRow(node: node)
                            .tag(node.entry?.name)
                    }
                }
            } else {
                List(model.filteredEntries, selection: entrySelectionBinding) { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                        .tag(entry.name)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("archive-directory-tree")
    }

    @ViewBuilder
    private var editorPane: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if model.isDirty {
                        Label(L10n.string("archive.modified"), systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button(L10n.string("archive.save")) {
                        model.requestSave(createBackup: store.preferences.archiveEditorCreatesBackup)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isEditable || !model.isDirty)
                    .accessibilityIdentifier("archive-save-button")
                }

                if model.isEditable {
                    TextEditor(text: $model.editorText)
                        .font(.system(.body, design: .monospaced))
                        .border(Color.secondary.opacity(0.25))
                } else {
                    ContentUnavailableView(
                        L10n.string("archive.notTextTitle"),
                        systemImage: "doc.badge.ellipsis",
                        description: Text(L10n.string("archive.notTextDescription"))
                    )
                }

                HStack(spacing: 12) {
                    Text(entry.compressionMethod.displayName)
                    Text(model.lineEndingLabel)
                    Text(entry.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(entry.uncompressedSize) B / \(entry.compressedSize) B")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                L10n.string("archive.selectTitle"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(L10n.string("archive.selectDescription"))
            )
        }
    }

    private var entrySelectionBinding: Binding<String?> {
        Binding(get: { model.selectedEntryName }, set: { model.requestSelectEntry(named: $0) })
    }

    private var pendingActionBinding: Binding<Bool> {
        Binding(
            get: { model.isShowingUnsavedConfirmation },
            set: { model.setUnsavedConfirmationPresented($0) }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private func openArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "jar") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L10n.string("archive.open")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.requestOpen(url)
    }
}

private struct ArchiveTreeRow: View {
    let node: ArchiveTreeNode

    var body: some View {
        Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
    }
}
