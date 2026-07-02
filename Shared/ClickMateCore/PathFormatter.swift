import Foundation

enum PathFormatter {
    static func format(_ urls: [URL], as command: MenuCommand) -> String {
        urls.map { url in
            switch command {
            case .copyPOSIXPath:
                return url.path
            case .copyFileURL:
                return url.absoluteString
            case .copyShellPath:
                return shellEscaped(url.path)
            case .copyFilename:
                return url.lastPathComponent
            case .copyBasename:
                return url.deletingPathExtension().lastPathComponent
            case .copyExtension:
                return url.pathExtension
            case .copyParentPath:
                return url.deletingLastPathComponent().path
            default:
                return url.path
            }
        }
        .joined(separator: "\n")
    }

    static func shellEscaped(_ path: String) -> String {
        if path.isEmpty { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
        if path.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
