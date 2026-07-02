import Foundation

enum FileCreator {
    enum FileCreatorError: Error {
        case targetIsNotDirectory(URL)
    }

    static func availableURL(in directory: URL, preferredFilename: String, fileManager: FileManager = .default) -> URL {
        let preferredURL = directory.appendingPathComponent(preferredFilename)
        guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let nsName = preferredFilename as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    @discardableResult
    static func createFile(from template: FileTemplate, in directory: URL, fileManager: FileManager = .default) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileCreatorError.targetIsNotDirectory(directory)
        }

        let destination = availableURL(in: directory, preferredFilename: template.filename, fileManager: fileManager)
        let data = Data(template.contents.utf8)
        guard fileManager.createFile(atPath: destination.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }
}
