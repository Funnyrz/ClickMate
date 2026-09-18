import Foundation
import XCTest

final class ZipArchiveEditorTests: XCTestCase {
    func testReplacingStoredEntryKeepsCompressionAndUntouchedEntryBytes() throws {
        let directory = try makeTemporaryDirectory()
        let configURL = directory.appendingPathComponent("config.properties")
        let untouchedURL = directory.appendingPathComponent("untouched.txt")
        try Data("server.port=8080\n".utf8).write(to: configURL)
        try Data(repeating: 0x41, count: 16_384).write(to: untouchedURL)
        let archiveURL = directory.appendingPathComponent("app.jar")
        try zip(["-0", archiveURL.path, configURL.lastPathComponent], in: directory)
        try zip([archiveURL.path, untouchedURL.lastPathComponent], in: directory)

        let original = try ZipArchiveEditor.open(archiveURL)
        let stored = try XCTUnwrap(original.entries.first(where: { $0.name == "config.properties" }))
        let untouched = try XCTUnwrap(original.entries.first(where: { $0.name == "untouched.txt" }))
        XCTAssertEqual(stored.compressionMethod, .store)
        let untouchedContents = try ZipArchiveEditor.readEntry(named: untouched.name, from: original)

        try ZipArchiveEditor.replaceEntry(
            named: stored.name,
            with: Data("server.port=9090\n".utf8),
            in: original,
            createBackup: true
        )

        let rewritten = try ZipArchiveEditor.open(archiveURL)
        XCTAssertEqual(rewritten.entries.count, original.entries.count)
        XCTAssertEqual(try XCTUnwrap(rewritten.entries.first(where: { $0.name == stored.name })).compressionMethod, .store)
        XCTAssertEqual(try ZipArchiveEditor.readEntry(named: stored.name, from: rewritten), Data("server.port=9090\n".utf8))
        XCTAssertEqual(try ZipArchiveEditor.readEntry(named: untouched.name, from: rewritten), untouchedContents)
        XCTAssertEqual(try XCTUnwrap(rewritten.entries.first(where: { $0.name == untouched.name })).compressionMethod, untouched.compressionMethod)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.appendingPathExtension("bak").path))
    }

    func testReplacingDeflatedEntryKeepsDeflate() throws {
        let directory = try makeTemporaryDirectory()
        let configURL = directory.appendingPathComponent("BOOT-INF/classes/application.yml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 8_192).write(to: configURL)
        let archiveURL = directory.appendingPathComponent("app.jar")
        try zip([archiveURL.path, "BOOT-INF/classes/application.yml"], in: directory)

        let original = try ZipArchiveEditor.open(archiveURL)
        let entry = try XCTUnwrap(original.entries.first(where: { $0.name == "BOOT-INF/classes/application.yml" }))
        XCTAssertEqual(entry.compressionMethod, .deflate)
        let changed = Data("spring:\n  profiles:\n    active: prod\n".utf8)
        try ZipArchiveEditor.replaceEntry(named: entry.name, with: changed, in: original, createBackup: false)

        let rewritten = try ZipArchiveEditor.open(archiveURL)
        XCTAssertEqual(try XCTUnwrap(rewritten.entries.first(where: { $0.name == entry.name })).compressionMethod, .deflate)
        XCTAssertEqual(try ZipArchiveEditor.readEntry(named: entry.name, from: rewritten), changed)
    }

    private func zip(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip \(arguments.joined(separator: " "))")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
