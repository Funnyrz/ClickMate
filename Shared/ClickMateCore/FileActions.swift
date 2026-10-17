import AppKit
import Darwin
import Foundation
import ImageIO

enum FileActions {
    @discardableResult
    static func writeToPasteboard(_ string: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(string, forType: .string)
    }

    static func destinationDirectory(selectedURLs: [URL], targetedURL: URL?) -> URL? {
        if selectedURLs.count == 1, let first = selectedURLs.first {
            return first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        }
        if let first = selectedURLs.first {
            return first.deletingLastPathComponent()
        }
        return targetedURL
    }

    static func duplicateWithTimestamp(urls: [URL]) throws {
        let result = duplicateBatch(urls: urls)
        if let error = result.failures.first?.errorDescription { throw BatchError.failed(error) }
    }

    static func createAliases(urls: [URL]) throws {
        let result = createAliasBatch(urls: urls)
        if let error = result.failures.first?.errorDescription { throw BatchError.failed(error) }
    }

    static func moveToNewFolder(urls: [URL]) throws {
        let result = moveToNewFolderBatch(urls: urls)
        if let error = result.failures.first?.errorDescription { throw BatchError.failed(error) }
    }

    static func revealParent(urls: [URL]) {
        guard let first = urls.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([first.deletingLastPathComponent()])
    }

    static func metadataSummary(urls: [URL]) -> String {
        urls.map { url in
            var lines = [String]()
            lines.append("Name: \(url.lastPathComponent)")
            lines.append("Path: \(url.path)")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if let size = attributes[.size] { lines.append("Size: \(size) bytes") }
                if let created = attributes[.creationDate] { lines.append("Created: \(created)") }
                if let modified = attributes[.modificationDate] { lines.append("Modified: \(modified)") }
                if let type = attributes[.type] { lines.append("Type: \(type)") }
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static func imageDimensions(urls: [URL]) -> String {
        urls.map { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth],
                  let height = properties[kCGImagePropertyPixelHeight]
            else {
                return "\(url.lastPathComponent): unavailable"
            }
            return "\(url.lastPathComponent): \(width)x\(height)"
        }
        .joined(separator: "\n")
    }
}

extension FileActions {
    struct ItemResult: Sendable {
        let sourceURL: URL
        let destinationURL: URL?
        let errorDescription: String?
        var accessFailure: FileAccessFailure? = nil
        var succeeded: Bool { errorDescription == nil && destinationURL != nil }
    }

    struct BatchResult: Sendable {
        let items: [ItemResult]
        var wasCancelled = false
        var moveReceipt: MoveReceipt?
        var successes: [ItemResult] { items.filter(\.succeeded) }
        var failures: [ItemResult] { items.filter { !$0.succeeded } }
    }

    struct MoveReceipt: Sendable {
        struct Entry: Sendable {
            let sourceURL: URL
            let destinationURL: URL
            fileprivate let fingerprint: Fingerprint
        }
        let entries: [Entry]
        fileprivate let createdFolderURL: URL?
    }

