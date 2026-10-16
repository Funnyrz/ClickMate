import Foundation
import XCTest

final class FinderMenuContextTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/ClickMateContext", isDirectory: true)

    func testContainerIgnoresStaleFinderSelection() {
        let file = directory.appendingPathComponent("selected.txt")
        let context = FinderMenuContext(kind: .container, selectedURLs: [file], targetedURL: directory)

        XCTAssertTrue(context.actionURLs.isEmpty)
        XCTAssertEqual(context.destinationDirectory, directory)
        for command in [MenuCommand.moveToNewFolder, .duplicateTimestamp, .createAlias, .compress, .md5, .copyFilename] {
            XCTAssertTrue(context.urls(for: command).isEmpty, command.rawValue)
        }
        XCTAssertEqual(context.urls(for: .copyPOSIXPath), [directory])
        XCTAssertEqual(context.urls(for: .openVSCode), [directory])
    }

    func testItemMenuNeverUsesCurrentDirectoryAsSelection() {
        let context = FinderMenuContext(kind: .items, selectedURLs: [], targetedURL: directory)
        XCTAssertTrue(context.actionURLs.isEmpty)
        XCTAssertTrue(context.urls(for: .compress).isEmpty)
    }

    func testSelectedFileAndFolderPreserveActionAndDestination() {
        let file = directory.appendingPathComponent("selected.txt")
        for kind in [FinderMenuContext.Kind.items, .sidebar, .toolbar] {
            let context = FinderMenuContext(kind: kind, selectedURLs: [file], targetedURL: directory)
            XCTAssertEqual(context.actionURLs, [file])
            XCTAssertEqual(context.urls(for: .compress), [file])
            XCTAssertEqual(context.destinationDirectory, directory)
        }
        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        let context = FinderMenuContext(kind: .items, selectedURLs: [folder], targetedURL: directory)
        XCTAssertEqual(context.destinationDirectory, folder)
        XCTAssertEqual(context.actionURLs, [folder])
    }

    func testExecutionRejectsChangedSelectionInsteadOfUsingNewFiles() {
        let original = directory.appendingPathComponent("original.txt")
        let changed = directory.appendingPathComponent("other.txt")
        let context = FinderMenuContext(kind: .items, selectedURLs: [original], targetedURL: directory)
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [changed], currentTargetedURL: directory, exists: { _ in true }))
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [], currentTargetedURL: directory, exists: { _ in true }))
    }

    func testExecutionRejectsMissingFileAndAcceptsReorderedSelection() {
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let context = FinderMenuContext(kind: .items, selectedURLs: [first, second], targetedURL: directory)
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [first, second], currentTargetedURL: directory, exists: { $0 != second }))
        XCTAssertTrue(context.isValidForExecution(currentSelectedURLs: [second, first], currentTargetedURL: directory, exists: { _ in true }))
    }

    func testContainerValidatesOriginalDirectoryWithoutAdoptingSelection() {
        let context = FinderMenuContext(kind: .container, selectedURLs: [], targetedURL: directory)
        XCTAssertTrue(context.isValidForExecution(currentSelectedURLs: [directory.appendingPathComponent("new.txt")], currentTargetedURL: directory, exists: { _ in true }))
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [], currentTargetedURL: directory.deletingLastPathComponent(), exists: { _ in true }))
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [], currentTargetedURL: directory, exists: { _ in false }))
    }
}
