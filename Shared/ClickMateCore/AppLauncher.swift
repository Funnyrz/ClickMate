import AppKit
import Foundation

struct PinnedApplicationSyncSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var updatedAt: Date
    var paths: [String]

    init(paths: [String], updatedAt: Date = .now) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.paths = PinnedApplicationPathPolicy.normalizedPaths(paths)
    }
}

enum PinnedApplicationPathPolicy {
    static func sanitizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let sanitizedPath = sanitizedPath(path),
                  seen.insert(sanitizedPath).inserted
            else {
                return nil
            }
            return sanitizedPath
        }
    }

    static func sanitizedPath(_ path: String) -> String? {
        guard (path as NSString).isAbsolutePath else { return nil }
        let applicationURL = URL(fileURLWithPath: path).standardizedFileURL
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }
        return applicationURL.path
    }

    static func normalizedPaths(
        _ paths: [String],
        fileManager: FileManager = .default
    ) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let normalizedPath = normalizedPath(path, fileManager: fileManager),
                  seen.insert(normalizedPath).inserted
            else {
                return nil
            }
            return normalizedPath
        }
    }

    static func normalizedPath(
        _ path: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard let sanitizedPath = sanitizedPath(path) else { return nil }
        let applicationURL = URL(fileURLWithPath: sanitizedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: applicationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              Bundle(url: applicationURL) != nil
        else {
            return nil
        }
        return applicationURL.path
    }
}

enum PinnedApplicationSyncStore {
    static let notificationName = "\(AppConstants.bundleIdentifier).pinnedApplicationsChanged"
    static let pasteboardName = NSPasteboard.Name("\(AppConstants.bundleIdentifier).pinned-applications")
    static let pasteboardType = NSPasteboard.PasteboardType("\(AppConstants.bundleIdentifier).pinned-applications+json")

    static var defaultCacheFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClickMate", isDirectory: true)
            .appendingPathComponent("PinnedApplicationSync.json")
    }

    @discardableResult
    static func publish(
        paths: [String],
        updatedAt: Date = .now,
        pasteboardName: NSPasteboard.Name = pasteboardName
    ) -> Bool {
        let snapshot = PinnedApplicationSyncSnapshot(paths: paths, updatedAt: updatedAt)
        let pasteboard = NSPasteboard(name: pasteboardName)
        if loadPublishedSnapshot(from: pasteboard)?.paths == snapshot.paths {
            return true
        }

        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: pasteboardType) else { return false }
        postNotification()
        return true
    }

    static func synchronizedPaths(
        cacheFileURL: URL = defaultCacheFileURL,
        pasteboardName: NSPasteboard.Name = pasteboardName
    ) -> [String]? {
        let publishedSnapshot = loadPublishedSnapshot(
            from: NSPasteboard(name: pasteboardName)
        )
        let cachedSnapshot = loadCachedSnapshot(from: cacheFileURL)
        let latestSnapshot: PinnedApplicationSyncSnapshot?
        if let publishedSnapshot {
            if let cachedSnapshot,
               cachedSnapshot.updatedAt > publishedSnapshot.updatedAt {
                latestSnapshot = cachedSnapshot
            } else {
                latestSnapshot = publishedSnapshot
            }
        } else {
            latestSnapshot = cachedSnapshot
        }

        guard let latestSnapshot else { return nil }
        if publishedSnapshot == latestSnapshot,
           cachedSnapshot != latestSnapshot {
            writeCache(latestSnapshot, to: cacheFileURL)
        }
        return latestSnapshot.paths
    }

    private static func loadPublishedSnapshot(
        from pasteboard: NSPasteboard
    ) -> PinnedApplicationSyncSnapshot? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return decodeValidatedSnapshot(from: data)
    }

    private static func loadCachedSnapshot(
        from fileURL: URL
    ) -> PinnedApplicationSyncSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return decodeValidatedSnapshot(from: data)
    }

    private static func decodeValidatedSnapshot(
        from data: Data
    ) -> PinnedApplicationSyncSnapshot? {
        guard var snapshot = try? JSONDecoder().decode(PinnedApplicationSyncSnapshot.self, from: data),
              snapshot.version == PinnedApplicationSyncSnapshot.currentVersion
        else {
            return nil
        }
        snapshot.paths = PinnedApplicationPathPolicy.sanitizedPaths(snapshot.paths)
        return snapshot
    }

    private static func writeCache(
        _ snapshot: PinnedApplicationSyncSnapshot,
        to fileURL: URL
    ) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Could not cache pinned applications: \(error.localizedDescription)")
        }
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

struct ApplicationOpenRoute: Equatable {
    static let host = "openApplication"

    var command: MenuCommand?
    var applicationPath: String?
    var urls: [URL]

    static func url(command: MenuCommand, urls: [URL]) -> URL? {
        routeURL(
            queryItems: [URLQueryItem(name: "command", value: command.rawValue)],
            urls: urls
        )
    }

