import AppKit
import XCTest

final class BatchFileOperationTests: XCTestCase {
    func testDuplicateContinuesAfterMissingFileAndPreservesExistingCopy() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.txt", in: directory)
        let missing = directory.appendingPathComponent("missing.txt")
        let last = try file("last.txt", in: directory)
        let result = FileActions.duplicateBatch(urls: [first, missing, last])
        XCTAssertEqual(result.successes.count, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.sourceURL, missing)
        for item in result.successes {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.destinationURL)), Data("original".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceURL.path))
        }
        let second = FileActions.duplicateBatch(urls: [first])
        XCTAssertNotEqual(second.successes.first?.destinationURL, result.successes.first?.destinationURL)
    }

    func testAliasContinuesAfterFailureAndCreatesFinderAliases() throws {
        let directory = try temporaryDirectory()
        let source = try file("first.txt", in: directory)
        let result = FileActions.createAliasBatch(urls: [directory.appendingPathComponent("missing"), source])
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        let destination = try XCTUnwrap(result.successes.first?.destinationURL)
        XCTAssertEqual(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        XCTAssertEqual(try URL(resolvingAliasFileAt: destination).resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
    }

    func testMovePartialSuccessCanRestoreOnlySuccessfulItems() throws {
        let directory = try temporaryDirectory()
        let source = try file("first.txt", in: directory)
        let missing = directory.appendingPathComponent("missing.txt")
        let result = FileActions.moveToNewFolderBatch(urls: [source, missing])
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let receipt = try XCTUnwrap(result.moveReceipt)
        XCTAssertEqual(receipt.entries.count, 1)
        let restored = FileActions.restoreMovedItems(receipt)
        XCTAssertEqual(restored.successes.count, 1)
        XCTAssertEqual(restored.failures.count, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(result.successes.first?.destinationURL).path))
    }

    func testCancellationRetainsCompletedMovesAndReceipt() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.txt", in: directory)
        let second = try file("second.txt", in: directory)
        var cancelled = false
        let result = FileActions.moveToNewFolderBatch(urls: [first, second], isCancelled: { cancelled }, didProcess: { _ in cancelled = true })
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(result.moveReceipt?.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(FileActions.restoreMovedItems(try XCTUnwrap(result.moveReceipt)).successes.count, 1)
    }

    func testRestoreRefusesOriginalPathConflict() throws {
        let directory = try temporaryDirectory()
        let source = try file("first.txt", in: directory)
        let moved = FileActions.moveToNewFolderBatch(urls: [source])
        try Data("replacement".utf8).write(to: source)
        let result = FileActions.restoreMovedItems(try XCTUnwrap(moved.moveReceipt))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(moved.successes.first?.destinationURL)), Data("original".utf8))
        try FileManager.default.removeItem(at: source)
        let retried = FileActions.restoreMovedItems(try XCTUnwrap(result.moveReceipt))
        XCTAssertEqual(retried.successes.count, 1)
        XCTAssertNil(retried.moveReceipt)
    }

    func testRestoreRefusesChangedFileAndNestedDirectoryContents() throws {
        let directory = try temporaryDirectory()
        let source = try file("first.txt", in: directory)
        let folder = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        _ = try file("child.txt", in: folder)
        let moved = FileActions.moveToNewFolderBatch(urls: [source, folder])
        let movedFile = try XCTUnwrap(moved.successes.first?.destinationURL)
        let movedFolder = try XCTUnwrap(moved.successes.last?.destinationURL)
        try Data("changed file".utf8).write(to: movedFile)
        try Data("changed nested content".utf8).write(to: movedFolder.appendingPathComponent("child.txt"))
        let restored = FileActions.restoreMovedItems(try XCTUnwrap(moved.moveReceipt))
        XCTAssertEqual(restored.failures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFolder.path))
    }

    func testRestoreDoesNotTraverseSymbolicLinks() throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let external = try file("external.txt", in: outside)
        let source = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)
        let moved = FileActions.moveToNewFolderBatch(urls: [source])
        try Data("external changed".utf8).write(to: external)
        let restored = FileActions.restoreMovedItems(try XCTUnwrap(moved.moveReceipt))
        XCTAssertEqual(restored.successes.count, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), external.path)
    }

    func testRestoreFailureDoesNotPreventOtherItemsFromRestoring() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.txt", in: directory)
        let second = try file("second.txt", in: directory)
        let moved = FileActions.moveToNewFolderBatch(urls: [first, second])
        try FileManager.default.removeItem(at: XCTUnwrap(moved.successes.first?.destinationURL))
        let restored = FileActions.restoreMovedItems(try XCTUnwrap(moved.moveReceipt))
        XCTAssertEqual(restored.failures.count, 1)
        XCTAssertEqual(restored.successes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testCrossVolumeFallbackCopiesAndRemovesSourceAfterExclusivePublish() throws {
        let sourceDirectory = try temporaryDirectory()
        let targetDirectory = try temporaryDirectory()
        let source = try file("first.txt", in: sourceDirectory)
        let target = targetDirectory.appendingPathComponent("first.txt")
        var calls = 0
        try FileActions.moveItemExclusively(from: source, to: target, rename: { from, to in
            calls += 1
            if calls == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
            try FileManager.default.moveItem(at: from, to: to)
        })
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path), ["first.txt"])
    }

    func testExclusiveMoveNeverOverwritesConflictingTarget() throws {
        let directory = try temporaryDirectory()
        let source = try file("source.txt", in: directory)
        let target = try file("target.txt", in: directory, contents: "existing")
        XCTAssertThrowsError(try FileActions.moveItemExclusively(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func file(_ name: String, in directory: URL, contents: String = "original") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
