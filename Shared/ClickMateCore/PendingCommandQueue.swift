import Darwin
import Foundation

struct PendingCommand: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case createFile
        case copyHash
        case openHere
        case openApplication
        case compress
        case toggleHiddenFiles
    }

    var id: UUID
    var kind: Kind
    var templateID: String?
    var directoryURL: URL?
    var urls: [URL]
    var hashAlgorithm: HashAlgorithm?
    var menuCommand: MenuCommand?
    var applicationPath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case templateID
        case directoryURL
        case urls
        case hashAlgorithm
        case menuCommand
        case applicationPath
    }

    init(
        id: UUID,
        kind: Kind,
        templateID: String?,
        directoryURL: URL?,
        urls: [URL],
        hashAlgorithm: HashAlgorithm?,
        menuCommand: MenuCommand?,
        applicationPath: String?
    ) {
        self.id = id
        self.kind = kind
        self.templateID = templateID
        self.directoryURL = directoryURL
        self.urls = urls
        self.hashAlgorithm = hashAlgorithm
        self.menuCommand = menuCommand
        self.applicationPath = applicationPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        directoryURL = try container.decodeIfPresent(URL.self, forKey: .directoryURL)
        urls = try container.decodeIfPresent([URL].self, forKey: .urls) ?? []
        hashAlgorithm = try container.decodeIfPresent(HashAlgorithm.self, forKey: .hashAlgorithm)
        menuCommand = try container.decodeIfPresent(MenuCommand.self, forKey: .menuCommand)
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath)
    }

    static func createFile(templateID: String, directoryURL: URL) -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .createFile,
            templateID: templateID,
            directoryURL: directoryURL,
            urls: [],
            hashAlgorithm: nil,
            menuCommand: nil,
            applicationPath: nil
        )
    }

    static func copyHash(algorithm: HashAlgorithm, urls: [URL]) -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .copyHash,
            templateID: nil,
            directoryURL: nil,
            urls: urls,
            hashAlgorithm: algorithm,
            menuCommand: nil,
            applicationPath: nil
        )
    }

    static func openHere(command: MenuCommand, directoryURL: URL) -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .openHere,
            templateID: nil,
            directoryURL: directoryURL,
            urls: [],
            hashAlgorithm: nil,
            menuCommand: command,
            applicationPath: nil
        )
    }

    static func openApplication(command: MenuCommand, urls: [URL]) -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .openApplication,
            templateID: nil,
            directoryURL: nil,
            urls: urls,
            hashAlgorithm: nil,
            menuCommand: command,
            applicationPath: nil
        )
    }

    static func openPinnedApplication(path: String, urls: [URL]) -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .openApplication,
            templateID: nil,
            directoryURL: nil,
            urls: urls,
            hashAlgorithm: nil,
            menuCommand: nil,
            applicationPath: path
        )
    }

    static func compress(urls: [URL]) -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .compress,
            templateID: nil,
            directoryURL: nil,
            urls: urls,
            hashAlgorithm: nil,
            menuCommand: nil,
            applicationPath: nil
        )
    }

    static func toggleHiddenFiles() -> PendingCommand {
        PendingCommand(
            id: UUID(),
            kind: .toggleHiddenFiles,
            templateID: nil,
            directoryURL: nil,
            urls: [],
            hashAlgorithm: nil,
            menuCommand: nil,
            applicationPath: nil
        )
    }
}

enum PendingCommandQueue {
    static let notificationName = "\(AppConstants.bundleIdentifier).pendingCommandsChanged"

    private static var queueDirectoryURL: URL {
        let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)
        let baseURL = containerURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClickMate", isDirectory: true)
        return baseURL.appendingPathComponent("PendingCommands", isDirectory: true)
    }

    static func enqueue(_ command: PendingCommand) {
        save(command)
        postNotification()
    }

    static func drain() -> [PendingCommand] {
        let fileManager = FileManager.default
        let commands = pendingCommandFileURLs()
            .compactMap { url -> PendingCommand? in
                guard let data = try? Data(contentsOf: url),
                      let command = try? JSONDecoder().decode(PendingCommand.self, from: data)
                else {
                    return nil
                }
                try? fileManager.removeItem(at: url)
                return command
            }
        return commands
    }

    static func hasPendingCommands() -> Bool {
        pendingCommandFileURLs().contains { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return (try? JSONDecoder().decode(PendingCommand.self, from: data)) != nil
        }
    }

    private static func save(_ command: PendingCommand) {
        do {
            try FileManager.default.createDirectory(
                at: queueDirectoryURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(command)
            let fileURL = queueDirectoryURL.appendingPathComponent("\(command.id.uuidString).json")
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Could not save pending ClickMate commands: \(error.localizedDescription)")
        }
    }

    private static func pendingCommandFileURLs() -> [URL] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: queueDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return fileURLs
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
