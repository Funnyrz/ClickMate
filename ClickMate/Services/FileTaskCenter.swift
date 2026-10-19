import AppKit
import SwiftUI

final class FileTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct FileTaskItem: Identifiable, Sendable {
    enum State: Sendable { case running, succeeded, partial, failed, cancelled }
    let id: UUID
    let title: String
    var detail = ""
    var fraction: Double?
    var state: State = .running
    var outputURLs: [URL] = []
    var successfulText: String?
    var results: [FileTaskResult] = []
    var canRestore = false
    let cancellation: FileTaskCancellation
}

struct FileTaskResult: Sendable {
    let source: URL
    let destination: URL?
    let error: String?
}

private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = 0.0
    func shouldUpdate(force: Bool) -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastUpdate >= 0.1 else { return false }
            lastUpdate = now
            return true
        }
    }
}

@MainActor
final class FileTaskCenter: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = FileTaskCenter()
    @Published var items: [FileTaskItem] = []
    private var window: NSWindow?
    private let presentsWindows: Bool
    private let clipboardWriter: (String) -> Bool
    private let accessMonitor: DirectoryAccessMonitor
    private var receipts: [UUID: FileActions.MoveReceipt] = [:]

    init(
        presentsWindows: Bool = true,
        clipboardWriter: @escaping (String) -> Bool = FileActions.writeToPasteboard,
        accessMonitor: DirectoryAccessMonitor = .shared
    ) {
        self.presentsWindows = presentsWindows
        self.clipboardWriter = clipboardWriter
        self.accessMonitor = accessMonitor
        super.init()
    }

    func show() {
        guard presentsWindows else { return }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: FileTasksView(center: self)))
            window.title = L10n.string("tasks.title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 430))
            window.minSize = NSSize(width: 520, height: 300)
            window.isReleasedWhenClosed = false
            window.identifier = AppWindows.tasksID
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        receipts = receipts.filter { id, _ in items.contains { $0.id == id } }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @discardableResult
    func begin(title: String) -> FileTaskItem {
        let item = FileTaskItem(id: UUID(), title: title, cancellation: FileTaskCancellation())
        items.insert(item, at: 0)
        show()
        return item
    }

    func update(_ id: UUID, _ change: (inout FileTaskItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    func cancelAndWait(completion: @escaping () -> Void) {
        let runningItems = items.filter { $0.state == .running }
        guard !runningItems.isEmpty else {
            completion()
            return
        }
        runningItems.forEach { $0.cancellation.cancel() }
        Task {
            while items.contains(where: { $0.state == .running }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            completion()
        }
    }

    func compress(_ urls: [URL]) {
        let job = begin(title: L10n.string("command.compress"))
        let preferences = PreferencesStore.loadSnapshot()
        let accesses = urls.compactMap {
            DiskAccessPolicy.scopedOrDirectAccess(containing: $0.deletingLastPathComponent(), preferences: preferences)
        }
        let name = L10n.string("tasks.archiveName")
        Task {
            defer { accesses.forEach { $0.stopAccessing() } }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try FileCompressor.compress(urls: urls, archiveName: name, isCancelled: { job.cancellation.isCancelled }) { progress in
                        Task { @MainActor in
                            self.update(job.id) {
                                guard $0.state == .running else { return }
                                $0.detail = L10n.string("tasks.stage.\(progress.stage)")
                            }
                        }
                    }
                }.value
                accessMonitor.record(directoryURL: output.deletingLastPathComponent())
                update(job.id) {
                    $0.state = .succeeded
                    $0.detail = output.lastPathComponent
                    $0.outputURLs = [output]
                }
                ActionNotifier.notify(titleKey: "notification.successTitle", bodyKey: "notification.completed")
            } catch is CancellationError {
                update(job.id) { $0.state = .cancelled; $0.detail = L10n.string("tasks.cancelled") }
            } catch {
                recordFailure(error, fallbackDirectory: urls.first?.deletingLastPathComponent())
                update(job.id) { $0.state = .failed; $0.detail = error.localizedDescription }
            }
        }
    }

    func hash(_ urls: [URL], algorithm: HashAlgorithm) {
        let job = begin(title: algorithm.rawValue)
        let gate = ProgressGate()
        let accesses = folderAccesses(for: urls)
        Task {
            defer { accesses.forEach { $0.stopAccessing() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileHasher.hashResult(for: urls, algorithm: algorithm, isCancelled: { job.cancellation.isCancelled }) { progress in
                        guard gate.shouldUpdate(force: progress.completedBytes == 0 || progress.completedBytes == progress.totalBytes) else { return }
                        Task { @MainActor in
                            self.update(job.id) { item in
                                guard item.state == .running else { return }
                                item.fraction = progress.totalBytes > 0 ? min(1, Double(progress.completedBytes) / Double(progress.totalBytes)) : nil
                                item.detail = "\(progress.fileIndex)/\(progress.totalFiles) · \(progress.currentFile.lastPathComponent)\n"
                                    + ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
                                    + " / " + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                            }
                        }
                    }
                }.value
                guard !job.cancellation.isCancelled else { throw CancellationError() }
                // Publish failures last so a successful neighbor cannot hide a denied target.
                for item in result.items.filter(\.succeeded) {
                    accessMonitor.record(directoryURL: item.source.deletingLastPathComponent())
                }
                for item in result.items.filter({ !$0.succeeded }) {
                    let failure = item.accessFailure ?? FileAccessFailure(CocoaError(.fileReadUnknown))
                    accessMonitor.record(directoryURL: failure.directoryURL(fallback: item.source.deletingLastPathComponent()), failure: failure)
                }
                let copied = result.succeeded && clipboardWriter(result.text)
                update(job.id) {
                    $0.state = result.succeeded ? (copied ? .succeeded : .failed) : (result.successfulText.isEmpty ? .failed : .partial)
                    $0.fraction = nil
                    $0.detail = copied ? L10n.string("notification.copied") : (result.succeeded ? L10n.string("notification.actionFailed") : L10n.string("tasks.partial"))
                    $0.successfulText = !copied && !result.successfulText.isEmpty ? result.successfulText : nil
                    $0.results = result.items.map { FileTaskResult(source: $0.source, destination: nil, error: $0.error) }
                }
            } catch is CancellationError {
                update(job.id) { $0.state = .cancelled; $0.fraction = nil; $0.detail = L10n.string("tasks.cancelled") }
            } catch {
                recordFailure(error, fallbackDirectory: urls.first?.deletingLastPathComponent())
                update(job.id) { $0.state = .failed; $0.detail = error.localizedDescription }
            }
        }
    }

    func batch(_ urls: [URL], command: MenuCommand) {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL), [.duplicateTimestamp, .createAlias, .moveToNewFolder].contains(command) else { return }
        let job = begin(title: command.title)
        let accesses = folderAccesses(for: urls)
        let folderName = L10n.string("tasks.newFolder")
        Task {
            defer { accesses.forEach { $0.stopAccessing() } }
            let result = await Task.detached(priority: .userInitiated) {
                switch command {
                case .duplicateTimestamp: return FileActions.duplicateBatch(urls: urls, isCancelled: { job.cancellation.isCancelled })
                case .createAlias: return FileActions.createAliasBatch(urls: urls, isCancelled: { job.cancellation.isCancelled })
                default: return FileActions.moveToNewFolderBatch(urls: urls, folderName: folderName, isCancelled: { job.cancellation.isCancelled })
                }
            }.value
            completeBatch(job, result: result)
        }
    }

    func restore(_ id: UUID) {
        guard let receipt = receipts.removeValue(forKey: id) else { return }
        update(id) { $0.canRestore = false }
        let job = begin(title: L10n.string("tasks.restore"))
        let accesses = folderAccesses(for: receipt.entries.flatMap { [$0.sourceURL, $0.destinationURL] })
        Task {
            defer { accesses.forEach { $0.stopAccessing() } }
            let result = await Task.detached(priority: .userInitiated) {
                FileActions.restoreMovedItems(receipt, isCancelled: { job.cancellation.isCancelled })
            }.value
            completeBatch(job, result: result)
        }
    }

    private func completeBatch(_ job: FileTaskItem, result: FileActions.BatchResult) {
        for item in result.successes {
            accessMonitor.record(directoryURL: item.sourceURL.deletingLastPathComponent())
            if let destination = item.destinationURL {
                accessMonitor.record(directoryURL: destination.deletingLastPathComponent())
            }
        }
        for item in result.failures {
            let failure = item.accessFailure ?? FileAccessFailure(CocoaError(.fileReadUnknown))
            accessMonitor.record(directoryURL: failure.directoryURL(fallback: item.sourceURL.deletingLastPathComponent()), failure: failure)
        }
        let successes = result.items.filter(\.succeeded).count
        let failures = result.items.count - successes
        if let receipt = result.moveReceipt { receipts[job.id] = receipt }
        update(job.id) {
            $0.state = result.wasCancelled ? .cancelled : (failures == 0 ? .succeeded : (successes == 0 ? .failed : .partial))
            $0.detail = L10n.string("tasks.summary", successes, failures)
                + (result.wasCancelled ? "\n" + L10n.string("tasks.cancelled") : "")
            $0.outputURLs = result.items.filter(\.succeeded).compactMap(\.destinationURL)
            $0.results = result.items.map { FileTaskResult(source: $0.sourceURL, destination: $0.destinationURL, error: $0.errorDescription) }
            $0.canRestore = result.moveReceipt != nil
        }
    }

    private func folderAccesses(for urls: [URL]) -> [SecurityScopedFolderAccess.ScopedAccess] {
        let preferences = PreferencesStore.loadSnapshot()
        return Set(urls.map { $0.deletingLastPathComponent() }).compactMap {
            DiskAccessPolicy.scopedOrDirectAccess(containing: $0, preferences: preferences)
        }
    }

    private func recordFailure(_ error: Error, fallbackDirectory: URL?) {
        let failure = FileAccessFailure(error)
        guard let fallbackDirectory else { return }
        let directory = failure.directoryURL(fallback: fallbackDirectory)
        accessMonitor.record(directoryURL: directory, error: error)
    }
}

