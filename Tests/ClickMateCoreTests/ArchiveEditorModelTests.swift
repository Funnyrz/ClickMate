import Foundation
import XCTest

@MainActor
final class ArchiveEditorModelTests: XCTestCase {
    func testSelectingAnotherEntryPreservesDirtyContentUntilConfirmed() throws {
        let model = ArchiveEditorModel()
        model.open(try makeArchive())
        model.selectEntry(named: "first.txt")
        model.editorText = "unsaved draft"
        model.selectEntry(named: "second.txt")
        XCTAssertEqual(model.selectedEntry?.name, "first.txt")
        XCTAssertEqual(model.editorText, "unsaved draft")
        XCTAssertTrue(model.isDirty)
    }

    func testInvalidArchiveDoesNotDiscardCurrentEditor() throws {
        let model = ArchiveEditorModel()
        let url = try makeArchive()
        model.open(url)
        model.selectEntry(named: "first.txt")
        model.open(url.deletingLastPathComponent().appendingPathComponent("missing.zip"))
        XCTAssertEqual(model.archive?.url, url)
        XCTAssertEqual(model.selectedEntry?.name, "first.txt")
        XCTAssertEqual(model.editorText, "first")
        XCTAssertNotNil(model.errorMessage)
    }

    func testSavingBeforeEntrySwitchPersistsDraftThenSelectsRequestedEntry() throws {
        let (model, url) = try dirtyModel()
        model.requestSelectEntry(named: "second.txt")
        XCTAssertEqual(model.pendingAction, .selectEntry("second.txt"))
        model.savePendingAction(createBackup: false)
        XCTAssertEqual(model.selectedEntryName, "second.txt")
        XCTAssertEqual(model.editorText, "second")
        XCTAssertNil(model.pendingAction)
        XCTAssertEqual(try ZipArchiveEditor.readEntry(named: "first.txt", from: ZipArchiveEditor.open(url)), Data("draft".utf8))
    }

    func testCancelAndDiscardEntrySelection() throws {
        let (model, _) = try dirtyModel()
        model.requestSelectEntry(named: "second.txt")
        model.cancelPendingAction()
        XCTAssertEqual(model.selectedEntryName, "first.txt")
        XCTAssertEqual(model.editorText, "draft")
        XCTAssertNil(model.pendingAction)
        model.requestSelectEntry(named: "second.txt")
        model.discardPendingAction()
        XCTAssertEqual(model.selectedEntryName, "second.txt")
        XCTAssertEqual(model.editorText, "second")
    }

    func testOpeningAnotherArchiveWaitsForSaveAndPreservesFirstPendingAction() throws {
        let (model, original) = try dirtyModel()
        let replacement = try makeArchive()
        model.requestOpen(replacement)
        model.requestSelectEntry(named: "second.txt")
        XCTAssertEqual(model.archive?.url, original)
        XCTAssertEqual(model.pendingAction, .open(replacement))
        model.savePendingAction(createBackup: false)
        XCTAssertEqual(model.archive?.url, replacement)
        XCTAssertNil(model.selectedEntryName)
        XCTAssertNil(model.pendingAction)
    }

    func testCloseWaitsForDecisionAndCancellationPreservesDraft() throws {
        let (model, _) = try dirtyModel()
        var outcomes: [Bool] = []
        model.requestClose { outcomes.append($0) }
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(model.pendingAction, .close)
        model.cancelPendingAction()
        XCTAssertEqual(outcomes, [false])
        XCTAssertEqual(model.editorText, "draft")
        model.requestClose { outcomes.append($0) }
        model.discardPendingAction()
        XCTAssertEqual(outcomes, [false, true])
        XCTAssertNil(model.archive)
    }

    func testTerminationSavesBeforeApprovingAndRejectsDuplicatePendingRequest() throws {
        let (model, url) = try dirtyModel()
        var allowed: Bool?
        var duplicateAllowed: Bool?
        model.requestTermination { allowed = $0 }
        model.requestTermination { duplicateAllowed = $0 }
        XCTAssertNil(allowed)
        XCTAssertEqual(duplicateAllowed, false)
        XCTAssertEqual(model.pendingAction, .terminate)
        model.savePendingAction(createBackup: false)
        XCTAssertEqual(allowed, true)
        XCTAssertNil(model.archive)
        XCTAssertEqual(try ZipArchiveEditor.readEntry(named: "first.txt", from: ZipArchiveEditor.open(url)), Data("draft".utf8))
    }

