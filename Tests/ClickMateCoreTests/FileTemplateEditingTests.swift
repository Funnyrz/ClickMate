import Foundation
import XCTest

final class FileTemplateEditingTests: XCTestCase {
    func testEmptyExtensionCreatesExactFilenameAndContents() throws {
        let directory = try makeDirectory()
        let template = FileTemplate(id: "custom", displayName: "Configuration", fileExtension: "", defaultBasename: "Dockerfile", contents: "FROM scratch\n# 中文\n")
        XCTAssertNil(template.validationError)
        XCTAssertEqual(template.filename, "Dockerfile")
        let file = try FileCreator.createFile(from: template, in: directory)
        XCTAssertEqual(file.lastPathComponent, "Dockerfile")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), template.contents)
    }

    func testInvalidNamesAndExtensionsAreRejected() {
        var template = validTemplate()
        for invalid in ["", "   ", "\t"] {
            template.displayName = invalid
            XCTAssertEqual(template.validationError, .emptyDisplayName)
        }
        for invalid in ["bad/name", "bad:name", "bad\0name", "bad\nname", ".", ".."] {
            template = validTemplate()
            template.displayName = invalid
            XCTAssertEqual(template.validationError, .invalidDisplayName, invalid)
            template = validTemplate()
            template.defaultBasename = invalid
            XCTAssertEqual(template.validationError, .invalidBasename, invalid)
            template = validTemplate()
            template.fileExtension = invalid
            XCTAssertEqual(template.validationError, .invalidExtension, invalid)
        }
        template = validTemplate()
        template.defaultBasename = "  "
        XCTAssertEqual(template.validationError, .emptyBasename)
    }

    func testFileCreatorRejectsNestedPathsBeforeWriting() throws {
        let directory = try makeDirectory()
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        var template = validTemplate()
        template.defaultBasename = "nested/name"
        XCTAssertThrowsError(try FileCreator.createFile(from: template, in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent("name.txt").path))
    }

    func testCreatingTemplatePreservesExistingDanglingSymbolicLink() throws {
        let directory = try makeDirectory()
        let template = validTemplate()
        let link = directory.appendingPathComponent(template.filename)
        let missing = directory.appendingPathComponent("missing.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        let created = try FileCreator.createFile(from: template, in: directory)
        XCTAssertNotEqual(created, link)
        XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), template.contents)
    }

    func testEditingValueDraftPreservesIDAndDoesNotChangeOriginalUntilAssigned() {
        let original = validTemplate()
        var draft = original
        draft.displayName = "Edited Name"
        draft.defaultBasename = "settings"
        draft.fileExtension = "conf"
        draft.contents = "key=value\n"
        XCTAssertEqual(draft.id, original.id)
        XCTAssertEqual(original, validTemplate())
        XCTAssertNotEqual(draft, original)
        XCTAssertEqual(draft.filename, "settings.conf")
    }

    func testDuplicatingBuiltinGetsIndependentIDAndLocalizedNameWithContents() throws {
        let builtin = try XCTUnwrap(FileTemplate.defaults.first(where: { $0.id == "json" }))
        let duplicate = builtin.duplicated()
        XCTAssertNotEqual(duplicate.id, builtin.id)
        XCTAssertNotEqual(duplicate.id, builtin.duplicated().id)
        XCTAssertEqual(duplicate.displayName, builtin.localizedDisplayName)
        XCTAssertEqual(duplicate.contents, builtin.contents)
        XCTAssertEqual(duplicate.defaultBasename, builtin.defaultBasename)
        XCTAssertEqual(duplicate.fileExtension, builtin.fileExtension)
        XCTAssertNil(duplicate.validationError)
    }

    func testRenamedBuiltinDisplaysCustomNameWhileRetainingShortcutID() throws {
        var builtin = try XCTUnwrap(FileTemplate.defaults.first(where: { $0.id == "txt" }))
        builtin.displayName = "Project Notes"
        XCTAssertEqual(builtin.id, "txt")
        XCTAssertEqual(builtin.localizedDisplayName, "Project Notes")
    }

    func testLegacyCodableShapeAndEditedContentRoundTrip() throws {
        let legacy = Data(#"{"id":"custom-old","displayName":"Legacy","fileExtension":"txt","defaultBasename":"Old","contents":"existing"}"#.utf8)
        var template = try JSONDecoder().decode(FileTemplate.self, from: legacy)
        template.displayName = "Edited"
        template.fileExtension = ""
        template.contents = "first\nsecond\n中文\n"
        let restored = try JSONDecoder().decode(FileTemplate.self, from: JSONEncoder().encode(template))
        XCTAssertEqual(restored, template)
        XCTAssertEqual(restored.id, "custom-old")
        XCTAssertEqual(restored.filename, "Old")
    }

    private func validTemplate() -> FileTemplate {
        FileTemplate(id: "custom-test", displayName: "Notes", fileExtension: "txt", defaultBasename: "Untitled", contents: "notes")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
