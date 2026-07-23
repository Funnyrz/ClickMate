import AppKit
import Foundation

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
        let appURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: appURL.path) else { return false }
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
        if let applicationPath {
            return openPinnedApplication(path: applicationPath, with: urls)
        }

        guard let command else { return false }
        switch command {
        case .openVSCode:
            return openBundle(identifier: "com.microsoft.VSCode", with: urls)
        case .openCursor:
            return openBundle(identifier: "com.todesktop.230313mzl4w4u92", with: urls)
        case .openBBEdit:
            return openBundle(identifier: "com.barebones.bbedit", with: urls)
        case .openSublime:
            return openBundle(identifier: "com.sublimetext.4", with: urls)
        default:
            return false
        }
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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.open(url, configuration: configuration)
        return true
    }
}
