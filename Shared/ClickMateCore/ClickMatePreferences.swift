import Darwin
import Foundation

enum MonitoringMode: String, Codable, Equatable {
    case wideCoverage
}

struct ClickMatePreferences: Codable, Equatable {
    var enabledCommands: Set<MenuCommand>
    var menuCommandOrder: [MenuCommand]
    var foldedMenuGroups: Set<MenuCommandGroup>
    var templates: [FileTemplate]
    var monitoringMode: MonitoringMode
    var monitoredFolderPaths: [String]
    var monitoredFolderBookmarks: [String: Data]
    var detectedApplicationOrder: [String]
    var pinnedApplicationPaths: [String]
    var language: AppLanguage
    var hasDismissedPermissionGuide: Bool
    var menuLayoutDefaultsVersion: Int

    init(
        enabledCommands: Set<MenuCommand>,
        menuCommandOrder: [MenuCommand] = MenuCommand.allCases,
        foldedMenuGroups: Set<MenuCommandGroup> = MenuCommandGroup.defaultFoldedGroups,
        templates: [FileTemplate],
        monitoringMode: MonitoringMode = .wideCoverage,
        monitoredFolderPaths: [String],
        monitoredFolderBookmarks: [String: Data] = [:],
        detectedApplicationOrder: [String] = AppDetector.defaultApplicationOrder,
        pinnedApplicationPaths: [String],
        language: AppLanguage = .system,
        hasDismissedPermissionGuide: Bool = false,
        menuLayoutDefaultsVersion: Int = Self.currentMenuLayoutDefaultsVersion
    ) {
        self.enabledCommands = enabledCommands
        self.menuCommandOrder = Self.normalizedMenuCommandOrder(menuCommandOrder)
        self.foldedMenuGroups = foldedMenuGroups
        self.templates = templates
        self.monitoringMode = monitoringMode
        self.monitoredFolderPaths = monitoredFolderPaths
        self.monitoredFolderBookmarks = monitoredFolderBookmarks
        self.detectedApplicationOrder = AppDetector.normalizedApplicationOrder(detectedApplicationOrder)
        self.pinnedApplicationPaths = pinnedApplicationPaths
        self.language = language
        self.hasDismissedPermissionGuide = hasDismissedPermissionGuide
        self.menuLayoutDefaultsVersion = menuLayoutDefaultsVersion
    }

    static let currentMenuLayoutDefaultsVersion = 1

    static let defaults = ClickMatePreferences(
        enabledCommands: Set(MenuCommand.allCases),
        menuCommandOrder: MenuCommand.allCases,
        foldedMenuGroups: MenuCommandGroup.defaultFoldedGroups,
        templates: FileTemplate.defaults,
        monitoringMode: .wideCoverage,
        monitoredFolderPaths: [],
        monitoredFolderBookmarks: [:],
        detectedApplicationOrder: AppDetector.defaultApplicationOrder,
        pinnedApplicationPaths: [],
        language: .system,
        hasDismissedPermissionGuide: false,
        menuLayoutDefaultsVersion: currentMenuLayoutDefaultsVersion
    )

    var orderedMenuCommands: [MenuCommand] {
        Self.normalizedMenuCommandOrder(menuCommandOrder)
    }

    var enabledMenuCommandsInCustomOrder: [MenuCommand] {
        orderedMenuCommands.filter { enabledCommands.contains($0) }
    }

    var enabledOpenApplicationCommandsInCustomOrder: [MenuCommand] {
        detectedApplicationOrder
            .compactMap(MenuCommand.openApplicationCommand(forBundleIdentifier:))
            .filter { enabledCommands.contains($0) }
    }

    var orderedVisibleMenuGroups: [MenuCommandGroup] {
        MenuLayoutPolicy.orderedVisibleGroups(for: self)
    }

    var menuGroupPlacement: MenuGroupPlacement {
        MenuLayoutPolicy.placement(for: self)
    }

    static func normalizedMenuCommandOrder(_ commands: [MenuCommand]) -> [MenuCommand] {
        var seen = Set<MenuCommand>()
        var orderedCommands: [MenuCommand] = []

        for command in commands where !seen.contains(command) {
            orderedCommands.append(command)
            seen.insert(command)
        }

        for command in MenuCommand.allCases where !seen.contains(command) {
            orderedCommands.append(command)
        }

        return orderedCommands
    }

