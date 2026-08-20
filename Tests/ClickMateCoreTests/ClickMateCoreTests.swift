import AppKit
import XCTest

final class ClickMateCoreTests: XCTestCase {
    func testAvailableURLAddsIncrementingSuffix() throws {
        let directory = try makeTemporaryDirectory()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("Untitled.txt").path, contents: Data())
        FileManager.default.createFile(atPath: directory.appendingPathComponent("Untitled 2.txt").path, contents: Data())

        let url = FileCreator.availableURL(in: directory, preferredFilename: "Untitled.txt")

        XCTAssertEqual(url.lastPathComponent, "Untitled 3.txt")
    }

    func testPathFormatting() {
        let urls = [
            URL(fileURLWithPath: "/Users/example/My File.txt"),
            URL(fileURLWithPath: "/tmp/Another.md")
        ]

        XCTAssertEqual(PathFormatter.format(urls, as: .copyFilename), "My File.txt\nAnother.md")
        XCTAssertEqual(PathFormatter.format(urls, as: .copyBasename), "My File\nAnother")
        XCTAssertEqual(PathFormatter.format(urls, as: .copyExtension), "txt\nmd")
        XCTAssertEqual(PathFormatter.format(urls, as: .copyParentPath), "/Users/example\n/tmp")
    }

    func testShellEscaping() {
        XCTAssertEqual(PathFormatter.shellEscaped("/tmp/simple-file.txt"), "/tmp/simple-file.txt")
        XCTAssertEqual(PathFormatter.shellEscaped("/tmp/My File.txt"), "'/tmp/My File.txt'")
        XCTAssertEqual(PathFormatter.shellEscaped("/tmp/Bob's File.txt"), "'/tmp/Bob'\\''s File.txt'")
    }

    func testDestinationDirectoryPrefersSelectedFolderOverTargetedParent() {
        let selectedFolder = URL(fileURLWithPath: "/Users/example/Project", isDirectory: true)
        let targetedParent = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            FileActions.destinationDirectory(selectedURLs: [selectedFolder], targetedURL: targetedParent),
            selectedFolder
        )
    }

    func testDestinationDirectoryUsesParentForSelectedFile() {
        let selectedFile = URL(fileURLWithPath: "/Users/example/Project/readme.md")
        let targetedParent = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            FileActions.destinationDirectory(selectedURLs: [selectedFile], targetedURL: targetedParent),
            URL(fileURLWithPath: "/Users/example/Project", isDirectory: true)
        )
    }

    func testHashes() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("hash.txt")
        try Data("hello".utf8).write(to: file)

        XCTAssertEqual(try FileHasher.hash(fileAt: file, algorithm: .sha256), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try FileHasher.hash(fileAt: file, algorithm: .sha1), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        XCTAssertEqual(try FileHasher.hash(fileAt: file, algorithm: .md5), "5d41402abc4b2a76b9719d911017c592")
    }

    func testHashResultReportsFailuresSeparatelyFromPasteboardText() throws {
        let missing = URL(fileURLWithPath: "/Users/example/Definitely Missing.txt")

        let result = FileHasher.hashResult(for: [missing], algorithm: .md5)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failures, ["Definitely Missing.txt"])
        XCTAssertTrue(result.text.contains("ERROR"))
    }

    func testDefaultTemplatesAreValid() {
        XCTAssertFalse(FileTemplate.defaults.isEmpty)
        for template in FileTemplate.defaults {
            XCTAssertFalse(template.id.isEmpty)
            XCTAssertFalse(template.displayName.isEmpty)
            XCTAssertFalse(template.localizedDisplayName.isEmpty)
            XCTAssertFalse(template.fileExtension.contains("."))
            XCTAssertTrue(template.filename.hasSuffix(".\(template.fileExtension)"))
        }
    }

    func testFinderCommandTokenParsing() {
        XCTAssertEqual(FinderCommandToken(rawValue: "command:copyPOSIXPath"), .command(.copyPOSIXPath))
        XCTAssertEqual(FinderCommandToken(rawValue: "template:md"), .template("md"))
        XCTAssertEqual(FinderCommandToken(rawValue: "pinned:/Applications/Test.app"), .pinnedApplication("/Applications/Test.app"))
        XCTAssertNil(FinderCommandToken(rawValue: "command:missing"))
        XCTAssertNil(FinderCommandToken(rawValue: "bogus:value"))
    }

    func testMenuCommandGroupsMapCommandsToSubmenus() {
        XCTAssertEqual(MenuCommandGroup.group(for: .newFile), .newFile)
        XCTAssertEqual(MenuCommandGroup.group(for: .copyFileURL), .copy)
        XCTAssertEqual(MenuCommandGroup.group(for: .openVSCode), .openHere)
        XCTAssertEqual(MenuCommandGroup.group(for: .md5), .hash)
        XCTAssertEqual(MenuCommandGroup.group(for: .compress), .fileUtilities)
        XCTAssertEqual(MenuCommandGroup.group(for: .metadata), .advanced)
        XCTAssertEqual(MenuCommandGroup.copy.titleKey, "menu.copy")
        XCTAssertEqual(MenuCommandGroup.openHere.commands, [.openTerminal, .openITerm, .openVSCode, .openCursor, .openBBEdit, .openSublime])
    }

    func testMenuCommandGroupsExposeIconSymbols() {
        for group in MenuCommandGroup.allCases {
            XCTAssertFalse(group.symbolName.isEmpty, group.rawValue)
        }
    }

    func testMenuCommandsExposeIconSymbols() {
        for command in MenuCommand.allCases {
            XCTAssertFalse(command.symbolName.isEmpty, command.rawValue)
        }
    }

    func testOpenApplicationCommandsExposeStableBundleIdentifiers() {
        let expected: [MenuCommand: String] = [
            .openTerminal: "com.apple.Terminal",
            .openITerm: "com.googlecode.iterm2",
            .openVSCode: "com.microsoft.VSCode",
            .openCursor: "com.todesktop.230313mzl4w4u92",
            .openBBEdit: "com.barebones.bbedit",
            .openSublime: "com.sublimetext.4"
        ]

        XCTAssertEqual(Set(expected.values), Set(AppDetector.defaultApplicationOrder))
        for (command, bundleIdentifier) in expected {
            XCTAssertEqual(command.applicationBundleIdentifier, bundleIdentifier)
            XCTAssertEqual(MenuCommand.openApplicationCommand(forBundleIdentifier: bundleIdentifier), command)
        }
    }

    func testLocalizationKeysExistForCommandsAndTemplates() {
        for command in MenuCommand.allCases {
            XCTAssertTrue(L10n.allKnownKeys.contains(command.titleKey), command.titleKey)
            XCTAssertFalse(command.title.isEmpty)
        }
        for language in AppLanguage.allCases {
            XCTAssertTrue(L10n.allKnownKeys.contains(language.titleKey), language.titleKey)
        }
        for template in FileTemplate.defaults {
            let key = "template.\(template.id)"
            XCTAssertTrue(L10n.allKnownKeys.contains(key), key)
        }
        for key in [
            "tab.layout",
            "layout.title",
            "layout.description",
            "layout.foldIntoApp",
            "layout.statusFolded",
            "layout.statusTopLevel",
            "layout.topLevelShortcut",
            "menu.newFileShortcut",
            "permissions.openFullDiskAccess",
            "permissions.fullDiskAccessGranted",
            "permissions.fullDiskAccessMissing",
            "permissions.fullDiskAccessDescription",
            "permissions.fullDiskAccessManualAdd",
            "permissions.fullDiskAccessRestartRequired",
            "permissions.fullDiskAccessApplying",
            "permissions.fullDiskAccessApplied",
            "permissions.fullDiskAccessAppliedDetail",
            "permissions.fullDiskAccessApplyFailed",
            "permissions.fullDiskAccessSystemManaged",
            "permissions.fullDiskAccessExtensionNotReporting",
            "permissions.fullDiskAccessExtensionRunning",
            "permissions.finderPolicyUpdateRequired",
            "permissions.finderPolicyReloading",
            "permissions.finderPolicyReloadFailed",
            "permissions.finderPolicyReloadTimedOut",
            "permissions.finderRuntimeUnavailableStatus",
            "permissions.sharedContainerUnavailable",
            "permissions.finderMonitoringMigration",
            "permissions.completeGuide",
            "permissions.stepInstallTitle",
            "permissions.stepInstallDescription",
            "permissions.installedInApplications",
            "permissions.notInApplications",
            "permissions.stepLaunchAtLoginTitle",
            "permissions.launchAtLoginDescription",
            "permissions.launchAtLoginToggle",
            "permissions.launchAtLoginEnabled",
            "permissions.launchAtLoginDisabled",
            "permissions.launchAtLoginRequiresApproval",
            "permissions.launchAtLoginUnavailable",
            "permissions.launchAtLoginUpdateFailed",
            "permissions.openLoginItems",
            "permissions.stepExtensionTitle",
            "permissions.stepExtensionDescription",
            "permissions.extensionEnabled",
            "permissions.extensionDisabled",
            "permissions.extensionNotRegistered",
            "permissions.extensionUnknown",
            "permissions.extensionEnabledHint",
            "permissions.stepDiskAccessTitle",
            "permissions.stepManualFoldersTitle",
            "permissions.manualFoldersDescription",
            "permissions.manualFoldersStatus",
            "permissions.removeFolder",
            "notification.permissionRequired"
        ] {
            XCTAssertTrue(L10n.allKnownKeys.contains(key), key)
        }
    }

    func testLocalizationUsesExplicitLanguage() {
        XCTAssertEqual(L10n.string("tab.permissions", language: .english), "Permissions")
        XCTAssertEqual(L10n.string("tab.permissions", language: .simplifiedChinese), "权限")
        XCTAssertEqual(L10n.string("app.name", language: .english), "ClickMate")
        XCTAssertEqual(L10n.string("app.name", language: .simplifiedChinese), "右键大师")
        XCTAssertEqual(L10n.string("app.versionWithBuild", language: .english), "Version %@ (%@)")
        XCTAssertEqual(L10n.string("app.versionWithBuild", language: .simplifiedChinese), "版本 %@ (%@)")
    }

    func testAppVersionDisplayUsesBundleVersionMetadata() throws {
        L10n.languageProvider = { .english }
        addTeardownBlock {
            L10n.languageProvider = { .system }
        }

        XCTAssertEqual(
            AppVersion.displayString(bundle: try makeBundle(shortVersion: "1.2.3", build: "45")),
            "Version 1.2.3 (45)"
        )
        XCTAssertEqual(
            AppVersion.displayString(bundle: try makeBundle(shortVersion: "1.2.3", build: "1.2.3")),
            "Version 1.2.3"
        )
        XCTAssertEqual(
            AppVersion.displayString(bundle: try makeBundle(shortVersion: nil, build: "45")),
            "Build 45"
        )
        XCTAssertEqual(
            AppVersion.displayString(bundle: try makeBundle(shortVersion: nil, build: nil)),
            ""
        )
    }

    func testBundleIdentifiersUseZxacnNamespace() {
        XCTAssertEqual(AppConstants.appGroupIdentifier, "group.com.zxacn")
        XCTAssertEqual(AppConstants.bundleIdentifier, "com.zxacn.clickmate")
        XCTAssertEqual(AppConstants.finderExtensionBundleIdentifier, "com.zxacn.clickmate.FinderExtension")
    }

    func testProvisioningProfileMustExplicitlyAuthorizeApplicationGroup() {
        let authorizedProfile: [String: Any] = [
            "Entitlements": [
                "com.apple.security.application-groups": ["group.com.zxacn"]
            ]
        ]
        let wildcardProfile: [String: Any] = [
            "Entitlements": [
                "com.apple.application-identifier": "AA8ZVDT74G.*"
            ]
        ]

        XCTAssertTrue(ApplicationGroupAccessPolicy.profileAuthorizesApplicationGroup(
            "group.com.zxacn",
            propertyList: authorizedProfile
        ))
        XCTAssertFalse(ApplicationGroupAccessPolicy.profileAuthorizesApplicationGroup(
            "group.com.zxacn",
            propertyList: wildcardProfile
        ))
    }

    func testProvisioningProfileIdentityMustMatchSignedBundle() {
        let matchingProfile: [String: Any] = [
            "TeamIdentifier": ["AA8ZVDT74G"],
            "Entitlements": [
                "com.apple.application-identifier": "AA8ZVDT74G.com.zxacn.clickmate",
                "com.apple.developer.team-identifier": "AA8ZVDT74G",
                "com.apple.security.application-groups": ["group.com.zxacn"]
            ]
        ]

        XCTAssertTrue(ApplicationGroupAccessPolicy.profileAuthorizesApplicationGroup(
            "group.com.zxacn",
            bundleIdentifier: "com.zxacn.clickmate",
            teamIdentifier: "AA8ZVDT74G",
            propertyList: matchingProfile
        ))
        XCTAssertFalse(ApplicationGroupAccessPolicy.profileAuthorizesApplicationGroup(
            "group.com.zxacn",
            bundleIdentifier: "com.zxacn.clickmate.FinderExtension",
            teamIdentifier: "AA8ZVDT74G",
            propertyList: matchingProfile
        ))
        XCTAssertFalse(ApplicationGroupAccessPolicy.profileAuthorizesApplicationGroup(
            "group.com.zxacn",
            bundleIdentifier: "com.zxacn.clickmate",
            teamIdentifier: "DIFFERENTTEAM",
            propertyList: matchingProfile
        ))
    }

    func testSharedContainerDoesNotCallProviderWhenApplicationGroupIsUnauthorized() {
        var providerCallCount = 0

        let resolvedURL = ApplicationGroupAccessPolicy.sharedContainerURL(
            groupIdentifier: "group.com.zxacn",
            authorizationProvider: { _, _ in false },
            containerURLProvider: { _ in
                providerCallCount += 1
                return URL(fileURLWithPath: "/should-not-be-used", isDirectory: true)
            }
        )

        XCTAssertNil(resolvedURL)
        XCTAssertEqual(providerCallCount, 0)
    }

    func testSharedContainerCallsProviderAfterApplicationGroupAuthorization() throws {
        let expectedURL = try makeTemporaryDirectory()
        var providerCallCount = 0

        let resolvedURL = ApplicationGroupAccessPolicy.sharedContainerURL(
            groupIdentifier: "group.com.zxacn",
            authorizationProvider: { _, identifier in
                identifier == "group.com.zxacn"
            },
            containerURLProvider: { identifier in
                providerCallCount += 1
                return identifier == "group.com.zxacn" ? expectedURL : nil
            }
        )

        XCTAssertEqual(resolvedURL, expectedURL)
        XCTAssertEqual(providerCallCount, 1)
    }

    func testLocalizationProviderOverridesBundleLanguage() {
        L10n.languageProvider = { .simplifiedChinese }
        addTeardownBlock {
            L10n.languageProvider = { .system }
        }

        XCTAssertEqual(L10n.string("tab.permissions"), "权限")
    }

    func testCustomTemplateDisplayNameFallsBackToStoredName() {
        let template = FileTemplate(id: "custom-log", displayName: "Log File", fileExtension: "log", defaultBasename: "Untitled", contents: "")

        XCTAssertEqual(template.localizedDisplayName, "Log File")
    }

    func testKnownAppDetectionCatalogIncludesExpectedApps() {
        let names = Set(AppDetector.knownApplications.map(\.displayName))
        XCTAssertTrue(names.contains("Terminal"))
        XCTAssertTrue(names.contains("Visual Studio Code"))
        XCTAssertTrue(names.contains("Cursor"))
    }

    func testKnownAppOrderNormalizesCustomApplicationOrder() {
        let order = AppDetector.normalizedApplicationOrder([
            "com.microsoft.VSCode",
            "unknown.bundle",
            "com.apple.Terminal",
            "com.microsoft.VSCode"
        ])

        XCTAssertEqual(Array(order.prefix(3)), [
            "com.microsoft.VSCode",
            "com.apple.Terminal",
            "com.googlecode.iterm2"
        ])
        XCTAssertEqual(Set(order), Set(AppDetector.defaultApplicationOrder))
    }

    func testDefaultMonitoredFoldersExcludeHomeAndUserLibrary() {
        let home = MonitoredFolderPolicy.userHomeDirectory().resolvingSymlinksInPath().path
        let defaults = Set(MonitoredFolderPolicy.defaultMonitoredFolderPaths())

        XCTAssertFalse(defaults.contains(home))
        XCTAssertFalse(defaults.contains { $0 == "\(home)/Library" || $0.hasPrefix("\(home)/Library/") })
        XCTAssertTrue(defaults.contains(URL(fileURLWithPath: home).appendingPathComponent("Desktop").path))
        XCTAssertTrue(defaults.contains(URL(fileURLWithPath: home).appendingPathComponent("Documents").path))
        XCTAssertTrue(defaults.contains(URL(fileURLWithPath: home).appendingPathComponent("Downloads").path))
    }

    func testBootstrapDirectoryURLsExcludeHomeAndUserLibrary() {
        let home = MonitoredFolderPolicy.userHomeDirectory().standardizedFileURL
        let urls = Set(MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap())

        XCTAssertFalse(urls.contains(home))
        XCTAssertFalse(urls.contains { $0.path == home.appendingPathComponent("Library").path })
        XCTAssertTrue(urls.contains(home.appendingPathComponent("Desktop", isDirectory: true)))
        XCTAssertTrue(urls.contains(home.appendingPathComponent("Documents", isDirectory: true)))
        XCTAssertTrue(urls.contains(home.appendingPathComponent("Downloads", isDirectory: true)))
    }

    func testSafeTopLevelDirectoriesIncludeProjectsAndWorkspaceWithoutRecursing() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent("Projects", isDirectory: true)
        let workspace = home.appendingPathComponent("Workspace", isDirectory: true)
        let nestedProject = projects.appendingPathComponent("Client/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let urls = Set(MonitoredFolderPolicy.safeTopLevelDirectoryURLs(in: home))

        XCTAssertTrue(urls.contains(projects))
        XCTAssertTrue(urls.contains(workspace))
        XCTAssertFalse(urls.contains(nestedProject))
        XCTAssertFalse(urls.contains(projects.appendingPathComponent("Client", isDirectory: true)))
    }

    func testSafeTopLevelDirectoriesExcludeHomeLibraryHiddenPackagesAndLibrarySymlinks() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let hidden = home.appendingPathComponent(".Hidden", isDirectory: true)
        let package = home.appendingPathComponent("Example.app", isDirectory: true)
        let libraryLink = home.appendingPathComponent("Library Link", isDirectory: true)
        let currentUserLibrary = MonitoredFolderPolicy.userHomeDirectory()
            .appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: libraryLink, withDestinationURL: currentUserLibrary)

        let urls = Set(MonitoredFolderPolicy.safeTopLevelDirectoryURLs(in: home))
        let paths = Set(urls.map(\.path))

        XCTAssertFalse(paths.contains(home.path))
        XCTAssertFalse(paths.contains(library.path))
        XCTAssertFalse(paths.contains(hidden.path))
        XCTAssertFalse(paths.contains(package.path))
        XCTAssertFalse(paths.contains(libraryLink.path))
        XCTAssertFalse(paths.contains(currentUserLibrary.resolvingSymlinksInPath().path))
    }

    func testSystemPathsAreRejectedFromMonitoring() {
        let result = MonitoredFolderPolicy.acceptedAndRejectedPaths(from: [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/Library")
        ])

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(Set(result.rejected), ["/", "/System", "/Library"])
    }

    func testHomeAndUserLibraryAreRejectedFromMonitoring() {
        let home = MonitoredFolderPolicy.userHomeDirectory().standardizedFileURL
        let userLibrary = home.appendingPathComponent("Library", isDirectory: true)
        let containers = userLibrary.appendingPathComponent("Containers", isDirectory: true)

        let result = MonitoredFolderPolicy.acceptedAndRejectedPaths(from: [home, userLibrary, containers])

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(Set(result.rejected), Set([home.path, userLibrary.path, containers.path]))
    }

    func testNormalizedMonitoringPathsDeduplicateAndResolveSymlink() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appendingPathComponent("Target", isDirectory: true)
        let link = directory.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let paths = MonitoredFolderPolicy.normalizedUserPaths([target.path, link.path, target.path])

        XCTAssertEqual(paths, [target.resolvingSymlinksInPath().path])
    }

    func testFinderMonitoringMigrationRemovesHomeAndLibraryButKeepsProjectFolders() throws {
        let home = MonitoredFolderPolicy.userHomeDirectory().standardizedFileURL
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let project = try makeTemporaryDirectory()
        var preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [home.path, library.path, project.path],
            monitoredFolderBookmarks: [
                home.path: Data("home".utf8),
                library.path: Data("library".utf8),
                project.path: Data("project".utf8)
            ],
            pinnedApplicationPaths: [],
            hasAcknowledgedFinderMonitoringMigration: true,
            finderMonitoringPolicyVersion: 1
        )

        XCTAssertTrue(preferences.migrateFinderMonitoringPolicyIfNeeded())
        XCTAssertEqual(preferences.monitoredFolderPaths, [project.path])
        XCTAssertEqual(Set(preferences.monitoredFolderBookmarks.keys), [project.path])
        XCTAssertFalse(preferences.hasAcknowledgedFinderMonitoringMigration)
        XCTAssertEqual(
            preferences.finderMonitoringPolicyVersion,
            ClickMatePreferences.currentFinderMonitoringPolicyVersion
        )
    }

    func testWideCoverageDoesNotAutomaticallyRegisterMountedVolumeRoots() throws {
        let directory = try makeTemporaryDirectory()
        let volumesRoot = directory.appendingPathComponent("Volumes", isDirectory: true)
        let volume = volumesRoot.appendingPathComponent("External", isDirectory: true)
        let nested = volume.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )

        let urls = MonitoredFolderPolicy.effectiveDirectoryURLs(for: preferences, volumesRoot: volumesRoot)
        let paths = Set(urls.map { $0.path })

        XCTAssertFalse(paths.contains(volume.path))
        XCTAssertFalse(paths.contains(nested.path))
    }

    func testFinderSyncRegistrationUsesChosenRootWithoutEnumeratingDescendants() throws {
        let root = try makeTemporaryDirectory()
        let child = root.appendingPathComponent("Child", isDirectory: true)
        let grandchild = child.appendingPathComponent("Grandchild", isDirectory: true)
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)

        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [root.path],
            monitoredFolderBookmarks: [root.path: Data("bookmark".utf8)],
            pinnedApplicationPaths: []
        )

        let urls = MonitoredFolderPolicy.finderSyncDirectoryURLs(
            for: preferences,
            hasFullDiskAccess: false,
            volumesRoot: URL(fileURLWithPath: "/definitely-missing-volumes", isDirectory: true)
        )
        let paths = Set(urls.map(\.path))

        XCTAssertTrue(paths.contains(root.path))
        XCTAssertFalse(paths.contains(child.path))
        XCTAssertFalse(paths.contains(grandchild.path))
    }

    func testFinderSyncRegistrationDoesNotExpandUnbookmarkedFolderWithoutFullDiskAccess() throws {
        let root = try makeTemporaryDirectory()
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [root.path],
            monitoredFolderBookmarks: [:],
            pinnedApplicationPaths: []
        )

        let urls = MonitoredFolderPolicy.finderSyncDirectoryURLs(
            for: preferences,
            hasFullDiskAccess: false,
            volumesRoot: URL(fileURLWithPath: "/definitely-missing-volumes", isDirectory: true)
        )
        let paths = Set(urls.map(\.path))

        XCTAssertFalse(paths.contains(root.path))
        XCTAssertFalse(paths.contains(child.path))
    }

    func testFinderSyncRegistrationUsesUnbookmarkedRootWithFullDiskAccessWithoutEnumeration() throws {
        let root = try makeTemporaryDirectory()
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [root.path],
            monitoredFolderBookmarks: [:],
            pinnedApplicationPaths: []
        )

        let urls = MonitoredFolderPolicy.finderSyncDirectoryURLs(
            for: preferences,
            hasFullDiskAccess: true,
            volumesRoot: URL(fileURLWithPath: "/definitely-missing-volumes", isDirectory: true)
        )
        let paths = Set(urls.map(\.path))

        XCTAssertTrue(paths.contains(root.path))
        XCTAssertFalse(paths.contains(child.path))
    }

    func testEffectiveMonitoringKeepsSavedPathsWithoutExtensionAccessCheck() throws {
        let inaccessibleFromThisProcess = "/Users/example/Chosen In Finder"
        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [inaccessibleFromThisProcess],
            pinnedApplicationPaths: []
        )

        let urls = MonitoredFolderPolicy.effectiveDirectoryURLs(for: preferences)

        XCTAssertTrue(urls.map(\.path).contains(inaccessibleFromThisProcess))
    }

    func testAddFolderNormalizationStillRejectsMissingPaths() {
        let result = MonitoredFolderPolicy.acceptedAndRejectedPaths(from: [
            URL(fileURLWithPath: "/Users/example/Definitely Missing")
        ])

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, ["/Users/example/Definitely Missing"])
    }

    func testPreferencesJSONRoundTripPreservesMonitoringModeAndFolders() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ClickMatePreferences.json")
        let store = PreferencesStore(fileURL: fileURL)
        let folder = try makeTemporaryDirectory()
        let secondFolder = try makeTemporaryDirectory()
        let templates = [
            FileTemplate(id: "custom-a", displayName: "A", fileExtension: "a", defaultBasename: "Untitled", contents: ""),
            FileTemplate(id: "custom-b", displayName: "B", fileExtension: "b", defaultBasename: "Untitled", contents: "")
        ]

        store.preferences = ClickMatePreferences(
            enabledCommands: [.copyPOSIXPath],
            menuCommandOrder: [.md5, .copyPOSIXPath, .newFile],
            foldedMenuGroups: [.copy, .hash],
            topLevelShortcutCommands: [.copyPOSIXPath, .md5],
            topLevelShortcutTemplateIDs: ["custom-b"],
            removedMenuCommands: [.newFile],
            templates: templates,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [secondFolder.path, folder.path],
            monitoredFolderBookmarks: [folder.path: Data("bookmark".utf8)],
            detectedApplicationOrder: ["com.microsoft.VSCode", "com.apple.Terminal"],
            removedDetectedApplicationBundleIDs: ["com.apple.Terminal"],
            pinnedApplicationPaths: ["/Applications/Zed.app", "/Applications/Test.app"]
        )
        store.waitForPendingSaves()

        let reloaded = PreferencesStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.preferences.monitoringMode, .wideCoverage)
        XCTAssertEqual(Array(reloaded.preferences.menuCommandOrder.prefix(3)), [.md5, .copyPOSIXPath, .newFile])
        XCTAssertEqual(Array(reloaded.preferences.orderedMenuCommands.prefix(3)), [.md5, .copyPOSIXPath, .copyFileURL])
        XCTAssertEqual(reloaded.preferences.enabledMenuCommandsInCustomOrder, [.copyPOSIXPath])
        XCTAssertEqual(reloaded.preferences.foldedMenuGroups, [.copy, .hash])
        XCTAssertEqual(reloaded.preferences.topLevelShortcutCommands, [.copyPOSIXPath, .md5])
        XCTAssertEqual(reloaded.preferences.topLevelShortcutTemplateIDs, ["custom-b"])
        XCTAssertEqual(reloaded.preferences.removedMenuCommands, [.newFile])
        XCTAssertEqual(reloaded.preferences.templates.map(\.id), ["custom-a", "custom-b"])
        XCTAssertEqual(reloaded.preferences.monitoredFolderPaths, [secondFolder.path, folder.path])
        XCTAssertEqual(reloaded.preferences.monitoredFolderBookmarks, [folder.path: Data("bookmark".utf8)])
        XCTAssertEqual(Array(reloaded.preferences.detectedApplicationOrder.prefix(2)), ["com.microsoft.VSCode", "com.apple.Terminal"])
        XCTAssertEqual(reloaded.preferences.orderedDetectedApplicationBundleIDs.first, "com.microsoft.VSCode")
        XCTAssertFalse(reloaded.preferences.orderedDetectedApplicationBundleIDs.contains("com.apple.Terminal"))
        XCTAssertEqual(reloaded.preferences.removedDetectedApplicationBundleIDs, ["com.apple.Terminal"])
        XCTAssertEqual(reloaded.preferences.pinnedApplicationPaths, ["/Applications/Zed.app", "/Applications/Test.app"])
    }

    func testPreferencesJSONRoundTripPreservesPermissionGuideDismissal() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ClickMatePreferences.json")
        let store = PreferencesStore(fileURL: fileURL)

        store.preferences.hasDismissedPermissionGuide = true
        store.waitForPendingSaves()

        let reloaded = PreferencesStore(fileURL: fileURL)

        XCTAssertTrue(reloaded.preferences.hasDismissedPermissionGuide)
    }

    func testPreferencesJSONRoundTripPreservesLanguage() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ClickMatePreferences.json")
        let store = PreferencesStore(fileURL: fileURL)

        store.preferences.language = .simplifiedChinese
        store.waitForPendingSaves()

        let reloaded = PreferencesStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.preferences.language, .simplifiedChinese)
    }

    func testLegacyPreferencesDefaultLanguageAndBookmarks() throws {
        let json = """
        {
          "enabledCommands": ["copyPOSIXPath"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "monitoredFolderPaths": ["/Users/example"],
          "pinnedApplicationPaths": []
        }
        """
        let preferences = try JSONDecoder().decode(ClickMatePreferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.language, .system)
        XCTAssertFalse(preferences.hasDismissedPermissionGuide)
        XCTAssertEqual(preferences.monitoredFolderBookmarks, [:])
        XCTAssertEqual(preferences.monitoredFolderPaths, ["/Users/example"])
        XCTAssertEqual(preferences.menuCommandOrder, MenuCommand.allCases)
        XCTAssertTrue(preferences.foldedMenuGroups.isEmpty)
        XCTAssertTrue(preferences.removedMenuCommands.isEmpty)
        XCTAssertEqual(preferences.detectedApplicationOrder, AppDetector.defaultApplicationOrder)
        XCTAssertTrue(preferences.removedDetectedApplicationBundleIDs.isEmpty)
        XCTAssertTrue(preferences.topLevelShortcutCommands.isEmpty)
        XCTAssertTrue(preferences.topLevelShortcutTemplateIDs.isEmpty)
    }

    func testMenuLayoutDefaultsToTopLevelGroups() throws {
        let preferences = ClickMatePreferences(
            enabledCommands: [.newFile, .copyPOSIXPath, .sha256],
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )

        XCTAssertTrue(preferences.foldedMenuGroups.isEmpty)
        XCTAssertEqual(preferences.menuGroupPlacement.topLevelGroups, [.newFile, .copy, .hash])
        XCTAssertEqual(preferences.menuGroupPlacement.foldedGroups, [])
    }

    func testLegacyAllFoldedMenuLayoutMigratesToTopLevelDefault() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ClickMatePreferences.json")
        let allGroups = MenuCommandGroup.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        let json = """
        {
          "enabledCommands": ["newFile", "copyPOSIXPath", "sha256"],
          "foldedMenuGroups": [\(allGroups)],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "monitoredFolderPaths": [],
          "pinnedApplicationPaths": []
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let store = PreferencesStore(fileURL: fileURL)
        store.waitForPendingSaves()

        XCTAssertTrue(store.preferences.foldedMenuGroups.isEmpty)
        XCTAssertEqual(store.preferences.menuLayoutDefaultsVersion, ClickMatePreferences.currentMenuLayoutDefaultsVersion)

        let reloaded = PreferencesStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.preferences.foldedMenuGroups.isEmpty)
        XCTAssertEqual(reloaded.preferences.menuLayoutDefaultsVersion, ClickMatePreferences.currentMenuLayoutDefaultsVersion)
    }

    func testLegacyCustomFoldedMenuLayoutIsPreservedDuringMigration() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ClickMatePreferences.json")
        let json = """
        {
          "enabledCommands": ["newFile", "copyPOSIXPath", "sha256"],
          "foldedMenuGroups": ["hash"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "monitoredFolderPaths": [],
          "pinnedApplicationPaths": []
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let store = PreferencesStore(fileURL: fileURL)

        XCTAssertEqual(store.preferences.foldedMenuGroups, [.hash])
        XCTAssertEqual(store.preferences.menuLayoutDefaultsVersion, ClickMatePreferences.currentMenuLayoutDefaultsVersion)
    }

    func testMenuLayoutPlacementSplitsTopLevelAndFoldedGroups() throws {
        let preferences = ClickMatePreferences(
            enabledCommands: [.newFile, .copyPOSIXPath, .sha256],
            menuCommandOrder: [.sha256, .copyPOSIXPath, .newFile],
            foldedMenuGroups: [.hash],
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )

        XCTAssertEqual(preferences.orderedVisibleMenuGroups, [.hash, .copy, .newFile])
        XCTAssertEqual(preferences.menuGroupPlacement.topLevelGroups, [.copy, .newFile])
        XCTAssertEqual(preferences.menuGroupPlacement.foldedGroups, [.hash])
    }

    func testMenuLayoutOnlyShowsEnabledCommandGroups() throws {
        let withoutPinned = ClickMatePreferences(
            enabledCommands: [.copyPOSIXPath],
            templates: [],
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )
        let withPinned = ClickMatePreferences(
            enabledCommands: [.copyPOSIXPath],
            templates: [],
            monitoredFolderPaths: [],
            pinnedApplicationPaths: ["/Applications/Test.app"]
        )

        XCTAssertEqual(withoutPinned.orderedVisibleMenuGroups, [.copy])
        XCTAssertEqual(withPinned.orderedVisibleMenuGroups, [.copy])
        XCTAssertFalse(withPinned.menuGroupPlacement.foldedGroups.contains(.openPinned))
        XCTAssertFalse(withPinned.menuGroupPlacement.topLevelGroups.contains(.openPinned))
    }

    func testPreferencesNormalizesMenuCommandOrder() throws {
        let preferences = ClickMatePreferences(
            enabledCommands: [.sha256, .md5, .copyPOSIXPath],
            menuCommandOrder: [.md5, .copyPOSIXPath, .md5],
            templates: [],
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )

        XCTAssertEqual(Array(preferences.menuCommandOrder.prefix(3)), [.md5, .copyPOSIXPath, .newFile])
        XCTAssertEqual(preferences.enabledMenuCommandsInCustomOrder, [.md5, .copyPOSIXPath, .sha256])
    }

    func testMenuLayoutOrdersAndFiltersTopLevelShortcuts() throws {
        let templates = [
            FileTemplate(id: "first", displayName: "First", fileExtension: "one", defaultBasename: "Untitled", contents: ""),
            FileTemplate(id: "second", displayName: "Second", fileExtension: "two", defaultBasename: "Untitled", contents: "")
        ]
        var preferences = ClickMatePreferences(
            enabledCommands: [.newFile, .copyPOSIXPath, .copyFileURL, .sha256, .md5, .openTerminal, .openVSCode],
            menuCommandOrder: [.md5, .copyFileURL, .sha256, .copyPOSIXPath],
            topLevelShortcutCommands: [.md5, .copyPOSIXPath, .copyFileURL, .openTerminal, .openVSCode],
            topLevelShortcutTemplateIDs: ["second", "missing", "first"],
            templates: templates,
            monitoredFolderPaths: [],
            detectedApplicationOrder: ["com.microsoft.VSCode", "com.apple.Terminal"],
            pinnedApplicationPaths: []
        )

        XCTAssertEqual(MenuLayoutPolicy.selectedShortcutCommands(for: .copy, preferences: preferences), [.copyFileURL, .copyPOSIXPath])
        XCTAssertEqual(MenuLayoutPolicy.selectedShortcutCommands(for: .hash, preferences: preferences), [.md5])
        XCTAssertEqual(MenuLayoutPolicy.selectedShortcutCommands(for: .openHere, preferences: preferences), [.openVSCode, .openTerminal])
        XCTAssertEqual(MenuLayoutPolicy.selectedShortcutTemplates(for: preferences).map(\.id), ["first", "second"])

        preferences.enabledCommands.remove(.copyFileURL)
        XCTAssertEqual(MenuLayoutPolicy.selectedShortcutCommands(for: .copy, preferences: preferences), [.copyPOSIXPath])
        XCTAssertTrue(preferences.topLevelShortcutCommands.contains(.copyFileURL))
    }

    func testRemovingShortcutItemsClearsPersistedSelections() throws {
        var preferences = ClickMatePreferences(
            enabledCommands: [.newFile, .copyPOSIXPath],
            topLevelShortcutCommands: [.copyPOSIXPath],
            topLevelShortcutTemplateIDs: ["custom"],
            templates: [
                FileTemplate(id: "custom", displayName: "Custom", fileExtension: "log", defaultBasename: "Untitled", contents: "")
            ],
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )

        preferences.removeMenuCommand(.copyPOSIXPath)
        preferences.removeTemplate(id: "custom")

        XCTAssertFalse(preferences.topLevelShortcutCommands.contains(.copyPOSIXPath))
        XCTAssertFalse(preferences.topLevelShortcutTemplateIDs.contains("custom"))
        XCTAssertTrue(preferences.templates.isEmpty)

        preferences.topLevelShortcutTemplateIDs = ["restored"]
        preferences.removeMenuCommand(.newFile)
        XCTAssertTrue(preferences.topLevelShortcutTemplateIDs.isEmpty)
    }

    func testNewFileShortcutTitleUsesExplicitLanguage() {
        XCTAssertEqual(L10n.string("menu.newFileShortcut", language: .english), "New %@")
        XCTAssertEqual(L10n.string("menu.newFileShortcut", language: .simplifiedChinese), "新建 %@")
    }

    func testRemovedMenuCommandsAreExcludedFromSettingsAndVisibleGroups() throws {
        var preferences = ClickMatePreferences(
            enabledCommands: [.newFile, .copyPOSIXPath, .copyFileURL],
            menuCommandOrder: [.newFile, .copyPOSIXPath, .copyFileURL],
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [],
            pinnedApplicationPaths: []
        )

        preferences.removeMenuCommand(.newFile)
        preferences.removeMenuCommand(.copyPOSIXPath)

        XCTAssertFalse(preferences.orderedMenuCommands.contains(.newFile))
        XCTAssertFalse(preferences.enabledCommands.contains(.newFile))
        XCTAssertEqual(preferences.enabledMenuCommandsInCustomOrder, [.copyFileURL])
        XCTAssertEqual(preferences.orderedVisibleMenuGroups, [.copy])
    }

    func testPreferencesMapsApplicationOrderToEnabledOpenCommands() throws {
        let preferences = ClickMatePreferences(
            enabledCommands: [.openTerminal, .openVSCode, .openCursor],
            templates: [],
            monitoredFolderPaths: [],
            detectedApplicationOrder: [
                "com.todesktop.230313mzl4w4u92",
                "com.microsoft.VSCode",
                "com.apple.Terminal"
            ],
            pinnedApplicationPaths: []
        )

        XCTAssertEqual(preferences.enabledOpenApplicationCommandsInCustomOrder, [.openCursor, .openVSCode, .openTerminal])
    }

    func testRemovedDetectedApplicationsAreExcludedFromOpenCommands() throws {
        var preferences = ClickMatePreferences(
            enabledCommands: [.openTerminal, .openVSCode, .openCursor],
            topLevelShortcutCommands: [.openVSCode],
            templates: [],
            monitoredFolderPaths: [],
            detectedApplicationOrder: [
                "com.todesktop.230313mzl4w4u92",
                "com.microsoft.VSCode",
                "com.apple.Terminal"
            ],
            pinnedApplicationPaths: []
        )

        preferences.removeDetectedApplication(bundleIdentifier: "com.microsoft.VSCode")

        XCTAssertFalse(preferences.orderedDetectedApplicationBundleIDs.contains("com.microsoft.VSCode"))
        XCTAssertFalse(preferences.enabledCommands.contains(.openVSCode))
        XCTAssertFalse(preferences.topLevelShortcutCommands.contains(.openVSCode))
        XCTAssertEqual(preferences.enabledOpenApplicationCommandsInCustomOrder, [.openCursor, .openTerminal])
    }

    func testRestoreRemovedDefaultsRestoresHiddenDefaultsAndMissingTemplates() throws {
        var preferences = ClickMatePreferences(
            enabledCommands: [.copyPOSIXPath],
            removedMenuCommands: [.newFile],
            templates: [
                FileTemplate(id: "custom-log", displayName: "Log", fileExtension: "log", defaultBasename: "Untitled", contents: "")
            ],
            monitoredFolderPaths: [],
            removedDetectedApplicationBundleIDs: ["com.apple.Terminal"],
            pinnedApplicationPaths: []
        )

        preferences.restoreRemovedDefaults()

        XCTAssertTrue(preferences.removedMenuCommands.isEmpty)
        XCTAssertTrue(preferences.removedDetectedApplicationBundleIDs.isEmpty)
        XCTAssertTrue(preferences.orderedMenuCommands.contains(.newFile))
        XCTAssertEqual(preferences.templates.first?.id, "custom-log")
        for template in FileTemplate.defaults {
            XCTAssertTrue(preferences.templates.contains { $0.id == template.id }, template.id)
        }
    }

    func testLegacyPreferencesWithoutFoldersKeepsSelectionEmpty() throws {
        let json = """
        {
          "enabledCommands": ["copyPOSIXPath"],
          "templates": [],
          "monitoringMode": "wideCoverage",
          "pinnedApplicationPaths": []
        }
        """
        let preferences = try JSONDecoder().decode(ClickMatePreferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.monitoredFolderPaths, [])
    }

    func testFinderExtensionStatusParsesPlugInKitOutput() {
        XCTAssertEqual(
            FinderExtensionPolicy.status(fromPlugInKitOutput: "+    com.zxacn.clickmate.FinderExtension(1) /Applications/ClickMate.app"),
            .enabled
        )
        XCTAssertEqual(
            FinderExtensionPolicy.status(fromPlugInKitOutput: "-    com.zxacn.clickmate.FinderExtension(1) /Applications/ClickMate.app"),
            .disabled
        )
        XCTAssertEqual(
            FinderExtensionPolicy.status(fromPlugInKitOutput: "\n"),
            .notRegistered
        )
        XCTAssertEqual(
            FinderExtensionPolicy.status(fromPlugInKitOutput: "?    com.zxacn.clickmate.FinderExtension(1) /Applications/ClickMate.app"),
            .unknown
        )
    }

    func testManualFinderExtensionReloadCompletesFromPlugInKitStatusWithoutRuntimeSnapshot() async throws {
        let appURL = try makeTemporaryDirectory().appendingPathComponent("ClickMate.app", isDirectory: true)
        let extensionURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("ClickMateFinderExtension.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)

        var invocations: [[String]] = []
        let status = await FinderExtensionPolicy.reloadBundledExtension(appBundleURL: appURL) { _, arguments in
            invocations.append(arguments)
            if arguments.first == "-m" {
                return (0, "+    com.zxacn.clickmate.FinderExtension(1) /Applications/ClickMate.app")
            }
            return (0, "")
        }

        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(invocations, [
            ["-a", extensionURL.path],
            ["-e", "use", "-p", "com.apple.FinderSync", "-i", "com.zxacn.clickmate.FinderExtension"],
            ["-m", "-p", "com.apple.FinderSync", "-i", "com.zxacn.clickmate.FinderExtension"]
        ])
    }

    func testPendingCopyHashCommandRoundTrips() throws {
        let file = URL(fileURLWithPath: "/Users/example/Untitled.txt")
        let command = PendingCommand.copyHash(algorithm: .md5, urls: [file])

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.kind, .copyHash)
        XCTAssertEqual(decoded.hashAlgorithm, .md5)
        XCTAssertEqual(decoded.urls, [file])
    }

    func testPendingOpenHereCommandRoundTrips() throws {
        let directory = URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
        let command = PendingCommand.openHere(command: .openTerminal, directoryURL: directory)

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.kind, .openHere)
        XCTAssertEqual(decoded.menuCommand, .openTerminal)
        XCTAssertEqual(decoded.directoryURL, directory)
    }

    func testPendingOpenApplicationCommandRoundTrips() throws {
        let file = URL(fileURLWithPath: "/Users/example/Project/readme.md")
        let command = PendingCommand.openApplication(command: .openVSCode, urls: [file])

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.kind, .openApplication)
        XCTAssertEqual(decoded.menuCommand, .openVSCode)
        XCTAssertEqual(decoded.urls, [file])
    }

    func testPendingPinnedApplicationCommandRoundTrips() throws {
        let file = URL(fileURLWithPath: "/Users/example/Project/readme.md")
        let command = PendingCommand.openPinnedApplication(path: "/Applications/Test.app", urls: [file])

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.kind, .openApplication)
        XCTAssertEqual(decoded.applicationPath, "/Applications/Test.app")
        XCTAssertEqual(decoded.urls, [file])
    }

    func testPendingCompressCommandRoundTrips() throws {
        let file = URL(fileURLWithPath: "/Users/example/Project/archive-me.txt")
        let command = PendingCommand.compress(urls: [file])

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.kind, .compress)
        XCTAssertEqual(decoded.urls, [file])
    }

    func testPendingToggleHiddenFilesCommandRoundTrips() throws {
        let command = PendingCommand.toggleHiddenFiles()

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: JSONEncoder().encode(command))

        XCTAssertEqual(decoded.kind, .toggleHiddenFiles)
        XCTAssertTrue(decoded.urls.isEmpty)
    }

    func testLegacyPendingCreateFileCommandDecodesWithoutURLList() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "kind": "createFile",
          "templateID": "txt",
          "directoryURL": "file:///Users/example/Desktop/"
        }
        """

        let decoded = try JSONDecoder().decode(PendingCommand.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.kind, .createFile)
        XCTAssertEqual(decoded.templateID, "txt")
        XCTAssertEqual(decoded.urls, [])
        XCTAssertNil(decoded.hashAlgorithm)
        XCTAssertNil(decoded.menuCommand)
        XCTAssertNil(decoded.applicationPath)
    }

    func testSecurityScopedAccessMatchesNearestAuthorizedParent() throws {
        let root = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let nested = project.appendingPathComponent("Nested", isDirectory: true)
        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [root.path, project.path],
            monitoredFolderBookmarks: [
                root.path: Data("root".utf8),
                project.path: Data("project".utf8)
            ],
            pinnedApplicationPaths: []
        )

        XCTAssertEqual(
            SecurityScopedFolderAccess.authorizedBookmarkPath(containing: nested, preferences: preferences),
            project.path
        )
    }

    func testSecurityScopedAccessReturnsNilWhenTargetIsOutsideAuthorizedFolders() {
        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoredFolderPaths: ["/Users/example"],
            monitoredFolderBookmarks: ["/Users/example": Data("bookmark".utf8)],
            pinnedApplicationPaths: []
        )

        XCTAssertNil(
            SecurityScopedFolderAccess.authorizedBookmarkPath(
                containing: URL(fileURLWithPath: "/Users/other/Desktop", isDirectory: true),
                preferences: preferences
            )
        )
    }

    func testDiskAccessPolicyUsesDirectAccessWhenFullDiskAccessIsGranted() throws {
        let directory = try makeTemporaryDirectory()
        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [],
            monitoredFolderBookmarks: [:],
            pinnedApplicationPaths: []
        )

        let access = DiskAccessPolicy.scopedOrDirectAccess(
            containing: directory,
            preferences: preferences,
            hasFullDiskAccess: true
        )

        XCTAssertEqual(access?.resolvedURL(for: directory), directory)
        access?.stopAccessing()
    }

    func testDiskAccessPolicyRequiresBookmarkWhenFullDiskAccessIsMissing() throws {
        let directory = try makeTemporaryDirectory()
        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [directory.path],
            monitoredFolderBookmarks: [:],
            pinnedApplicationPaths: []
        )

        let access = DiskAccessPolicy.scopedOrDirectAccess(
            containing: directory,
            preferences: preferences,
            hasFullDiskAccess: false
        )

        XCTAssertNil(access)
    }

    func testDiskAccessPolicyAttemptsDirectAccessOnlyForUserInitiatedOperations() throws {
        let directory = try makeTemporaryDirectory()
        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoredFolderPaths: [],
            monitoredFolderBookmarks: [:],
            pinnedApplicationPaths: []
        )

        let access = DiskAccessPolicy.scopedOrDirectAccess(
            containing: directory,
            preferences: preferences
        )

        XCTAssertEqual(access?.resolvedURL(for: directory), directory)
        access?.stopAccessing()
    }

    func testDiskAccessStatusPrefersAccessibleProtectedProbe() {
        let probes = [URL(fileURLWithPath: "/one"), URL(fileURLWithPath: "/two")]
        let status = DiskAccessPolicy.status(probes: probes) { url in
            url.path == "/two" ? .accessible : .permissionDenied
        }

        XCTAssertEqual(status, .granted)
    }

    func testDiskAccessStatusDoesNotProbeProtectedAppDataAutomatically() {
        XCTAssertEqual(DiskAccessPolicy.status(), .unknown)
        XCTAssertFalse(DiskAccessPolicy.hasFullDiskAccess())
    }

    func testDiskAccessStatusDistinguishesDeniedUnavailableAndUnknown() {
        let probe = URL(fileURLWithPath: "/probe")

        XCTAssertEqual(DiskAccessPolicy.status(probes: [probe]) { _ in .permissionDenied }, .denied)
        XCTAssertEqual(DiskAccessPolicy.status(probes: [probe]) { _ in .unavailable }, .unavailable)
        XCTAssertEqual(DiskAccessPolicy.status(probes: [probe]) { _ in .unknown }, .unknown)
    }

    func testFinderExtensionRuntimeSnapshotRoundTrips() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("finder-runtime.json")
        let store = FinderExtensionRuntimeSnapshotStore(fileURL: fileURL)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = FinderExtensionRuntimeSnapshot(
            pid: 42,
            version: "1.0 (1)",
            updatedAt: updatedAt,
            diskAccessStatus: .unknown,
            lastAccessResult: .permissionDenied,
            lastAccessAt: updatedAt
        )

        XCTAssertTrue(store.write(snapshot))
        XCTAssertEqual(store.load(), snapshot)
        XCTAssertEqual(
            snapshot.monitoringPolicyVersion,
            FinderExtensionRuntimeSnapshot.currentMonitoringPolicyVersion
        )
    }

    func testFinderExtensionRuntimeSnapshotStoreRequiresSharedLocation() {
        let store = FinderExtensionRuntimeSnapshotStore(fileURL: nil)
        let snapshot = FinderExtensionRuntimeSnapshot(
            pid: 42,
            version: "1.3.2 (7)",
            diskAccessStatus: .unknown
        )

        XCTAssertFalse(store.write(snapshot))
        XCTAssertNil(store.load())
        store.remove()
    }

    func testFinderExtensionRuntimeSnapshotPolicyRequiresReloadedRunningProcess() {
        let reloadStartedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let referenceDate = reloadStartedAt.addingTimeInterval(1)
        let snapshot = FinderExtensionRuntimeSnapshot(
            pid: 84,
            version: "1.3.2 (7)",
            updatedAt: reloadStartedAt.addingTimeInterval(0.5),
            diskAccessStatus: .unknown
        )
        let accepts: (FinderExtensionRuntimeSnapshot) -> Bool = { candidate in
            FinderExtensionRuntimeSnapshotPolicy.accepts(
                candidate,
                currentVersion: "1.3.2 (7)",
                previousPID: 42,
                updatedAfter: reloadStartedAt,
                referenceDate: referenceDate,
                isExpectedRunningProcess: { $0 == 84 }
            )
        }

        XCTAssertTrue(accepts(snapshot))

        var previousProcess = snapshot
        previousProcess.pid = 42
        XCTAssertFalse(accepts(previousProcess))

        var snapshotBeforeReload = snapshot
        snapshotBeforeReload.updatedAt = reloadStartedAt.addingTimeInterval(-0.001)
        XCTAssertFalse(accepts(snapshotBeforeReload))

        var wrongVersion = snapshot
        wrongVersion.version = "1.3.2 (6)"
        XCTAssertFalse(accepts(wrongVersion))

        var wrongPolicy = snapshot
        wrongPolicy.monitoringPolicyVersion = FinderExtensionRuntimeSnapshot.currentMonitoringPolicyVersion - 1
        XCTAssertFalse(accepts(wrongPolicy))

        XCTAssertFalse(FinderExtensionRuntimeSnapshotPolicy.accepts(
            snapshot,
            currentVersion: "1.3.2 (7)",
            previousPID: 42,
            updatedAfter: reloadStartedAt,
            referenceDate: referenceDate,
            isExpectedRunningProcess: { _ in false }
        ))
    }

    func testFinderExtensionRuntimeSnapshotPolicyDoesNotExpireAStillRunningProcessByAge() {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = FinderExtensionRuntimeSnapshot(
            pid: 42,
            version: "1.3.2 (7)",
            updatedAt: updatedAt,
            diskAccessStatus: .unknown
        )

        XCTAssertTrue(FinderExtensionRuntimeSnapshotPolicy.accepts(
            snapshot,
            currentVersion: "1.3.2 (7)",
            updatedAfter: updatedAt,
            referenceDate: updatedAt.addingTimeInterval(86_400),
            isExpectedRunningProcess: { $0 == 42 }
        ))
    }

    func testFinderExtensionRuntimeSnapshotDecodesLegacyHeartbeat() throws {
        let json = """
        {
          "pid": 42,
          "version": "1.3.2 (5)",
          "updatedAt": 1000,
          "diskAccessStatus": "unknown",
          "monitoringPolicyVersion": 3
        }
        """

        let snapshot = try JSONDecoder().decode(
            FinderExtensionRuntimeSnapshot.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(snapshot.lastAccessResult)
        XCTAssertNil(snapshot.lastAccessAt)
    }

    func testFullDiskAccessRecoveryStorePersistsSingleRelaunchAndReload() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("full-disk-access.json")
        let store = FullDiskAccessRecoveryStore(fileURL: fileURL)
        var request = FullDiskAccessRecoveryRequest(
            id: UUID(),
            settingsOpenedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            previousApplicationPID: 42,
            previousFinderExtensionPID: 84
        )

        XCTAssertTrue(store.write(request))
        XCTAssertEqual(store.load(), request)
        XCTAssertTrue(request.markRelaunchScheduled())
        XCTAssertFalse(request.markRelaunchScheduled())
        XCTAssertFalse(request.markExtensionReloadStarted(currentApplicationPID: 42))
        XCTAssertTrue(request.markExtensionReloadStarted(currentApplicationPID: 43))
        XCTAssertFalse(request.markExtensionReloadStarted(currentApplicationPID: 44))
        XCTAssertTrue(store.write(request))
        XCTAssertEqual(store.load(), request)

        store.remove()
        XCTAssertNil(store.load())
    }

    func testLegacyFullDiskAccessRecoveryStopsRepeatedAutomaticRecovery() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "settingsOpenedAt": 1000,
          "didAttemptProcessRefresh": true
        }
        """

        let request = try JSONDecoder().decode(
            FullDiskAccessRecoveryRequest.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(request.phase, .failed)
        XCTAssertNil(request.previousApplicationPID)
        XCTAssertNil(request.previousFinderExtensionPID)
    }

    func testReadOnlyPreferencesStoreDoesNotCreateOrMigrateSharedFile() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("ClickMatePreferences.json")
        var legacyPreferences = ClickMatePreferences.defaults
        legacyPreferences.monitoredFolderPaths = [MonitoredFolderPolicy.userHomeDirectory().path]
        legacyPreferences.finderMonitoringPolicyVersion = 1
        let originalData = try JSONEncoder().encode(legacyPreferences)
        try originalData.write(to: fileURL)

        let store = PreferencesStore(fileURL: fileURL, allowsWrites: false)
        store.waitForPendingSaves()

        XCTAssertEqual(store.preferences.monitoredFolderPaths, [])
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testLegacyFinderExtensionRuntimeSnapshotDecodesWithoutPolicyVersion() throws {
        let json = """
        {
          "pid": 42,
          "version": "1.3.2 (1)",
          "updatedAt": 1000,
          "diskAccessStatus": "unknown"
        }
        """

        let snapshot = try JSONDecoder().decode(
            FinderExtensionRuntimeSnapshot.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(snapshot.monitoringPolicyVersion)
    }

    func testFinderExtensionPolicyRecoveryRunsAutomaticallyAtMostOnce() {
        var tracker = FinderExtensionPolicyRecoveryTracker()

        XCTAssertTrue(tracker.begin(isAutomatic: true))
        XCTAssertFalse(tracker.begin(isAutomatic: true))
        XCTAssertTrue(tracker.begin(isAutomatic: false))
        XCTAssertTrue(tracker.begin(isAutomatic: false))
    }

    func testScopedAccessToCurrentProcessURLIsSafeForPlainLocalFolder() throws {
        let directory = try makeTemporaryDirectory()

        let access = SecurityScopedFolderAccess.scopedAccess(toCurrentProcessURL: directory)

        access?.stopAccessing()
    }

    func testPreferencesStoreCreatesDefaultsFileOnInit() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("ClickMatePreferences.json")
        let store = PreferencesStore(fileURL: fileURL)

        store.waitForPendingSaves()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testPinnedApplicationSyncRejectsInvalidPathsAndCachesPublishedSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        let applicationURL = try makeApplicationBundle(in: directory, name: "Pinned")
        let invalidDirectory = directory.appendingPathComponent("NotAnApplication", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let missingApplicationURL = directory.appendingPathComponent("Missing.app", isDirectory: true)
        let cacheFileURL = directory.appendingPathComponent("PinnedApplicationSync.json")
        let pasteboardName = NSPasteboard.Name("com.zxacn.clickmate.tests.\(UUID().uuidString)")
        NSPasteboard(name: pasteboardName).clearContents()

        XCTAssertTrue(PinnedApplicationSyncStore.publish(
            paths: [
                applicationURL.path,
                invalidDirectory.path,
                missingApplicationURL.path,
                applicationURL.path
            ],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            pasteboardName: pasteboardName
        ))

        XCTAssertEqual(
            PinnedApplicationSyncStore.synchronizedPaths(
                cacheFileURL: cacheFileURL,
                pasteboardName: pasteboardName
            ),
            [applicationURL.path]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFileURL.path))

        NSPasteboard(name: pasteboardName).clearContents()
        XCTAssertEqual(
            PinnedApplicationSyncStore.synchronizedPaths(
                cacheFileURL: cacheFileURL,
                pasteboardName: pasteboardName
            ),
            [applicationURL.path]
        )
    }

    func testPinnedApplicationSyncPropagatesRemovalOfAllPinnedApplications() throws {
        let directory = try makeTemporaryDirectory()
        let applicationURL = try makeApplicationBundle(in: directory, name: "Pinned")
        let cacheFileURL = directory.appendingPathComponent("PinnedApplicationSync.json")
        let pasteboardName = NSPasteboard.Name("com.zxacn.clickmate.tests.\(UUID().uuidString)")
        NSPasteboard(name: pasteboardName).clearContents()

        XCTAssertTrue(PinnedApplicationSyncStore.publish(
            paths: [applicationURL.path],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            pasteboardName: pasteboardName
        ))
        XCTAssertEqual(
            PinnedApplicationSyncStore.synchronizedPaths(
                cacheFileURL: cacheFileURL,
                pasteboardName: pasteboardName
            ),
            [applicationURL.path]
        )

        XCTAssertTrue(PinnedApplicationSyncStore.publish(
            paths: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            pasteboardName: pasteboardName
        ))
        XCTAssertEqual(
            PinnedApplicationSyncStore.synchronizedPaths(
                cacheFileURL: cacheFileURL,
                pasteboardName: pasteboardName
            ),
            []
        )
    }

    func testPinnedApplicationSyncPrefersNewerPublishedSnapshotOverCache() throws {
        let directory = try makeTemporaryDirectory()
        let oldApplicationURL = try makeApplicationBundle(in: directory, name: "OldPinned")
        let newApplicationURL = try makeApplicationBundle(in: directory, name: "NewPinned")
        let cacheFileURL = directory.appendingPathComponent("PinnedApplicationSync.json")
        let pasteboardName = NSPasteboard.Name("com.zxacn.clickmate.tests.\(UUID().uuidString)")
        NSPasteboard(name: pasteboardName).clearContents()
        let oldSnapshot = PinnedApplicationSyncSnapshot(
            paths: [oldApplicationURL.path],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try JSONEncoder().encode(oldSnapshot).write(to: cacheFileURL)

        XCTAssertTrue(PinnedApplicationSyncStore.publish(
            paths: [newApplicationURL.path],
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            pasteboardName: pasteboardName
        ))

        XCTAssertEqual(
            PinnedApplicationSyncStore.synchronizedPaths(
                cacheFileURL: cacheFileURL,
                pasteboardName: pasteboardName
            ),
            [newApplicationURL.path]
        )
        let cachedSnapshot = try JSONDecoder().decode(
            PinnedApplicationSyncSnapshot.self,
            from: Data(contentsOf: cacheFileURL)
        )
        XCTAssertEqual(cachedSnapshot.paths, [newApplicationURL.path])
    }

    func testPinnedApplicationSyncPrefersPublishedSnapshotWhenTimestampsMatch() throws {
        let directory = try makeTemporaryDirectory()
        let cachedApplicationURL = try makeApplicationBundle(in: directory, name: "CachedPinned")
        let publishedApplicationURL = try makeApplicationBundle(in: directory, name: "PublishedPinned")
        let cacheFileURL = directory.appendingPathComponent("PinnedApplicationSync.json")
        let pasteboardName = NSPasteboard.Name("com.zxacn.clickmate.tests.\(UUID().uuidString)")
        NSPasteboard(name: pasteboardName).clearContents()
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000)
        let cachedSnapshot = PinnedApplicationSyncSnapshot(
            paths: [cachedApplicationURL.path],
            updatedAt: timestamp
        )
        try JSONEncoder().encode(cachedSnapshot).write(to: cacheFileURL)

        XCTAssertTrue(PinnedApplicationSyncStore.publish(
            paths: [publishedApplicationURL.path],
            updatedAt: timestamp,
            pasteboardName: pasteboardName
        ))

        XCTAssertEqual(
            PinnedApplicationSyncStore.synchronizedPaths(
                cacheFileURL: cacheFileURL,
                pasteboardName: pasteboardName
            ),
            [publishedApplicationURL.path]
        )
    }

    func testApplicationOpenRouteRoundTripsPinnedApplicationAndProjectURL() throws {
        let directory = try makeTemporaryDirectory()
        let applicationURL = try makeApplicationBundle(in: directory, name: "Pinned")
        let projectURL = directory.appendingPathComponent("项目 Private", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let url = try XCTUnwrap(ApplicationOpenRoute.url(
            pinnedApplicationPath: applicationURL.path,
            urls: [projectURL]
        ))

        let route = try XCTUnwrap(ApplicationOpenRoute(url: url))

        XCTAssertNil(route.command)
        XCTAssertEqual(route.applicationPath, applicationURL.path)
        XCTAssertEqual(route.urls, [projectURL])
    }

    func testApplicationOpenRouteRoundTripsDetectedApplicationCommand() throws {
        let fileURL = URL(fileURLWithPath: "/Users/example/Project/readme.md")
        let url = try XCTUnwrap(ApplicationOpenRoute.url(
            command: .openVSCode,
            urls: [fileURL]
        ))

        let route = try XCTUnwrap(ApplicationOpenRoute(url: url))

        XCTAssertEqual(route.command, .openVSCode)
        XCTAssertNil(route.applicationPath)
        XCTAssertEqual(route.urls, [fileURL])
    }

    func testApplicationOpenRouteRejectsNonFileURLsAndUnpinnedApplications() throws {
        XCTAssertNil(ApplicationOpenRoute.url(
            command: .openVSCode,
            urls: [try XCTUnwrap(URL(string: "https://example.com"))]
        ))

        let directory = try makeTemporaryDirectory()
        let pinnedApplicationURL = try makeApplicationBundle(in: directory, name: "Pinned")
        let otherApplicationURL = try makeApplicationBundle(in: directory, name: "Other")

        XCTAssertTrue(ApplicationOpenRoute.isAuthorizedPinnedApplication(
            path: pinnedApplicationURL.path,
            pinnedApplicationPaths: [pinnedApplicationURL.path]
        ))
        XCTAssertFalse(ApplicationOpenRoute.isAuthorizedPinnedApplication(
            path: otherApplicationURL.path,
            pinnedApplicationPaths: [pinnedApplicationURL.path]
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeBundle(shortVersion: String?, build: String?) throws -> Bundle {
        let bundleURL = try makeTemporaryDirectory().appendingPathComponent("Test.bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": "com.zxacn.clickmate.tests",
            "CFBundlePackageType": "BNDL"
        ]
        if let shortVersion {
            info["CFBundleShortVersionString"] = shortVersion
        }
        if let build {
            info["CFBundleVersion"] = build
        }

        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))

        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func makeApplicationBundle(in directory: URL, name: String) throws -> URL {
        let applicationURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.zxacn.clickmate.tests.\(name.lowercased())",
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return applicationURL
    }
}
