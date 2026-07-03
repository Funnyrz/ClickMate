import Foundation

enum AppConstants {
    static let appGroupIdentifier = "group.com.zxacn"
    static let bundleIdentifier = "com.zxacn.clickmate"
    static let finderExtensionBundleIdentifier = "com.zxacn.clickmate.FinderExtension"
    static let urlScheme = "clickmate"
}

enum AppVersion {
    static func displayString(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (nonEmpty(version), nonEmpty(build)) {
        case let (version?, build?) where version != build:
            return L10n.string("app.versionWithBuild", version, build)
        case let (version?, _):
            return L10n.string("app.version", version)
        case let (_, build?):
            return L10n.string("app.build", build)
        default:
            return ""
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
