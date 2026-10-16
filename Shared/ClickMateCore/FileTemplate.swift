import Foundation

struct FileTemplate: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var fileExtension: String
    var defaultBasename: String
    var contents: String

    enum ValidationError: Error, LocalizedError {
        case emptyDisplayName
        case emptyBasename
        case invalidDisplayName
        case invalidBasename
        case invalidExtension

        var errorDescription: String? {
            switch self {
            case .emptyDisplayName: L10n.string("templates.validation.emptyDisplayName")
            case .emptyBasename: L10n.string("templates.validation.emptyBasename")
            case .invalidDisplayName: L10n.string("templates.validation.invalidDisplayName")
            case .invalidBasename: L10n.string("templates.validation.invalidBasename")
            case .invalidExtension: L10n.string("templates.validation.invalidExtension")
            }
        }
    }

    var localizedDisplayName: String {
        guard Self.defaults.contains(where: { $0.id == id && $0.displayName == displayName }) else { return displayName }
        return L10n.string("template.\(id)", fallback: displayName)
    }

    var validationError: ValidationError? {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyDisplayName }
        if Self.isInvalidName(displayName) { return .invalidDisplayName }
        if defaultBasename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyBasename }
        if Self.isInvalidName(defaultBasename) { return .invalidBasename }
        if !fileExtension.isEmpty && (fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty || Self.isInvalidName(fileExtension)) {
            return .invalidExtension
        }
        return nil
    }

    func duplicated() -> FileTemplate {
        var duplicate = self
        duplicate.id = "custom-\(UUID().uuidString)"
        duplicate.displayName = localizedDisplayName
        return duplicate
    }

    private static func isInvalidName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prohibited = CharacterSet.controlCharacters.union(.newlines).union(CharacterSet(charactersIn: "/:"))
        return trimmed == "." || trimmed == ".." || value.rangeOfCharacter(from: prohibited) != nil
    }

    var filename: String {
        let cleanExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleanExtension.isEmpty else { return defaultBasename }
        return "\(defaultBasename).\(cleanExtension)"
    }

    static let defaults: [FileTemplate] = [
        .init(id: "txt", displayName: "Text File", fileExtension: "txt", defaultBasename: "Untitled", contents: ""),
        .init(id: "md", displayName: "Markdown", fileExtension: "md", defaultBasename: "Untitled", contents: ""),
        .init(id: "json", displayName: "JSON", fileExtension: "json", defaultBasename: "Untitled", contents: "{\n  \n}\n"),
        .init(id: "csv", displayName: "CSV", fileExtension: "csv", defaultBasename: "Untitled", contents: ""),
        .init(id: "html", displayName: "HTML", fileExtension: "html", defaultBasename: "Untitled", contents: "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <title>Untitled</title>\n</head>\n<body>\n</body>\n</html>\n"),
        .init(id: "css", displayName: "CSS", fileExtension: "css", defaultBasename: "Untitled", contents: ""),
        .init(id: "js", displayName: "JavaScript", fileExtension: "js", defaultBasename: "Untitled", contents: ""),
        .init(id: "swift", displayName: "Swift", fileExtension: "swift", defaultBasename: "Untitled", contents: "import Foundation\n"),
        .init(id: "py", displayName: "Python", fileExtension: "py", defaultBasename: "Untitled", contents: "#!/usr/bin/env python3\n")
    ]
}
