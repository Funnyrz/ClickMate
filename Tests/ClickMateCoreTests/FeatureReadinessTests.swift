import Foundation
import XCTest

final class FeatureReadinessTests: XCTestCase {
    func testFinderReadinessDoesNotRequireScreenshotOrHelperPermissions() {
        let snapshot = FeatureReadinessSnapshot(finderStatus: .enabled)
        XCTAssertEqual(snapshot.status(for: .finderTools), .available)
        XCTAssertEqual(snapshot.status(for: .screenshot), .needsPermission)
    }

    func testFinderReadinessIncludesRestartAndFailureStates() {
        XCTAssertEqual(FeatureReadinessSnapshot(finderStatus: .enabled, finderNeedsRestart: true).status(for: .finderTools), .restartRequired)
        XCTAssertEqual(FeatureReadinessSnapshot(finderStatus: .disabled).status(for: .finderTools), .needsPermission)
        XCTAssertEqual(FeatureReadinessSnapshot(finderStatus: .enabled, finderAccess: .permissionDenied).status(for: .finderTools), .needsPermission)
        XCTAssertEqual(FeatureReadinessSnapshot(finderStatus: .enabled, finderAccess: .failed).status(for: .finderTools), .failed)
    }

    func testGrantedPermissionAloneDoesNotProveFeatureAvailable() {
        var snapshot = FeatureReadinessSnapshot(accessibility: .granted, screenRecording: .granted)
        XCTAssertEqual(snapshot.status(for: .finderCut), .needsPermission)
        snapshot.backgroundServiceEnabled = true
        snapshot.helperRunning = true
        XCTAssertEqual(snapshot.status(for: .finderCut), .restartRequired)
        snapshot.activeFeatures = [.finderCut]
        XCTAssertEqual(snapshot.status(for: .finderCut), .available)
        XCTAssertEqual(snapshot.status(for: .screenshot), .restartRequired)
    }

    func testShortcutAndHelperFailuresPreventAvailableStatus() {
        var snapshot = FeatureReadinessSnapshot(backgroundServiceEnabled: true, helperRunning: true, accessibility: .granted, screenRecording: .granted, activeFeatures: [.finderCut, .screenshot])
        snapshot.failedFeatures = [.finderCut]
        XCTAssertEqual(snapshot.status(for: .finderCut), .failed)
        XCTAssertEqual(snapshot.status(for: .screenshot), .available)
        snapshot.helperRunning = false
        snapshot.helperFailed = true
        XCTAssertEqual(snapshot.status(for: .screenshot), .failed)
    }

    func testPermissionRestartAndFailureArePreserved() {
        var snapshot = FeatureReadinessSnapshot(backgroundServiceEnabled: true, helperRunning: true, accessibility: .restartRequired, screenRecording: .failed)
        XCTAssertEqual(snapshot.status(for: .finderCut), .restartRequired)
        XCTAssertEqual(snapshot.status(for: .screenshot), .failed)
        snapshot.screenRecording = .notGranted
        XCTAssertEqual(snapshot.status(for: .screenshot), .needsPermission)
    }

    func testFeatureSelectionReflectsPreferencesWithoutChangingGuideDismissal() {
        var preferences = ClickMatePreferences.defaults
        preferences.hasDismissedPermissionGuide = true
        preferences.quickFeatureSettings[0].isEnabled = true
        preferences.quickFeatureSettings[1].isEnabled = false
        XCTAssertEqual(FeatureGuideFeature.selectedFeatures(in: preferences), [.finderTools, .finderCut])
        XCTAssertTrue(preferences.hasDismissedPermissionGuide)
        preferences.enabledCommands = []
        XCTAssertEqual(FeatureGuideFeature.selectedFeatures(in: preferences), [.finderTools, .finderCut])
        preferences.finderToolsEnabled = false
        XCTAssertEqual(FeatureGuideFeature.selectedFeatures(in: preferences), [.finderCut])
    }

