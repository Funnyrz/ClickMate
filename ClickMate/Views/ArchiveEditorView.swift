import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ArchiveEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ArchiveEditorWindowController()

    private let preferencesStore = PreferencesStore()
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
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
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
        window.identifier = NSUserInterfaceItemIdentifier("com.zxacn.clickmate.archive-editor")
        window.delegate = self
        self.window = window
        return window
    }

    private func hideSettingsWindows(excluding editorWindow: NSWindow) {
        for window in NSApp.windows where window !== editorWindow {
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
            Button(L10n.string("archive.cancel"), role: .cancel) {}
            Button(L10n.string("archive.continue")) { model.saveAfterSignatureWarning(createBackup: store.preferences.archiveEditorCreatesBackup) }
        } message: {
            Text(L10n.string("archive.signedMessage"))
        }
        .confirmationDialog(
            L10n.string("archive.unsavedTitle"),
            isPresented: pendingArchiveBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.string("archive.saveAndOpen")) {
                model.beginSaveAndOpenPending(createBackup: store.preferences.archiveEditorCreatesBackup)
            }
            Button(L10n.string("archive.discardAndOpen"), role: .destructive) {
                model.discardAndOpenPending()
            }
            Button(L10n.string("archive.cancel"), role: .cancel) {
                model.cancelPendingOpen()
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
        .onChange(of: model.selectedEntryName) { _, name in
            model.selectEntry(named: name)
        }
    }

    private var archiveTree: some View {
        Group {
            if model.searchText.isEmpty {
                List(selection: $model.selectedEntryName) {
                    OutlineGroup(model.tree, children: \.children) { node in
                        ArchiveTreeRow(node: node)
                            .tag(node.entry?.name)
                    }
                }
            } else {
                List(model.filteredEntries, selection: $model.selectedEntryName) { entry in
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

    private var pendingArchiveBinding: Binding<Bool> {
        Binding(
            get: { model.isShowingOpenConfirmation },
            set: { model.isShowingOpenConfirmation = $0 }
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

struct ArchiveTreeNode: Identifiable {
    let id: String
    let name: String
    let entry: ZipArchiveEditor.Entry?
    let children: [ArchiveTreeNode]?

    var isDirectory: Bool { children != nil || entry?.isDirectory == true }
}

@MainActor
final class ArchiveEditorModel: ObservableObject {
    @Published private(set) var archive: ZipArchiveEditor.Archive?
    @Published var searchText = ""
    @Published var selectedEntryName: String?
    @Published private(set) var selectedEntry: ZipArchiveEditor.Entry?
    @Published var editorText = ""
    @Published private(set) var originalText = ""
    @Published private(set) var isEditable = false
    @Published var showSignatureWarning = false
    @Published var errorMessage: String?
    @Published private(set) var tree: [ArchiveTreeNode] = []
    @Published private(set) var pendingArchiveURL: URL?
    @Published var isShowingOpenConfirmation = false

    private var hasSecurityScopedAccess = false
    private var didAcknowledgeSignature = false
    private var didCreateBackup = false

    var isDirty: Bool { isEditable && editorText != originalText }
    var lineEndingLabel: String { originalText.contains("\r\n") ? "CRLF" : "LF" }
    var filteredEntries: [ZipArchiveEditor.Entry] {
        guard let archive else { return [] }
        return archive.entries.filter { !$0.isDirectory && $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func requestOpen(_ url: URL) {
        guard isDirty else {
            open(url)
            return
        }
        pendingArchiveURL = url
        isShowingOpenConfirmation = true
    }

    func beginSaveAndOpenPending(createBackup: Bool) {
        guard pendingArchiveURL != nil else { return }
        isShowingOpenConfirmation = false
        guard archive?.hasSignatureFiles != true || didAcknowledgeSignature else {
            showSignatureWarning = true
            return
        }
        saveCurrent(createBackup: createBackup)
        openPendingArchiveIfSaved()
    }

    func discardAndOpenPending() {
        guard let pendingArchiveURL else { return }
        self.pendingArchiveURL = nil
        isShowingOpenConfirmation = false
        open(pendingArchiveURL)
    }

    func cancelPendingOpen() {
        pendingArchiveURL = nil
        isShowingOpenConfirmation = false
    }

    func open(_ url: URL) {
        closeArchive()
        errorMessage = nil
        hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        do {
            archive = try ZipArchiveEditor.open(url)
            tree = Self.makeTree(from: archive?.entries ?? [])
            didAcknowledgeSignature = false
            didCreateBackup = false
            searchText = ""
        } catch {
            if hasSecurityScopedAccess { url.stopAccessingSecurityScopedResource() }
            hasSecurityScopedAccess = false
            errorMessage = error.localizedDescription
        }
    }

    func closeArchive() {
        if hasSecurityScopedAccess { archive?.url.stopAccessingSecurityScopedResource() }
        hasSecurityScopedAccess = false
        archive = nil
        selectedEntryName = nil
        selectedEntry = nil
        tree = []
        editorText = ""
        originalText = ""
        isEditable = false
    }

    func selectEntry(named name: String?) {
        guard let name, let archive, let entry = archive.entries.first(where: { $0.name == name }), !entry.isDirectory else {
            selectedEntry = nil
            isEditable = false
            return
        }
        do {
            let data = try ZipArchiveEditor.readEntry(named: name, from: archive)
            selectedEntry = entry
            if let text = Self.decodeText(data) {
                editorText = text
                originalText = text
                isEditable = true
            } else {
                editorText = ""
                originalText = ""
                isEditable = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestSave(createBackup: Bool) {
        guard archive?.hasSignatureFiles == true, !didAcknowledgeSignature else {
            saveCurrent(createBackup: createBackup)
            return
        }
        showSignatureWarning = true
    }

    func saveCurrent(createBackup: Bool) {
        guard let archive, let entry = selectedEntry, isEditable, isDirty else { return }
        do {
            try ZipArchiveEditor.replaceEntry(
                named: entry.name,
                with: Data(editorText.utf8),
                in: archive,
                createBackup: createBackup && !didCreateBackup
            )
            didCreateBackup = didCreateBackup || createBackup
            didAcknowledgeSignature = true
            self.archive = try ZipArchiveEditor.open(archive.url)
            selectedEntry = self.archive?.entries.first(where: { $0.name == entry.name })
            originalText = editorText
            tree = Self.makeTree(from: self.archive?.entries ?? [])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAfterSignatureWarning(createBackup: Bool) {
        saveCurrent(createBackup: createBackup)
        openPendingArchiveIfSaved()
    }

    private func openPendingArchiveIfSaved() {
        guard let pendingArchiveURL, !isDirty, errorMessage == nil else { return }
        self.pendingArchiveURL = nil
        isShowingOpenConfirmation = false
        open(pendingArchiveURL)
    }

    private static func decodeText(_ data: Data) -> String? {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func makeTree(from entries: [ZipArchiveEditor.Entry]) -> [ArchiveTreeNode] {
        let root = TreeBuilder(name: "", path: "")
        for entry in entries {
            var current = root
            let components = entry.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            for (index, component) in components.enumerated() {
                let path = current.path.isEmpty ? component : "\(current.path)/\(component)"
                if current.children[component] == nil {
                    current.children[component] = TreeBuilder(name: component, path: path)
                }
                current = current.children[component]!
                if index == components.count - 1 { current.entry = entry }
            }
        }
        return root.nodes
    }

    private final class TreeBuilder {
        let name: String
        let path: String
        var entry: ZipArchiveEditor.Entry?
        var children: [String: TreeBuilder] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        var nodes: [ArchiveTreeNode] {
            children.values.sorted {
                let lhsDirectory = !$0.children.isEmpty
                let rhsDirectory = !$1.children.isEmpty
                if lhsDirectory != rhsDirectory { return lhsDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.map { child in
                ArchiveTreeNode(
                    id: child.path,
                    name: child.name,
                    entry: child.entry,
                    children: child.children.isEmpty ? nil : child.nodes
                )
            }
        }
    }
}
