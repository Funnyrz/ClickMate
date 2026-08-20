import Darwin
import Foundation
import Security

enum MonitoringMode: String, Codable, Equatable {
    case wideCoverage
}

struct ClickMatePreferences: Codable, Equatable {
    var enabledCommands: Set<MenuCommand>
    var menuCommandOrder: [MenuCommand]
    var foldedMenuGroups: Set<MenuCommandGroup>
    var topLevelShortcutCommands: Set<MenuCommand>
    var topLevelShortcutTemplateIDs: Set<String>
    var removedMenuCommands: Set<MenuCommand>
    var templates: [FileTemplate]
    var monitoringMode: MonitoringMode
    var monitoredFolderPaths: [String]
    var monitoredFolderBookmarks: [String: Data]
    var detectedApplicationOrder: [String]
    var removedDetectedApplicationBundleIDs: Set<String>
    var pinnedApplicationPaths: [String]
    var language: AppLanguage
    var hasDismissedPermissionGuide: Bool
    var backgroundServiceEnabled: Bool
    var hasAcknowledgedHelperPermissionMigration: Bool
    var hasAcknowledgedFinderMonitoringMigration: Bool
    var menuLayoutDefaultsVersion: Int
    var quickFeatureDefaultsVersion: Int
    var finderMonitoringPolicyVersion: Int
    var quickFeatureSettings: [QuickFeatureSettings]
    var screenshotSettings: ScreenshotSettings

    init(
        enabledCommands: Set<MenuCommand>,
        menuCommandOrder: [MenuCommand] = MenuCommand.allCases,
        foldedMenuGroups: Set<MenuCommandGroup> = MenuCommandGroup.defaultFoldedGroups,
        topLevelShortcutCommands: Set<MenuCommand> = [],
        topLevelShortcutTemplateIDs: Set<String> = [],
        removedMenuCommands: Set<MenuCommand> = [],
        templates: [FileTemplate],
        monitoringMode: MonitoringMode = .wideCoverage,
        monitoredFolderPaths: [String],
        monitoredFolderBookmarks: [String: Data] = [:],
        detectedApplicationOrder: [String] = AppDetector.defaultApplicationOrder,
        removedDetectedApplicationBundleIDs: Set<String> = [],
        pinnedApplicationPaths: [String],
        language: AppLanguage = .system,
        hasDismissedPermissionGuide: Bool = false,
        backgroundServiceEnabled: Bool = true,
        hasAcknowledgedHelperPermissionMigration: Bool = true,
        hasAcknowledgedFinderMonitoringMigration: Bool = true,
        menuLayoutDefaultsVersion: Int = Self.currentMenuLayoutDefaultsVersion,
        quickFeatureDefaultsVersion: Int = Self.currentQuickFeatureDefaultsVersion,
        finderMonitoringPolicyVersion: Int = Self.currentFinderMonitoringPolicyVersion,
        quickFeatureSettings: [QuickFeatureSettings] = QuickFeatureSettings.defaults,
        screenshotSettings: ScreenshotSettings = .defaults
    ) {
        self.removedMenuCommands = removedMenuCommands
        self.enabledCommands = enabledCommands.subtracting(removedMenuCommands)
        self.menuCommandOrder = Self.normalizedMenuCommandOrder(menuCommandOrder)
        self.foldedMenuGroups = foldedMenuGroups
        self.topLevelShortcutCommands = topLevelShortcutCommands.subtracting(removedMenuCommands)
        self.topLevelShortcutTemplateIDs = topLevelShortcutTemplateIDs
        self.templates = templates
        self.monitoringMode = monitoringMode
        self.monitoredFolderPaths = monitoredFolderPaths
        self.monitoredFolderBookmarks = monitoredFolderBookmarks
        self.detectedApplicationOrder = AppDetector.normalizedApplicationOrder(detectedApplicationOrder)
        self.removedDetectedApplicationBundleIDs = removedDetectedApplicationBundleIDs.intersection(AppDetector.defaultApplicationOrder)
        self.pinnedApplicationPaths = pinnedApplicationPaths
        self.language = language
        self.hasDismissedPermissionGuide = hasDismissedPermissionGuide
        self.backgroundServiceEnabled = backgroundServiceEnabled
        self.hasAcknowledgedHelperPermissionMigration = hasAcknowledgedHelperPermissionMigration
        self.hasAcknowledgedFinderMonitoringMigration = hasAcknowledgedFinderMonitoringMigration
        self.menuLayoutDefaultsVersion = menuLayoutDefaultsVersion
        self.quickFeatureDefaultsVersion = quickFeatureDefaultsVersion
        self.finderMonitoringPolicyVersion = finderMonitoringPolicyVersion
        self.quickFeatureSettings = QuickFeatureSettings.normalized(quickFeatureSettings)
        self.screenshotSettings = screenshotSettings
    }

