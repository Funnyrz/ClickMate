import AppKit
import Foundation
import OSLog

@MainActor
enum URLRouter {
    private static let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "URLRouter")
    private static var recentlyHandledURLs: [String: Date] = [:]

    static func handle(_ url: URL) {
        guard url.scheme == AppConstants.urlScheme else { return }
        guard shouldHandle(url) else { return }
        logger.info("Handling URL \(url.absoluteString, privacy: .public)")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let urls = queryItems
            .filter { $0.name == "url" }
            .compactMap(\.value)
            .compactMap(URL.init(string:)) ?? []

        switch url.host {
        case "processPendingCommands":
            processPendingCommands()
        case "createFile":
            hideApplicationAfterHandlingBackgroundAction()
            let templateID = queryItems.first { $0.name == "template" }?.value
            createFile(templateID: templateID, directories: urls)
            hideApplicationAfterHandlingBackgroundAction()
        case "toggleHiddenFiles":
            toggleHiddenFiles()
        case "compress":
            urls.forEach { NSWorkspace.shared.open($0) }
        default:
            break
        }
    }

    static func processPendingCommands() {
        let commands = PendingCommandQueue.drain()
        guard !commands.isEmpty else { return }
        logger.info("Processing \(commands.count, privacy: .public) pending command(s)")

        for command in commands {
            switch command.kind {
            case .createFile:
                createFile(templateID: command.templateID, directories: command.directoryURL.map { [$0] } ?? [])
            case .copyHash:
                copyHash(algorithm: command.hashAlgorithm, urls: command.urls)
            case .openHere:
                openHere(command: command.menuCommand, directory: command.directoryURL)
            case .openApplication:
                openApplication(command: command.menuCommand, applicationPath: command.applicationPath, urls: command.urls)
            }
        }
        hideApplicationAfterHandlingBackgroundAction()
    }

    private static func shouldHandle(_ url: URL) -> Bool {
        let key = url.absoluteString
        let now = Date()
        recentlyHandledURLs = recentlyHandledURLs.filter { now.timeIntervalSince($0.value) < 3 }
        guard recentlyHandledURLs[key] == nil else { return false }
        recentlyHandledURLs[key] = now
        return true
    }

    private static func hideApplicationAfterHandlingBackgroundAction() {
        DispatchQueue.main.async {
            NSApp.hide(nil)
        }
    }

    private static func createFile(templateID: String?, directories: [URL]) {
        let directorySummary = directories.map(\.path).joined(separator: ",")
        logger.info("Create file route template=\(templateID ?? "nil", privacy: .public), directories=\(directorySummary, privacy: .public)")
        let store = PreferencesStore()
        guard let directory = directories.first,
              let templateID,
              let template = store.preferences.templates.first(where: { $0.id == templateID })
        else {
            logger.error("Create file route missing directory or template")
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.createFailed")
            return
        }

        guard let access = DiskAccessPolicy.scopedOrDirectAccess(containing: directory, preferences: store.preferences) else {
            logger.error("Create file route missing disk access for \(directory.path, privacy: .public)")
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.permissionRequired")
            return
        }
        defer { access.stopAccessing() }

        do {
            let writableDirectory = access.resolvedURL(for: directory)
            let createdURL = try FileCreator.createFile(from: template, in: writableDirectory)
            logger.info("Create file route created \(createdURL.path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([createdURL])
            ActionNotifier.notify(
                titleKey: "notification.successTitle",
                bodyKey: "notification.createdFile",
                bodyArguments: [createdURL.lastPathComponent]
            )
        } catch {
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.createFailed")
        }
    }

    private static func copyHash(algorithm: HashAlgorithm?, urls: [URL]) {
        guard let algorithm, !urls.isEmpty else {
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.noSelection")
            return
        }

        let result = FileHasher.hashResult(for: urls, algorithm: algorithm)
        guard result.succeeded else {
            logger.error("Hash failed for \(result.failures.joined(separator: ","), privacy: .public)")
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.permissionRequired")
            return
        }

        FileActions.writeToPasteboard(result.text)
            ? ActionNotifier.notify(titleKey: "notification.successTitle", bodyKey: "notification.copied")
            : ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.actionFailed")
    }

    private static func openHere(command: MenuCommand?, directory: URL?) {
        guard let command, let directory else {
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.openFailed")
            return
        }

        let opened: Bool
        switch command {
        case .openTerminal:
            opened = AppLauncher.openTerminal(at: directory)
        case .openITerm:
            opened = AppLauncher.openBundle(identifier: "com.googlecode.iterm2", with: [directory])
        default:
            opened = false
        }

        opened
            ? ActionNotifier.notify(titleKey: "notification.successTitle", bodyKey: "notification.opened")
            : ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.openFailed")
    }

    private static func openApplication(command: MenuCommand?, applicationPath: String?, urls: [URL]) {
        guard !urls.isEmpty else {
            ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.noSelection")
            return
        }

        let opened: Bool
        if let applicationPath {
            opened = AppLauncher.openPinnedApplication(path: applicationPath, with: urls)
        } else if let command {
            switch command {
            case .openVSCode:
                opened = AppLauncher.openBundle(identifier: "com.microsoft.VSCode", with: urls)
            case .openCursor:
                opened = AppLauncher.openBundle(identifier: "com.todesktop.230313mzl4w4u92", with: urls)
            case .openBBEdit:
                opened = AppLauncher.openBundle(identifier: "com.barebones.bbedit", with: urls)
            case .openSublime:
                opened = AppLauncher.openBundle(identifier: "com.sublimetext.4", with: urls)
            default:
                opened = false
            }
        } else {
            opened = false
        }

        opened
            ? ActionNotifier.notify(titleKey: "notification.successTitle", bodyKey: "notification.opened")
            : ActionNotifier.notify(titleKey: "notification.failureTitle", bodyKey: "notification.openFailed")
    }

    private static func toggleHiddenFiles() {
        let script = """
        tell application "System Events"
          set currentValue to do shell script "defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || echo false"
          if currentValue is "TRUE" or currentValue is "true" or currentValue is "1" then
            do shell script "defaults write com.apple.finder AppleShowAllFiles false"
          else
            do shell script "defaults write com.apple.finder AppleShowAllFiles true"
          end if
        end tell
        tell application "Finder" to quit
        delay 0.5
        tell application "Finder" to activate
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