    static func url(pinnedApplicationPath: String, urls: [URL]) -> URL? {
        guard let applicationPath = PinnedApplicationPathPolicy.sanitizedPath(pinnedApplicationPath) else {
            return nil
        }
        return routeURL(
            queryItems: [URLQueryItem(name: "applicationPath", value: applicationPath)],
            urls: urls
        )
    }

    init?(url: URL) {
        guard url.scheme == AppConstants.urlScheme,
              url.host == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let queryItems = components.queryItems ?? []
        let command = queryItems
            .first { $0.name == "command" }?
            .value
            .flatMap(MenuCommand.init(rawValue:))
        let applicationPath = queryItems
            .first { $0.name == "applicationPath" }?
            .value
            .flatMap(PinnedApplicationPathPolicy.sanitizedPath)
        guard (command == nil) != (applicationPath == nil) else { return nil }

        let urls = queryItems
            .filter { $0.name == "url" }
            .compactMap(\.value)
            .compactMap(URL.init(string:))
            .filter(\.isFileURL)
        guard !urls.isEmpty else { return nil }

        self.command = command
        self.applicationPath = applicationPath
        self.urls = urls
    }

    static func isAuthorizedPinnedApplication(
        path: String,
        pinnedApplicationPaths: [String]
    ) -> Bool {
        guard let normalizedPath = PinnedApplicationPathPolicy.normalizedPath(path) else {
            return false
        }
        return PinnedApplicationPathPolicy.normalizedPaths(pinnedApplicationPaths)
            .contains(normalizedPath)
    }

    private static func routeURL(
        queryItems: [URLQueryItem],
        urls: [URL]
    ) -> URL? {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return nil }
        var components = URLComponents()
        components.scheme = AppConstants.urlScheme
        components.host = host
        components.queryItems = queryItems + urls.map {
            URLQueryItem(name: "url", value: $0.absoluteString)
        }
        return components.url
    }
}

enum FinderActionRoute: Equatable {
    private enum Host {
        static let createFile = "createFile"
        static let copyHash = "copyHash"
        static let openHere = "openHere"
        static let compress = "compress"
        static let toggleHiddenFiles = "toggleHiddenFiles"
    }

    case createFile(templateID: String, directory: URL)
    case copyHash(algorithm: HashAlgorithm, urls: [URL])
    case openHere(command: MenuCommand, directory: URL)
    case compress(urls: [URL])
    case toggleHiddenFiles

    var url: URL? {
        switch self {
        case .createFile(let templateID, let directory):
            guard !templateID.isEmpty else { return nil }
            return Self.routeURL(
                host: Host.createFile,
                queryItems: [URLQueryItem(name: "template", value: templateID)],
                urls: [directory]
            )
        case .copyHash(let algorithm, let urls):
            return Self.routeURL(
                host: Host.copyHash,
                queryItems: [URLQueryItem(name: "algorithm", value: algorithm.rawValue)],
                urls: urls
            )
        case .openHere(let command, let directory):
            guard Self.isAllowedOpenHereCommand(command) else { return nil }
            return Self.routeURL(
                host: Host.openHere,
                queryItems: [URLQueryItem(name: "command", value: command.rawValue)],
                urls: [directory]
            )
        case .compress(let urls):
            return Self.routeURL(host: Host.compress, queryItems: [], urls: urls)
        case .toggleHiddenFiles:
            return Self.routeURL(host: Host.toggleHiddenFiles, queryItems: [], urls: [])
        }
    }

    var pendingCommand: PendingCommand {
        switch self {
        case .createFile(let templateID, let directory):
            PendingCommand.createFile(templateID: templateID, directoryURL: directory)
        case .copyHash(let algorithm, let urls):
            PendingCommand.copyHash(algorithm: algorithm, urls: urls)
        case .openHere(let command, let directory):
            PendingCommand.openHere(command: command, directoryURL: directory)
        case .compress(let urls):
            PendingCommand.compress(urls: urls)
        case .toggleHiddenFiles:
            PendingCommand.toggleHiddenFiles()
        }
    }

    init?(url: URL) {
        guard url.scheme == AppConstants.urlScheme,
              let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let queryItems = components.queryItems ?? []

        switch host {
        case Host.createFile:
            guard let templateID = Self.singleValue(named: "template", in: queryItems),
                  !templateID.isEmpty,
                  let directory = Self.fileURLs(in: queryItems, expectedCount: 1)?.first
            else {
                return nil
            }
            self = .createFile(templateID: templateID, directory: directory)
        case Host.copyHash:
            guard let algorithmValue = Self.singleValue(named: "algorithm", in: queryItems),
                  let algorithm = HashAlgorithm(rawValue: algorithmValue),
                  let urls = Self.fileURLs(in: queryItems),
                  !urls.isEmpty
            else {
                return nil
            }
            self = .copyHash(algorithm: algorithm, urls: urls)
        case Host.openHere:
            guard let commandValue = Self.singleValue(named: "command", in: queryItems),
                  let command = MenuCommand(rawValue: commandValue),
                  Self.isAllowedOpenHereCommand(command),
                  let directory = Self.fileURLs(in: queryItems, expectedCount: 1)?.first
            else {
                return nil
            }
            self = .openHere(command: command, directory: directory)
        case Host.compress:
            guard let urls = Self.fileURLs(in: queryItems), !urls.isEmpty else { return nil }
            self = .compress(urls: urls)
        case Host.toggleHiddenFiles:
            guard queryItems.isEmpty else { return nil }
            self = .toggleHiddenFiles
        default:
            return nil
        }
    }

