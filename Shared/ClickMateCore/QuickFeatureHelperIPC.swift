import Foundation

enum QuickFeatureHelperLaunchMode: String, Codable, Equatable {
    case managedLoginItem
    case directSession
}

enum QuickFeatureHelperLaunchModeResolver {
    static func resolve(
        mainTeamIdentifier: String?,
        helperTeamIdentifier: String?,
        mainSignatureIsValid: Bool,
        helperSignatureIsValid: Bool,
        isInstalledInApplications: Bool
    ) -> QuickFeatureHelperLaunchMode {
        guard isInstalledInApplications else {
            return .directSession
        }
        guard mainSignatureIsValid,
              helperSignatureIsValid,
              let mainTeamIdentifier,
              !mainTeamIdentifier.isEmpty,
              mainTeamIdentifier == helperTeamIdentifier
        else {
            return .directSession
        }
        return .managedLoginItem
    }
}

enum QuickFeatureHelperPolicy {
    static func shouldRun(preferences: ClickMatePreferences) -> Bool {
        preferences.backgroundServiceEnabled
            && preferences.quickFeatureSettings.contains(where: \.isEnabled)
    }
}

enum QuickFeatureHelperVersion {
    static func identifier(for bundle: Bundle) -> String {
        identifier(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func identifier(shortVersion: String?, buildVersion: String?) -> String {
        switch (shortVersion, buildVersion) {
        case let (shortVersion?, buildVersion?):
            return "\(shortVersion) (\(buildVersion))"
        case let (shortVersion?, nil):
            return shortVersion
        case let (nil, buildVersion?):
            return buildVersion
        case (nil, nil):
            return "0"
        }
    }
}

struct QuickFeatureHelperCommand: Codable, Equatable, Hashable, Identifiable {
    enum Action: Codable, Equatable, Hashable {
        case requestAccessibility
        case requestScreenRecording
        case refreshStatus
        case beginShortcutRecording(sessionID: UUID)
        case endShortcutRecording(sessionID: UUID)
        case restart
        case shutdown

        private enum CodingKeys: String, CodingKey {
            case kind
            case sessionID
        }

        private enum Kind: String, Codable {
            case requestAccessibility
            case requestScreenRecording
            case refreshStatus
            case beginShortcutRecording
            case endShortcutRecording
            case restart
            case shutdown
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .requestAccessibility:
                self = .requestAccessibility
            case .requestScreenRecording:
                self = .requestScreenRecording
            case .refreshStatus:
                self = .refreshStatus
            case .beginShortcutRecording:
                self = .beginShortcutRecording(
                    sessionID: try container.decode(UUID.self, forKey: .sessionID)
                )
            case .endShortcutRecording:
                self = .endShortcutRecording(
                    sessionID: try container.decode(UUID.self, forKey: .sessionID)
                )
            case .restart:
                self = .restart
            case .shutdown:
                self = .shutdown
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .requestAccessibility:
                try container.encode(Kind.requestAccessibility, forKey: .kind)
            case .requestScreenRecording:
                try container.encode(Kind.requestScreenRecording, forKey: .kind)
            case .refreshStatus:
                try container.encode(Kind.refreshStatus, forKey: .kind)
            case let .beginShortcutRecording(sessionID):
                try container.encode(Kind.beginShortcutRecording, forKey: .kind)
                try container.encode(sessionID, forKey: .sessionID)
            case let .endShortcutRecording(sessionID):
                try container.encode(Kind.endShortcutRecording, forKey: .kind)
                try container.encode(sessionID, forKey: .sessionID)
            case .restart:
                try container.encode(Kind.restart, forKey: .kind)
            case .shutdown:
                try container.encode(Kind.shutdown, forKey: .kind)
            }
        }

        var shortcutRecordingSessionID: UUID? {
            switch self {
            case let .beginShortcutRecording(sessionID), let .endShortcutRecording(sessionID):
                return sessionID
            default:
                return nil
            }
        }
    }

    static let shortcutRecordingSessionTimeout: TimeInterval = 30

    var id: UUID
    var action: Action
    var enqueuedAt: Date
    var recordingSessionExpiresAt: Date?

    init(
        id: UUID = UUID(),
        action: Action,
        enqueuedAt: Date = .now,
        recordingSessionExpiresAt: Date? = nil
    ) {
        self.id = id
        self.action = action
        self.enqueuedAt = enqueuedAt
        self.recordingSessionExpiresAt = recordingSessionExpiresAt
            ?? action.shortcutRecordingSessionID.map { _ in
                enqueuedAt.addingTimeInterval(Self.shortcutRecordingSessionTimeout)
            }
    }

    var shortcutRecordingSessionID: UUID? {
        action.shortcutRecordingSessionID
    }

    func isShortcutRecordingSessionExpired(referenceDate: Date = .now) -> Bool {
        guard let recordingSessionExpiresAt else {
            return false
        }
        return referenceDate > recordingSessionExpiresAt
    }
}

struct QuickFeatureRuntimePermissions: Codable, Equatable {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool

