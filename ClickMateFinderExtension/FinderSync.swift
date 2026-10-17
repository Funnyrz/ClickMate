import Cocoa
import FinderSync
import OSLog

private final class FinderExtensionRuntimeReporter: @unchecked Sendable {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "FinderSync")
    private let queue = DispatchQueue(
        label: "com.zxacn.clickmate.finder-extension-runtime",
        qos: .utility
    )
    private let isAvailable = FinderExtensionRuntimeSnapshotStore.isAvailable
    private var lastAccessResult: FinderExtensionAccessResult?
    private var lastAccessAt: Date?
    private var monitoredDirectoryPaths: [String]?
    private var configurationUpdatedAt: Date?
    private var lastMenuRequestedAt: Date?
    private var unavailableBookmarkPaths: [String]?

    func start() {
        guard isAvailable else {
            logger.notice("Finder extension runtime reporting disabled because the shared App Group container is unavailable")
            return
        }
        queue.async { [weak self] in
            self?.publishSnapshot()
        }
    }

    func recordConfigurationUpdate(directoryURLs: Set<URL>, unavailableBookmarkPaths: [String]) {
        guard isAvailable else { return }
        queue.async { [weak self] in
            guard let self else { return }
            monitoredDirectoryPaths = directoryURLs.map(\.path).sorted()
            configurationUpdatedAt = .now
            self.unavailableBookmarkPaths = unavailableBookmarkPaths
            publishSnapshot()
        }
    }

    func recordMenuRequest() {
        guard isAvailable else { return }
        queue.async { [weak self] in
            guard let self else { return }
            lastMenuRequestedAt = .now
            publishSnapshot()
        }
    }

    func recordUserInitiatedAccess(_ result: FinderExtensionAccessResult) {
        guard isAvailable else { return }
        queue.async { [weak self] in
            guard let self else { return }
            lastAccessResult = result
            lastAccessAt = .now
            publishSnapshot()
        }
    }

    private func publishSnapshot() {
        let snapshot = FinderExtensionRuntimeSnapshot(
            pid: ProcessInfo.processInfo.processIdentifier,
            version: runtimeVersionIdentifier,
            diskAccessStatus: .unknown,
            monitoringPolicyVersion: FinderExtensionRuntimeSnapshot.currentMonitoringPolicyVersion,
            lastAccessResult: lastAccessResult,
            lastAccessAt: lastAccessAt,
            monitoredDirectoryPaths: monitoredDirectoryPaths,
            configurationUpdatedAt: configurationUpdatedAt,
            lastMenuRequestedAt: lastMenuRequestedAt,
            unavailableBookmarkPaths: unavailableBookmarkPaths
        )

        if FinderExtensionRuntimeSnapshotStore.write(snapshot) {
            logger.info(
                "Published Finder extension runtime snapshot pid=\(snapshot.pid, privacy: .public) policy=\(FinderExtensionRuntimeSnapshot.currentMonitoringPolicyVersion, privacy: .public)"
            )
        } else {
            logger.error("Failed to publish Finder extension runtime snapshot")
        }
    }

    private var runtimeVersionIdentifier: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

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

class FinderSync: FIFinderSync {
    // The discovery queue transports this weak reference without accessing it.
    // Its value and all FinderSync state are read only on the main queue.
    private final class MainQueueReference: @unchecked Sendable {
        weak var value: FinderSync?

        init(_ value: FinderSync) {
            self.value = value
        }
    }

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "FinderSync")
    private let menuIconSize = NSSize(width: 16, height: 16)
    private lazy var store = PreferencesStore(allowsWrites: false)
    private var menuActions: [Int: FinderMenuAction] = [:]
    private var menuImageCache: [String: NSImage] = [:]
    private var pendingApplicationIconCacheKeys: Set<String> = []
    private var nextMenuActionTag = 1
    private lazy var runtimeReporter = FinderExtensionRuntimeReporter()
    private lazy var sharedContainerAvailable = ApplicationGroupAccessPolicy.sharedContainerURL() != nil
    private let monitoredFolderAccess = FinderSyncFolderAccess()
    private var discoveredDirectoryURLs: Set<URL> = []
    private var synchronizedDirectoryURLs: Set<URL> = []
    private var appliedDirectoryURLs: Set<URL>?
    private var monitoringGeneration = 0

