import Foundation

enum MenuCommand: String, Codable, CaseIterable, Identifiable {
    case newFile
    case copyPOSIXPath
    case copyFileURL
    case copyShellPath
    case copyFilename
    case copyBasename
    case copyExtension
    case copyParentPath
    case openTerminal
    case openITerm
    case openVSCode
    case openCursor
    case openBBEdit
    case openSublime
    case sha256
    case sha1
    case md5
    case revealParent
    case duplicateTimestamp
    case createAlias
    case moveToNewFolder
    case compress
    case metadata
    case imageDimensions
    case toggleHiddenFiles

    var id: String { rawValue }

    var title: String {
        L10n.string(titleKey)
    }

    var titleKey: String {
        switch self {
        case .newFile: return "command.newFile"
        case .copyPOSIXPath: return "command.copyPOSIXPath"
        case .copyFileURL: return "command.copyFileURL"
        case .copyShellPath: return "command.copyShellPath"
        case .copyFilename: return "command.copyFilename"
        case .copyBasename: return "command.copyBasename"
        case .copyExtension: return "command.copyExtension"
        case .copyParentPath: return "command.copyParentPath"
        case .openTerminal: return "command.openTerminal"
        case .openITerm: return "command.openITerm"
        case .openVSCode: return "command.openVSCode"
        case .openCursor: return "command.openCursor"
        case .openBBEdit: return "command.openBBEdit"
        case .openSublime: return "command.openSublime"
        case .sha256: return "command.sha256"
        case .sha1: return "command.sha1"
        case .md5: return "command.md5"
        case .revealParent: return "command.revealParent"
        case .duplicateTimestamp: return "command.duplicateTimestamp"
        case .createAlias: return "command.createAlias"
        case .moveToNewFolder: return "command.moveToNewFolder"
        case .compress: return "command.compress"
        case .metadata: return "command.metadata"
        case .imageDimensions: return "command.imageDimensions"
        case .toggleHiddenFiles: return "command.toggleHiddenFiles"
        }
    }

    static func openApplicationCommand(forBundleIdentifier bundleIdentifier: String) -> MenuCommand? {
        switch bundleIdentifier {
        case "com.apple.Terminal":
            return .openTerminal
        case "com.googlecode.iterm2":
            return .openITerm
        case "com.microsoft.VSCode":
            return .openVSCode
        case "com.todesktop.230313mzl4w4u92":
            return .openCursor
        case "com.barebones.bbedit":
            return .openBBEdit
        case "com.sublimetext.4":
            return .openSublime
        default:
            return nil
        }
    }
}

enum MenuCommandGroup: String, Codable, CaseIterable, Identifiable, Hashable {
    case newFile
    case copy
    case openHere
    case openPinned
    case hash
    case fileUtilities
    case advanced

    var id: String { rawValue }

    var title: String {
        L10n.string(titleKey)
    }

    var titleKey: String {
        switch self {
        case .newFile: return "menu.newFile"
        case .copy: return "menu.copy"
        case .openHere: return "menu.openHere"
        case .openPinned: return "menu.openPinned"
        case .hash: return "menu.hash"
        case .fileUtilities: return "menu.fileUtilities"
        case .advanced: return "menu.advanced"
        }
    }

    var commands: [MenuCommand] {
        switch self {
        case .newFile:
            return [.newFile]
        case .copy:
            return [.copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename, .copyBasename, .copyExtension, .copyParentPath]
        case .openHere:
            return [.openTerminal, .openITerm, .openVSCode, .openCursor, .openBBEdit, .openSublime]
        case .openPinned:
            return []
        case .hash:
            return [.sha256, .sha1, .md5]
        case .fileUtilities:
            return [.revealParent, .duplicateTimestamp, .createAlias, .moveToNewFolder, .compress]
        case .advanced:
            return [.metadata, .imageDimensions, .toggleHiddenFiles]
        }
    }

    static func group(for command: MenuCommand) -> MenuCommandGroup {
        switch command {
        case .newFile:
            return .newFile
        case .copyPOSIXPath, .copyFileURL, .copyShellPath, .copyFilename, .copyBasename, .copyExtension, .copyParentPath:
            return .copy
        case .openTerminal, .openITerm, .openVSCode, .openCursor, .openBBEdit, .openSublime:
            return .openHere
        case .sha256, .sha1, .md5:
            return .hash
        case .revealParent, .duplicateTimestamp, .createAlias, .moveToNewFolder, .compress:
            return .fileUtilities
        case .metadata, .imageDimensions, .toggleHiddenFiles:
            return .advanced
        }
    }

    var defaultCommand: MenuCommand? {
        switch self {
        case .newFile:
            return .newFile
        case .copy:
            return .copyPOSIXPath
        case .openHere:
            return .openTerminal
        case .openPinned:
            return nil
        case .hash:
            return .sha256
        case .fileUtilities:
            return .revealParent
        case .advanced:
            return .metadata
        }
    }
}
