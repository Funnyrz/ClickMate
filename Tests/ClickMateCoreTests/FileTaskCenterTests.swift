import Foundation
import XCTest

@MainActor
final class FileTaskCenterTests: XCTestCase {
    func testSuccessfulHashCopiesOnlyAfterFinishing() async throws {
        let source = try makeFile()
        var clipboard = "before"
        let center = FileTaskCenter(presentsWindows: false, clipboardWriter: { clipboard = $0; return true })
        center.hash([source], algorithm: .sha256)
        XCTAssertEqual(clipboard, "before")
        try await waitForTasks(center)
        XCTAssertEqual(center.items.first?.state, .succeeded)
        XCTAssertEqual(clipboard, try FileHasher.hashes(for: [source], algorithm: .sha256))
    }

    func testPartialFailureKeepsClipboardAndOffersSuccessfulResults() async throws {
        let source = try makeFile()
        var clipboard = "before"
        let center = FileTaskCenter(presentsWindows: false, clipboardWriter: { clipboard = $0; return true })
        center.hash([source, source.appendingPathExtension("missing")], algorithm: .md5)
        try await waitForTasks(center)
        XCTAssertEqual(clipboard, "before")
        XCTAssertEqual(center.items.first?.state, .partial)
        XCTAssertFalse(try XCTUnwrap(center.items.first?.successfulText).contains("ERROR"))
        XCTAssertEqual(center.items.first?.results.count, 2)
    }

    func testCancelKeepsClipboardAndDoesNotPublishLateSuccess() async throws {
        let source = try makeFile()
        var clipboard = "before"
        let center = FileTaskCenter(presentsWindows: false, clipboardWriter: { clipboard = $0; return true })
        center.hash([source], algorithm: .sha1)
        center.items.first?.cancellation.cancel()
        try await waitForTasks(center)
        XCTAssertEqual(clipboard, "before")
        XCTAssertEqual(center.items.first?.state, .cancelled)
        XCTAssertNil(center.items.first?.successfulText)
    }

    func testClipboardWriteFailureRemainsRecoverable() async throws {
        let source = try makeFile()
        let center = FileTaskCenter(presentsWindows: false, clipboardWriter: { _ in false })
        center.hash([source], algorithm: .md5)
        try await waitForTasks(center)
        XCTAssertEqual(center.items.first?.state, .failed)
        XCTAssertNotNil(center.items.first?.successfulText)
    }

    func testMoveTaskRestoresFilesWithinTheSession() async throws {
        let source = try makeFile()
        let center = FileTaskCenter(presentsWindows: false)
        center.batch([source], command: .moveToNewFolder)
        try await waitForTasks(center)
        let move = try XCTUnwrap(center.items.first)
        XCTAssertTrue(move.canRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        center.restore(move.id)
        try await waitForTasks(center)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(center.items.first?.state, .succeeded)
        XCTAssertFalse(center.items.first?.canRestore ?? true)
    }

    func testRestoreConflictCanBeRetriedFromTheResultTask() async throws {
        let source = try makeFile()
        let original = try Data(contentsOf: source)
        let center = FileTaskCenter(presentsWindows: false)
        center.batch([source], command: .moveToNewFolder)
        try await waitForTasks(center)
        let moveID = try XCTUnwrap(center.items.first?.id)
        try Data("conflicting file".utf8).write(to: source)
        center.restore(moveID)
        try await waitForTasks(center)
        let failure = try XCTUnwrap(center.items.first)
        XCTAssertEqual(failure.state, .failed)
        XCTAssertTrue(failure.canRestore)
        XCTAssertEqual(try Data(contentsOf: source), Data("conflicting file".utf8))
        try FileManager.default.removeItem(at: source)
        center.restore(failure.id)
        try await waitForTasks(center)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(center.items.first?.state, .succeeded)
    }

    private func makeFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input.txt")
        try Data("ClickMate file task test".utf8).write(to: file)
        return file
    }

    private func waitForTasks(_ center: FileTaskCenter) async throws {
        for _ in 0..<500 {
            if !center.items.contains(where: { $0.state == .running }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("File task did not finish")
    }
}
