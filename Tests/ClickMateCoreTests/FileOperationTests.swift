import AppKit
import XCTest

final class FileOperationTests: XCTestCase {
    func testAliasIsFinderAliasAndResolvesToOriginal() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("文档.txt")
        try Data("original".utf8).write(to: source)

        try FileActions.createAliases(urls: [source])

        let alias = directory.appendingPathComponent("文档 alias")
        let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isAliasFile, true)
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertEqual(try URL(resolvingAliasFileAt: alias).resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testCompressProducesValidatedArchiveWithLiteralNamesAndLinks() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("中文 folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let source = folder.appendingPathComponent("[*] $test.txt")
        try Data("literal contents".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: source.lastPathComponent)
        let dash = directory.appendingPathComponent("-input [1].txt")
        try Data("second".utf8).write(to: dash)

        let archive = try FileCompressor.compress(urls: [folder, dash], archiveName: "归档")
        XCTAssertEqual(archive.lastPathComponent, "归档.zip")
        let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/unzip", ["-q", archive.path, "-d", extracted.path])
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("中文 folder/[*] $test.txt")), Data("literal contents".utf8))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("-input [1].txt")), Data("second".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("中文 folder/link").path), source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try contents(directory).filter { $0.hasPrefix(".clickmate-compress-") }, [])
    }

    func testCompressSingleNameAndExistingArchiveArePreserved() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: source)
        let existing = directory.appendingPathComponent("notes.zip")
        try Data("existing".utf8).write(to: existing)
        let archive = try FileCompressor.compress(urls: [source])
        XCTAssertEqual(archive.lastPathComponent, "notes 2.zip")
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        try run("/usr/bin/unzip", ["-t", archive.path])
    }

    func testCompressRejectsMixedDirectoriesWithoutArtifacts() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        let a = first.appendingPathComponent("a.txt")
        let b = second.appendingPathComponent("b.txt")
        try Data().write(to: a)
        try Data().write(to: b)
        XCTAssertThrowsError(try FileCompressor.compress(urls: [a, b])) { error in
            guard case FileCompressor.CompressionError.mixedDirectories = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try contents(first), ["a.txt"])
        XCTAssertEqual(try contents(second), ["b.txt"])
    }

    func testCompressCancellationRemovesTemporaryArtifactsAndPreservesSource() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: source)
        var cancelled = false
        XCTAssertThrowsError(try FileCompressor.compress(urls: [source], isCancelled: { cancelled }, progress: { value in
            if value.stage == .validating { cancelled = true }
        })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try contents(directory), ["notes.txt"])
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testCompressFailsForMissingInputWithoutPublishingPartialArchive() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try FileCompressor.compress(urls: [source]))
        XCTAssertEqual(try contents(directory), [])
    }

    func testCompressDottedFolderRetainsFolderName() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("app contents".utf8).write(to: folder.appendingPathComponent("file.txt"))
        XCTAssertEqual(try FileCompressor.compress(urls: [folder]).lastPathComponent, "Example.app.zip")
    }

    func testCompressDoesNotOverwriteDanglingSymlinkAtDestination() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: source)
        let occupied = directory.appendingPathComponent("notes.zip")
        try FileManager.default.createSymbolicLink(atPath: occupied.path, withDestinationPath: "missing.zip")
        XCTAssertEqual(try FileCompressor.compress(urls: [source]).lastPathComponent, "notes 2.zip")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), "missing.zip")
    }

    func testCompressFailsWithoutWritePermissionAndLeavesSourceIntact() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try FileCompressor.compress(urls: [source]))
        XCTAssertEqual(try contents(directory), ["notes.txt"])
    }

    func testCompressCancellationBeforeLaunchingCreatesNothing() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: source)
        XCTAssertThrowsError(try FileCompressor.compress(urls: [source], isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try contents(directory), ["notes.txt"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func contents(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