    static let currentMenuLayoutDefaultsVersion = 1
    static let currentQuickFeatureDefaultsVersion = 1
    static let currentFinderMonitoringPolicyVersion = 4

    static let defaults = ClickMatePreferences(
        enabledCommands: Set(MenuCommand.allCases),
        menuCommandOrder: MenuCommand.allCases,
        foldedMenuGroups: MenuCommandGroup.defaultFoldedGroups,
        topLevelShortcutCommands: [],
        topLevelShortcutTemplateIDs: [],
        removedMenuCommands: [],
        templates: FileTemplate.defaults,
        monitoringMode: .wideCoverage,
        monitoredFolderPaths: [],
        monitoredFolderBookmarks: [:],
        detectedApplicationOrder: AppDetector.defaultApplicationOrder,
        removedDetectedApplicationBundleIDs: [],
        pinnedApplicationPaths: [],
        language: .system,
        hasDismissedPermissionGuide: false,
        backgroundServiceEnabled: true,
        hasAcknowledgedHelperPermissionMigration: true,
        hasAcknowledgedFinderMonitoringMigration: true,
        menuLayoutDefaultsVersion: currentMenuLayoutDefaultsVersion,
        quickFeatureDefaultsVersion: currentQuickFeatureDefaultsVersion,
        finderMonitoringPolicyVersion: currentFinderMonitoringPolicyVersion,
        quickFeatureSettings: QuickFeatureSettings.defaults,
        screenshotSettings: .defaults
    )

    var orderedMenuCommands: [MenuCommand] {
        Self.normalizedMenuCommandOrder(menuCommandOrder)
            .filter { !removedMenuCommands.contains($0) }
    }

    var enabledMenuCommandsInCustomOrder: [MenuCommand] {
        orderedMenuCommands.filter { enabledCommands.contains($0) }
    }

    var orderedDetectedApplicationBundleIDs: [String] {
        AppDetector.normalizedApplicationOrder(detectedApplicationOrder)
            .filter { !removedDetectedApplicationBundleIDs.contains($0) }
    }

    var enabledOpenApplicationCommandsInCustomOrder: [MenuCommand] {
        orderedDetectedApplicationBundleIDs
            .compactMap(MenuCommand.openApplicationCommand(forBundleIdentifier:))
            .filter { enabledCommands.contains($0) && !removedMenuCommands.contains($0) }
    }

    var orderedVisibleMenuGroups: [MenuCommandGroup] {
        MenuLayoutPolicy.orderedVisibleGroups(for: self)
    }

    var menuGroupPlacement: MenuGroupPlacement {
        MenuLayoutPolicy.placement(for: self)
    }

    func quickFeatureSettings(for id: QuickFeatureID) -> QuickFeatureSettings {
        quickFeatureSettings.first { $0.id == id } ?? QuickFeatureSettings(id: id)
    }

