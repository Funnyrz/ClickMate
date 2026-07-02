import AppKit
import Foundation
import ImageIO

enum FileActions {
    @discardableResult
    static func writeToPasteboard(_ string: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(string, forType: .string)
    }

    static func destinationDirectory(selectedURLs: [URL], targetedURL: URL?) -> URL? {
        if selectedURLs.count == 1, let first = selectedURLs.first {
            return first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        }
        if let first = selectedURLs.first {
            return first.deletingLastPathComponent()
        }
        return targetedURL
    }

    static func duplicateWithTimestamp(urls: [URL]) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        for url in urls {
            let parent = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let name = ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)"
            let destination = FileCreator.availableURL(in: parent, preferredFilename: name)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    static func createAliases(urls: [URL]) throws {
        for url in urls {
            let aliasURL = FileCreator.availableURL(
                in: url.deletingLastPathComponent(),
                preferredFilename: "\(url.deletingPathExtension().lastPathComponent) alias"
            )
            try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: url)
        }
    }

    static func moveToNewFolder(urls: [URL]) throws {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        let folderURL = FileCreator.availableURL(in: parent, preferredFilename: "New Folder")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        for url in urls {
            let destination = FileCreator.availableURL(in: folderURL, preferredFilename: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    static func revealParent(urls: [URL]) {
        guard let first = urls.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([first.deletingLastPathComponent()])
    }

    static func metadataSummary(urls: [URL]) -> String {
        urls.map { url in
            var lines = [String]()
            lines.append("Name: \(url.lastPathComponent)")
            lines.append("Path: \(url.path)")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if let size = attributes[.size] { lines.append("Size: \(size) bytes") }
                if let created = attributes[.creationDate] { lines.append("Created: \(created)") }
                if let modified = attributes[.modificationDate] { lines.append("Modified: \(modified)") }
                if let type = attributes[.type] { lines.append("Type: \(type)") }
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static func imageDimensions(urls: [URL]) -> String {
        urls.map { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth],
                  let height = properties[kCGImagePropertyPixelHeight]
            else {
                return "\(url.lastPathComponent): unavailable"
            }
            return "\(url.lastPathComponent): \(width)x\(height)"
        }
        .joined(separator: "\n")
    }
}
