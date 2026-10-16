import CryptoKit
import Foundation

enum HashAlgorithm: String, Codable, Sendable {
    case sha256 = "SHA-256"
    case sha1 = "SHA-1"
    case md5 = "MD5"
}

enum FileHasher {
    struct HashProgress: Equatable, Sendable {
        let currentFile: URL
        let completedBytes: Int64
        let totalBytes: Int64
        /// One-based position in the requested batch, including failed files.
        let fileIndex: Int
        let totalFiles: Int
    }

    struct HashItemResult: Equatable, Sendable {
        let source: URL
        let hash: String?
        let error: String?

        var succeeded: Bool { hash != nil && error == nil }

        fileprivate var text: String {
            if let hash { return "\(hash)  \(source.lastPathComponent)" }
            return "ERROR  \(source.lastPathComponent): \(error ?? "")"
        }
    }

    struct HashResult: Equatable, Sendable {
        let items: [HashItemResult]

        var text: String { items.map(\.text).joined(separator: "\n") }
        var failures: [String] { items.filter { !$0.succeeded }.map { $0.source.lastPathComponent } }
        var successfulText: String { items.filter(\.succeeded).map(\.text).joined(separator: "\n") }
        var succeeded: Bool { items.allSatisfy(\.succeeded) }
    }

    private static let chunkSize = 1_048_576

    static func hash(fileAt url: URL, algorithm: HashAlgorithm) throws -> String {
        _ = try regularFileSize(at: url)
        return try streamHash(fileAt: url, algorithm: algorithm, isCancelled: { false }, didRead: { _ in })
    }

    static func hashes(for urls: [URL], algorithm: HashAlgorithm) -> String {
        hashResult(for: urls, algorithm: algorithm).text
    }

    static func hashResult(for urls: [URL], algorithm: HashAlgorithm) -> HashResult {
        // The throwing overload only propagates cancellation, which this compatibility entry point disables.
        do {
            return try hashResult(for: urls, algorithm: algorithm, isCancelled: { false }, progress: { _ in })
        } catch {
            return HashResult(items: urls.map { HashItemResult(source: $0, hash: nil, error: error.localizedDescription) })
        }
    }

    static func hashResult(
        for urls: [URL],
        algorithm: HashAlgorithm,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (HashProgress) -> Void
    ) throws -> HashResult {
        try checkCancellation(isCancelled)
        var totalBytes: Int64 = 0
        for url in urls {
            try checkCancellation(isCancelled)
            totalBytes += (try? regularFileSize(at: url)) ?? 0
        }
        var completedBytes: Int64 = 0
        var items: [HashItemResult] = []
        for (index, url) in urls.enumerated() {
            try checkCancellation(isCancelled)
            progress(HashProgress(currentFile: url, completedBytes: completedBytes, totalBytes: totalBytes, fileIndex: index + 1, totalFiles: urls.count))
            do {
                try checkCancellation(isCancelled)
                _ = try regularFileSize(at: url)
                let hash = try streamHash(fileAt: url, algorithm: algorithm, isCancelled: isCancelled) { bytes in
                    completedBytes += Int64(bytes)
                    progress(HashProgress(currentFile: url, completedBytes: completedBytes, totalBytes: totalBytes, fileIndex: index + 1, totalFiles: urls.count))
                }
                try checkCancellation(isCancelled)
                items.append(HashItemResult(source: url, hash: hash, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                items.append(HashItemResult(source: url, hash: nil, error: error.localizedDescription))
            }
        }
        try checkCancellation(isCancelled)
        return HashResult(items: items)
    }

    private static func regularFileSize(at url: URL) throws -> Int64 {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Only regular files can be hashed."])
        }
        return Int64(values.fileSize ?? 0)
    }

    private static func streamHash(
        fileAt url: URL,
        algorithm: HashAlgorithm,
        isCancelled: () -> Bool,
        didRead: (Int) -> Void
    ) throws -> String {
        switch algorithm {
        case .sha256:
            return try streamHash(fileAt: url, using: SHA256(), isCancelled: isCancelled, didRead: didRead)
        case .sha1:
            return try streamHash(fileAt: url, using: Insecure.SHA1(), isCancelled: isCancelled, didRead: didRead)
        case .md5:
            return try streamHash(fileAt: url, using: Insecure.MD5(), isCancelled: isCancelled, didRead: didRead)
        }
    }

    private static func streamHash<H: HashFunction>(
        fileAt url: URL,
        using initialHasher: H,
        isCancelled: () -> Bool,
        didRead: (Int) -> Void
    ) throws -> String {
        try checkCancellation(isCancelled)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = initialHasher
        while true {
            try checkCancellation(isCancelled)
            let nextChunk = try autoreleasepool { try file.read(upToCount: chunkSize) }
            guard let chunk = nextChunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            didRead(chunk.count)
        }
        try checkCancellation(isCancelled)
        return hasher.finalize().hexString
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
