import Foundation
import Combine

struct ArchiveTreeNode: Identifiable {
    let id: String
    let name: String
    let entry: ZipArchiveEditor.Entry?
    let children: [ArchiveTreeNode]?

    var isDirectory: Bool { children != nil || entry?.isDirectory == true }
}

@MainActor
final class ArchiveEditorModel: ObservableObject {
    enum PendingAction: Equatable {
        case selectEntry(String?)
        case open(URL)
        case close
        case terminate
    }

    @Published private(set) var archive: ZipArchiveEditor.Archive?
    @Published var searchText = ""
    @Published private(set) var selectedEntryName: String?
    @Published private(set) var selectedEntry: ZipArchiveEditor.Entry?
    @Published var editorText = ""
    @Published private(set) var originalText = ""
    @Published private(set) var isEditable = false
    @Published var showSignatureWarning = false
    @Published var errorMessage: String?
    @Published private(set) var tree: [ArchiveTreeNode] = []
    @Published private(set) var pendingAction: PendingAction?
    @Published private(set) var isShowingUnsavedConfirmation = false

    private var pendingCompletion: ((Bool) -> Void)?
    private var hasSecurityScopedAccess = false
    private var didAcknowledgeSignature = false
    private var didCreateBackup = false

    var isDirty: Bool { isEditable && editorText != originalText }
    var lineEndingLabel: String { originalText.contains("\r\n") ? "CRLF" : "LF" }
    var filteredEntries: [ZipArchiveEditor.Entry] {
        guard let archive else { return [] }
        return archive.entries.filter { !$0.isDirectory && $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func requestOpen(_ url: URL) { request(.open(url)) }
    func open(_ url: URL) { requestOpen(url) }

    func requestSelectEntry(named name: String?) {
        guard name != selectedEntryName else { return }
        request(.selectEntry(name))
    }

    func selectEntry(named name: String?) { requestSelectEntry(named: name) }

    func requestClose(completion: @escaping (Bool) -> Void) {
        request(.close, completion: completion)
    }

    func requestTermination(completion: @escaping (Bool) -> Void) {
        request(.terminate, completion: completion)
    }

    private func request(_ action: PendingAction, completion: ((Bool) -> Void)? = nil) {
        // Keep the first requested action stable while the user decides or acknowledges a signature.
        guard pendingAction == nil, !showSignatureWarning else {
            completion?(false)
            return
        }
        guard isDirty else {
            perform(action, completion: completion)
            return
        }
        pendingAction = action
        pendingCompletion = completion
        isShowingUnsavedConfirmation = true
    }

    func setUnsavedConfirmationPresented(_ isPresented: Bool) {
        isShowingUnsavedConfirmation = isPresented
        guard !isPresented else { return }
        // SwiftUI dismisses the dialog before delivering its button action. Wait until
        // that action can save, discard, or present the signature warning.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingAction != nil,
                  !self.isShowingUnsavedConfirmation, !self.showSignatureWarning else { return }
            self.cancelPendingAction()
        }
    }

    func savePendingAction(createBackup: Bool) {
        guard pendingAction != nil else { return }
        isShowingUnsavedConfirmation = false
        requestSave(createBackup: createBackup)
    }

    func discardPendingAction() {
        guard let action = pendingAction else { return }
        let completion = takePendingCompletion()
        perform(action, completion: completion)
    }

    func cancelPendingAction() {
        takePendingCompletion()?(false)
    }

    func cancelSignatureWarning() {
        showSignatureWarning = false
        cancelPendingAction()
    }

    private func takePendingCompletion() -> ((Bool) -> Void)? {
        let completion = pendingCompletion
        pendingCompletion = nil
        pendingAction = nil
        isShowingUnsavedConfirmation = false
        return completion
    }

    private func perform(_ action: PendingAction, completion: ((Bool) -> Void)?) {
        switch action {
        case let .open(url):
            let opened = loadArchive(url)
            completion?(opened)
        case let .selectEntry(name):
            loadEntry(named: name)
            completion?(true)
        case .close, .terminate:
            closeArchive()
            completion?(true)
        }
    }

    @discardableResult
    private func loadArchive(_ url: URL) -> Bool {
        let newAccess = url.startAccessingSecurityScopedResource()
        do {
            let opened = try ZipArchiveEditor.open(url)
            closeArchive()
            archive = opened
            hasSecurityScopedAccess = newAccess
            tree = Self.makeTree(from: opened.entries)
            didAcknowledgeSignature = false
            didCreateBackup = false
            searchText = ""
            errorMessage = nil
            return true
        } catch {
            if newAccess { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func closeArchive() {
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

    private func loadEntry(named name: String?) {
        guard let name, let archive, let entry = archive.entries.first(where: { $0.name == name }), !entry.isDirectory else {
            selectedEntryName = name
            selectedEntry = nil
            editorText = ""
            originalText = ""
            isEditable = false
            return
        }
        do {
            let data = try ZipArchiveEditor.readEntry(named: name, from: archive)
            selectedEntryName = name
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
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestSave(createBackup: Bool) {
        guard isDirty else {
            finishPendingActionAfterSave()
            return
        }
        guard archive?.hasSignatureFiles != true || didAcknowledgeSignature else {
            showSignatureWarning = true
            return
        }
        saveAndFinishPendingAction(createBackup: createBackup)
    }

    func saveAfterSignatureWarning(createBackup: Bool) {
        showSignatureWarning = false
        saveAndFinishPendingAction(createBackup: createBackup)
    }

    private func saveAndFinishPendingAction(createBackup: Bool) {
        if saveCurrent(createBackup: createBackup) {
            finishPendingActionAfterSave()
        } else {
            cancelPendingAction()
        }
    }

    @discardableResult
    func saveCurrent(createBackup: Bool) -> Bool {
        guard let archive, let entry = selectedEntry, isEditable, isDirty else { return !isDirty }
        do {
            try ZipArchiveEditor.replaceEntry(
                named: entry.name,
                with: Data(editorText.utf8),
                in: archive,
                createBackup: createBackup && !didCreateBackup
            )
            let updated = try ZipArchiveEditor.open(archive.url)
            self.archive = updated
            didCreateBackup = didCreateBackup || createBackup
            didAcknowledgeSignature = true
            selectedEntry = updated.entries.first(where: { $0.name == entry.name })
            originalText = editorText
            tree = Self.makeTree(from: updated.entries)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func finishPendingActionAfterSave() {
        guard let action = pendingAction, !isDirty else { return }
        let completion = takePendingCompletion()
        perform(action, completion: completion)
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
