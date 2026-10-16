import Darwin
import Foundation

/// Runs system ZIP tools synchronously; callers should execute this work off the main thread.
enum FileCompressor {
    struct Progress: Sendable {
        enum Stage: Sendable { case compressing, validating, publishing }
        let stage: Stage
        let currentFile: URL?
    }

    enum CompressionError: LocalizedError {
        case noFiles
        case mixedDirectories
        case invalidName
        case commandFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .noFiles: L10n.string("compression.noFiles")
            case .mixedDirectories: L10n.string("compression.mixedDirectories")
            case .invalidName: L10n.string("compression.invalidName")
            case let .commandFailed(status, message): L10n.string("compression.commandFailed", status, message)
            }
        }
    }

    static func compress(
        urls: [URL],
        archiveName: String = "Archive",
        isCancelled: () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) throws -> URL {
        try checkCancellation(isCancelled)
        guard let first = urls.first, urls.allSatisfy(\.isFileURL) else { throw CompressionError.noFiles }
        let inputs = urls.map(\.standardizedFileURL)
        let parent = first.standardizedFileURL.deletingLastPathComponent()
        guard inputs.allSatisfy({ $0.deletingLastPathComponent() == parent && $0 != parent }) else {
            throw CompressionError.mixedDirectories
        }
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: inputs[0].path)
        let isDirectory = firstAttributes[.type] as? FileAttributeType == .typeDirectory
        let sourceName = isDirectory ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        let baseName = inputs.count == 1 ? sourceName : archiveName
        guard !baseName.isEmpty, ![".", ".."].contains(baseName), !baseName.contains("/"), !baseName.contains("\0") else {
            throw CompressionError.invalidName
        }
        let manager = FileManager.default
        // Fail before starting zip: its warnings otherwise permit successful partial archives.
        for input in inputs {
            _ = try manager.attributesOfItem(atPath: input.path)
        }
        let temporaryDirectory = parent.appendingPathComponent(".clickmate-compress-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporaryDirectory) }
        let temporaryArchive = temporaryDirectory.appendingPathComponent("archive.zip")
        let outputLog = temporaryDirectory.appendingPathComponent("command.log")
        progress(Progress(stage: .compressing, currentFile: inputs.count == 1 ? inputs[0] : nil))
        try run(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-r", "-y", "-nw", temporaryArchive.path, "--"] + inputs.map { "./" + $0.lastPathComponent },
            directory: parent, outputLog: outputLog, isCancelled: isCancelled
        )
        progress(Progress(stage: .validating, currentFile: nil))
        try run(
            executable: "/usr/bin/unzip", arguments: ["-t", "-qq", temporaryArchive.path],
            directory: parent, outputLog: outputLog, isCancelled: isCancelled
        )
        progress(Progress(stage: .publishing, currentFile: nil))
        try checkCancellation(isCancelled)
        // The temporary file is on the same volume. Exclusive rename publishes atomically
        // without overwriting existing files or requiring hard-link support (e.g. exFAT).
        var suffix = 1
        while true {
            try checkCancellation(isCancelled)
            let name = suffix == 1 ? "\(baseName).zip" : "\(baseName) \(suffix).zip"
            let destination = parent.appendingPathComponent(name)
            let status = temporaryArchive.withUnsafeFileSystemRepresentation { sourcePath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
                }
            }
            if status == 0 { return destination }
            let failure = errno
            guard failure == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSFilePathErrorKey: destination.path])
            }
            suffix += 1
        }
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func run(
        executable: String, arguments: [String], directory: URL, outputLog: URL,
        isCancelled: () -> Bool
    ) throws {
        try checkCancellation(isCancelled)
        FileManager.default.createFile(atPath: outputLog.path, contents: Data())
        let output = try FileHandle(forWritingTo: outputLog)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        // Environment options must not enable update/move modes or change selected inputs.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZIPOPT")
        environment.removeValue(forKey: "UNZIP")
        environment.removeValue(forKey: "UNZIPOPT")
        process.environment = environment
        try process.run()
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try checkCancellation(isCancelled)
        guard process.terminationStatus == 0 else {
            let log = try? FileHandle(forReadingFrom: outputLog)
            defer { try? log?.close() }
            let data = (try? log?.read(upToCount: 8192)) ?? Data()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CompressionError.commandFailed(process.terminationStatus, message)
        }
    }
}
