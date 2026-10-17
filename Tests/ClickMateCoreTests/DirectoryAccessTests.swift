import Foundation
import XCTest

@MainActor
final class DirectoryAccessTests: XCTestCase {
    func testFinderFallbackTargetsItsOwnContainingAppInsteadOfAnotherRegisteredCopy() {
        let current = URL(fileURLWithPath: "/Applications/Current ClickMate.app", isDirectory: true)
        let old = URL(fileURLWithPath: "/Backups/Old ClickMate.app", isDirectory: true)
        let extensionURL = current.appendingPathComponent("Contents/PlugIns/ClickMateFinderExtension.appex", isDirectory: true)
        let helperURL = current.appendingPathComponent("Contents/Library/LoginItems/ClickMateHelper.app", isDirectory: true)
        let identity: (URL) -> String? = { url in
            if url == current || url == old { return AppConstants.bundleIdentifier }
            return QuickFeatureHelperService.helperBundleIdentifier
        }
        for source in [current, extensionURL, helperURL] {
            XCTAssertEqual(AppLauncher.containingApplicationURL(for: source, bundleIdentifier: identity), current)
        }
        XCTAssertNil(AppLauncher.containingApplicationURL(
            for: URL(fileURLWithPath: "/Unrelated/Unknown.appex"), bundleIdentifier: identity
        ))
    }

    func testObservationStartsUnknownAndDoesNotProbeFiles() {
        let monitor = DirectoryAccessMonitor()
        XCTAssertNil(monitor.latest)
        let directory = URL(fileURLWithPath: "/does-not-exist/Chosen Folder", isDirectory: true)
        monitor.record(directoryURL: directory)
        XCTAssertEqual(monitor.latest?.directoryURL, directory)
        XCTAssertEqual(monitor.latest?.result, .success)
        XCTAssertEqual(monitor.latest?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertNil(monitor.latest?.errorCode)
    }

    func testPermissionFailureKeepsUnderlyingDomainCodeAndTarget() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSFilePathErrorKey: "/selected/file"])
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: underlying])
        let failure = FileAccessFailure(error)
        XCTAssertTrue(failure.isPermissionDenied)
        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.code, Int(EACCES))
        XCTAssertEqual(failure.fileURL?.path, "/selected/file")
        let monitor = DirectoryAccessMonitor()
        monitor.record(directoryURL: URL(fileURLWithPath: "/selected", isDirectory: true), error: error)
        XCTAssertEqual(monitor.latest?.result, .permissionDenied)
        XCTAssertEqual(monitor.latest?.errorCode, Int(EACCES))
    }

    func testMissingFileAndCancellationAreNotPermissionDenial() {
        let monitor = DirectoryAccessMonitor()
        let directory = URL(fileURLWithPath: "/selected", isDirectory: true)
        monitor.record(directoryURL: directory, error: CocoaError(.fileNoSuchFile))
        XCTAssertEqual(monitor.latest?.result, .failed)
        let before = monitor.latest
        monitor.record(directoryURL: directory, error: CancellationError())
        XCTAssertEqual(monitor.latest, before)
        monitor.record(directoryURL: directory, error: CocoaError(.userCancelled))
        XCTAssertEqual(monitor.latest, before)
    }

    func testCrossVolumeSourceRemovalDenialPreservesOriginalErrorAndBothCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        try Data("preserve both copies".utf8).write(to: source)
        var renames = 0
        XCTAssertThrowsError(try FileActions.moveItemExclusively(from: source, to: destination, rename: { old, new in
            renames += 1
            if renames == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
            try FileManager.default.moveItem(at: old, to: new)
        }, removeSource: { url in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: [NSFilePathErrorKey: url.path])
        })) { error in
            let failure = FileAccessFailure(error)
            XCTAssertTrue(failure.isPermissionDenied)
            XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(failure.code, Int(EPERM))
            XCTAssertEqual(failure.fileURL, source)
        }
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination))
    }

    func testRecoveryCanRetryOnlyAfterTerminalStateWithFreshIdentity() throws {
        let request = FullDiskAccessRecoveryRequest(previousApplicationPID: 1, previousFinderExtensionPID: 2)
        XCTAssertNil(request.retry())
        var failed = request
        failed.markFailed()
        var retry = try XCTUnwrap(failed.retry(previousApplicationPID: 3, previousFinderExtensionPID: 4))
        XCTAssertNotEqual(retry.id, request.id)
        XCTAssertEqual(retry.previousApplicationPID, 3)
        XCTAssertEqual(retry.previousFinderExtensionPID, 4)
        XCTAssertTrue(retry.markRelaunchScheduled())
        XCTAssertNil(retry.retry())
        retry.markCompleted()
        XCTAssertNotNil(retry.retry())
    }
}