    private static func routeURL(
        host: String,
        queryItems: [URLQueryItem],
        urls: [URL]
    ) -> URL? {
        guard urls.allSatisfy(\.isFileURL) else { return nil }
        var components = URLComponents()
        components.scheme = AppConstants.urlScheme
        components.host = host
        components.queryItems = queryItems + urls.map {
            URLQueryItem(name: "url", value: $0.absoluteString)
        }
        return components.url
    }

    private static func singleValue(named name: String, in queryItems: [URLQueryItem]) -> String? {
        let values = queryItems.filter { $0.name == name }.compactMap(\.value)
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func fileURLs(
        in queryItems: [URLQueryItem],
        expectedCount: Int? = nil
    ) -> [URL]? {
        let values = queryItems.filter { $0.name == "url" }.compactMap(\.value)
        if let expectedCount, values.count != expectedCount {
            return nil
        }
        let urls = values.compactMap(URL.init(string:))
        guard urls.count == values.count, urls.allSatisfy(\.isFileURL) else { return nil }
        return urls
    }

    private static func isAllowedOpenHereCommand(_ command: MenuCommand) -> Bool {
        command == .openTerminal || command == .openITerm
    }
}

enum AppLauncher {
    @discardableResult
    static func openTerminal(at directory: URL) -> Bool {
        let appURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { return false }
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    @discardableResult
    static func openBundle(identifier: String, with urls: [URL]) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    @discardableResult
    static func openPinnedApplication(path: String, with urls: [URL]) -> Bool {
        guard let sanitizedPath = PinnedApplicationPathPolicy.sanitizedPath(path) else { return false }
        let appURL = URL(fileURLWithPath: sanitizedPath)
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    @discardableResult
    static func openHere(command: MenuCommand, directory: URL) -> Bool {
        switch command {
        case .openTerminal:
            openTerminal(at: directory)
        case .openITerm:
            openBundle(identifier: "com.googlecode.iterm2", with: [directory])
        default:
            false
        }
    }

    @discardableResult
    static func openApplication(command: MenuCommand?, applicationPath: String?, urls: [URL]) -> Bool {
        guard let applicationURL = applicationURL(
            command: command,
            applicationPath: applicationPath
        ) else { return false }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }

    static func openApplication(
        command: MenuCommand?,
        applicationPath: String?,
        urls: [URL],
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) {
        guard !urls.isEmpty,
              urls.allSatisfy(\.isFileURL),
              let applicationURL = applicationURL(
                command: command,
                applicationPath: applicationPath
              )
        else {
            completion(false, "Invalid application or file URLs")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { application, error in
            if let error {
                completion(false, error.localizedDescription)
            } else if application == nil {
                completion(false, "LaunchServices returned no running application")
            } else {
                completion(true, nil)
            }
        }
    }

    @discardableResult
    static func requestContainingAppToOpenApplication(
        command: MenuCommand,
        urls: [URL],
        activates: Bool = false
    ) -> Bool {
        guard let url = ApplicationOpenRoute.url(command: command, urls: urls) else {
            return false
        }
        return openContainingApp(url: url, activates: activates)
    }

    @discardableResult
    static func requestContainingAppToOpenPinnedApplication(
        path: String,
        urls: [URL],
        activates: Bool = false
    ) -> Bool {
        guard let url = ApplicationOpenRoute.url(pinnedApplicationPath: path, urls: urls) else {
            return false
        }
        return openContainingApp(url: url, activates: activates)
    }

    @discardableResult
    static func requestContainingAppToPerform(
        _ action: FinderActionRoute,
        activates: Bool = false
    ) -> Bool {
        guard let url = action.url else { return false }
        return openContainingApp(url: url, activates: activates)
    }

    @discardableResult
    static func openContainingApp(
        action: String,
        urls: [URL],
        queryItems: [URLQueryItem] = [],
        activates: Bool = true
    ) -> Bool {
        var components = URLComponents()
        components.scheme = AppConstants.urlScheme
        components.host = action
        components.queryItems = queryItems + urls.map { URLQueryItem(name: "url", value: $0.absoluteString) }
        guard let url = components.url else { return false }
        return openContainingApp(url: url, activates: activates)
    }

    private static func openContainingApp(url: URL, activates: Bool) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.open(url, configuration: configuration)
        return true
    }

    private static func applicationURL(
        command: MenuCommand?,
        applicationPath: String?
    ) -> URL? {
        if let applicationPath,
           let sanitizedPath = PinnedApplicationPathPolicy.sanitizedPath(applicationPath) {
            return URL(fileURLWithPath: sanitizedPath)
        }

        guard let bundleIdentifier = command?.applicationBundleIdentifier else {
            return nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