    init(accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
    }
}

enum QuickFeatureRuntimePermissionKind: String, Codable, Equatable {
    case accessibility
    case screenRecording
}

struct QuickFeaturePermissionRequestDiagnostic: Codable, Equatable {
    var commandID: UUID
    var kind: QuickFeatureRuntimePermissionKind
    var requestedAt: Date
    var completedAt: Date
    var requestReturnedGranted: Bool
    var observedPermissionGranted: Bool
    var processBundleIdentifier: String?
}

struct QuickFeatureRuntimeSnapshot: Codable, Equatable {
    static let staleTimeout: TimeInterval = 5

    var pid: Int32
    var version: String
    var updatedAt: Date
    var permissions: QuickFeatureRuntimePermissions
    var activeFeatures: Set<QuickFeatureID>
    var failedFeatures: Set<QuickFeatureID>
    var error: String?
    var lastProcessedCommandID: UUID?
    var lastPermissionRequest: QuickFeaturePermissionRequestDiagnostic?

    init(
        pid: Int32,
        version: String,
        updatedAt: Date = .now,
        permissions: QuickFeatureRuntimePermissions,
        activeFeatures: Set<QuickFeatureID> = [],
        failedFeatures: Set<QuickFeatureID> = [],
        error: String? = nil,
        lastProcessedCommandID: UUID? = nil,
        lastPermissionRequest: QuickFeaturePermissionRequestDiagnostic? = nil
    ) {
        self.pid = pid
        self.version = version
        self.updatedAt = updatedAt
        self.permissions = permissions
        self.activeFeatures = activeFeatures
        self.failedFeatures = failedFeatures
        self.error = error
        self.lastProcessedCommandID = lastProcessedCommandID
        self.lastPermissionRequest = lastPermissionRequest
    }

    func isStale(
        referenceDate: Date = .now,
        timeout: TimeInterval = Self.staleTimeout
    ) -> Bool {
        referenceDate.timeIntervalSince(updatedAt) > timeout
    }
}

struct QuickFeatureHelperCommandQueue {
    static let notificationName = "\(AppConstants.bundleIdentifier).quickFeatureHelperCommandsChanged"

    private let storage: QuickFeatureHelperIPCStorage

    init(storageDirectoryURL: URL? = nil) {
        storage = QuickFeatureHelperIPCStorage(
            directoryURL: storageDirectoryURL ?? Self.defaultStorageDirectoryURL
        )
    }

    @discardableResult
    static func enqueue(_ action: QuickFeatureHelperCommand.Action) -> Bool {
        Self().enqueue(action)
    }

    static func enqueueCommand(_ action: QuickFeatureHelperCommand.Action) -> QuickFeatureHelperCommand? {
        Self().enqueueCommand(action)
    }

