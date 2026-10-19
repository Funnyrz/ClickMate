import AppKit
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

    @MainActor
    func testInitialCaptureRejectsFrameFromChangedTarget() async throws {
        let clock = LongScreenshotTestClock()
        let target = LongScreenshotTestTarget()
        let image = try scrollingImage(offset: 0)
        let started = expectation(description: "initial capture waiting")
        let cancelled = expectation(description: "changed target cancels initial capture")
        var pendingCapture: CheckedContinuation<CGImage, Error>?
        var reportedError: LongScreenshotCaptureError?
        let controller = try makeController(clock: clock, capture: {
            try await withCheckedThrowingContinuation { continuation in
                pendingCapture = continuation
                started.fulfill()
            }
        }, targetActive: { target.isActive }, onCompleted: { _ in XCTFail("Wrong target exported") },
           onCancelled: { cancelled.fulfill() }, onError: { reportedError = $0 as? LongScreenshotCaptureError })
        controller.start()
        await fulfillment(of: [started], timeout: 2)
        target.isActive = false
        pendingCapture?.resume(returning: image)
        await fulfillment(of: [cancelled], timeout: 2)
        guard case .targetChanged? = reportedError else { return XCTFail("Expected target-change error") }
    }

    @MainActor
    func testPeriodicCapturePreservesIntermediateFramesWithoutScrollEvents() async throws {
        let clock = LongScreenshotTestClock()
        var frame = 0
        var output: CGImage?
        let controller = try makeController(clock: clock, capture: {
            defer { frame += 1 }
            return try self.scrollingImage(offset: frame * 20)
        }, onCompleted: { output = $0 })
        controller.start()
        await waitForTick(clock)
        for _ in 0..<6 {
            clock.advance()
            await waitForTick(clock)
        }
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(frame, 7)
        XCTAssertEqual(output?.height, 200)
    }

    @MainActor
    func testIdleFramesKeepCaptureOpenUntilExplicitFinish() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        var completions = 0
        let controller = try makeController(clock: clock, capture: { image }, onCompleted: { _ in
            completions += 1
        })
        controller.start()
        await waitForTick(clock)
        for _ in 0..<5 {
            clock.advance()
            await waitForTick(clock)
        }
        XCTAssertEqual(completions, 0)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testPauseAndResumeKeepOneSamplingLoop() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        var captures = 0
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            return image
        })
        controller.start()
        await waitForTick(clock)
        controller.togglePause()
        clock.advance()
        await waitForTick(clock)
        XCTAssertEqual(captures, 1)
        controller.togglePause()
        clock.advance()
        await waitForTick(clock)
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(clock.samplingSleeperCount, 1)
        await controller.finish(reachedLimit: false)
    }

    @MainActor
    func testFinishExportsCommittedContentWithoutWaitingForCapture() async throws {
        let clock = LongScreenshotTestClock()
        let firstImage = try scrollingImage(offset: 0)
        let laterImage = try scrollingImage(offset: 20)
        let captureStarted = expectation(description: "second capture started")
        var pendingCapture: CheckedContinuation<CGImage, Error>?
        var captures = 0
        var output: CGImage?
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            if captures == 1 { return firstImage }
            return try await withCheckedThrowingContinuation { continuation in
                pendingCapture = continuation
                captureStarted.fulfill()
            }
        }, onCompleted: { output = $0 })
        controller.start()
        await waitForTick(clock)
        clock.advance()
        await fulfillment(of: [captureStarted], timeout: 2)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(output?.height, 80)
        pendingCapture?.resume(returning: laterImage)
        XCTAssertEqual(output?.height, 80)
        XCTAssertEqual(captures, 2)
    }

    @MainActor
    func testTargetChangePausesWithDistinctErrorBeforeTakingAnotherFrame() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        let target = LongScreenshotTestTarget()
        var captures = 0
        var reportedError: LongScreenshotCaptureError?
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            return image
        }, targetActive: { target.isActive }, onError: { reportedError = $0 as? LongScreenshotCaptureError })
        controller.start()
        await waitForTick(clock)
        target.isActive = false
        clock.advance()
        await waitForTick(clock)
        XCTAssertEqual(captures, 1)
        guard case .targetChanged? = reportedError else {
            controller.cancel()
            return XCTFail("Expected a target-change error")
        }
        target.isActive = true
        controller.togglePause()
        clock.advance()
        await waitForTick(clock)
        XCTAssertEqual(captures, 2)
        await controller.finish(reachedLimit: false)
    }

    @MainActor
    func testPauseResumeInvalidatesFrameAlreadyBeingCaptured() async throws {
        let clock = LongScreenshotTestClock()
        let firstImage = try scrollingImage(offset: 0)
        let lateImage = try scrollingImage(offset: 20)
        let captureStarted = expectation(description: "capture awaiting image")
        var pendingCapture: CheckedContinuation<CGImage, Error>?
        var captures = 0
        var output: CGImage?
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            if captures == 1 { return firstImage }
            return try await withCheckedThrowingContinuation { continuation in
                pendingCapture = continuation
                captureStarted.fulfill()
            }
        }, onCompleted: { output = $0 })
        controller.start()
        await waitForTick(clock)
        clock.advance()
        await fulfillment(of: [captureStarted], timeout: 2)
        controller.togglePause()
        controller.togglePause()
        pendingCapture?.resume(returning: lateImage)
        await waitForTick(clock)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(output?.height, 80)
        XCTAssertEqual(captures, 2)
    }

    @MainActor
    func testCancelSuppressesPendingOutputAndLateCaptureError() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        let captureStarted = expectation(description: "capture awaiting image")
        var pendingCapture: CheckedContinuation<CGImage, Error>?
        var captures = 0
        var completions = 0
        var cancellations = 0
        var errors = 0
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            if captures == 1 { return image }
            return try await withCheckedThrowingContinuation { continuation in
                pendingCapture = continuation
                captureStarted.fulfill()
            }
        }, onCompleted: { _ in completions += 1 }, onCancelled: { cancellations += 1 },
           onError: { _ in errors += 1 })
        controller.start()
        await waitForTick(clock)
        clock.advance()
        await fulfillment(of: [captureStarted], timeout: 2)
        controller.cancel()
        pendingCapture?.resume(throwing: LongScreenshotCaptureError.captureFailed)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(errors, 0)
    }

    @MainActor
    func testConsecutiveCaptureErrorsPauseAfterThirdAttempt() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        var captures = 0
        var errors = 0
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            if captures == 1 { return image }
            throw LongScreenshotCaptureError.captureFailed
        }, onError: { _ in errors += 1 })
        controller.start()
        await waitForTick(clock)
        for attempt in 1...3 {
            clock.advance()
            await waitForTick(clock)
            XCTAssertEqual(errors, attempt == 3 ? 1 : 0)
        }
        clock.advance()
        await waitForTick(clock)
        XCTAssertEqual(captures, 4)
        await controller.finish(reachedLimit: false)
    }

    @MainActor
    func testPauseInvalidatesFrameWaitingForAssemblerAdmission() async throws {
        let clock = LongScreenshotTestClock()
        let gate = LongScreenshotTestAppendGate()
        var captures = 0
        var output: CGImage?
        let controller = try makeController(clock: clock, capture: {
            defer { captures += 1 }
            return try self.scrollingImage(offset: captures * 20)
        }, onCompleted: { output = $0 }, beforeAppend: { await gate.wait() })
        controller.start()
        await waitForTick(clock)
        clock.advance()
        await fulfillment(of: [gate.entered], timeout: 2)
        controller.togglePause()
        controller.togglePause()
        gate.release()
        await waitForTick(clock)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(output?.height, 80)
    }

    @MainActor
    func testFinishExportsWithoutWaitingForInvalidatedQueuedSample() async throws {
        let clock = LongScreenshotTestClock()
        let gate = LongScreenshotTestAppendGate()
        var captures = 0
        var output: CGImage?
        let controller = try makeController(clock: clock, capture: {
            defer { captures += 1 }
            return try self.scrollingImage(offset: captures * 20)
        }, onCompleted: { output = $0 }, beforeAppend: { await gate.wait() })
        controller.start()
        await waitForTick(clock)
        clock.advance()
        await fulfillment(of: [gate.entered], timeout: 2)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(output?.height, 80)
        gate.release()
    }

    @MainActor
    func testTimeoutExportsCommittedContentWhileCaptureIsUnresponsive() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        let started = expectation(description: "second capture waiting")
        let completed = expectation(description: "timeout exports without waiting")
        var pendingCapture: CheckedContinuation<CGImage, Error>?
        var captures = 0
        var output: CGImage?
        let controller = try makeController(clock: clock, capture: {
            captures += 1
            if captures == 1 { return image }
            return try await withCheckedThrowingContinuation { continuation in
                pendingCapture = continuation
                started.fulfill()
            }
        }, onCompleted: {
            output = $0
            completed.fulfill()
        })
        controller.start()
        await waitForTick(clock)
        clock.advance()
        await fulfillment(of: [started], timeout: 2)
        clock.advance(.seconds(60))
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(output?.height, 80)
        pendingCapture?.resume(returning: image)
    }

    @MainActor
    func testEarlyFinishKeepsInitialFrameTimeoutActive() async throws {
        let clock = LongScreenshotTestClock()
        let image = try scrollingImage(offset: 0)
        let failed = expectation(description: "initial frame timed out")
        var completions = 0
        var cancellations = 0
        let controller = try makeController(clock: clock, capture: {
            try await clock.sleep(.seconds(999))
            return image
        }, onCompleted: { _ in completions += 1 }, onCancelled: { cancellations += 1 },
           onError: { _ in failed.fulfill() })
        controller.start()
        await fulfillment(of: [clock.nextTimeoutSleep()], timeout: 2)
        await controller.finish(reachedLimit: false)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(cancellations, 0)
        clock.advance(.seconds(60))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    private func makeController(
        clock: LongScreenshotTestClock,
        capture: @escaping @MainActor () async throws -> CGImage,
        targetActive: @escaping @MainActor () -> Bool = { true },
        onCompleted: @escaping (CGImage) -> Void = { _ in },
        onCancelled: @escaping () -> Void = {},
        onError: @escaping (Error) -> Void = { _ in },
        beforeAppend: (@Sendable () async -> Void)? = nil
    ) throws -> LongScreenshotCaptureController {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        return LongScreenshotCaptureController(
            screen: screen,
            selection: CGRect(x: 0, y: 0, width: 96, height: 80),
            targetProcessIdentifier: nil,
            capture: capture,
            onCompleted: { image, _ in onCompleted(image) },
            onCancelled: onCancelled,
            onError: onError,
            showsOverlay: false,
            sleep: { try await clock.sleep($0) },
            targetApplicationIsActive: targetActive,
            screenConfigurationIsValid: { true },
            beforeAppend: beforeAppend
        )
    }

    @MainActor
    private func waitForTick(_ clock: LongScreenshotTestClock) async {
        await fulfillment(of: [clock.nextSamplingSleep()], timeout: 2)
    }

    private func scrollingImage(offset: Int) throws -> CGImage {
        let width = 96
        let height = 80
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let mixed = UInt32(truncatingIfNeeded:
                    ((y + offset) &* 1_103_515_245) ^ (x &* 12_345) ^ 0x5A5A_5A5A
                )
                let index = (y * width + x) * 4
                pixels[index] = UInt8(truncatingIfNeeded: mixed >> 16)
                pixels[index + 1] = UInt8(truncatingIfNeeded: mixed >> 8)
                pixels[index + 2] = UInt8(truncatingIfNeeded: mixed)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }
}

