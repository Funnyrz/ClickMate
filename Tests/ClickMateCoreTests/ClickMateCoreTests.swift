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

    func testMenuCommandGroupsExposeExpectedDefaultActions() {
        XCTAssertEqual(MenuCommandGroup.newFile.defaultCommand, .newFile)
        XCTAssertEqual(MenuCommandGroup.copy.defaultCommand, .copyPOSIXPath)
        XCTAssertEqual(MenuCommandGroup.openHere.defaultCommand, .openTerminal)
        XCTAssertNil(MenuCommandGroup.openPinned.defaultCommand)
        XCTAssertEqual(MenuCommandGroup.hash.defaultCommand, .sha256)
        XCTAssertEqual(MenuCommandGroup.fileUtilities.defaultCommand, .revealParent)
        XCTAssertEqual(MenuCommandGroup.advanced.defaultCommand, .metadata)
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
            "permissions.openFullDiskAccess",
            "permissions.fullDiskAccessGranted",
            "permissions.fullDiskAccessMissing",
            "permissions.fullDiskAccessDescription",
            "permissions.fullDiskAccessManualAdd",
            "permissions.completeGuide",
            "permissions.stepInstallTitle",
            "permissions.stepInstallDescription",
            "permissions.installedInApplications",
            "permissions.notInApplications",
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

    func testDefaultMonitoredFoldersIncludeHomeAndCommonFolders() {
        let home = MonitoredFolderPolicy.userHomeDirectory().resolvingSymlinksInPath().path
        let defaults = Set(MonitoredFolderPolicy.defaultMonitoredFolderPaths())

        XCTAssertTrue(defaults.contains(home))
        XCTAssertTrue(defaults.contains(URL(fileURLWithPath: home).appendingPathComponent("Desktop").path))
        XCTAssertTrue(defaults.contains(URL(fileURLWithPath: home).appendingPathComponent("Documents").path))
        XCTAssertTrue(defaults.contains(URL(fileURLWithPath: home).appendingPathComponent("Downloads").path))
    }

    func testBootstrapDirectoryURLsIncludeHomeAndCommonFolders() {
        let home = MonitoredFolderPolicy.userHomeDirectory().standardizedFileURL
        let urls = Set(MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap())

        XCTAssertTrue(urls.contains(home))
        XCTAssertTrue(urls.contains(home.appendingPathComponent("Desktop", isDirectory: true)))
        XCTAssertTrue(urls.contains(home.appendingPathComponent("Documents", isDirectory: true)))
        XCTAssertTrue(urls.contains(home.appendingPathComponent("Downloads", isDirectory: true)))
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

    func testNormalizedMonitoringPathsDeduplicateAndResolveSymlink() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appendingPathComponent("Target", isDirectory: true)
        let link = directory.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let paths = MonitoredFolderPolicy.normalizedUserPaths([target.path, link.path, target.path])

        XCTAssertEqual(paths, [target.resolvingSymlinksInPath().path])
    }

    func testWideCoverageUsesMountedVolumeRootsWithoutRecursing() throws {
        let directory = try makeTemporaryDirectory()
        let volumesRoot = directory.appendingPathComponent("Volumes", isDirectory: true)
        let volume = volumesRoot.appendingPathComponent("External", isDirectory: true)
        let nested = volume.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let preferences = ClickMatePreferences(
            enabledCommands: Set(MenuCommand.allCases),
            templates: FileTemplate.defaults,
            monitoringMode: .wideCoverage,
            monitoredFolderPaths: [volume.path],
            pinnedApplicationPaths: []
        )

        let urls = MonitoredFolderPolicy.effectiveDirectoryURLs(for: preferences, volumesRoot: volumesRoot)
        let paths = Set(urls.map { $0.path })

        XCTAssertTrue(paths.contains(volume.path))
        XCTAssertFalse(paths.contains(nested.path))
    }

    func testFinderSyncRegistrationExpandsChosenFolderDescendants() throws {
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
            volumesRoot: URL(fileURLWithPath: "/definitely-missing-volumes", isDirectory: true),
            maxDepth: 2,
            maxDirectoryCount: 20
        )
        let paths = Set(urls.map(\.path))

        XCTAssertTrue(paths.contains(root.path))
        XCTAssertTrue(paths.contains(child.path))
        XCTAssertTrue(paths.contains(grandchild.path))
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
            volumesRoot: URL(fileURLWithPath: "/definitely-missing-volumes", isDirectory: true),
            maxDepth: 2,
            maxDirectoryCount: 20
        )
        let paths = Set(urls.map(\.path))

        XCTAssertFalse(paths.contains(root.path))
        XCTAssertFalse(paths.contains(child.path))
    }

    func testFinderSyncRegistrationExpandsUnbookmarkedFolderWithFullDiskAccess() throws {
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
            volumesRoot: URL(fileURLWithPath: "/definitely-missing-volumes", isDirectory: true),
            maxDepth: 2,
            maxDirectoryCount: 20
        )
        let paths = Set(urls.map(\.path))

        XCTAssertTrue(paths.contains(root.path))
        XCTAssertTrue(paths.contains(child.path))
    }

    func testFinderSyncRegistrationHonorsDirectoryLimit() throws {
        let root = try makeTemporaryDirectory()
        for index in 0..<10 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Folder\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let urls = MonitoredFolderPolicy.expandedDirectoryURLs(
            from: [root],
            maxDepth: 1,
            maxDirectoryCount: 5
        )

        XCTAssertLessThanOrEqual(urls.count, 5)
        XCTAssertTrue(urls.map(\.path).contains(MonitoredFolderPolicy.canonicalPath(for: root)))
    }

    func testFinderSyncRegistrationSkipsUserLibraryDescendants() throws {
        let root = try makeTemporaryDirectory()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let groupContainer = library.appendingPathComponent("Group Containers", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let nested = documents.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: groupContainer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let urls = MonitoredFolderPolicy.expandedDirectoryURLs(
            from: [root],
            maxDepth: 3,
            maxDirectoryCount: 20
        )
        let paths = Set(urls.map(\.path))

        XCTAssertFalse(paths.contains(MonitoredFolderPolicy.canonicalPath(for: library)))
        XCTAssertFalse(paths.contains(MonitoredFolderPolicy.canonicalPath(for: groupContainer)))
        XCTAssertTrue(paths.contains(MonitoredFolderPolicy.canonicalPath(for: documents)))
        XCTAssertTrue(paths.contains(MonitoredFolderPolicy.canonicalPath(for: nested)))
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

    func testFinderExtensionReloadRegistersAndEnablesBundledExtension() async throws {
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
}
