import Foundation

/// A menu-time snapshot. Container menus deliberately discard Finder's selection,
/// which can still refer to an item selected before the user clicked blank space.
struct FinderMenuContext {
    enum Kind {
        case items, container, sidebar, toolbar, unknown
    }

    let kind: Kind
    let selectedURLs: [URL]
    let targetedURL: URL?

    init(kind: Kind, selectedURLs: [URL], targetedURL: URL?) {
        self.kind = kind
        self.selectedURLs = kind == .container || kind == .unknown ? [] : selectedURLs
        self.targetedURL = targetedURL
    }

    var destinationDirectory: URL? {
        FileActions.destinationDirectory(selectedURLs: selectedURLs, targetedURL: targetedURL)
    }

    var actionURLs: [URL] { selectedURLs }

    func urls(for command: MenuCommand) -> [URL] {
        if !selectedURLs.isEmpty { return selectedURLs }
        switch command {
        case .copyPOSIXPath, .copyFileURL, .copyShellPath,
             .openVSCode, .openCursor, .openBBEdit, .openSublime:
            return destinationDirectory.map { [$0] } ?? []
        default:
            return []
        }
    }

    func isValidForExecution(
        currentSelectedURLs: [URL],
        currentTargetedURL: URL?,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Bool {
        if !selectedURLs.isEmpty {
            let snapshot = Set(selectedURLs.map(\.standardizedFileURL))
            let current = Set(currentSelectedURLs.map(\.standardizedFileURL))
            return snapshot == current && selectedURLs.allSatisfy(exists)
        }
        guard let destinationDirectory,
              targetedURL?.standardizedFileURL == currentTargetedURL?.standardizedFileURL
        else { return false }
        return exists(destinationDirectory)
    }
}