    func testFailedSaveRetainsDraftSelectionAndDeniesTermination() throws {
        let (model, url) = try dirtyModel()
        try FileManager.default.removeItem(at: url)
        var allowed: Bool?
        model.requestTermination { allowed = $0 }
        model.savePendingAction(createBackup: false)
        XCTAssertEqual(allowed, false)
        XCTAssertEqual(model.selectedEntryName, "first.txt")
        XCTAssertEqual(model.editorText, "draft")
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.archive)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.pendingAction)
    }

    func testCancelledSignatureWarningCancelsTransitionAndRetainsDraft() throws {
        let (model, url) = try dirtyModel(signed: true)
        model.requestSelectEntry(named: "second.txt")
        model.savePendingAction(createBackup: false)
        XCTAssertTrue(model.showSignatureWarning)
        XCTAssertEqual(model.selectedEntryName, "first.txt")
        model.cancelSignatureWarning()
        XCTAssertFalse(model.showSignatureWarning)
        XCTAssertNil(model.pendingAction)
        XCTAssertEqual(model.editorText, "draft")
        XCTAssertEqual(try ZipArchiveEditor.readEntry(named: "first.txt", from: ZipArchiveEditor.open(url)), Data("first".utf8))
        model.requestSave(createBackup: false)
        XCTAssertTrue(model.showSignatureWarning)
        model.saveAfterSignatureWarning(createBackup: false)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.selectedEntryName, "first.txt")
    }

    func testAcknowledgedSignatureSavesThenPerformsPendingTransition() throws {
        let (model, _) = try dirtyModel(signed: true)
        var allowed: Bool?
        model.requestClose { allowed = $0 }
        model.savePendingAction(createBackup: false)
        XCTAssertNil(allowed)
        XCTAssertTrue(model.showSignatureWarning)
        model.saveAfterSignatureWarning(createBackup: false)
        XCTAssertEqual(allowed, true)
        XCTAssertNil(model.archive)
        XCTAssertFalse(model.showSignatureWarning)
    }

    func testCleanCloseAndTerminationApproveImmediately() throws {
        let model = ArchiveEditorModel()
        var outcomes: [Bool] = []
        model.requestClose { outcomes.append($0) }
        model.open(try makeArchive())
        model.requestTermination { outcomes.append($0) }
        XCTAssertEqual(outcomes, [true, true])
        XCTAssertNil(model.pendingAction)
        XCTAssertFalse(model.isShowingUnsavedConfirmation)
    }

    func testPassiveDialogDismissalCancelsPendingTerminationAndPreservesDraft() async throws {
        let (model, _) = try dirtyModel()
        var allowed: Bool?
        model.requestTermination { allowed = $0 }
        model.setUnsavedConfirmationPresented(false)
        await nextMainQueueTurn()
        XCTAssertEqual(allowed, false)
        XCTAssertNil(model.pendingAction)
        XCTAssertEqual(model.selectedEntryName, "first.txt")
        XCTAssertEqual(model.editorText, "draft")
        model.requestSave(createBackup: false)
        XCTAssertNotNil(model.archive)
        XCTAssertEqual(model.selectedEntryName, "first.txt")
        model.requestClose { allowed = $0 }
        XCTAssertEqual(allowed, true)
    }

    func testDialogDismissalBeforeSaveRetainsPendingActionDuringSignatureWarning() async throws {
        let (model, _) = try dirtyModel(signed: true)
        var allowed: Bool?
        model.requestClose { allowed = $0 }
        model.setUnsavedConfirmationPresented(false)
        model.savePendingAction(createBackup: false)
        await nextMainQueueTurn()
        XCTAssertNil(allowed)
        XCTAssertEqual(model.pendingAction, .close)
        XCTAssertTrue(model.showSignatureWarning)
        XCTAssertEqual(model.editorText, "draft")
        model.saveAfterSignatureWarning(createBackup: false)
        XCTAssertEqual(allowed, true)
        XCTAssertNil(model.archive)
    }

    func testDeferredDismissalDoesNotCancelNewConfirmationAfterDiscard() async throws {
        let (model, _) = try dirtyModel()
        model.requestSelectEntry(named: "second.txt")
        model.setUnsavedConfirmationPresented(false)
        model.discardPendingAction()
        model.editorText = "second draft"
        model.requestSelectEntry(named: "first.txt")
        await nextMainQueueTurn()
        XCTAssertEqual(model.pendingAction, .selectEntry("first.txt"))
        XCTAssertTrue(model.isShowingUnsavedConfirmation)
        XCTAssertEqual(model.editorText, "second draft")
        model.cancelPendingAction()
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func dirtyModel(signed: Bool = false) throws -> (ArchiveEditorModel, URL) {
        let url = try makeArchive(signed: signed)
        let model = ArchiveEditorModel()
        model.open(url)
        model.selectEntry(named: "first.txt")
        model.editorText = "draft"
        return (model, url)
    }

    private func makeArchive(signed: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("first".utf8).write(to: directory.appendingPathComponent("first.txt"))
        try Data("second".utf8).write(to: directory.appendingPathComponent("second.txt"))
        var names = ["first.txt", "second.txt"]
        if signed {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try Data("signature".utf8).write(to: directory.appendingPathComponent("META-INF/TEST.SF"))
            names.append("META-INF/TEST.SF")
        }
        let archiveURL = directory.appendingPathComponent("test.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", archiveURL.path] + names
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archiveURL
    }
}