    static func consumePending() -> [QuickFeatureHelperCommand] {
        Self().consumePending()
    }

    @discardableResult
    func enqueue(
        _ action: QuickFeatureHelperCommand.Action,
        enqueuedAt: Date = .now
    ) -> Bool {
        let command = QuickFeatureHelperCommand(action: action, enqueuedAt: enqueuedAt)
        do {
            let commands = try loadPendingCommands()
            guard !commands.contains(where: { $0.action == action }) else {
                return false
            }
            try storage.write(command, to: commandFileURL(for: command.id))
            Self.postNotification()
            return true
        } catch {
            assertionFailure("Could not enqueue quick feature helper command: \(error.localizedDescription)")
            return false
        }
    }

    func enqueueCommand(
        _ action: QuickFeatureHelperCommand.Action,
        enqueuedAt: Date = .now
    ) -> QuickFeatureHelperCommand? {
        let command = QuickFeatureHelperCommand(action: action, enqueuedAt: enqueuedAt)

        do {
            let commands = try loadPendingCommands()
            if let existingCommand = commands.first(where: { $0.action == action }) {
                return existingCommand
            }
            try storage.write(command, to: commandFileURL(for: command.id))
            Self.postNotification()
            return command
        } catch {
            assertionFailure("Could not enqueue quick feature helper command: \(error.localizedDescription)")
            return nil
        }
    }

    func consumePending() -> [QuickFeatureHelperCommand] {
        do {
            let commands = try loadPendingCommands()
            try storage.removeItemIfPresent(at: legacyQueueFileURL)
            for fileURL in try commandFileURLs() {
                try storage.removeItemIfPresent(at: fileURL)
            }
            return commands
        } catch {
            assertionFailure("Could not consume quick feature helper commands: \(error.localizedDescription)")
            return []
        }
    }

    private static var defaultStorageDirectoryURL: URL {
        QuickFeatureHelperIPCStorage.defaultDirectoryURL
    }

    private var legacyQueueFileURL: URL {
        storage.directoryURL.appendingPathComponent("commands.json")
    }

    private var commandsDirectoryURL: URL {
        storage.directoryURL.appendingPathComponent("commands", isDirectory: true)
    }

    private func commandFileURL(for id: UUID) -> URL {
        let sequence = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
        return commandsDirectoryURL.appendingPathComponent("\(sequence)-\(id.uuidString).json")
    }

    private func loadPendingCommands() throws -> [QuickFeatureHelperCommand] {
        var commands = try storage.load(
            [QuickFeatureHelperCommand].self,
            from: legacyQueueFileURL
        ) ?? []
        for fileURL in try commandFileURLs() {
            if let command = try storage.load(QuickFeatureHelperCommand.self, from: fileURL) {
                commands.append(command)
            }
        }
        var seenIDs = Set<UUID>()
        return commands.filter { seenIDs.insert($0.id).inserted }
    }

    private func commandFileURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: commandsDirectoryURL.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: commandsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func postNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

struct QuickFeatureRuntimeSnapshotStore {
    static let notificationName = "\(AppConstants.bundleIdentifier).quickFeatureHelperRuntimeSnapshotChanged"

    private let storage: QuickFeatureHelperIPCStorage

    init(storageDirectoryURL: URL? = nil) {
        storage = QuickFeatureHelperIPCStorage(
            directoryURL: storageDirectoryURL ?? Self.defaultStorageDirectoryURL
        )
    }

    static func load() -> QuickFeatureRuntimeSnapshot? {
        Self().load()
    }

    @discardableResult
    static func write(_ snapshot: QuickFeatureRuntimeSnapshot) -> Bool {
        Self().write(snapshot)
    }

    static func remove() {
        Self().remove()
    }

