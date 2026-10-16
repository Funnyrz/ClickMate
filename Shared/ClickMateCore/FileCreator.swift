import Foundation

enum FileCreator {
    enum FileCreatorError: LocalizedError {
        case targetIsNotDirectory(URL)
        case invalidTemplate(FileTemplate.ValidationError)

        var errorDescription: String? {
            switch self {
            case let .targetIsNotDirectory(url): L10n.string("templates.targetNotDirectory", url.path)
            case let .invalidTemplate(error): error.errorDescription
            }
        }
    }

    static func availableURL(in directory: URL, preferredFilename: String, fileManager: FileManager = .default) -> URL {
        let exists: (URL) -> Bool = {
            fileManager.fileExists(atPath: $0.path) || (try? fileManager.attributesOfItem(atPath: $0.path)) != nil
        }
        let preferredURL = directory.appendingPathComponent(preferredFilename)
        guard exists(preferredURL) else { return preferredURL }

        let nsName = preferredFilename as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !exists(candidateURL) {
                return candidateURL
            }
            index += 1
        }
    }

    @discardableResult
    static func createFile(from template: FileTemplate, in directory: URL, fileManager: FileManager = .default) throws -> URL {
        if let error = template.validationError { throw FileCreatorError.invalidTemplate(error) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileCreatorError.targetIsNotDirectory(directory)
        }

        let destination = availableURL(in: directory, preferredFilename: template.filename, fileManager: fileManager)
        let data = Data(template.contents.utf8)
        try data.write(to: destination, options: .withoutOverwriting)
        return destination
    }
}
