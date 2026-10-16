import Darwin
import Foundation

enum FeatureGuideFeature: String, CaseIterable, Identifiable, Hashable {
    case finderTools, finderCut, screenshot
    var id: Self { self }

    var quickFeatureID: QuickFeatureID? {
        switch self {
        case .finderTools: nil
        case .finderCut: .finderCut
        case .screenshot: .screenshot
        }
    }

    static func selectedFeatures(in preferences: ClickMatePreferences) -> Set<Self> {
        var selected: Set<Self> = preferences.finderToolsEnabled ? [.finderTools] : []
        for feature in allCases {
            if let id = feature.quickFeatureID, preferences.quickFeatureSettings(for: id).isEnabled {
                selected.insert(feature)
            }
        }
        return selected
    }
}

enum FeatureReadiness: String, Equatable {
    case available, needsPermission, restartRequired, failed
}

enum FeatureTrialState: String, Equatable {
    case notTested, instructions, awaitingConfirmation, passed, failed, cancelled
}

/// Uses reported runtime state only. Readiness does not imply a trial succeeded.
struct FeatureReadinessSnapshot {
    var finderStatus: FinderExtensionStatus = .unknown
    var finderNeedsRestart = false
    var finderAccess: FinderExtensionAccessResult?
    var backgroundServiceEnabled = false
    var helperRunning = false
    var helperFailed = false
    var accessibility: QuickFeaturePermissionState = .unknown
    var screenRecording: QuickFeaturePermissionState = .unknown
    var activeFeatures: Set<QuickFeatureID> = []
    var failedFeatures: Set<QuickFeatureID> = []

    func status(for feature: FeatureGuideFeature) -> FeatureReadiness {
        if feature == .finderTools {
            if finderAccess == .failed { return .failed }
            if finderNeedsRestart { return .restartRequired }
            if finderAccess == .permissionDenied { return .needsPermission }
            return finderStatus == .enabled ? .available : .needsPermission
        }
        guard let id = feature.quickFeatureID else { return .failed }
        if failedFeatures.contains(id) || helperFailed { return .failed }
        let permission = feature == .finderCut ? accessibility : screenRecording
        if permission == .failed { return .failed }
        if permission == .restartRequired { return .restartRequired }
        guard backgroundServiceEnabled, helperRunning, permission == .granted else { return .needsPermission }
        return activeFeatures.contains(id) ? .available : .restartRequired
    }
}

/// Only the unchanged test file is disposable. Unexpected files keep the trial folder alive.
struct FeatureTrialFiles {
    let directoryURL: URL
    let sourceURL: URL
    let destinationDirectory: URL
    var destinationURL: URL { destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent) }
    private let directoryIdentity: Identity
    private let destinationIdentity: Identity
    private let fileIdentity: Identity
    private static let contents = Data("ClickMate Finder cut trial\n".utf8)

    private struct Identity {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
        func matches(_ info: stat) -> Bool { device == info.st_dev && inode == info.st_ino }
    }

    static func create(in parent: URL = FileManager.default.temporaryDirectory) throws -> Self {
        let directory = parent.appendingPathComponent("ClickMate-Trial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("Destination", isDirectory: true)
        let source = directory.appendingPathComponent("ClickMate-Test.txt")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try contents.write(to: source, options: .withoutOverwriting)
            return try Self(
                directoryURL: directory, sourceURL: source, destinationDirectory: destination,
                directoryIdentity: identity(at: directory), destinationIdentity: identity(at: destination),
                fileIdentity: identity(at: source)
            )
        } catch {
            // Even failed setup must not recursively delete unexpected files.
            _ = destination.path.withCString { Darwin.rmdir($0) }
            _ = directory.path.withCString { Darwin.rmdir($0) }
            throw error
        }
    }

    var hasCompletedMove: Bool {
        guard let root = openDirectory(directoryURL, identity: directoryIdentity) else { return false }
        defer { Darwin.close(root) }
        var sourceInfo = stat()
        guard fstatat(root, sourceURL.lastPathComponent, &sourceInfo, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              let destination = openDestination(in: root)
        else { return false }
        defer { Darwin.close(destination) }
        return unchangedOwnedFile(in: destination, name: sourceURL.lastPathComponent)
    }

    /// Returns the retained location when user files, modifications, or access errors prevent cleanup.
    @discardableResult
    func cleanup() -> URL? {
        guard let root = openDirectory(directoryURL, identity: directoryIdentity) else {
            var info = stat()
            return lstat(directoryURL.path, &info) == 0 || errno != ENOENT ? directoryURL : nil
        }
        defer { Darwin.close(root) }
        removeOwnedFile(in: root)
        if let destination = openDestination(in: root) {
            removeOwnedFile(in: destination)
            Darwin.close(destination)
            _ = unlinkat(root, destinationDirectory.lastPathComponent, AT_REMOVEDIR)
        }
        // rmdir refuses nonempty folders; it cannot erase unrecognized or modified files.
        var info = stat()
        guard lstat(directoryURL.path, &info) == 0, directoryIdentity.matches(info),
              Darwin.rmdir(directoryURL.path) == 0 else { return directoryURL }
        return nil
    }

    private func removeOwnedFile(in directory: Int32) {
        let name = sourceURL.lastPathComponent
        guard unchangedOwnedFile(in: directory, name: name) else { return }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              fileIdentity.matches(info), info.st_mode & S_IFMT == S_IFREG,
              info.st_size == Self.contents.count else { return }
        _ = unlinkat(directory, name, 0)
    }

    private func unchangedOwnedFile(in directory: Int32, name: String) -> Bool {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { return false }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, fileIdentity.matches(before),
              before.st_mode & S_IFMT == S_IFREG, before.st_size == Self.contents.count
        else { return false }
        // The owned sample is tiny. Never read an arbitrary replacement or oversized file.
        var data = Data(count: Self.contents.count + 1)
        let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
        guard count == Self.contents.count else { return false }
        data.count = count
        var after = stat()
        return data == Self.contents && fstat(file, &after) == 0 && fileIdentity.matches(after)
            && after.st_size == before.st_size
            && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    }

    private func openDestination(in root: Int32) -> Int32? {
        let directory = openat(root, destinationDirectory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return nil }
        var info = stat()
        guard fstat(directory, &info) == 0, destinationIdentity.matches(info) else {
            Darwin.close(directory)
            return nil
        }
        return directory
    }

    private func openDirectory(_ url: URL, identity: Identity) -> Int32? {
        let directory = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { return nil }
        var info = stat()
        guard fstat(directory, &info) == 0, identity.matches(info) else {
            Darwin.close(directory)
            return nil
        }
        return directory
    }

    private static func identity(at url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return Identity(info)
    }
}