    func load() -> QuickFeatureRuntimeSnapshot? {
        do {
            return try storage.load(QuickFeatureRuntimeSnapshot.self, from: snapshotFileURL)
        } catch {
            assertionFailure("Could not load quick feature runtime snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func write(_ snapshot: QuickFeatureRuntimeSnapshot) -> Bool {
        do {
            try storage.write(snapshot, to: snapshotFileURL)
            Self.postNotification()
            return true
        } catch {
            assertionFailure("Could not write quick feature runtime snapshot: \(error.localizedDescription)")
            return false
        }
    }

    func remove() {
        do {
            try storage.removeItemIfPresent(at: snapshotFileURL)
            Self.postNotification()
        } catch {
            assertionFailure("Could not remove quick feature runtime snapshot: \(error.localizedDescription)")
        }
    }

    private static var defaultStorageDirectoryURL: URL {
        QuickFeatureHelperIPCStorage.defaultDirectoryURL
    }

    private var snapshotFileURL: URL {
        storage.directoryURL.appendingPathComponent("runtime-snapshot.json")
    }

    private static func postNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

struct QuickFeatureHelperConfiguration: Codable, Equatable {
    var language: AppLanguage
    var quickFeatureSettings: [QuickFeatureSettings]

    init(language: AppLanguage, quickFeatureSettings: [QuickFeatureSettings]) {
        self.language = language
        self.quickFeatureSettings = QuickFeatureSettings.normalized(quickFeatureSettings)
    }

    init(preferences: ClickMatePreferences) {
        self.init(
            language: preferences.language,
            quickFeatureSettings: preferences.quickFeatureSettings
        )
    }

    static var defaults: QuickFeatureHelperConfiguration {
        QuickFeatureHelperConfiguration(preferences: .defaults)
    }
}

struct QuickFeatureHelperConfigurationStore {
    static let notificationName = "\(AppConstants.bundleIdentifier).quickFeatureHelperConfigurationChanged"

    private let storage: QuickFeatureHelperIPCStorage

    init(storageDirectoryURL: URL? = nil) {
        storage = QuickFeatureHelperIPCStorage(
            directoryURL: storageDirectoryURL ?? QuickFeatureHelperIPCStorage.defaultDirectoryURL
        )
    }

    static var fileURL: URL {
        Self().configurationFileURL
    }

    static func load() -> QuickFeatureHelperConfiguration? {
        Self().load()
    }

    @discardableResult
    static func write(_ preferences: ClickMatePreferences) -> Bool {
        Self().write(QuickFeatureHelperConfiguration(preferences: preferences))
    }

    func load() -> QuickFeatureHelperConfiguration? {
        do {
            return try storage.load(QuickFeatureHelperConfiguration.self, from: configurationFileURL)
        } catch {
            if let legacyPreferences = try? storage.load(
                ClickMatePreferences.self,
                from: configurationFileURL
            ) {
                return QuickFeatureHelperConfiguration(preferences: legacyPreferences)
            }
            assertionFailure("Could not load quick feature helper configuration: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func write(_ configuration: QuickFeatureHelperConfiguration) -> Bool {
        do {
            let existingConfiguration = try? storage.load(
                QuickFeatureHelperConfiguration.self,
                from: configurationFileURL
            )
            if existingConfiguration == configuration {
                return true
            }
            try storage.write(configuration, to: configurationFileURL)
            Self.postNotification()
            return true
        } catch {
            assertionFailure("Could not write quick feature helper configuration: \(error.localizedDescription)")
            return false
        }
    }

    private var configurationFileURL: URL {
        storage.directoryURL.appendingPathComponent("helper-preferences.json")
    }

    private static func postNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

private struct QuickFeatureHelperIPCStorage {
    let directoryURL: URL

    static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClickMate", isDirectory: true)
            .appendingPathComponent("QuickFeatureHelperIPC", isDirectory: true)
    }

    func load<Value: Decodable>(_ type: Value.Type, from fileURL: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
    }

    func write<Value: Encodable>(_ value: Value, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
    }

    func removeItemIfPresent(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

}