    static var defaultMonitoredFolderPaths: [String] {
        MonitoredFolderPolicy.defaultMonitoredFolderPaths()
    }

    private enum CodingKeys: String, CodingKey {
        case enabledCommands
        case menuCommandOrder
        case foldedMenuGroups
        case templates
        case monitoringMode
        case monitoredFolderPaths
        case monitoredFolderBookmarks
        case detectedApplicationOrder
        case pinnedApplicationPaths
        case language
        case hasDismissedPermissionGuide
        case menuLayoutDefaultsVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledCommands = try container.decode(Set<MenuCommand>.self, forKey: .enabledCommands)
        menuCommandOrder = Self.normalizedMenuCommandOrder(
            try container.decodeIfPresent([MenuCommand].self, forKey: .menuCommandOrder) ?? MenuCommand.allCases
        )
        foldedMenuGroups = try container.decodeIfPresent(Set<MenuCommandGroup>.self, forKey: .foldedMenuGroups) ?? MenuCommandGroup.defaultFoldedGroups
        templates = try container.decode([FileTemplate].self, forKey: .templates)
        monitoringMode = try container.decodeIfPresent(MonitoringMode.self, forKey: .monitoringMode) ?? .wideCoverage
        monitoredFolderPaths = try container.decodeIfPresent([String].self, forKey: .monitoredFolderPaths) ?? []
        monitoredFolderBookmarks = try container.decodeIfPresent([String: Data].self, forKey: .monitoredFolderBookmarks) ?? [:]
        detectedApplicationOrder = AppDetector.normalizedApplicationOrder(
            try container.decodeIfPresent([String].self, forKey: .detectedApplicationOrder) ?? AppDetector.defaultApplicationOrder
        )
        pinnedApplicationPaths = try container.decodeIfPresent([String].self, forKey: .pinnedApplicationPaths) ?? []
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        hasDismissedPermissionGuide = try container.decodeIfPresent(Bool.self, forKey: .hasDismissedPermissionGuide) ?? false
        menuLayoutDefaultsVersion = try container.decodeIfPresent(Int.self, forKey: .menuLayoutDefaultsVersion) ?? 0
    }

    mutating func migrateMenuLayoutDefaultsIfNeeded() -> Bool {
        guard menuLayoutDefaultsVersion < Self.currentMenuLayoutDefaultsVersion else {
            return false
        }

        if foldedMenuGroups == Set(MenuCommandGroup.allCases) {
            foldedMenuGroups = MenuCommandGroup.defaultFoldedGroups
        }
        menuLayoutDefaultsVersion = Self.currentMenuLayoutDefaultsVersion
        return true
    }
}

extension MenuCommandGroup {
    static var defaultFoldedGroups: Set<MenuCommandGroup> {
        []
    }
}

struct MenuGroupPlacement: Equatable {
    let topLevelGroups: [MenuCommandGroup]
    let foldedGroups: [MenuCommandGroup]
}

enum MenuLayoutPolicy {
    static func orderedVisibleGroups(for preferences: ClickMatePreferences) -> [MenuCommandGroup] {
        preferences.orderedMenuCommands
            .compactMap(MenuCommandGroup.group(for:))
            .uniqued()
            .filter { group in
                switch group {
                case .openPinned:
                    return false
                case .newFile:
                    return preferences.enabledCommands.contains(.newFile) && !preferences.templates.isEmpty
                default:
                    return group.commands.contains { preferences.enabledCommands.contains($0) }
                }
            }
    }

    static func placement(for preferences: ClickMatePreferences) -> MenuGroupPlacement {
        let groups = orderedVisibleGroups(for: preferences)
        return MenuGroupPlacement(
            topLevelGroups: groups.filter { !preferences.foldedMenuGroups.contains($0) },
            foldedGroups: groups.filter { preferences.foldedMenuGroups.contains($0) }
        )
    }

}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

final class PreferencesStore: ObservableObject {
    private enum Storage {
        static let filename = "ClickMatePreferences.json"
    }

