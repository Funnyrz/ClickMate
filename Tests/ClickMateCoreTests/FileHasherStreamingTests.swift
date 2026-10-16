import CryptoKit
import Foundation
import XCTest

final class FileHasherStreamingTests: XCTestCase {
    func testEveryAlgorithmMatchesOneShotDigestAcrossChunkBoundaries() throws {
        let data = Data((0..<(2 * 1_048_576 + 97)).map { UInt8($0 % 251) })
        let url = try makeFile(contents: data)
        let expected: [(HashAlgorithm, String)] = [
            (.sha256, hex(SHA256.hash(data: data))),
            (.sha1, hex(Insecure.SHA1.hash(data: data))),
            (.md5, hex(Insecure.MD5.hash(data: data)))
        ]
        for (algorithm, digest) in expected {
            let progress = ProgressRecorder()
            let result = try FileHasher.hashResult(for: [url], algorithm: algorithm, isCancelled: { false }, progress: { progress.append($0) })
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.items.first?.hash, digest)
            XCTAssertEqual(result.successfulText, "\(digest)  \(url.lastPathComponent)")
            XCTAssertEqual(try FileHasher.hash(fileAt: url, algorithm: algorithm), digest)
            let updates = progress.values
            XCTAssertEqual(updates.map(\.completedBytes), [0, 1_048_576, 2_097_152, Int64(data.count)])
            XCTAssertTrue(updates.allSatisfy { $0.totalBytes == Int64(data.count) && $0.fileIndex == 1 && $0.totalFiles == 1 })
        }
    }

    func testCancellationAfterFirstChunkStopsBatchBeforeSecondFile() throws {
        let first = try makeFile(contents: Data(repeating: 0x41, count: 3 * 1_048_576))
        let second = try makeFile(contents: Data("later".utf8))
        let recorder = ProgressRecorder()
        XCTAssertThrowsError(try FileHasher.hashResult(
            for: [first, second], algorithm: .sha256,
            isCancelled: { recorder.values.contains { $0.completedBytes >= 1_048_576 } },
            progress: { recorder.append($0) }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(recorder.values.map(\.completedBytes), [0, 1_048_576])
        XCTAssertTrue(recorder.values.allSatisfy { $0.currentFile == first })
    }

    func testCancelledBeforeStartDoesNotPublishProgress() throws {
        let recorder = ProgressRecorder()
        XCTAssertThrowsError(try FileHasher.hashResult(for: [], algorithm: .md5, isCancelled: { true }, progress: { recorder.append($0) })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testPartialFailureContinuesAndSuccessfulTextExcludesErrorLines() throws {
        let good = try makeFile(contents: Data("hello".utf8))
        let missing = good.deletingLastPathComponent().appendingPathComponent("missing.txt")
        let result = try FileHasher.hashResult(for: [missing, good], algorithm: .md5, isCancelled: { false }, progress: { _ in })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failures, ["missing.txt"])
        XCTAssertEqual(result.items.map(\.source), [missing, good])
        XCTAssertFalse(result.items[0].succeeded)
        XCTAssertNotNil(result.items[0].error)
        XCTAssertTrue(result.items[1].succeeded)
        XCTAssertTrue(result.text.contains("ERROR  missing.txt:"))
        XCTAssertEqual(result.successfulText, "5d41402abc4b2a76b9719d911017c592  \(good.lastPathComponent)")
    }

    func testMultipleFilesReportSerialGlobalProgressAndEmptyFileDigest() throws {
        let first = try makeFile(contents: Data("hello".utf8))
        let empty = try makeFile(contents: Data())
        let recorder = ProgressRecorder()
        let result = try FileHasher.hashResult(for: [first, empty], algorithm: .md5, isCancelled: { false }, progress: { recorder.append($0) })
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.items[1].hash, "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(recorder.values.map(\.fileIndex), [1, 1, 2])
        XCTAssertEqual(recorder.values.map(\.completedBytes), [0, 5, 5])
        XCTAssertTrue(recorder.values.allSatisfy { $0.totalBytes == 5 && $0.totalFiles == 2 })
    }

    func testDirectoriesAreRejectedWithoutReadingAndNextFileStillHashes() throws {
        let file = try makeFile(contents: Data())
        let directory = file.deletingLastPathComponent()
        let result = try FileHasher.hashResult(for: [directory, file], algorithm: .sha256, isCancelled: { false }, progress: { _ in })
        XCTAssertFalse(result.items[0].succeeded)
        XCTAssertTrue(result.items[1].succeeded)
        XCTAssertEqual(result.items.count, 2)
    }

    private func makeFile(contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hash.txt")
        try contents.write(to: file)
        return file
    }

    private func hex<D: Digest>(_ digest: D) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FileHasher.HashProgress] = []
        var values: [FileHasher.HashProgress] { lock.withLock { storage } }
        func append(_ progress: FileHasher.HashProgress) { lock.withLock { storage.append(progress) } }
    }
}
