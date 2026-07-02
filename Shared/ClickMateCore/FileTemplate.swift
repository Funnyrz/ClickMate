import Foundation

struct FileTemplate: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var fileExtension: String
    var defaultBasename: String
    var contents: String

    var localizedDisplayName: String {
        L10n.string("template.\(id)", fallback: displayName)
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
