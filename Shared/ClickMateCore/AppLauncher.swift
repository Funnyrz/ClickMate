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