    @Published var preferences: ClickMatePreferences {
        didSet {
            guard !isReloading else { return }
            save(preferences)
        }
    }

    private let fileURL: URL
    private let saveQueue = DispatchQueue(label: "\(AppConstants.bundleIdentifier).preferences.save")
    private var isReloading = false

    init(fileURL: URL = PreferencesStore.sharedPreferencesURL) {
        self.fileURL = fileURL
        Self.migrateFallbackPreferencesIfNeeded(to: fileURL)
        let loaded = Self.loadWithMigration(from: fileURL)
        self.preferences = loaded.preferences
        if !FileManager.default.fileExists(atPath: fileURL.path) || loaded.didMigrate {
            saveSynchronously(preferences)
        }
    }

    func reset() {
        preferences = .defaults
    }

    func reload() {
        isReloading = true
        let loaded = Self.loadWithMigration(from: fileURL)
        preferences = loaded.preferences
        isReloading = false
        if loaded.didMigrate {
            saveSynchronously(preferences)
        }
    }

    func replaceLoadedPreferences(_ loadedPreferences: ClickMatePreferences) {
        isReloading = true
        preferences = loadedPreferences
        isReloading = false
    }

    func waitForPendingSaves() {
        saveQueue.sync {}
    }

    static func loadSnapshot(fileURL: URL = PreferencesStore.sharedPreferencesURL) -> ClickMatePreferences {
        loadWithMigration(from: fileURL).preferences
    }

    static func currentLanguagePreference(fileURL: URL = PreferencesStore.sharedPreferencesURL) -> AppLanguage {
        loadWithMigration(from: fileURL).preferences.language
    }

    private func save(_ preferences: ClickMatePreferences) {
        let fileURL = fileURL
        saveQueue.async {
            Self.write(preferences, to: fileURL)
        }
    }

    private func saveSynchronously(_ preferences: ClickMatePreferences) {
        let fileURL = fileURL
        saveQueue.sync {
            Self.write(preferences, to: fileURL)
        }
    }

    private static func write(_ preferences: ClickMatePreferences, to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            if directoryURL.path != fileURL.path {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            }
            try data.write(to: fileURL, options: .atomic)
            PreferencesChangeNotifier.post()
        } catch {
            assertionFailure("Could not save ClickMate preferences: \(error.localizedDescription)")
        }
    }

    private static func load(from fileURL: URL) -> ClickMatePreferences {
        loadWithMigration(from: fileURL).preferences
    }

    private static func loadWithMigration(from fileURL: URL) -> (preferences: ClickMatePreferences, didMigrate: Bool) {
        guard let data = try? Data(contentsOf: fileURL),
              var preferences = try? JSONDecoder().decode(ClickMatePreferences.self, from: data)
        else {
            return (.defaults, false)
        }
        let didMigrate = preferences.migrateMenuLayoutDefaultsIfNeeded()
        return (preferences, didMigrate)
    }

    private static func migrateFallbackPreferencesIfNeeded(to fileURL: URL) {
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              fileURL != fallbackPreferencesURL,
              FileManager.default.fileExists(atPath: fallbackPreferencesURL.path)
        else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: fallbackPreferencesURL, to: fileURL)
        } catch {
            assertionFailure("Could not migrate ClickMate preferences: \(error.localizedDescription)")
        }
    }

    static var sharedPreferencesURL: URL {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier) {
            return containerURL.appendingPathComponent(Storage.filename)
        }
        return fallbackPreferencesURL
    }

    private static var fallbackPreferencesURL: URL {
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClickMate", isDirectory: true)
            .appendingPathComponent(Storage.filename)
    }
}

enum PreferencesChangeNotifier {
    static let name = "\(AppConstants.bundleIdentifier).preferencesChanged"

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

enum MonitoredFolderPolicy {
    private static let blockedSystemTrees: Set<String> = [
        "/", "/System", "/Library", "/dev", "/Network",
        "/bin", "/sbin", "/usr", "/etc"
    ]
    private static let blockedExactRoots: Set<String> = [
        "/private", "/var", "/tmp"
    ]
    private static let skippedExpandedDirectoryNames: Set<String> = [
        "Library"
    ]