    func conflictingQuickFeatureIDs() -> Set<QuickFeatureID> {
        QuickFeatureSettings.conflictingFeatureIDs(in: quickFeatureSettings)
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

    mutating func removeMenuCommand(_ command: MenuCommand) {
        removedMenuCommands.insert(command)
        enabledCommands.remove(command)
        topLevelShortcutCommands.remove(command)
        if command == .newFile {
            topLevelShortcutTemplateIDs.removeAll()
        }
    }

    mutating func removeTemplate(id: String) {
        templates.removeAll { $0.id == id }
        topLevelShortcutTemplateIDs.remove(id)
    }

    mutating func removeDetectedApplication(bundleIdentifier: String) {
        guard AppDetector.defaultApplicationOrder.contains(bundleIdentifier) else { return }
        removedDetectedApplicationBundleIDs.insert(bundleIdentifier)
        if let command = MenuCommand.openApplicationCommand(forBundleIdentifier: bundleIdentifier) {
            enabledCommands.remove(command)
            topLevelShortcutCommands.remove(command)
        }
    }

    mutating func restoreRemovedDefaults() {
        removedMenuCommands.removeAll()
        removedDetectedApplicationBundleIDs.removeAll()

        let existingTemplateIDs = Set(templates.map(\.id))
        templates.append(contentsOf: FileTemplate.defaults.filter { !existingTemplateIDs.contains($0.id) })
    }

    private enum CodingKeys: String, CodingKey {
        case enabledCommands
        case menuCommandOrder
        case foldedMenuGroups
        case topLevelShortcutCommands
        case topLevelShortcutTemplateIDs
        case removedMenuCommands
        case templates
        case monitoringMode
        case monitoredFolderPaths
        case monitoredFolderBookmarks
        case detectedApplicationOrder
        case removedDetectedApplicationBundleIDs
        case pinnedApplicationPaths
        case language
        case hasDismissedPermissionGuide
        case backgroundServiceEnabled
        case hasAcknowledgedHelperPermissionMigration
        case hasAcknowledgedFinderMonitoringMigration
        case menuLayoutDefaultsVersion
        case quickFeatureDefaultsVersion
        case finderMonitoringPolicyVersion
        case quickFeatureSettings
        case screenshotSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledCommands = try container.decode(Set<MenuCommand>.self, forKey: .enabledCommands)
        menuCommandOrder = Self.normalizedMenuCommandOrder(
            try container.decodeIfPresent([MenuCommand].self, forKey: .menuCommandOrder) ?? MenuCommand.allCases
        )
        foldedMenuGroups = try container.decodeIfPresent(Set<MenuCommandGroup>.self, forKey: .foldedMenuGroups) ?? MenuCommandGroup.defaultFoldedGroups
        topLevelShortcutCommands = try container.decodeIfPresent(Set<MenuCommand>.self, forKey: .topLevelShortcutCommands) ?? []
        topLevelShortcutTemplateIDs = try container.decodeIfPresent(Set<String>.self, forKey: .topLevelShortcutTemplateIDs) ?? []
        removedMenuCommands = try container.decodeIfPresent(Set<MenuCommand>.self, forKey: .removedMenuCommands) ?? []
        enabledCommands.subtract(removedMenuCommands)
        topLevelShortcutCommands.subtract(removedMenuCommands)
        templates = try container.decode([FileTemplate].self, forKey: .templates)
        monitoringMode = try container.decodeIfPresent(MonitoringMode.self, forKey: .monitoringMode) ?? .wideCoverage
        monitoredFolderPaths = try container.decodeIfPresent([String].self, forKey: .monitoredFolderPaths) ?? []
        monitoredFolderBookmarks = try container.decodeIfPresent([String: Data].self, forKey: .monitoredFolderBookmarks) ?? [:]
        detectedApplicationOrder = AppDetector.normalizedApplicationOrder(
            try container.decodeIfPresent([String].self, forKey: .detectedApplicationOrder) ?? AppDetector.defaultApplicationOrder
        )
        let removedBundleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .removedDetectedApplicationBundleIDs) ?? []
        removedDetectedApplicationBundleIDs = removedBundleIDs.intersection(AppDetector.defaultApplicationOrder)
        pinnedApplicationPaths = try container.decodeIfPresent([String].self, forKey: .pinnedApplicationPaths) ?? []
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        hasDismissedPermissionGuide = try container.decodeIfPresent(Bool.self, forKey: .hasDismissedPermissionGuide) ?? false
        backgroundServiceEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundServiceEnabled) ?? true
        hasAcknowledgedHelperPermissionMigration = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAcknowledgedHelperPermissionMigration
        ) ?? false
        hasAcknowledgedFinderMonitoringMigration = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAcknowledgedFinderMonitoringMigration
        ) ?? false
        menuLayoutDefaultsVersion = try container.decodeIfPresent(Int.self, forKey: .menuLayoutDefaultsVersion) ?? 0
        quickFeatureDefaultsVersion = try container.decodeIfPresent(Int.self, forKey: .quickFeatureDefaultsVersion) ?? 0
        finderMonitoringPolicyVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .finderMonitoringPolicyVersion
        ) ?? 0
        let decodedQuickFeatures = try container.decodeIfPresent(
            LossyQuickFeatureSettings.self,
            forKey: .quickFeatureSettings
        )?.values
        quickFeatureSettings = QuickFeatureSettings.normalized(
            decodedQuickFeatures ?? QuickFeatureSettings.defaults
        )
        screenshotSettings = try container.decodeIfPresent(ScreenshotSettings.self, forKey: .screenshotSettings) ?? .defaults
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

    mutating func migrateQuickFeatureDefaultsIfNeeded() -> Bool {
        guard quickFeatureDefaultsVersion < Self.currentQuickFeatureDefaultsVersion else {
            return false
        }

        if let screenshotIndex = quickFeatureSettings.firstIndex(where: { $0.id == .screenshot }),
           quickFeatureSettings[screenshotIndex].shortcut == .legacyScreenshotDefault {
            quickFeatureSettings[screenshotIndex].shortcut = .screenshotDefault
        }
        quickFeatureDefaultsVersion = Self.currentQuickFeatureDefaultsVersion
        return true
    }

    mutating func migrateFinderMonitoringPolicyIfNeeded() -> Bool {
        guard finderMonitoringPolicyVersion < Self.currentFinderMonitoringPolicyVersion else {
            return false
        }

        monitoredFolderPaths = MonitoredFolderPolicy.sanitizedCustomFolderPaths(monitoredFolderPaths)
        let retainedPaths = Set(monitoredFolderPaths)
        monitoredFolderBookmarks = monitoredFolderBookmarks.reduce(into: [:]) { result, entry in
            let canonicalPath = MonitoredFolderPolicy.canonicalPath(
                for: URL(fileURLWithPath: entry.key, isDirectory: true)
            )
            guard retainedPaths.contains(canonicalPath) else { return }
            result[canonicalPath] = entry.value
        }
        finderMonitoringPolicyVersion = Self.currentFinderMonitoringPolicyVersion
        hasAcknowledgedFinderMonitoringMigration = false
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

    static func shortcutCommandCandidates(
        for group: MenuCommandGroup,
        preferences: ClickMatePreferences
    ) -> [MenuCommand] {
        switch group {
        case .newFile, .openPinned:
            return []
        case .openHere:
            return preferences.enabledOpenApplicationCommandsInCustomOrder
        default:
            let groupCommands = Set(group.commands)
            return preferences.enabledMenuCommandsInCustomOrder.filter { groupCommands.contains($0) }
        }
    }

    static func selectedShortcutCommands(
        for group: MenuCommandGroup,
        preferences: ClickMatePreferences
    ) -> [MenuCommand] {
        shortcutCommandCandidates(for: group, preferences: preferences)
            .filter { preferences.topLevelShortcutCommands.contains($0) }
    }

    static func shortcutTemplateCandidates(for preferences: ClickMatePreferences) -> [FileTemplate] {
        guard preferences.enabledCommands.contains(.newFile),
              !preferences.removedMenuCommands.contains(.newFile)
        else {
            return []
        }
        return preferences.templates
    }

    static func selectedShortcutTemplates(for preferences: ClickMatePreferences) -> [FileTemplate] {
        shortcutTemplateCandidates(for: preferences)
            .filter { preferences.topLevelShortcutTemplateIDs.contains($0.id) }
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
    private let allowsWrites: Bool
    private let publishesPinnedApplications: Bool
    private let saveQueue = DispatchQueue(label: "\(AppConstants.bundleIdentifier).preferences.save")
    private var isReloading = false

    init(
        fileURL: URL = PreferencesStore.sharedPreferencesURL,
        allowsWrites: Bool = true
    ) {
        self.fileURL = fileURL
        self.allowsWrites = allowsWrites
        self.publishesPinnedApplications = allowsWrites
            && fileURL.standardizedFileURL == Self.fallbackPreferencesURL.standardizedFileURL
        if allowsWrites {
            Self.migrateFallbackPreferencesIfNeeded(to: fileURL)
        }
        let loaded = Self.loadWithMigration(from: fileURL)
        self.preferences = loaded.preferences
        publishPinnedApplicationsIfNeeded(loaded.preferences)
        if allowsWrites,
           (!FileManager.default.fileExists(atPath: fileURL.path) || loaded.didMigrate) {
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
        guard allowsWrites else { return }
        publishPinnedApplicationsIfNeeded(preferences)
        let fileURL = fileURL
        saveQueue.async {
            Self.write(preferences, to: fileURL)
        }
    }

    private func saveSynchronously(_ preferences: ClickMatePreferences) {
        guard allowsWrites else { return }
        publishPinnedApplicationsIfNeeded(preferences)
        let fileURL = fileURL
        saveQueue.sync {
            Self.write(preferences, to: fileURL)
        }
    }

    private func publishPinnedApplicationsIfNeeded(_ preferences: ClickMatePreferences) {
        guard publishesPinnedApplications else { return }
        PinnedApplicationSyncStore.publish(paths: preferences.pinnedApplicationPaths)
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
        let didMigrateMenuLayout = preferences.migrateMenuLayoutDefaultsIfNeeded()
        let didMigrateQuickFeatures = preferences.migrateQuickFeatureDefaultsIfNeeded()
        let didMigrateFinderMonitoring = preferences.migrateFinderMonitoringPolicyIfNeeded()
        let didMigrate = didMigrateMenuLayout || didMigrateQuickFeatures || didMigrateFinderMonitoring
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
        if let containerURL = ApplicationGroupAccessPolicy.sharedContainerURL() {
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

enum ApplicationGroupAccessPolicy {
    static var isSharedContainerAuthorized: Bool {
        isSharedContainerAuthorized(bundle: .main)
    }

    static func isSharedContainerAuthorized(
        bundle: Bundle,
        groupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> Bool {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              let signingIdentity = signingIdentity(
            bundleURL: bundle.bundleURL,
            groupIdentifier: groupIdentifier
              ),
              signingIdentity.applicationIdentifier
                == "\(signingIdentity.teamIdentifier).\(bundleIdentifier)"
        else {
            return false
        }
        let profileURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("embedded.provisionprofile")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return false
        }
        guard let profileData = try? Data(contentsOf: profileURL),
              let propertyList = decodedProvisioningProfilePropertyList(from: profileData)
        else {
            return false
        }
        return profileAuthorizesApplicationGroup(
            groupIdentifier,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: signingIdentity.teamIdentifier,
            propertyList: propertyList
        )
    }

    static func sharedContainerURL(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        groupIdentifier: String = AppConstants.appGroupIdentifier,
        authorizationProvider: ((Bundle, String) -> Bool)? = nil,
        containerURLProvider: ((String) -> URL?)? = nil
    ) -> URL? {
        let isAuthorized = authorizationProvider?(bundle, groupIdentifier)
            ?? isSharedContainerAuthorized(bundle: bundle, groupIdentifier: groupIdentifier)
        guard isAuthorized else { return nil }
        if let containerURLProvider {
            return containerURLProvider(groupIdentifier)
        }
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        )
    }

    static func profileAuthorizesApplicationGroup(
        _ groupIdentifier: String,
        bundleIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        propertyList: Any
    ) -> Bool {
        guard let profile = propertyList as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else {
            return false
        }
        guard groups.contains(groupIdentifier) else { return false }

        if let bundleIdentifier, let teamIdentifier {
            let expectedApplicationIdentifier = "\(teamIdentifier).\(bundleIdentifier)"
            guard entitlements["com.apple.application-identifier"] as? String
                    == expectedApplicationIdentifier,
                  entitlements["com.apple.developer.team-identifier"] as? String
                    == teamIdentifier,
                  let profileTeamIdentifiers = profile["TeamIdentifier"] as? [String],
                  profileTeamIdentifiers.contains(teamIdentifier)
            else {
                return false
            }
        }
        return true
    }

    private static func decodedProvisioningProfilePropertyList(from data: Data) -> Any? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess,
              let decoder
        else {
            return nil
        }
        let updateStatus = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, baseAddress, data.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else {
            return nil
        }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content
        else {
            return nil
        }
        return try? PropertyListSerialization.propertyList(
            from: content as Data,
            options: [],
            format: nil
        )
    }

    private struct SigningIdentity {
        let teamIdentifier: String
        let applicationIdentifier: String
    }

    private static func signingIdentity(
        bundleURL: URL,
        groupIdentifier: String
    ) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamIdentifier.isEmpty,
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let applicationIdentifier = entitlements["com.apple.application-identifier"] as? String,
              let entitlementTeamIdentifier = entitlements["com.apple.developer.team-identifier"] as? String,
              entitlementTeamIdentifier == teamIdentifier,
              let applicationGroups = entitlements["com.apple.security.application-groups"] as? [String],
              applicationGroups.contains(groupIdentifier)
        else {
            return nil
        }
        return SigningIdentity(
            teamIdentifier: teamIdentifier,
            applicationIdentifier: applicationIdentifier
        )
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
    private static let commonUserDirectoryNames = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
        "Projects", "Workspace"
    ]

    static func defaultMonitoredFolderPaths(fileManager: FileManager = .default) -> [String] {
        defaultDirectoryURLsForFinderSyncBootstrap(fileManager: fileManager).map(\.path)
    }

    static func defaultDirectoryURLsForFinderSyncBootstrap(fileManager: FileManager = .default) -> [URL] {
        let home = userHomeDirectory(fileManager: fileManager).standardizedFileURL
        return safeTopLevelDirectoryURLs(in: home, fileManager: fileManager)
    }

    static func safeTopLevelDirectoryURLs(
        in homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let home = homeDirectory.standardizedFileURL
        let homeLibrary = canonicalPath(
            for: home.appendingPathComponent("Library", isDirectory: true)
        )
        var candidates = commonUserDirectoryNames.map {
            home.appendingPathComponent($0, isDirectory: true)
        }

        if let discovered = try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: discovered)
        }

        let safeDirectories = candidates.compactMap { candidate -> URL? in
            guard !candidate.lastPathComponent.hasPrefix(".") else { return nil }
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }

            let canonical = canonicalPath(for: candidate)
            guard canonical != homeLibrary,
                  !canonical.hasPrefix(homeLibrary + "/"),
                  !isBlockedSystemPath(canonical),
                  !isUnsafeFinderSyncRoot(canonical, fileManager: fileManager),
                  isAvailableDirectory(canonical, fileManager: fileManager)
            else {
                return nil
            }
            return URL(fileURLWithPath: canonical, isDirectory: true)
        }

        return Array(Set(safeDirectories)).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
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

    static func isUnsafeFinderSyncRoot(
        _ path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let canonical = canonicalPath(for: URL(fileURLWithPath: path, isDirectory: true))
        let home = canonicalPath(for: userHomeDirectory(fileManager: fileManager))
        let userLibrary = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .path
        return canonical == home
            || canonical == userLibrary
            || canonical.hasPrefix(userLibrary + "/")
    }

    static func sanitizedCustomFolderPaths(
        _ paths: [String],
        fileManager: FileManager = .default
    ) -> [String] {
        normalizedUserPaths(paths, fileManager: fileManager)
    }

    static func normalizedUserPaths(
        _ paths: [String],
        fileManager: FileManager = .default,
        requireExistingDirectory: Bool = true
    ) -> [String] {
        let normalized = paths.compactMap { path -> String? in
            let canonical = canonicalPath(for: URL(fileURLWithPath: path))
            guard !isBlockedSystemPath(canonical),
                  !isUnsafeFinderSyncRoot(canonical, fileManager: fileManager)
            else {
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
            if isBlockedSystemPath(path)
                || isUnsafeFinderSyncRoot(path, fileManager: fileManager)
                || !isAvailableDirectory(path, fileManager: fileManager) {
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
        volumesRoot _: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) -> Set<URL> {
        let paths = normalizedUserPaths(
            defaultMonitoredFolderPaths(fileManager: fileManager) + preferences.monitoredFolderPaths,
            fileManager: fileManager,
            requireExistingDirectory: false
        )

        return Set(normalizedUserPaths(paths, fileManager: fileManager, requireExistingDirectory: false).map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    static func finderSyncDirectoryURLs(
        for preferences: ClickMatePreferences,
        hasFullDiskAccess: Bool = DiskAccessPolicy.hasFullDiskAccess(),
        fileManager: FileManager = .default,
        volumesRoot _: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) -> Set<URL> {
        var urls = Set(defaultDirectoryURLsForFinderSyncBootstrap(fileManager: fileManager))

        let selectedRoots = monitoredDirectoryURLs(
            for: preferences,
            requiresBookmarks: !hasFullDiskAccess,
            fileManager: fileManager
        )
        urls.formUnion(selectedRoots)

        return urls
    }

    static func mountedVolumeRootPaths(
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default
    ) -> [String] {
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
                  !isUnsafeFinderSyncRoot(canonical, fileManager: fileManager),
                  isAvailableDirectory(canonical, fileManager: fileManager)
            else {
                return nil
            }
            return URL(fileURLWithPath: canonical, isDirectory: true)
        })
    }

    private static func isAvailableDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

enum DiskAccessStatus: String, Codable, Equatable {
    case granted
    case denied
    case unavailable
    case unknown

    var isGranted: Bool {
        self == .granted
    }
}

enum DiskAccessProbeResult: Equatable {
    case accessible
    case permissionDenied
    case unavailable
    case unknown
}

enum FinderExtensionAccessResult: String, Codable, Equatable {
    case success
    case permissionDenied
    case failed
}

enum DiskAccessPolicy {
    typealias ProbeProvider = (URL) -> DiskAccessProbeResult

    static func status(fileManager: FileManager = .default) -> DiskAccessStatus {
        .unknown
    }

    static func status(
        probes: [URL],
        probeProvider: ProbeProvider
    ) -> DiskAccessStatus {
        let results = probes.map(probeProvider)
        if results.contains(.accessible) {
            return .granted
        }
        if results.contains(.permissionDenied) {
            return .denied
        }
        if !results.isEmpty, results.allSatisfy({ $0 == .unavailable }) {
            return .unavailable
        }
        return .unknown
    }

    static func hasFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        false
    }

    static func scopedOrDirectAccess(
        containing targetDirectory: URL,
        preferences: ClickMatePreferences,
        hasFullDiskAccess: Bool? = nil
    ) -> SecurityScopedFolderAccess.ScopedAccess? {
        if let scopedAccess = SecurityScopedFolderAccess.scopedAccess(
            containing: targetDirectory,
            preferences: preferences
        ) {
            return scopedAccess
        }
        if hasFullDiskAccess != false {
            return SecurityScopedFolderAccess.ScopedAccess(url: targetDirectory, didStartAccessing: false)
        }
        return nil
    }

}

struct FinderExtensionRuntimeSnapshot: Codable, Equatable {
    static let currentMonitoringPolicyVersion = 4

    var pid: Int32
    var version: String
    var updatedAt: Date
    var diskAccessStatus: DiskAccessStatus
    var monitoringPolicyVersion: Int?
    var lastAccessResult: FinderExtensionAccessResult?
    var lastAccessAt: Date?

    init(
        pid: Int32,
        version: String,
        updatedAt: Date = .now,
        diskAccessStatus: DiskAccessStatus,
        monitoringPolicyVersion: Int? = Self.currentMonitoringPolicyVersion,
        lastAccessResult: FinderExtensionAccessResult? = nil,
        lastAccessAt: Date? = nil
    ) {
        self.pid = pid
        self.version = version
        self.updatedAt = updatedAt
        self.diskAccessStatus = diskAccessStatus
        self.monitoringPolicyVersion = monitoringPolicyVersion
        self.lastAccessResult = lastAccessResult
        self.lastAccessAt = lastAccessAt
    }

}

enum FinderExtensionRuntimeSnapshotPolicy {
    static func accepts(
        _ snapshot: FinderExtensionRuntimeSnapshot,
        currentVersion: String,
        previousPID: Int32? = nil,
        updatedAfter: Date? = nil,
        referenceDate _: Date = .now,
        isExpectedRunningProcess: (Int32) -> Bool
    ) -> Bool {
        guard snapshot.version == currentVersion,
              snapshot.monitoringPolicyVersion == FinderExtensionRuntimeSnapshot.currentMonitoringPolicyVersion,
              isExpectedRunningProcess(snapshot.pid)
        else {
            return false
        }

        if let previousPID, snapshot.pid == previousPID {
            return false
        }
        if let updatedAfter, snapshot.updatedAt < updatedAfter {
            return false
        }
        return true
    }
}

struct FinderExtensionPolicyRecoveryTracker {
    private(set) var attemptedAutomaticRecovery = false

    mutating func begin(isAutomatic: Bool) -> Bool {
        guard isAutomatic else { return true }
        guard !attemptedAutomaticRecovery else { return false }
        attemptedAutomaticRecovery = true
        return true
    }
}

enum FullDiskAccessRecoveryPhase: String, Codable, Equatable {
    case waitingForReturn
    case relaunchScheduled
    case reloadingExtension
    case completed
    case failed
}

struct FullDiskAccessRecoveryRequest: Codable, Equatable {
    let id: UUID
    let settingsOpenedAt: Date
    let previousApplicationPID: Int32?
    let previousFinderExtensionPID: Int32?
    private(set) var phase: FullDiskAccessRecoveryPhase

    init(
        id: UUID = UUID(),
        settingsOpenedAt: Date = .now,
        previousApplicationPID: Int32? = ProcessInfo.processInfo.processIdentifier,
        previousFinderExtensionPID: Int32? = nil,
        phase: FullDiskAccessRecoveryPhase = .waitingForReturn
    ) {
        self.id = id
        self.settingsOpenedAt = settingsOpenedAt
        self.previousApplicationPID = previousApplicationPID
        self.previousFinderExtensionPID = previousFinderExtensionPID
        self.phase = phase
    }

    mutating func markRelaunchScheduled() -> Bool {
        guard phase == .waitingForReturn else { return false }
        phase = .relaunchScheduled
        return true
    }

    mutating func markExtensionReloadStarted(currentApplicationPID: Int32) -> Bool {
        guard phase == .relaunchScheduled,
              previousApplicationPID == nil || previousApplicationPID != currentApplicationPID
        else { return false }
        phase = .reloadingExtension
        return true
    }

    mutating func markCompleted() {
        phase = .completed
    }

    mutating func markFailed() {
        phase = .failed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case settingsOpenedAt
        case previousApplicationPID
        case previousFinderExtensionPID
        case phase
        case didAttemptProcessRefresh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        settingsOpenedAt = try container.decode(Date.self, forKey: .settingsOpenedAt)
        previousApplicationPID = try container.decodeIfPresent(
            Int32.self,
            forKey: .previousApplicationPID
        )
        previousFinderExtensionPID = try container.decodeIfPresent(
            Int32.self,
            forKey: .previousFinderExtensionPID
        )
        if let decodedPhase = try container.decodeIfPresent(
            FullDiskAccessRecoveryPhase.self,
            forKey: .phase
        ) {
            phase = decodedPhase
        } else {
            let didAttempt = try container.decodeIfPresent(
                Bool.self,
                forKey: .didAttemptProcessRefresh
            ) ?? false
            phase = didAttempt ? .failed : .waitingForReturn
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(settingsOpenedAt, forKey: .settingsOpenedAt)
        try container.encodeIfPresent(previousApplicationPID, forKey: .previousApplicationPID)
        try container.encodeIfPresent(previousFinderExtensionPID, forKey: .previousFinderExtensionPID)
        try container.encode(phase, forKey: .phase)
    }
}

struct FullDiskAccessRecoveryStore {
    private let fileURL: URL

    init(fileURL: URL = defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() -> FullDiskAccessRecoveryRequest? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FullDiskAccessRecoveryRequest.self, from: data)
    }

    @discardableResult
    func write(_ request: FullDiskAccessRecoveryRequest) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(request).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var defaultFileURL: URL {
        PreferencesStore.sharedPreferencesURL
            .deletingLastPathComponent()
            .appendingPathComponent("PermissionRecovery", isDirectory: true)
            .appendingPathComponent("full-disk-access.json")
    }
}

struct FinderExtensionRuntimeSnapshotStore {
    static let notificationName = "\(AppConstants.bundleIdentifier).finderExtensionRuntimeSnapshotChanged"

    private let fileURL: URL?

    static var isAvailable: Bool {
        defaultFileURL != nil
    }

    init(fileURL: URL? = defaultFileURL) {
        self.fileURL = fileURL
    }

    static func load() -> FinderExtensionRuntimeSnapshot? {
        Self().load()
    }

    @discardableResult
    static func write(_ snapshot: FinderExtensionRuntimeSnapshot) -> Bool {
        Self().write(snapshot)
    }

    static func remove() {
        Self().remove()
    }

    func load() -> FinderExtensionRuntimeSnapshot? {
        guard let fileURL else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FinderExtensionRuntimeSnapshot.self, from: data)
    }

    @discardableResult
    func write(_ snapshot: FinderExtensionRuntimeSnapshot) -> Bool {
        guard let fileURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            Self.postNotification()
            return true
        } catch {
            return false
        }
    }

    func remove() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        Self.postNotification()
    }

    private static var defaultFileURL: URL? {
        ApplicationGroupAccessPolicy.sharedContainerURL()?
            .appendingPathComponent("FinderExtensionRuntime", isDirectory: true)
            .appendingPathComponent("snapshot.json")
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
