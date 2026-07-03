import Cocoa
import FinderSync
import OSLog

class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "FinderSync")
    private lazy var store = PreferencesStore()
    private var latestMenuContext: FinderContext?
    private var menuActionTokens: [Int: FinderCommandToken] = [:]
    private var menuActionTitleTokens: [String: FinderCommandToken] = [:]
    private var menuImageCache: [String: NSImage] = [:]
    private var pendingApplicationIconCacheKeys: Set<String> = []
    private var nextMenuActionTag = 1

    override init() {
        super.init()
        L10n.languageProvider = { [weak self] in
            self?.store.preferences.language ?? .system
        }
        setBootstrapMonitoredDirectories()
        refreshMonitoredDirectoriesFromPreferences()
        preloadApplicationIcons()
        observePreferenceChanges()
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(PreferencesChangeNotifier.name as CFString),
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
    }

    override func endObservingDirectory(at url: URL) {
    }

    override func requestBadgeIdentifier(for url: URL) {
        FIFinderSyncController.default().setBadgeIdentifier("", for: url)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            logger.debug("Built Finder menu in \(elapsed, privacy: .public) ms")
        }

        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        let targetedURL = FIFinderSyncController.default().targetedURL()
        let context = FinderContext(selectedURLs: selectedURLs, targetedURL: targetedURL)
        latestMenuContext = context
        menuActionTokens.removeAll(keepingCapacity: true)
        menuActionTitleTokens.removeAll(keepingCapacity: true)
        nextMenuActionTag = 1

        let rootMenu = NSMenu(title: L10n.string("app.name"))
        appendConfiguredMenuGroups(to: rootMenu, context: context)

        return rootMenu
    }

    private func updateMonitoredDirectories() {
        store.reload()
        refreshMonitoredDirectoriesFromPreferences()
    }

    private func setBootstrapMonitoredDirectories() {
        let urls = Set(MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap())
        applyMonitoredDirectoryURLs(urls)
    }

    private func refreshMonitoredDirectoriesFromPreferences() {
        applyMonitoredDirectoryURLs(monitoredDirectoryURLs())
    }

    private func applyMonitoredDirectoryURLs(_ urls: Set<URL>) {
        FIFinderSyncController.default().directoryURLs = Set(urls)
        let preview = urls.map(\.path).sorted().prefix(8).joined(separator: ", ")
        logger.info("Monitoring \(urls.count, privacy: .public) directories: \(preview, privacy: .public)")
    }

    private func monitoredDirectoryURLs() -> Set<URL> {
        var urls = MonitoredFolderPolicy.finderSyncDirectoryURLs(for: store.preferences)
        urls.formUnion(MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap())
        return urls
    }

    private func observePreferenceChanges() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
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
            PreferencesChangeNotifier.name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func appendNewFileMenu(to menu: NSMenu, context: FinderContext) {
        guard isEnabled(.newFile), context.destinationDirectory != nil else { return }
        let templates = store.preferences.templates
        guard let defaultTemplate = templates.first else { return }

        let submenu = NSMenu(title: L10n.string("menu.newFile"))
        submenu.addItem(actionItem(
            title: defaultActionTitle(defaultTemplate.localizedDisplayName),
            token: .template(defaultTemplate.id),
            context: context,
            isEnabled: true,
            image: templateIcon()
        ))
        submenu.addItem(.separator())

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
            commands: orderedEnabledCommands(from: [.revealParent, .duplicateTimestamp, .createAlias, .moveToNewFolder, .compress]),
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
        let placement = store.preferences.menuGroupPlacement
        let allGroups = store.preferences.orderedVisibleMenuGroups
        var didAddFoldedParent = false

        for group in allGroups {
            if placement.foldedGroups.contains(group) {
                guard !didAddFoldedParent else { continue }
                addClickMateSubmenu(groups: placement.foldedGroups, to: menu, context: context)
                didAddFoldedParent = true
            } else {
                appendMenuGroup(group, to: menu, context: context)
            }
        }

        appendPinnedMenu(to: menu, context: context)
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
        let visibleCommands = commands
        guard !visibleCommands.isEmpty else { return }

        let submenu = NSMenu(title: title)
        if let defaultCommand = group.defaultCommand.flatMap({ defaultCommand in
            visibleCommands.first { $0 == defaultCommand }
        }) ?? visibleCommands.first {
            submenu.addItem(commandItem(defaultCommand, context: context, usesDefaultTitle: true))
            submenu.addItem(.separator())
        }

        for command in visibleCommands {
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

    private func commandItem(_ command: MenuCommand, context: FinderContext, usesDefaultTitle: Bool = false) -> NSMenuItem {
        actionItem(
            title: usesDefaultTitle ? defaultActionTitle(command.title) : command.title,
            token: .command(command),
            context: context,
            isEnabled: isCommandEnabled(command, context: context),
            image: commandIcon(command)
        )
    }

    private func pinnedApplicationItem(path: String, context: FinderContext, usesDefaultTitle: Bool = false) -> NSMenuItem {
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return actionItem(
            title: usesDefaultTitle ? defaultActionTitle(title) : title,
            token: .pinnedApplication(path),
            context: context,
            isEnabled: !context.actionURLs.isEmpty,
            image: applicationIcon(atPath: path) ?? groupIcon(.openPinned)
        )
    }

    private func actionItem(title: String, token: FinderCommandToken, context: FinderContext, isEnabled: Bool, image: NSImage? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        item.image = image
        item.representedObject = token.rawValue
        item.tag = nextMenuActionTag
        menuActionTokens[item.tag] = token
        menuActionTitleTokens[title] = token
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
        let cacheKey = "symbol:\(symbolName)"
        if let cached = menuImageCache[cacheKey] {
            return cached
        }
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        let resized = resizedMenuIcon(image)
        menuImageCache[cacheKey] = resized
        return resized
    }

    private func resizedMenuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
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

    private func defaultActionTitle(_ title: String) -> String {
        L10n.string("menu.defaultAction", title)
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
        case .sha256, .sha1, .md5, .copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename, .copyBasename, .copyExtension, .copyParentPath, .revealParent, .duplicateTimestamp, .createAlias, .moveToNewFolder, .compress, .metadata, .imageDimensions, .openVSCode, .openCursor, .openBBEdit, .openSublime:
            return !context.actionURLs.isEmpty
        case .newFile:
            return context.destinationDirectory != nil
        }
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        guard let token = token(for: sender)
        else {
            logger.error("Menu action missing token for item \(sender.title, privacy: .public), tag=\(sender.tag, privacy: .public)")
            notifyFailure("notification.actionFailed")
            return
        }

        let context = latestMenuContext ?? currentContext()
        logger.info(
            "Handling menu action \(token.rawValue, privacy: .public), selected=\(context.selectedURLs.count, privacy: .public), targeted=\(context.targetedURL?.path ?? "nil", privacy: .public)"
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

    private func token(for item: NSMenuItem) -> FinderCommandToken? {
        menuActionTokens[item.tag]
            ?? ((item.representedObject as? String).flatMap(FinderCommandToken.init(rawValue:)))
            ?? menuActionTitleTokens[item.title]
            ?? tokenFromVisibleTitle(item.title)
    }

    private func tokenFromVisibleTitle(_ title: String) -> FinderCommandToken? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedTitle == L10n.string("menu.newFile"),
           let template = store.preferences.templates.first {
            return .template(template.id)
        }

        let defaultPrefix = defaultActionPrefix()
        let titleWithoutDefaultPrefix: String
        if normalizedTitle.hasPrefix(defaultPrefix) {
            titleWithoutDefaultPrefix = String(normalizedTitle.dropFirst(defaultPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            titleWithoutDefaultPrefix = normalizedTitle
        }

        if let template = store.preferences.templates.first(where: { template in
            template.localizedDisplayName == titleWithoutDefaultPrefix || template.displayName == titleWithoutDefaultPrefix
        }) {
            return .template(template.id)
        }

        if let command = MenuCommand.allCases.first(where: { $0.title == titleWithoutDefaultPrefix }) {
            return .command(command)
        }

        if let pinnedPath = store.preferences.pinnedApplicationPaths.first(where: { path in
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == titleWithoutDefaultPrefix
        }) {
            return .pinnedApplication(pinnedPath)
        }

        return nil
    }

    private func defaultActionPrefix() -> String {
        let marker = "__CLICKMATE_DEFAULT_ACTION_MARKER__"
        let localized = defaultActionTitle(marker)
        guard let range = localized.range(of: marker) else { return "" }
        return String(localized[..<range.lowerBound])
    }

    private func currentContext() -> FinderContext {
        FinderContext(
            selectedURLs: FIFinderSyncController.default().selectedItemURLs() ?? [],
            targetedURL: FIFinderSyncController.default().targetedURL()
        )
    }

    private func createFile(templateID: String, context: FinderContext) {
        guard store.preferences.templates.contains(where: { $0.id == templateID }),
              let directory = context.destinationDirectory
        else {
            notifyFailure("notification.createFailed")
            return
        }
        PendingCommandQueue.enqueue(.createFile(templateID: templateID, directoryURL: directory))
        let opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: false)
        opened ? notifySuccess("notification.completed") : notifyFailure("notification.createFailed")
    }

    private func run(command: MenuCommand, context: FinderContext) {
        switch command {
        case .copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename, .copyBasename, .copyExtension, .copyParentPath:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            FileActions.writeToPasteboard(PathFormatter.format(context.actionURLs, as: command))
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
        case .duplicateTimestamp:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            do {
                try FileActions.duplicateWithTimestamp(urls: context.actionURLs)
                notifySuccess("notification.completed")
            } catch {
                logger.error("Duplicate failed: \(error.localizedDescription, privacy: .public)")
                notifyFailure("notification.actionFailed")
            }
        case .createAlias:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            do {
                try FileActions.createAliases(urls: context.actionURLs)
                notifySuccess("notification.completed")
            } catch {
                logger.error("Create alias failed: \(error.localizedDescription, privacy: .public)")
                notifyFailure("notification.actionFailed")
            }
        case .moveToNewFolder:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            do {
                try FileActions.moveToNewFolder(urls: context.actionURLs)
                notifySuccess("notification.completed")
            } catch {
                logger.error("Move to new folder failed: \(error.localizedDescription, privacy: .public)")
                notifyFailure("notification.actionFailed")
            }
        case .compress:
            guard !context.actionURLs.isEmpty else { return notifyFailure("notification.noSelection") }
            AppLauncher.openContainingApp(action: "compress", urls: context.actionURLs)
                ? notifySuccess("notification.completed")
                : notifyFailure("notification.actionFailed")
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
            AppLauncher.openContainingApp(action: "toggleHiddenFiles", urls: [])
                ? notifySuccess("notification.completed")
                : notifyFailure("notification.actionFailed")
        case .newFile:
            break
        }
    }

    private func copyHash(algorithm: HashAlgorithm, context: FinderContext) {
        guard !context.actionURLs.isEmpty else {
            notifyFailure("notification.noSelection")
            return
        }
        PendingCommandQueue.enqueue(.copyHash(algorithm: algorithm, urls: context.actionURLs))
        let opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: false)
        if !opened {
            notifyFailure("notification.actionFailed")
        }
    }

    private func openHere(command: MenuCommand, context: FinderContext) {
        guard let directory = context.destinationDirectory else {
            notifyFailure("notification.openFailed")
            return
        }
        PendingCommandQueue.enqueue(.openHere(command: command, directoryURL: directory))
        let opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: false)
        if !opened {
            notifyFailure("notification.openFailed")
        }
    }

    private func openApplication(command: MenuCommand, context: FinderContext) {
        guard !context.actionURLs.isEmpty else {
            notifyFailure("notification.noSelection")
            return
        }
        PendingCommandQueue.enqueue(.openApplication(command: command, urls: context.actionURLs))
        let opened = AppLauncher.openContainingApp(action: "processPendingCommands", urls: [], activates: false)
        if !opened {
            notifyFailure("notification.openFailed")
        }
    }

    private func openPinnedApplication(path: String, context: FinderContext) {
        guard !context.actionURLs.isEmpty else {
            notifyFailure("notification.noSelection")
            return
        }
        PendingCommandQueue.enqueue(.openPinnedApplication(path: path, urls: context.actionURLs))
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

private struct FinderContext {
    let selectedURLs: [URL]
    let targetedURL: URL?

    var destinationDirectory: URL? {
        FileActions.destinationDirectory(selectedURLs: selectedURLs, targetedURL: targetedURL)
    }

    var actionURLs: [URL] {
        if selectedURLs.isEmpty, let targetedURL {
            return [targetedURL]
        }
        return selectedURLs
    }
}
