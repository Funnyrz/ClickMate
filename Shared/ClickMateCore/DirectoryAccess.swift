import Combine
import Darwin
import Foundation

/// Carries the original failure across background file tasks without guessing from localized text.
struct FileAccessFailure: Equatable, Sendable {
    let domain: String
    let code: Int
    let isPermissionDenied: Bool
    let fileURL: URL?

    init(_ error: Error) {
        var current = error as NSError
        var visited = Set<ObjectIdentifier>()
        var denied = false
        var failingURL: URL?
        var permissionError: NSError?
        while visited.insert(ObjectIdentifier(current)).inserted {
            if let path = current.userInfo[NSFilePathErrorKey] as? String {
                failingURL = URL(fileURLWithPath: path)
            } else if let url = current.userInfo[NSURLErrorKey] as? URL, url.isFileURL {
                failingURL = url
            }
            if (current.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(current.code))
                || (current.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(current.code)) {
                denied = true
                permissionError = current
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        let reported = permissionError ?? (error as NSError)
        domain = reported.domain
        code = reported.code
        isPermissionDenied = denied
        fileURL = failingURL
    }

    func directoryURL(fallback: URL) -> URL {
        guard let fileURL, fileURL.standardizedFileURL != fallback.standardizedFileURL else { return fallback }
        return fileURL.hasDirectoryPath ? fileURL : fileURL.deletingLastPathComponent()
    }
}

struct DirectoryAccessObservation: Equatable {
    let directoryURL: URL
    let processIdentifier: Int32
    let observedAt: Date
    let result: FinderExtensionAccessResult
    let errorDomain: String?
    let errorCode: Int?
}

/// Evidence from user-initiated operations only; success never implies Full Disk Access.
@MainActor
final class DirectoryAccessMonitor: ObservableObject {
    static let shared = DirectoryAccessMonitor()

    @Published private(set) var latest: DirectoryAccessObservation?

    func record(directoryURL: URL, error: Error? = nil) {
        guard !(error is CancellationError) else { return }
        if let error = error as NSError?, error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
            return
        }
        record(directoryURL: directoryURL, failure: error.map(FileAccessFailure.init))
    }

    func record(directoryURL: URL, failure: FileAccessFailure?) {
        guard directoryURL.isFileURL else { return }
        latest = DirectoryAccessObservation(
            directoryURL: directoryURL.standardizedFileURL,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            observedAt: .now,
            result: failure.map { $0.isPermissionDenied ? .permissionDenied : .failed } ?? .success,
            errorDomain: failure?.domain,
            errorCode: failure?.code
        )
    }
}