    static func defaultMonitoredFolderPaths(fileManager: FileManager = .default) -> [String] {
        let home = canonicalPath(for: userHomeDirectory(fileManager: fileManager))
        return normalizedUserPaths([
            home,
            URL(fileURLWithPath: home).appendingPathComponent("Desktop").path,
            URL(fileURLWithPath: home).appendingPathComponent("Documents").path,
            URL(fileURLWithPath: home).appendingPathComponent("Downloads").path
        ], fileManager: fileManager)
    }

    static func defaultDirectoryURLsForFinderSyncBootstrap(fileManager: FileManager = .default) -> [URL] {
        let home = userHomeDirectory(fileManager: fileManager).standardizedFileURL
        return [
            home,
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true)
        ]
    }

    static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func userHomeDirectory(fileManager: FileManager = .default) -> URL {
        let fallback = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir
        else {
            return fallback
        }

        let homePath = String(cString: homePointer)
        guard homePath.hasPrefix("/") else {
            return fallback
        }
        return URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
    }

    static func displayName(for path: String, fileManager: FileManager = .default) -> String {
        let canonical = canonicalPath(for: URL(fileURLWithPath: path))
        let home = canonicalPath(for: userHomeDirectory(fileManager: fileManager))
        if canonical == home {
            return L10n.string("permissions.userDirectory")
        }
        return URL(fileURLWithPath: canonical).lastPathComponent
    }

    static func isBlockedSystemPath(_ path: String) -> Bool {
        let canonical = canonicalPath(for: URL(fileURLWithPath: path))
        if blockedExactRoots.contains(canonical) {
            return true
        }
        return blockedSystemTrees.contains { root in
            canonical == root || canonical.hasPrefix(root + "/")
        }
    }

    static func normalizedUserPaths(
        _ paths: [String],
        fileManager: FileManager = .default,
        requireExistingDirectory: Bool = true
    ) -> [String] {
        let normalized = paths.compactMap { path -> String? in
            let canonical = canonicalPath(for: URL(fileURLWithPath: path))
            guard !isBlockedSystemPath(canonical) else {
                return nil
            }
            guard !requireExistingDirectory || isAvailableDirectory(canonical, fileManager: fileManager) else {
                return nil
            }
            return canonical
        }
        return Array(Set(normalized)).sorted()
    }

    static func acceptedAndRejectedPaths(from urls: [URL], fileManager: FileManager = .default) -> (accepted: [String], rejected: [String]) {
        var accepted: [String] = []
        var rejected: [String] = []

        for url in urls {
            let path = canonicalPath(for: url)
            if isBlockedSystemPath(path) || !isAvailableDirectory(path, fileManager: fileManager) {
                rejected.append(path)
            } else {
                accepted.append(path)
            }
        }

        return (Array(Set(accepted)).sorted(), Array(Set(rejected)).sorted())
    }