#if DEBUG
    private var documentationAppearance: MenuIconAppearance?

    /// Native documentation fixtures use an isolated, read-only store and never
    /// install Finder observers or publish extension runtime state.
    init(documentationStore: PreferencesStore) {
        super.init()
        store = documentationStore
        documentationAppearance = .light
        // Use the same SF Symbol fallbacks as a freshly opened production menu,
        // without scheduling lookups of applications installed on this Mac.
        for command in store.preferences.enabledOpenApplicationCommandsInCustomOrder {
            if let identifier = command.applicationBundleIdentifier {
                menuImageCache["bundle:\(identifier)"] = menuSymbolImage(command.symbolName)
            }
        }
        for path in store.preferences.pinnedApplicationPaths {
            menuImageCache["path:\(path)"] = groupIcon(.openPinned)
        }
    }

    func documentationMenu(context: FinderMenuContext) -> NSMenu {
        configuredMenu(context: context)
    }

    func documentationAction(
        for item: NSMenuItem,
        currentSelectedURLs: [URL],
        currentTargetedURL: URL?
    ) -> (token: FinderCommandToken, context: FinderMenuContext)? {
        guard let action = validatedMenuAction(
            for: item,
            currentSelectedURLs: currentSelectedURLs,
            currentTargetedURL: currentTargetedURL
        ) else { return nil }
        return (action.token, action.context)
    }
