/// Retry state is separate from capture/UI machinery so failures can be tested without recording a screen.
struct LongScreenshotFailureState {
    private(set) var captureFailures = 0
    private(set) var overlapFailures = 0

    mutating func recordAppend(_ result: LongScreenshotAppendResult) -> Bool {
        captureFailures = 0
        switch result {
        case .appended, .duplicate:
            overlapFailures = 0
        case .noOverlap:
            overlapFailures += 1
        }
        return overlapFailures >= 2
    }

    mutating func recordCaptureFailure() -> Bool {
        captureFailures += 1
        return captureFailures >= 3
    }

    mutating func reset() { self = Self() }
}