    static func effectiveDirectoryURLs(
        for preferences: ClickMatePreferences,
        fileManager: FileManager = .default,
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) -> Set<URL> {
        var paths = normalizedUserPaths(
            defaultMonitoredFolderPaths(fileManager: fileManager) + preferences.monitoredFolderPaths,
            fileManager: fileManager,
            requireExistingDirectory: false
        )

        if preferences.monitoringMode == .wideCoverage {
            paths.append(contentsOf: mountedVolumeRootPaths(volumesRoot: volumesRoot, fileManager: fileManager))
        }

        return Set(normalizedUserPaths(paths, fileManager: fileManager, requireExistingDirectory: false).map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    static func finderSyncDirectoryURLs(
        for preferences: ClickMatePreferences,
        hasFullDiskAccess: Bool = DiskAccessPolicy.hasFullDiskAccess(),
        fileManager: FileManager = .default,
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        maxDepth: Int = 5,
        maxDirectoryCount: Int = 2_000
    ) -> Set<URL> {
        var urls = Set(defaultDirectoryURLsForFinderSyncBootstrap(fileManager: fileManager))

        if preferences.monitoringMode == .wideCoverage {
            urls.formUnion(mountedVolumeRootPaths(volumesRoot: volumesRoot, fileManager: fileManager).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })
        }

        let selectedRoots = monitoredDirectoryURLs(
            for: preferences,
            requiresBookmarks: !hasFullDiskAccess,
            fileManager: fileManager
        )
        urls.formUnion(expandedDirectoryURLs(
            from: selectedRoots,
            fileManager: fileManager,
            maxDepth: maxDepth,
            maxDirectoryCount: maxDirectoryCount
        ))

        return urls
    }

    static func expandedDirectoryURLs(
        from roots: Set<URL>,
        fileManager: FileManager = .default,
        maxDepth: Int,
        maxDirectoryCount: Int
    ) -> Set<URL> {
        guard maxDepth >= 0, maxDirectoryCount > 0 else { return [] }

        var result: Set<URL> = []
        var queue = roots
            .map { $0.standardizedFileURL }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { (url: $0, depth: 0) }

        while !queue.isEmpty, result.count < maxDirectoryCount {
            let entry = queue.removeFirst()
            let path = canonicalPath(for: entry.url)
            guard !isBlockedSystemPath(path), isAvailableDirectory(path, fileManager: fileManager) else {
                continue
            }

            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard result.insert(url).inserted, entry.depth < maxDepth else {
                continue
            }

            let children = childDirectoryURLs(in: url, fileManager: fileManager)
            for child in children where result.count + queue.count < maxDirectoryCount {
                queue.append((url: child, depth: entry.depth + 1))
            }
        }

        return result
    }

    private static func mountedVolumeRootPaths(volumesRoot: URL, fileManager: FileManager) -> [String] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            let path = canonicalPath(for: url)
            guard !isBlockedSystemPath(path), isAvailableDirectory(path, fileManager: fileManager) else {
                return nil
            }
            return path
        }
    }

    private static func monitoredDirectoryURLs(
        for preferences: ClickMatePreferences,
        requiresBookmarks: Bool,
        fileManager: FileManager
    ) -> Set<URL> {
        let bookmarkPaths = Set(preferences.monitoredFolderBookmarks.keys.map {
            canonicalPath(for: URL(fileURLWithPath: $0, isDirectory: true))
        })

        return Set(preferences.monitoredFolderPaths.compactMap { path in
            let canonical = canonicalPath(for: URL(fileURLWithPath: path, isDirectory: true))
            guard (!requiresBookmarks || bookmarkPaths.contains(canonical)),
                  !isBlockedSystemPath(canonical),
                  isAvailableDirectory(canonical, fileManager: fileManager)
            else {
                return nil
            }
            return URL(fileURLWithPath: canonical, isDirectory: true)
        })
    }

    private static func childDirectoryURLs(in url: URL, fileManager: FileManager) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { child in
            guard !child.lastPathComponent.hasPrefix(".") else { return nil }
            guard !skippedExpandedDirectoryNames.contains(child.lastPathComponent) else { return nil }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }
            let path = canonicalPath(for: child)
            guard !isBlockedSystemPath(path), isAvailableDirectory(path, fileManager: fileManager) else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isAvailableDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

enum DiskAccessPolicy {
    static func hasFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let home = MonitoredFolderPolicy.userHomeDirectory(fileManager: fileManager)
        let probes = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
        ]

        return probes.contains { probe in
            guard fileManager.fileExists(atPath: probe.path) else { return false }
            return (try? fileManager.contentsOfDirectory(
                at: probe,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) != nil
        }
    }

    static func scopedOrDirectAccess(
        containing targetDirectory: URL,
        preferences: ClickMatePreferences,
        hasFullDiskAccess: Bool = hasFullDiskAccess()
    ) -> SecurityScopedFolderAccess.ScopedAccess? {
        if hasFullDiskAccess {
            return SecurityScopedFolderAccess.ScopedAccess(url: targetDirectory, didStartAccessing: false)
        }
        return SecurityScopedFolderAccess.scopedAccess(containing: targetDirectory, preferences: preferences)
    }
}

enum FinderExtensionStatus: Equatable {
    case enabled
    case disabled
    case notRegistered
    case unknown
}

enum FinderExtensionPolicy {
    typealias ProcessRunner = (_ executableURL: URL, _ arguments: [String]) -> (status: Int32, output: String)?