struct FileTasksView: View {
    @ObservedObject var center: FileTaskCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.string("tasks.title"), systemImage: "list.bullet.clipboard")
                    .font(.title2.bold())
                Spacer()
                Button(L10n.string("tasks.clearFinished")) {
                    center.clearFinished()
                }
            }
            if center.items.isEmpty {
                ContentUnavailableView(L10n.string("tasks.empty"), systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(center.items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(item.title).font(.headline)
                                    Spacer()
                                    if item.state == .running {
                                        Button(L10n.string("tasks.cancel")) { item.cancellation.cancel() }
                                            .disabled(item.cancellation.isCancelled)
                                    } else {
                                        Image(systemName: item.state == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                                            .foregroundStyle(item.state == .succeeded ? Color.green : Color.secondary)
                                    }
                                }
                                if item.state == .running {
                                    if let fraction = item.fraction { ProgressView(value: fraction) }
                                    else { ProgressView().controlSize(.small) }
                                }
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack {
                                    if !item.outputURLs.isEmpty {
                                        Button(L10n.string("tasks.reveal")) { NSWorkspace.shared.activateFileViewerSelecting(item.outputURLs) }
                                    }
                                    if let text = item.successfulText {
                                        Button(L10n.string("tasks.copySuccess")) { FileActions.writeToPasteboard(text) }
                                    }
                                    if item.canRestore {
                                        Button(L10n.string("tasks.restore")) { center.restore(item.id) }
                                    }
                                }
                                ForEach(Array(item.results.enumerated()), id: \.offset) { _, result in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label(result.source.lastPathComponent, systemImage: result.error == nil ? "checkmark" : "exclamationmark.triangle")
                                        Text(result.error ?? result.destination?.path ?? result.source.path)
                                            .font(.caption).foregroundStyle(result.error == nil ? Color.secondary : Color.red)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
