import AppKit
import Foundation

struct DetectedApplication: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let displayName: String
    let bundleIdentifier: String
    let path: String?
}

enum AppDetector {
    static let knownApplications: [DetectedApplication] = [
        .init(displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", path: nil),
        .init(displayName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", path: nil),
        .init(displayName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", path: nil),
        .init(displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", path: nil),
        .init(displayName: "BBEdit", bundleIdentifier: "com.barebones.bbedit", path: nil),
        .init(displayName: "Sublime Text", bundleIdentifier: "com.sublimetext.4", path: nil)
    ]

    static var defaultApplicationOrder: [String] {
        knownApplications.map(\.bundleIdentifier)
    }

    static func detectedApplications(workspace: NSWorkspace = .shared) -> [DetectedApplication] {
        knownApplications.map { app in
            let url = workspace.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
            return DetectedApplication(
                displayName: app.displayName,
                bundleIdentifier: app.bundleIdentifier,
                path: url?.path
            )
        }
    }

    static func detectedApplications(
        order: [String],
        removedBundleIdentifiers: Set<String> = [],
        workspace: NSWorkspace = .shared
    ) -> [DetectedApplication] {
        let detectedByBundleID = Dictionary(
            uniqueKeysWithValues: detectedApplications(workspace: workspace).map { ($0.bundleIdentifier, $0) }
        )
        return normalizedApplicationOrder(order)
            .filter { !removedBundleIdentifiers.contains($0) }
            .compactMap { detectedByBundleID[$0] }
    }

    static func normalizedApplicationOrder(_ bundleIdentifiers: [String]) -> [String] {
        let knownBundleIDs = Set(defaultApplicationOrder)
        var seen = Set<String>()
        var orderedBundleIDs: [String] = []

        for bundleIdentifier in bundleIdentifiers where knownBundleIDs.contains(bundleIdentifier) && !seen.contains(bundleIdentifier) {
            orderedBundleIDs.append(bundleIdentifier)
            seen.insert(bundleIdentifier)
        }

        for bundleIdentifier in defaultApplicationOrder where !seen.contains(bundleIdentifier) {
            orderedBundleIDs.append(bundleIdentifier)
        }

        return orderedBundleIDs
    }

    static func isInstalled(bundleIdentifier: String, workspace: NSWorkspace = .shared) -> Bool {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