    static func reloadBundledExtension(
        appBundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String = AppConstants.finderExtensionBundleIdentifier,
        runProcess: ProcessRunner = runProcess
    ) async -> FinderExtensionStatus {
        if let extensionURL = bundledExtensionURL(in: appBundleURL) {
            _ = runProcess(URL(fileURLWithPath: "/usr/bin/pluginkit"), ["-a", extensionURL.path])
        }

        _ = runProcess(URL(fileURLWithPath: "/usr/bin/pluginkit"), [
            "-e", "use",
            "-p", "com.apple.FinderSync",
            "-i", bundleIdentifier
        ])

        return await status(bundleIdentifier: bundleIdentifier, runProcess: runProcess)
    }

    static func status(
        bundleIdentifier: String = AppConstants.finderExtensionBundleIdentifier,
        runProcess: ProcessRunner = runProcess
    ) async -> FinderExtensionStatus {
        guard let result = runProcess(URL(fileURLWithPath: "/usr/bin/pluginkit"), [
            "-m",
            "-p", "com.apple.FinderSync",
            "-i", bundleIdentifier
        ]), result.status == 0 else {
            return .unknown
        }

        return status(fromPlugInKitOutput: result.output)
    }

    static func bundledExtensionURL(in appBundleURL: URL) -> URL? {
        let plugInsURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
        let extensionURL = plugInsURL.appendingPathComponent("ClickMateFinderExtension.appex", isDirectory: true)
        if FileManager.default.fileExists(atPath: extensionURL.path) {
            return extensionURL
        }
        return nil
    }

    private static func runProcess(executableURL: URL, arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, output)
    }

    static func status(fromPlugInKitOutput output: String) -> FinderExtensionStatus {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmed.first else {
            return .notRegistered
        }

        switch firstCharacter {
        case "+":
            return .enabled
        case "-":
            return .disabled
        default:
            return .unknown
        }
    }
}

struct SecurityScopedFolderAccess {
    struct ScopedAccess {
        let url: URL
        private let didStartAccessing: Bool

        fileprivate init(url: URL, didStartAccessing: Bool) {
            self.url = url
            self.didStartAccessing = didStartAccessing
        }

        func stopAccessing() {
            guard didStartAccessing else { return }
            url.stopAccessingSecurityScopedResource()
        }

        func resolvedURL(for requestedURL: URL) -> URL {
            let authorizedPath = MonitoredFolderPolicy.canonicalPath(for: url)
            let requestedPath = MonitoredFolderPolicy.canonicalPath(for: requestedURL)
            guard requestedPath != authorizedPath,
                  requestedPath.hasPrefix(authorizedPath + "/")
            else {
                return url
            }

            let relativePath = String(requestedPath.dropFirst(authorizedPath.count + 1))
            return url.appendingPathComponent(relativePath, isDirectory: true)
        }
    }

    static func bookmarkData(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func authorizedBookmarkPath(containing targetDirectory: URL, preferences: ClickMatePreferences) -> String? {
        let targetPath = MonitoredFolderPolicy.canonicalPath(for: targetDirectory)
        return preferences.monitoredFolderBookmarks.keys
            .map { MonitoredFolderPolicy.canonicalPath(for: URL(fileURLWithPath: $0, isDirectory: true)) }
            .filter { path in
                targetPath == path || targetPath.hasPrefix(path + "/")
            }
            .max { $0.count < $1.count }
    }

    static func scopedAccess(containing targetDirectory: URL, preferences: ClickMatePreferences) -> ScopedAccess? {
        guard let bookmarkPath = authorizedBookmarkPath(containing: targetDirectory, preferences: preferences),
              let bookmarkData = preferences.monitoredFolderBookmarks[bookmarkPath]
        else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else { return nil }
            return ScopedAccess(url: url, didStartAccessing: url.startAccessingSecurityScopedResource())
        } catch {
            return scopedTransportAccess(from: bookmarkData)
        }
    }

    static func scopedAccess(toCurrentProcessURL url: URL) -> ScopedAccess? {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        guard didStartAccessing else { return nil }
        return ScopedAccess(url: url, didStartAccessing: didStartAccessing)
    }

    private static func scopedTransportAccess(from bookmarkData: Data) -> ScopedAccess? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else { return nil }
            return ScopedAccess(url: url, didStartAccessing: false)
        } catch {
            return nil
        }
    }
}