    fileprivate struct Fingerprint: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let type: String
            let size: UInt64
            let identifier: UInt64
            let device: UInt64
            let modified: Date?
            let created: Date?
            let permissions: UInt16
            let linkDestination: String?
        }
        let entries: [String: Entry]
    }

    private enum BatchError: LocalizedError, CustomNSError {
        case changedSinceMove
        case originalPathOccupied
        case sourceChangedDuringCopy
        case copiedButSourceRemains(URL, NSError)
        case movedButRestoreUnavailable(URL, NSError)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .changedSinceMove: L10n.string("batch.changedSinceMove")
            case .originalPathOccupied: L10n.string("batch.originalPathOccupied")
            case .sourceChangedDuringCopy: L10n.string("batch.sourceChangedDuringCopy")
            case let .copiedButSourceRemains(url, error): L10n.string("batch.copiedButSourceRemains", url.path, error.localizedDescription)
            case let .movedButRestoreUnavailable(url, error): L10n.string("batch.movedButRestoreUnavailable", url.path, error.localizedDescription)
            case let .failed(message): message
            }
        }

        var errorUserInfo: [String: Any] {
            var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? ""]
            switch self {
            case let .copiedButSourceRemains(_, error), let .movedButRestoreUnavailable(_, error):
                info[NSUnderlyingErrorKey] = error
            default: break
            }
            return info
        }
    }

    static func duplicateBatch(
        urls: [URL], isCancelled: () -> Bool = { false }, didProcess: (ItemResult) -> Void = { _ in }
    ) -> BatchResult {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return performBatch(urls: urls, isCancelled: isCancelled, didProcess: didProcess) { source in
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            let name = ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)"
            let parent = source.deletingLastPathComponent()
            let stagingDirectory = parent.appendingPathComponent(".clickmate-copy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let stagedCopy = stagingDirectory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: stagedCopy)
            return try withAvailableDestination(in: parent, preferredFilename: name) { destination in
                try exclusiveRename(from: stagedCopy, to: destination)
            }
        }
    }

    static func createAliasBatch(
        urls: [URL], isCancelled: () -> Bool = { false }, didProcess: (ItemResult) -> Void = { _ in }
    ) -> BatchResult {
        performBatch(urls: urls, isCancelled: isCancelled, didProcess: didProcess) { source in
            let parent = source.deletingLastPathComponent()
            let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            let stagingDirectory = parent.appendingPathComponent(".clickmate-alias-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let stagedAlias = stagingDirectory.appendingPathComponent("alias")
            try URL.writeBookmarkData(bookmark, to: stagedAlias)
            return try withAvailableDestination(in: parent, preferredFilename: "\(source.deletingPathExtension().lastPathComponent) alias") { destination in
                try exclusiveRename(from: stagedAlias, to: destination)
            }
        }
    }

    static func moveToNewFolderBatch(
        urls: [URL], folderName: String = "New Folder", isCancelled: () -> Bool = { false }, didProcess: (ItemResult) -> Void = { _ in }
    ) -> BatchResult {
        guard let first = urls.first else { return BatchResult(items: []) }
        guard !isCancelled() else { return BatchResult(items: [], wasCancelled: true) }
        let folder: URL
        do {
            guard !folderName.isEmpty, !folderName.contains("/"), !folderName.contains("\0"), ![".", ".."].contains(folderName) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            folder = try withAvailableDestination(in: first.deletingLastPathComponent(), preferredFilename: folderName) { destination in
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
        } catch {
            let items = urls.map { ItemResult(sourceURL: $0, destinationURL: nil, errorDescription: error.localizedDescription, accessFailure: FileAccessFailure(error)) }
            items.forEach(didProcess)
            return BatchResult(items: items)
        }
        var receipts: [MoveReceipt.Entry] = []
        var result = performBatch(urls: urls, isCancelled: isCancelled, didProcess: didProcess) { source in
            _ = try fingerprint(of: source)
            let destination = try withAvailableDestination(in: folder, preferredFilename: source.lastPathComponent) { destination in
                try moveItemExclusively(from: source, to: destination)
            }
            do {
                receipts.append(MoveReceipt.Entry(sourceURL: source, destinationURL: destination, fingerprint: try fingerprint(of: destination)))
            } catch {
                throw BatchError.movedButRestoreUnavailable(destination, error as NSError)
            }
            return destination
        }
        result.moveReceipt = receipts.isEmpty ? nil : MoveReceipt(entries: receipts, createdFolderURL: folder)
        if result.successes.isEmpty { _ = folder.withUnsafeFileSystemRepresentation { rmdir($0!) } }
        return result
    }

    static func restoreMovedItems(
        _ receipt: MoveReceipt, isCancelled: () -> Bool = { false }, didProcess: (ItemResult) -> Void = { _ in }
    ) -> BatchResult {
        var items: [ItemResult] = []
        var wasCancelled = false
        var pending: [MoveReceipt.Entry] = []
        for (index, entry) in receipt.entries.enumerated() {
            if isCancelled() {
                wasCancelled = true
                pending.append(contentsOf: receipt.entries[index...])
                break
            }
            let item: ItemResult
            do {
                guard try fingerprint(of: entry.destinationURL) == entry.fingerprint else { throw BatchError.changedSinceMove }
                guard !itemExists(at: entry.sourceURL) else { throw BatchError.originalPathOccupied }
                try moveItemExclusively(from: entry.destinationURL, to: entry.sourceURL)
                item = ItemResult(sourceURL: entry.destinationURL, destinationURL: entry.sourceURL, errorDescription: nil)
            } catch {
                item = failure(sourceURL: entry.destinationURL, error: error)
                pending.append(entry)
            }
            items.append(item)
            didProcess(item)
        }
        if !wasCancelled, items.allSatisfy(\.succeeded), let folder = receipt.createdFolderURL {
            // rmdir removes only an empty directory; files added by the user are retained.
            _ = folder.withUnsafeFileSystemRepresentation { rmdir($0!) }
        }
        let remaining = pending.isEmpty ? nil : MoveReceipt(entries: pending, createdFolderURL: receipt.createdFolderURL)
        return BatchResult(items: items, wasCancelled: wasCancelled, moveReceipt: remaining)
    }

    /// The injectable rename is a bounded seam for testing EXDEV without a second volume.
    static func moveItemExclusively(
        from source: URL, to destination: URL,
        rename: (URL, URL) throws -> Void = { try exclusiveRename(from: $0, to: $1) },
        removeSource: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        do {
            try rename(source, destination)
            return
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EXDEV) else { throw error }
        }
        let before = try fingerprint(of: source)
        let stagingDirectory = destination.deletingLastPathComponent().appendingPathComponent(".clickmate-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedItem = stagingDirectory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: stagedItem)
        guard try fingerprint(of: source) == before else { throw BatchError.sourceChangedDuringCopy }
        try rename(stagedItem, destination)
        do {
            try removeSource(source)
        } catch {
            // Keep the complete published copy if source removal fails, including partial
            // directory removal. Deleting it here could destroy the only remaining data.
            throw BatchError.copiedButSourceRemains(destination, error as NSError)
        }
    }

    private static func performBatch(
        urls: [URL], isCancelled: () -> Bool, didProcess: (ItemResult) -> Void,
        operation: (URL) throws -> URL
    ) -> BatchResult {
        var items: [ItemResult] = []
        var wasCancelled = false
        for source in urls {
            if isCancelled() { wasCancelled = true; break }
            let item: ItemResult
            do {
                item = ItemResult(sourceURL: source, destinationURL: try operation(source), errorDescription: nil)
            } catch {
                item = failure(sourceURL: source, error: error)
            }
            items.append(item)
            didProcess(item)
        }
        return BatchResult(items: items, wasCancelled: wasCancelled)
    }

    private static func failure(sourceURL: URL, error: Error) -> ItemResult {
        var destination: URL?
        if let batchError = error as? BatchError {
            switch batchError {
            case let .copiedButSourceRemains(url, _), let .movedButRestoreUnavailable(url, _): destination = url
            default: break
            }
        }
        return ItemResult(sourceURL: sourceURL, destinationURL: destination, errorDescription: error.localizedDescription, accessFailure: FileAccessFailure(error))
    }

    private static func withAvailableDestination(
        in directory: URL, preferredFilename: String, operation: (URL) throws -> Void
    ) throws -> URL {
        let name = preferredFilename as NSString
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " \(index)"
            let filename = name.pathExtension.isEmpty ? "\(name)\(suffix)" : "\(name.deletingPathExtension)\(suffix).\(name.pathExtension)"
            let destination = directory.appendingPathComponent(filename)
            if itemExists(at: destination) { index += 1; continue }
            do {
                try operation(destination)
                return destination
            } catch {
                let error = error as NSError
                let isConflict = (error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST))
                    || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteFileExists.rawValue)
                guard isConflict else { throw error }
                index += 1
            }
        }
    }

    private static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func exclusiveRename(from source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { targetPath in
                renamex_np(sourcePath!, targetPath!, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            let failure = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private static func fingerprint(of root: URL) throws -> Fingerprint {
        var entries: [String: Fingerprint.Entry] = [:]
        func visit(_ url: URL, relativePath: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            entries[relativePath] = Fingerprint.Entry(
                type: type?.rawValue ?? "", size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                identifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                modified: attributes[.modificationDate] as? Date, created: attributes[.creationDate] as? Date,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                linkDestination: type == .typeSymbolicLink ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            )
            if type == .typeDirectory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for child in children {
                    let path = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
                    try visit(child, relativePath: path)
                }
            }
        }
        try visit(root, relativePath: "")
        return Fingerprint(entries: entries)
    }
}