    func testFinderMasterTogglePreservesCustomMenuConfiguration() {
        var preferences = ClickMatePreferences.defaults
        preferences.enabledCommands = [.copyPOSIXPath, .compress]
        preferences.finderToolsEnabled = false
        XCTAssertFalse(FeatureGuideFeature.selectedFeatures(in: preferences).contains(.finderTools))
        XCTAssertEqual(preferences.enabledCommands, [.copyPOSIXPath, .compress])
        preferences.finderToolsEnabled = true
        XCTAssertTrue(FeatureGuideFeature.selectedFeatures(in: preferences).contains(.finderTools))
        XCTAssertEqual(preferences.enabledCommands, [.copyPOSIXPath, .compress])
    }

    func testTrialStateRemainsSeparateFromReadiness() {
        let readiness = FeatureReadinessSnapshot(finderStatus: .enabled)
        let trial = FeatureTrialState.notTested
        XCTAssertEqual(readiness.status(for: .finderTools), .available)
        XCTAssertEqual(trial, .notTested)
        XCTAssertNotEqual(FeatureTrialState.awaitingConfirmation, .passed)
    }

    func testCutTrialUsesOwnedFilesAndRequiresActualMove() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let unrelated = parent.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let trial = try FeatureTrialFiles.create(in: parent)
        XCTAssertFalse(trial.hasCompletedMove)
        try FileManager.default.moveItem(at: trial.sourceURL, to: trial.destinationURL)
        XCTAssertTrue(trial.hasCompletedMove)
        XCTAssertNil(trial.cleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trial.directoryURL.path))
    }

    func testCutTrialCleanupPreservesUnexpectedDestinationFiles() throws {
        let trial = try FeatureTrialFiles.create()
        defer { try? FileManager.default.removeItem(at: trial.directoryURL) }
        let userFile = trial.destinationDirectory.appendingPathComponent("user.txt")
        let contents = Data("user work".utf8)
        try contents.write(to: userFile)
        XCTAssertEqual(trial.cleanup(), trial.directoryURL)
        XCTAssertEqual(try Data(contentsOf: userFile), contents)
    }

    func testCutTrialCleanupPreservesModifiedTestFile() throws {
        let trial = try FeatureTrialFiles.create()
        defer { try? FileManager.default.removeItem(at: trial.directoryURL) }
        let modified = Data("user edited this test file".utf8)
        try modified.write(to: trial.sourceURL)
        XCTAssertEqual(trial.cleanup(), trial.directoryURL)
        XCTAssertEqual(try Data(contentsOf: trial.sourceURL), modified)
    }

    func testCutTrialCleanupPreservesSameContentsWithDifferentFileIdentity() throws {
        let trial = try FeatureTrialFiles.create()
        defer { try? FileManager.default.removeItem(at: trial.directoryURL) }
        let contents = try Data(contentsOf: trial.sourceURL)
        let replacement = trial.directoryURL.appendingPathComponent("replacement.txt")
        try contents.write(to: replacement)
        try FileManager.default.removeItem(at: trial.sourceURL)
        try FileManager.default.moveItem(at: replacement, to: trial.sourceURL)
        XCTAssertEqual(trial.cleanup(), trial.directoryURL)
        XCTAssertEqual(try Data(contentsOf: trial.sourceURL), contents)
    }

    func testCutTrialCleanupDoesNotFollowReplacementSymlink() throws {
        let trial = try FeatureTrialFiles.create()
        defer { try? FileManager.default.removeItem(at: trial.directoryURL) }
        let target = trial.directoryURL.appendingPathComponent("user.txt")
        try Data("user file".utf8).write(to: target)
        try FileManager.default.removeItem(at: trial.sourceURL)
        try FileManager.default.createSymbolicLink(at: trial.sourceURL, withDestinationURL: target)
        XCTAssertEqual(trial.cleanup(), trial.directoryURL)
        XCTAssertEqual(try Data(contentsOf: target), Data("user file".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trial.sourceURL.path), target.path)
    }

    func testScreenshotTrialCommandRoundTripsAlongsideExistingCommands() throws {
        for action in [QuickFeatureHelperCommand.Action.testScreenshot, .refreshStatus, .requestScreenRecording] {
            let command = QuickFeatureHelperCommand(action: action)
            XCTAssertEqual(try JSONDecoder().decode(QuickFeatureHelperCommand.self, from: JSONEncoder().encode(command)), command)
        }
    }
}
