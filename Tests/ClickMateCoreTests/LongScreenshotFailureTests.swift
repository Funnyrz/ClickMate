import XCTest

final class LongScreenshotFailureTests: XCTestCase {
    func testTwoConsecutiveMissingOverlapsPauseCapture() {
        var state = LongScreenshotFailureState()
        XCTAssertFalse(state.recordAppend(.noOverlap))
        XCTAssertTrue(state.recordAppend(.noOverlap))
        XCTAssertEqual(state.overlapFailures, 2)
    }

    func testSuccessfulMatchingResetsOverlapFailures() {
        var state = LongScreenshotFailureState()
        XCTAssertFalse(state.recordAppend(.noOverlap))
        XCTAssertFalse(state.recordAppend(.duplicate))
        XCTAssertFalse(state.recordAppend(.noOverlap))
        XCTAssertEqual(state.overlapFailures, 1)
    }

    func testCaptureFailuresAreIndependentAndSuccessfulCaptureResetsThem() {
        var state = LongScreenshotFailureState()
        XCTAssertFalse(state.recordCaptureFailure())
        XCTAssertFalse(state.recordCaptureFailure())
        XCTAssertTrue(state.recordCaptureFailure())
        XCTAssertFalse(state.recordAppend(.noOverlap))
        XCTAssertEqual(state.captureFailures, 0)
        XCTAssertFalse(state.recordCaptureFailure())
        XCTAssertTrue(state.recordAppend(.noOverlap))
    }

    func testResumeOrCancelResetAllPendingFailures() {
        var state = LongScreenshotFailureState()
        _ = state.recordAppend(.noOverlap)
        _ = state.recordCaptureFailure()
        state.reset()
        XCTAssertEqual(state.captureFailures, 0)
        XCTAssertEqual(state.overlapFailures, 0)
        XCTAssertFalse(state.recordAppend(.noOverlap))
    }
}