@MainActor
private final class LongScreenshotTestTarget {
    var isActive = true
}

@MainActor
private final class LongScreenshotTestClock {
    private var sleepers: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var samplingExpectation: XCTestExpectation?
    private var timeoutExpectation: XCTestExpectation?

    var samplingSleeperCount: Int { sleepers.values.filter { $0.0 == .milliseconds(150) }.count }

    func nextSamplingSleep() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "sampling loop is waiting")
        if samplingSleeperCount > 0 {
            expectation.fulfill()
        } else {
            samplingExpectation = expectation
        }
        return expectation
    }

    func nextTimeoutSleep() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "timeout is waiting")
        if sleepers.values.contains(where: { $0.0 == .seconds(60) }) {
            expectation.fulfill()
        } else {
            timeoutExpectation = expectation
        }
        return expectation
    }

    func sleep(_ duration: Duration) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[identifier] = (duration, continuation)
                if duration == .milliseconds(150) {
                    samplingExpectation?.fulfill()
                    samplingExpectation = nil
                } else if duration == .seconds(60) {
                    timeoutExpectation?.fulfill()
                    timeoutExpectation = nil
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.sleepers.removeValue(forKey: identifier)?.1.resume(throwing: CancellationError())
            }
        }
    }

    func advance(_ duration: Duration = .milliseconds(150)) {
        guard let identifier = sleepers.first(where: { $0.value.0 == duration })?.key else {
            return XCTFail("No sampling tick to advance")
        }
        sleepers.removeValue(forKey: identifier)?.1.resume()
    }
}

@MainActor
private final class LongScreenshotTestAppendGate {
    let entered = XCTestExpectation(description: "assembler awaiting admission")
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
