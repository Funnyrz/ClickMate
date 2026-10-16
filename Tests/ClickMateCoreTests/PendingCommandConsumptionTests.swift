import Foundation
import XCTest

final class PendingCommandConsumptionTests: XCTestCase {
    func testFailedClaimDoesNotExecuteCommandOrDeletePendingFile() throws {
        let directory = try temporaryDirectory()
        let pending = try enqueue(in: directory)
        let commands = PendingCommandQueue.drain(directoryURL: directory, claim: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }, cleanup: { try FileManager.default.removeItem(at: $0) })
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testFailedCleanupCannotReplayClaimedCommand() throws {
        let directory = try temporaryDirectory()
        _ = try enqueue(in: directory)
        let commands = PendingCommandQueue.drain(directoryURL: directory, claim: claim, cleanup: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).map { URL(fileURLWithPath: $0).pathExtension }, ["claimed"])
        XCTAssertTrue(PendingCommandQueue.drain(directoryURL: directory, claim: claim, cleanup: cleanup).isEmpty)
    }

    func testMalformedOrUnreadableClaimIsNeverExecuted() throws {
        let directory = try temporaryDirectory()
        try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("invalid.json"))
        // A directory with a JSON extension cannot be read as command data.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("unreadable.json"), withIntermediateDirectories: false)
        XCTAssertTrue(PendingCommandQueue.drain(directoryURL: directory, claim: claim, cleanup: cleanup).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCompetingConsumerCannotExecuteAlreadyClaimedCommand() throws {
        let directory = try temporaryDirectory()
        _ = try enqueue(in: directory)
        var competingCommands: [PendingCommand] = []
        let commands = PendingCommandQueue.drain(directoryURL: directory, claim: { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
            competingCommands = PendingCommandQueue.drain(directoryURL: directory, claim: self.claim, cleanup: self.cleanup)
        }, cleanup: cleanup)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(competingCommands.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func claim(_ source: URL, _ destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func cleanup(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private func enqueue(in directory: URL) throws -> URL {
        let command = PendingCommand.batchFileAction(command: .duplicateTimestamp, urls: [directory.appendingPathComponent("file.txt")])
        let url = directory.appendingPathComponent("\(command.id.uuidString).json")
        try JSONEncoder().encode(command).write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