#endif

    override init() {
        super.init()
        // Install roots before loading shared preferences, probing user folders,
        // or looking up applications; all can be unavailable on first launch.
        applyMonitoredDirectoryURLs(Set(MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap()))
        L10n.languageProvider = { [weak self] in
            self?.store.preferences.language ?? .system
        }
        applyPinnedApplicationFallback()
        observePreferenceChanges()
        refreshMonitoredDirectoriesFromPreferences()
        preloadApplicationIcons()
        runtimeReporter.start()
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(PreferencesChangeNotifier.name as CFString),
            nil
        )
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(FinderFolderSyncStore.notificationName as CFString), nil
        )
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(PinnedApplicationSyncStore.notificationName as CFString),
            nil
        )
    }

    override var toolbarItemName: String {
        L10n.string("app.name")
    }

    override var toolbarItemToolTip: String {
        L10n.string("finder.toolbarTooltip")
    }

    override var toolbarItemImage: NSImage {
        menuSymbolImage("cursorarrow.click") ?? NSImage(named: NSImage.actionTemplateName) ?? NSImage()
    }

    override func beginObservingDirectory(at url: URL) {
        logger.notice("Finder began observing directory=\(url.path, privacy: .private)")
    }

    override func endObservingDirectory(at url: URL) {
    }

    override func requestBadgeIdentifier(for url: URL) {
        FIFinderSyncController.default().setBadgeIdentifier("", for: url)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let start = CFAbsoluteTimeGetCurrent()
        runtimeReporter.recordMenuRequest()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            logger.debug("Built Finder menu in \(elapsed, privacy: .public) ms")
        }

        applyPinnedApplicationFallback()
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        let targetedURL = FIFinderSyncController.default().targetedURL()
        let context = FinderContext(kind: contextKind(for: menuKind), selectedURLs: selectedURLs, targetedURL: targetedURL)
        return configuredMenu(context: context)
    }

    private func configuredMenu(context: FinderContext) -> NSMenu {
        menuActions.removeAll(keepingCapacity: true)

        let rootMenu = NSMenu(title: L10n.string("app.name"))
        appendConfiguredMenuGroups(to: rootMenu, context: context)

        return rootMenu
    }

    private func updateMonitoredDirectories() {
        store.reload()
        applyPinnedApplicationFallback()
        refreshMonitoredDirectoriesFromPreferences()
        preloadApplicationIcons()
    }

    private func applyPinnedApplicationFallback() {
        guard !sharedContainerAvailable,
              let pinnedApplicationPaths = PinnedApplicationSyncStore.synchronizedPaths()
        else {
            return
        }
        var preferences = store.preferences
        preferences.pinnedApplicationPaths = pinnedApplicationPaths
        store.replaceLoadedPreferences(preferences)
    }

    private func refreshMonitoredDirectoriesFromPreferences() {
        monitoringGeneration += 1
        let generation = monitoringGeneration
        monitoredFolderAccess.refresh(preferences: store.preferences)
        if !sharedContainerAvailable {
            synchronizedDirectoryURLs = Set((FinderFolderSyncStore.synchronizedPaths() ?? []).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })
        }
        applyMonitoredDirectoryURLs(monitoredDirectoryURLs())
        // Discovery only expands coverage; failure never removes bootstrap roots.
        let reference = MainQueueReference(self)
        DispatchQueue.global(qos: .utility).async {
            let discovered = Set(MonitoredFolderPolicy.safeTopLevelDirectoryURLs(
                in: MonitoredFolderPolicy.userHomeDirectory()
            ))
            DispatchQueue.main.async {
                guard let finderSync = reference.value,
                      finderSync.monitoringGeneration == generation else { return }
                finderSync.discoveredDirectoryURLs = discovered
                finderSync.applyMonitoredDirectoryURLs(finderSync.monitoredDirectoryURLs())
            }
        }
    }

    private func applyMonitoredDirectoryURLs(_ urls: Set<URL>) {
        guard appliedDirectoryURLs != urls else { return }
        appliedDirectoryURLs = urls
        FIFinderSyncController.default().directoryURLs = Set(urls)
        runtimeReporter.recordConfigurationUpdate(
            directoryURLs: urls,
            unavailableBookmarkPaths: monitoredFolderAccess.unavailableBookmarkPaths
        )
        if !monitoredFolderAccess.unavailableBookmarkPaths.isEmpty {
            logger.error("Some selected folders require reselection because their bookmark or directory access is unavailable")
        }
        logger.info(
            "Monitoring \(urls.count, privacy: .public) safe roots with policy \(FinderExtensionRuntimeSnapshot.currentMonitoringPolicyVersion, privacy: .public), selected=\(self.synchronizedDirectoryURLs.count, privacy: .public)"
        )
    }

    private func monitoredDirectoryURLs() -> Set<URL> {
        Set(MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap())
            .union(monitoredFolderAccess.directoryURLs)
            .union(discoveredDirectoryURLs)
            .union(synchronizedDirectoryURLs)
    }

    private func observePreferenceChanges() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for notificationName in [
            PreferencesChangeNotifier.name,
            PinnedApplicationSyncStore.notificationName,
            FinderFolderSyncStore.notificationName
        ] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let observerAddress = Int(bitPattern: observer)
                    DispatchQueue.main.async {
                        let finderSync = Unmanaged<FinderSync>
                            .fromOpaque(UnsafeRawPointer(bitPattern: observerAddress)!)
                            .takeUnretainedValue()
                        finderSync.updateMonitoredDirectories()
                    }
                },
                notificationName as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func appendNewFileMenu(to menu: NSMenu, context: FinderContext) {
        guard isEnabled(.newFile), context.destinationDirectory != nil else { return }
        let templates = store.preferences.templates
        guard !templates.isEmpty else { return }

        let submenu = NSMenu(title: L10n.string("menu.newFile"))
        for template in templates {
            submenu.addItem(actionItem(
                title: template.localizedDisplayName,
                token: .template(template.id),
                context: context,
                isEnabled: true,
                image: templateIcon()
            ))
        }
        addSubmenu(title: L10n.string("menu.newFile"), submenu: submenu, to: menu, image: groupIcon(.newFile))
    }

    private func appendCopyMenu(to menu: NSMenu, context: FinderContext) {
        let copyCommands = orderedEnabledCommands(from: [
            .copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename,
            .copyBasename, .copyExtension, .copyParentPath
        ])
        appendCommandSubmenu(title: L10n.string("menu.copy"), group: .copy, commands: copyCommands, to: menu, context: context)
    }

    private func appendOpenMenu(to menu: NSMenu, context: FinderContext) {
        let openCommands = store.preferences.enabledOpenApplicationCommandsInCustomOrder
        appendCommandSubmenu(title: L10n.string("menu.openHere"), group: .openHere, commands: openCommands, to: menu, context: context)
    }

    private func appendPinnedMenu(to menu: NSMenu, context: FinderContext) {
        for path in store.preferences.pinnedApplicationPaths {
            menu.addItem(pinnedApplicationItem(path: path, context: context))
        }
    }

    private func appendHashMenu(to menu: NSMenu, context: FinderContext) {
        appendCommandSubmenu(title: L10n.string("menu.hash"), group: .hash, commands: orderedEnabledCommands(from: [.sha256, .sha1, .md5]), to: menu, context: context)
    }

    private func appendUtilitiesMenu(to menu: NSMenu, context: FinderContext) {
        appendCommandSubmenu(
            title: L10n.string("menu.fileUtilities"),
            group: .fileUtilities,
            commands: orderedEnabledCommands(from: [.revealParent, .duplicateTimestamp, .createAlias, .moveToNewFolder, .compress, .editArchive])
                .filter { $0 != .editArchive || archiveEditorURL(in: context) != nil },
            to: menu,
            context: context
        )
    }

    private func appendAdvancedMenu(to menu: NSMenu, context: FinderContext) {
        appendCommandSubmenu(
            title: L10n.string("menu.advanced"),
            group: .advanced,
            commands: orderedEnabledCommands(from: [.metadata, .imageDimensions, .toggleHiddenFiles]),
            to: menu,
            context: context
        )
    }

    private func appendConfiguredMenuGroups(to menu: NSMenu, context: FinderContext) {
        guard store.preferences.finderToolsEnabled else { return }
        let placement = store.preferences.menuGroupPlacement
        let allGroups = store.preferences.orderedVisibleMenuGroups
        var didAddFoldedParent = false

        for group in allGroups {
            if placement.foldedGroups.contains(group) {
                guard !didAddFoldedParent else { continue }
                for foldedGroup in placement.foldedGroups {
                    appendTopLevelShortcuts(for: foldedGroup, to: menu, context: context)
                }
                addClickMateSubmenu(groups: placement.foldedGroups, to: menu, context: context)
                didAddFoldedParent = true
            } else {
                appendTopLevelShortcuts(for: group, to: menu, context: context)
                appendMenuGroup(group, to: menu, context: context)
            }
        }

        appendPinnedMenu(to: menu, context: context)
    }

    private func appendTopLevelShortcuts(for group: MenuCommandGroup, to menu: NSMenu, context: FinderContext) {
        if group == .newFile {
            for template in MenuLayoutPolicy.selectedShortcutTemplates(for: store.preferences) {
                menu.addItem(actionItem(
                    title: L10n.string("menu.newFileShortcut", template.localizedDisplayName),
                    token: .template(template.id),
                    context: context,
                    isEnabled: context.destinationDirectory != nil,
                    image: templateIcon()
                ))
            }
            return
        }

        for command in MenuLayoutPolicy.selectedShortcutCommands(for: group, preferences: store.preferences) {
            menu.addItem(commandItem(command, context: context))
        }
    }

    private func addClickMateSubmenu(groups: [MenuCommandGroup], to menu: NSMenu, context: FinderContext) {
        guard !groups.isEmpty else { return }
        let appName = L10n.string("app.name")
        let item = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        item.image = appIcon()
        let submenu = NSMenu(title: appName)
        appendMenuGroups(groups, to: submenu, context: context)
        item.submenu = submenu
        menu.addItem(item)
    }

    private func appendMenuGroups(_ groups: [MenuCommandGroup], to menu: NSMenu, context: FinderContext) {
        var shouldSeparateAfterNewFile = false

        for group in groups {
            if shouldSeparateAfterNewFile, menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            shouldSeparateAfterNewFile = false

            let itemCount = menu.items.count
            appendMenuGroup(group, to: menu, context: context)

            if group == .newFile, menu.items.count > itemCount {
                shouldSeparateAfterNewFile = true
            }
        }
    }

    private func appendMenuGroup(_ group: MenuCommandGroup, to menu: NSMenu, context: FinderContext) {
        switch group {
        case .newFile:
            appendNewFileMenu(to: menu, context: context)
        case .copy:
            appendCopyMenu(to: menu, context: context)
        case .openHere:
            appendOpenMenu(to: menu, context: context)
        case .openPinned:
            appendPinnedMenu(to: menu, context: context)
        case .hash:
            appendHashMenu(to: menu, context: context)
        case .fileUtilities:
            appendUtilitiesMenu(to: menu, context: context)
        case .advanced:
            appendAdvancedMenu(to: menu, context: context)
        }
    }

    private func appendCommandSubmenu(title: String, group: MenuCommandGroup, commands: [MenuCommand], to menu: NSMenu, context: FinderContext) {
        guard !commands.isEmpty else { return }

        let submenu = NSMenu(title: title)
        for command in commands {
            submenu.addItem(commandItem(command, context: context))
        }
        addSubmenu(title: title, submenu: submenu, to: menu, image: groupIcon(group))
    }

    private func orderedEnabledCommands(from commands: [MenuCommand]) -> [MenuCommand] {
        let commandSet = Set(commands)
        return store.preferences.enabledMenuCommandsInCustomOrder.filter { commandSet.contains($0) }
    }

    private func addSubmenu(title: String, submenu: NSMenu, to menu: NSMenu, image: NSImage? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        item.submenu = submenu
        menu.addItem(item)
    }

    private func commandItem(_ command: MenuCommand, context: FinderContext) -> NSMenuItem {
        actionItem(
            title: command.title,
            token: .command(command),
            context: context,
            isEnabled: isCommandEnabled(command, context: context),
            image: commandIcon(command)
        )
    }

    private func pinnedApplicationItem(path: String, context: FinderContext) -> NSMenuItem {
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return actionItem(
            title: title,
            token: .pinnedApplication(path),
            context: context,
            isEnabled: context.destinationDirectory != nil,
            image: applicationIcon(atPath: path) ?? groupIcon(.openPinned)
        )
    }

    private func actionItem(title: String, token: FinderCommandToken, context: FinderContext, isEnabled: Bool, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        item.image = image
        let action = FinderMenuAction(token: token, context: context)
        item.representedObject = action
        item.tag = nextMenuActionTag
        menuActions[item.tag] = action
        nextMenuActionTag += 1
        return item
    }

    private func appIcon() -> NSImage? {
        let bundleIcon = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        if let bundleIcon, let icon = NSImage(named: bundleIcon) {
            return resizedMenuIcon(icon)
        }
        return menuSymbolImage("cursorarrow.click")
    }

    private func groupIcon(_ group: MenuCommandGroup) -> NSImage? {
        menuSymbolImage(group.symbolName)
    }

    private func commandIcon(_ command: MenuCommand) -> NSImage? {
        if let bundleIdentifier = command.applicationBundleIdentifier {
            return cachedApplicationIcon(
                bundleIdentifier: bundleIdentifier,
                fallbackSymbolName: command.symbolName
            )
        }
        return menuSymbolImage(command.symbolName)
    }

    private func templateIcon() -> NSImage? {
        menuSymbolImage("doc.text")
    }

    private func applicationIcon(atPath path: String) -> NSImage? {
        cachedApplicationIcon(path: path, fallbackSymbolName: MenuCommandGroup.openPinned.symbolName)
    }

    private func menuSymbolImage(_ symbolName: String) -> NSImage? {
        let appearance = currentMenuIconAppearance()
        let cacheKey = "symbol:\(appearance.cacheKey):\(symbolName)"
        if let cached = menuImageCache[cacheKey] {
            return cached
        }
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let resized = renderedMenuSymbolImage(image, color: appearance.symbolColor)
        menuImageCache[cacheKey] = resized
        return resized
    }

    private func resizedMenuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = menuIconSize
        return copy
    }

    private func renderedMenuSymbolImage(_ image: NSImage, color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let source = image.withSymbolConfiguration(configuration) ?? image
        let rendered = NSImage(size: menuIconSize)
        rendered.lockFocus()
        defer { rendered.unlockFocus() }

        let rect = NSRect(origin: .zero, size: menuIconSize)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)
        rendered.isTemplate = false
        return rendered
    }

    private func currentMenuIconAppearance() -> MenuIconAppearance {
#if DEBUG
        if let documentationAppearance { return documentationAppearance }
#endif
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return .dark
        }
        return .light
    }

    private func cachedApplicationIcon(bundleIdentifier: String, fallbackSymbolName: String) -> NSImage? {
        let cacheKey = "bundle:\(bundleIdentifier)"
        if let cached = menuImageCache[cacheKey] {
            return cached
        }

        scheduleApplicationIconPreload(cacheKey: cacheKey, bundleIdentifier: bundleIdentifier)
        return menuSymbolImage(fallbackSymbolName)
    }

    private func cachedApplicationIcon(path: String, fallbackSymbolName: String) -> NSImage? {
        let cacheKey = "path:\(path)"
        if let cached = menuImageCache[cacheKey] {
            return cached
        }

        scheduleApplicationIconPreload(cacheKey: cacheKey, path: path)
        return menuSymbolImage(fallbackSymbolName)
    }

    private func preloadApplicationIcons() {
        for command in store.preferences.enabledOpenApplicationCommandsInCustomOrder {
            if let bundleIdentifier = command.applicationBundleIdentifier {
                scheduleApplicationIconPreload(cacheKey: "bundle:\(bundleIdentifier)", bundleIdentifier: bundleIdentifier)
            }
        }
        for path in store.preferences.pinnedApplicationPaths {
            scheduleApplicationIconPreload(cacheKey: "path:\(path)", path: path)
        }
    }

    private func scheduleApplicationIconPreload(cacheKey: String, bundleIdentifier: String) {
        guard menuImageCache[cacheKey] == nil,
              pendingApplicationIconCacheKeys.insert(cacheKey).inserted
        else {
            return
        }

        let finderSyncAddress = Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.main.async {
            guard let pointer = UnsafeRawPointer(bitPattern: finderSyncAddress) else { return }
            let finderSync = Unmanaged<FinderSync>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            defer { finderSync.pendingApplicationIconCacheKeys.remove(cacheKey) }
            guard finderSync.menuImageCache[cacheKey] == nil,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            else {
                return
            }
            finderSync.menuImageCache[cacheKey] = finderSync.resizedMenuIcon(NSWorkspace.shared.icon(forFile: appURL.path))
        }
    }

    private func scheduleApplicationIconPreload(cacheKey: String, path: String) {
        guard menuImageCache[cacheKey] == nil,
              pendingApplicationIconCacheKeys.insert(cacheKey).inserted
        else {
            return
        }

        let finderSyncAddress = Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.main.async {
            guard let pointer = UnsafeRawPointer(bitPattern: finderSyncAddress) else { return }
            let finderSync = Unmanaged<FinderSync>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            defer { finderSync.pendingApplicationIconCacheKeys.remove(cacheKey) }
            guard finderSync.menuImageCache[cacheKey] == nil,
                  FileManager.default.fileExists(atPath: path)
            else {
                return
            }
            finderSync.menuImageCache[cacheKey] = finderSync.resizedMenuIcon(NSWorkspace.shared.icon(forFile: path))
        }
    }

    private func isEnabled(_ command: MenuCommand) -> Bool {
        store.preferences.enabledCommands.contains(command)
    }

    private func isCommandEnabled(_ command: MenuCommand, context: FinderContext) -> Bool {
        switch command {
        case .openTerminal, .openITerm:
            return context.destinationDirectory != nil
        case .toggleHiddenFiles:
            return true
        case .editArchive:
            return archiveEditorURL(in: context) != nil
        case .sha256, .sha1, .md5, .copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename, .copyBasename, .copyExtension, .copyParentPath, .revealParent, .duplicateTimestamp, .createAlias, .moveToNewFolder, .compress, .metadata, .imageDimensions, .openVSCode, .openCursor, .openBBEdit, .openSublime:
            return !context.urls(for: command).isEmpty
        case .newFile:
            return context.destinationDirectory != nil
        }
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        logger.notice(
            "Received Finder menu action tag=\(sender.tag, privacy: .public), hasRepresentedObject=\(sender.representedObject != nil, privacy: .public)"
        )
        store.reload()
        guard store.preferences.finderToolsEnabled else {
            logger.notice("Rejected Finder menu action because Finder tools are disabled")
            return
        }
        let controller = FIFinderSyncController.default()
        guard let action = validatedMenuAction(
            for: sender,
            currentSelectedURLs: controller.selectedItemURLs() ?? [],
            currentTargetedURL: controller.targetedURL()
        ) else {
            notifyFailure("notification.noSelection")
            return
        }
        let token = action.token
        let context = action.context
        logger.info(
            "Handling Finder menu action tag=\(sender.tag, privacy: .public), selected=\(context.selectedURLs.count, privacy: .public), hasTarget=\(context.targetedURL != nil, privacy: .public)"
        )

        switch token {
        case .template(let id):
            createFile(templateID: id, context: context)
        case .pinnedApplication(let path):
            openPinnedApplication(path: path, context: context)
        case .command(let command):
            run(command: command, context: context)
        }
    }

    private func validatedMenuAction(
        for item: NSMenuItem,
        currentSelectedURLs: [URL],
        currentTargetedURL: URL?
    ) -> FinderMenuAction? {
        // Finder may return a proxy NSMenuItem without our representedObject.
        // The local entry binds both the command and its original Finder snapshot;
        // titles and represented objects cannot revive an expired menu tag.
        guard let action = menuActions[item.tag] else {
            logger.notice("Rejected Finder menu action with unknown or expired tag=\(item.tag, privacy: .public)")
            return nil
        }
        guard action.context.isValidForExecution(
            currentSelectedURLs: currentSelectedURLs,
            currentTargetedURL: currentTargetedURL
        ) else {
            logger.notice("Rejected Finder menu action because its Finder snapshot changed, tag=\(item.tag, privacy: .public)")
            return nil
        }
        return action
    }

    private func contextKind(for menuKind: FIMenuKind) -> FinderMenuContext.Kind {
        switch menuKind {
        case .contextualMenuForItems: return .items
        case .contextualMenuForContainer: return .container
        case .contextualMenuForSidebar: return .sidebar
        case .toolbarItemMenu: return .toolbar
        @unknown default: return .unknown
        }
    }

    private func createFile(templateID: String, context: FinderContext) {
        guard store.preferences.templates.contains(where: { $0.id == templateID }),
              let directory = context.destinationDirectory
        else {
            notifyFailure("notification.createFailed")
            return
        }
        let opened = dispatchToContainingApp(
            command: .createFile(templateID: templateID, directoryURL: directory),
            fallbackRoute: .createFile(templateID: templateID, directory: directory)
        )
        if !opened { notifyFailure("notification.createFailed") }
    }

    private func run(command: MenuCommand, context: FinderContext) {
        switch command {
        case .copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename, .copyBasename, .copyExtension, .copyParentPath:
            let urls = context.urls(for: command)
            guard !urls.isEmpty else { return notifyFailure("notification.noSelection") }
            FileActions.writeToPasteboard(PathFormatter.format(urls, as: command))
                ? notifySuccess("notification.copied")
                : notifyFailure("notification.actionFailed")
        case .openTerminal:
            openHere(command: .openTerminal, context: context)
        case .openITerm:
            openHere(command: .openITerm, context: context)
        case .openVSCode:
            openApplication(command: .openVSCode, context: context)
        case .openCursor:
            openApplication(command: .openCursor, context: context)
        case .openBBEdit:
            openApplication(command: .openBBEdit, context: context)
        case .openSublime:
            openApplication(command: .openSublime, context: context)
        case .sha256:
            copyHash(algorithm: .sha256, context: context)
        case .sha1:
            copyHash(algorithm: .sha1, context: context)
        case .md5:
            copyHash(algorithm: .md5, context: context)
        case .revealParent:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            FileActions.revealParent(urls: context.actionURLs)
            notifySuccess("notification.completed")
        case .duplicateTimestamp, .createAlias, .moveToNewFolder:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            if !dispatchToContainingApp(
                command: .batchFileAction(command: command, urls: context.actionURLs),
                fallbackRoute: .batchFileAction(command: command, urls: context.actionURLs)
            ) {
                notifyFailure("notification.actionFailed")
            }
        case .compress:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            if !dispatchToContainingApp(
                command: .compress(urls: context.actionURLs),
                fallbackRoute: .compress(urls: context.actionURLs)
            ) {
                notifyFailure("notification.actionFailed")
            }
        case .editArchive:
            guard let archiveURL = archiveEditorURL(in: context) else {
                return notifyFailure("notification.noSelection")
            }
            openArchiveEditor(at: archiveURL)
        case .metadata:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            FileActions.writeToPasteboard(FileActions.metadataSummary(urls: context.actionURLs))
                ? notifySuccess("notification.copied")
                : notifyFailure("notification.actionFailed")
        case .imageDimensions:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            FileActions.writeToPasteboard(FileActions.imageDimensions(urls: context.actionURLs))
                ? notifySuccess("notification.copied")
                : notifyFailure("notification.actionFailed")
        case .toggleHiddenFiles:
            dispatchToContainingApp(
                command: .toggleHiddenFiles(),
                fallbackRoute: .toggleHiddenFiles
            )
                ? notifySuccess("notification.completed")
                : notifyFailure("notification.actionFailed")
        case .newFile:
            break
        }
    }

    private func recordUserInitiatedAccess(_ result: FinderExtensionAccessResult) {
        runtimeReporter.recordUserInitiatedAccess(result)
    }

    private func accessResult(for error: Error) -> FinderExtensionAccessResult {
        isPermissionDenied(error as NSError) ? .permissionDenied : .failed
    }

    private func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            let permissionCodes = [
                Int(POSIXErrorCode.EACCES.rawValue),
                Int(POSIXErrorCode.EPERM.rawValue)
            ]
            if permissionCodes.contains(error.code) {
                return true
            }
        }

        if error.domain == NSCocoaErrorDomain {
            let permissionCodes = [
                CocoaError.Code.fileReadNoPermission.rawValue,
                CocoaError.Code.fileWriteNoPermission.rawValue
            ]
            if permissionCodes.contains(error.code) {
                return true
            }
        }

        guard let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlyingError !== error
        else {
            return false
        }
        return isPermissionDenied(underlyingError)
    }

    private func logFileActionFailure(
        _ action: String,
        result: FinderExtensionAccessResult,
        error: Error
    ) {
        let nsError = error as NSError
        logger.error(
            "File action \(action, privacy: .public) failed: result=\(result.rawValue, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
        )
    }

    private func copyHash(algorithm: HashAlgorithm, context: FinderContext) {
        guard !context.actionURLs.isEmpty else {
            notifyFailure("notification.noSelection")
            return
        }
        let opened = dispatchToContainingApp(
            command: .copyHash(algorithm: algorithm, urls: context.actionURLs),
            fallbackRoute: .copyHash(algorithm: algorithm, urls: context.actionURLs)
        )
        if !opened {
            notifyFailure("notification.actionFailed")
        }
    }

    private func openHere(command: MenuCommand, context: FinderContext) {
        guard let directory = context.destinationDirectory else {
            notifyFailure("notification.openFailed")
            return
        }
        let opened = dispatchToContainingApp(
            command: .openHere(command: command, directoryURL: directory),
            fallbackRoute: .openHere(command: command, directory: directory)
        )
        if !opened {
            notifyFailure("notification.openFailed")
        }
    }

    private func openArchiveEditor(at url: URL) {
        let opened: Bool
        if sharedContainerAvailable {
            PendingCommandQueue.enqueue(.editArchive(url: url))
            opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: true)
        } else {
            opened = AppLauncher.requestContainingAppToPerform(.editArchive(url: url), activates: true)
        }
        if !opened {
            notifyFailure("notification.openFailed")
        }
    }

    private func archiveEditorURL(in context: FinderContext) -> URL? {
        guard context.actionURLs.count == 1,
              let url = context.actionURLs.first,
              ArchiveEditorRoute.supports(url)
        else {
            return nil
        }
        return url
    }

    private func dispatchToContainingApp(
        command: PendingCommand,
        fallbackRoute: FinderActionRoute
    ) -> Bool {
        guard sharedContainerAvailable else {
            return AppLauncher.requestContainingAppToPerform(fallbackRoute)
        }
        PendingCommandQueue.enqueue(command)
        return AppLauncher.openContainingApp(
            action: "processPendingCommands",
            urls: [],
            activates: fallbackRoute.requiresVisibleWindow
        )
    }

    private func openApplication(command: MenuCommand, context: FinderContext) {
        let urls = context.urls(for: command)
        guard !urls.isEmpty else {
            notifyFailure("notification.noSelection")
            return
        }
        guard sharedContainerAvailable else {
            if !AppLauncher.requestContainingAppToOpenApplication(
                command: command,
                urls: urls
            ) {
                notifyFailure("notification.openFailed")
            }
            return
        }
        PendingCommandQueue.enqueue(.openApplication(command: command, urls: urls))
        let opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: false)
        if !opened {
            notifyFailure("notification.openFailed")
        }
    }

    private func openPinnedApplication(path: String, context: FinderContext) {
        let urls = context.actionURLs.isEmpty ? context.destinationDirectory.map { [$0] } ?? [] : context.actionURLs
        guard !urls.isEmpty else {
            notifyFailure("notification.noSelection")
            return
        }
        guard sharedContainerAvailable else {
            if !AppLauncher.requestContainingAppToOpenPinnedApplication(
                path: path,
                urls: urls
            ) {
                notifyFailure("notification.openFailed")
            }
            return
        }
        PendingCommandQueue.enqueue(.openPinnedApplication(path: path, urls: urls))
        let opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: false)
        if !opened {
            notifyFailure("notification.openFailed")
        }
    }

    private func notifySuccess(_ bodyKey: String, _ arguments: CVarArg...) {
        ActionNotifier.notify(titleKey: "notification.successTitle", bodyKey: bodyKey, bodyArguments: arguments)
    }

    private func notifyFailure(_ bodyKey: String) {
        ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: bodyKey)
    }
}

private typealias FinderContext = FinderMenuContext

private final class FinderMenuAction: NSObject {
    let token: FinderCommandToken
    let context: FinderContext

    init(token: FinderCommandToken, context: FinderContext) {
        self.token = token
        self.context = context
    }
}

private enum MenuIconAppearance {
    case light
    case dark

    var cacheKey: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        }
    }

    var symbolColor: NSColor {
        switch self {
        case .light:
            return NSColor.labelColor
        case .dark:
            return NSColor.white.withAlphaComponent(0.88)
        }
    }
}
