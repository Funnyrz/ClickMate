import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LongScreenshotState: Equatable, Sendable {
    case idle
    case capturing
    case waitingForStability
    case paused
    case assembling
    case previewing
    case failed
}

struct LongScreenshotFrame: @unchecked Sendable {
    let image: CGImage
    let capturedAt: Date
    let sequence: Int

    init(image: CGImage, capturedAt: Date = Date(), sequence: Int = 0) {
        self.image = image
        self.capturedAt = capturedAt
        self.sequence = sequence
    }

    var pixelWidth: Int { image.width }
    var pixelHeight: Int { image.height }
}

struct LongScreenshotMatch: Equatable, Sendable {
    let verticalOffset: Int
    let overlapHeight: Int
    let confidence: Double
    let normalizedDifference: Double
}

struct LongScreenshotLimits: Equatable, Sendable {
    var maxPixelHeight: Int
    var maxRawBytes: Int

    static let `default` = LongScreenshotLimits(
        maxPixelHeight: 40_000,
        maxRawBytes: 384 * 1_024 * 1_024
    )
}

enum LongScreenshotAppendResult: Equatable, Sendable {
    case appended(LongScreenshotMatch)
    case duplicate
    case noOverlap
}

final class LongScreenshotStitcher: @unchecked Sendable {
    enum StitchingError: Error, Equatable {
        case invalidLimits
        case incompatibleFrameSize(
            expectedWidth: Int,
            expectedHeight: Int,
            actualWidth: Int,
            actualHeight: Int
        )
        case pixelHeightLimitExceeded(limit: Int, attempted: Int)
        case rawMemoryLimitExceeded(limit: Int, attempted: Int)
        case imageConversionFailed
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        let grayscale: [UInt8]

        func lowerStrip(startingAt row: Int) -> PixelBuffer {
            let clampedRow = min(max(row, 0), height)
            let rgbaStart = clampedRow * width * 4
            let grayscaleStart = clampedRow * width
            return PixelBuffer(
                width: width,
                height: height - clampedRow,
                rgba: Array(rgba[rgbaStart...]),
                grayscale: Array(grayscale[grayscaleStart...])
            )
        }
    }

    private static let minimumOverlapRatio = 0.18
    private static let duplicateDifferenceThreshold = 0.004
    private static let acceptedDifferenceThreshold = 0.075
    private static let minimumConfidenceMargin = 0.006

    let limits: LongScreenshotLimits
    private let lock = NSLock()
    private let temporaryDirectory: URL
    private var stripURLs: [URL]
    private var lastFrame: PixelBuffer
    private var storedFrameCount = 1
    private var storedPixelHeight: Int

    init(firstFrame: CGImage, limits: LongScreenshotLimits = .default) throws {
        guard limits.maxPixelHeight > 0, limits.maxRawBytes > 0 else {
            throw StitchingError.invalidLimits
        }

        let pixels = try Self.makePixelBuffer(from: firstFrame)
        try Self.validateLimits(width: pixels.width, height: pixels.height, limits: limits)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickMate-LongScreenshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let firstStripURL = temporaryDirectory.appendingPathComponent("strip-000001.png")
        do {
            try Self.writePNG(pixels, to: firstStripURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
        self.limits = limits
        self.temporaryDirectory = temporaryDirectory
        stripURLs = [firstStripURL]
        lastFrame = pixels
        storedPixelHeight = pixels.height
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    var frameCount: Int {
        withLock { storedFrameCount }
    }

    var pixelHeight: Int {
        withLock { storedPixelHeight }
    }

    var estimatedRawBytes: Int {
        withLock { lastFrame.width * storedPixelHeight * 4 }
    }

    @discardableResult
    func append(_ image: CGImage) throws -> LongScreenshotAppendResult {
        let next = try Self.makePixelBuffer(from: image)
        return try withLock {
            try Self.validateCompatible(lastFrame, next)
            guard let match = Self.match(previous: lastFrame, next: next) else {
                return .noOverlap
            }
            guard match.verticalOffset > 0 else {
                return .duplicate
            }

            let attemptedHeight = storedPixelHeight + match.verticalOffset
            try Self.validateLimits(width: next.width, height: attemptedHeight, limits: limits)
            let strip = next.lowerStrip(startingAt: match.overlapHeight)
            let stripURL = temporaryDirectory.appendingPathComponent(
                String(format: "strip-%06d.png", stripURLs.count + 1)
            )
            try Self.writePNG(strip, to: stripURL)
            stripURLs.append(stripURL)
            lastFrame = next
            storedPixelHeight = attemptedHeight
            storedFrameCount += 1
            return .appended(match)
        }
    }

    func makeImage() throws -> CGImage {
        try withLock {
            let width = lastFrame.width
            let rowBytes = width * 4
            var combined = [UInt8](repeating: 0, count: rowBytes * storedPixelHeight)
            var destinationOffset = 0
            for stripURL in stripURLs {
                let strip = try Self.readPixelBuffer(from: stripURL)
                combined.replaceSubrange(
                    destinationOffset..<(destinationOffset + strip.rgba.count),
                    with: strip.rgba
                )
                destinationOffset += strip.rgba.count
            }
            return try Self.makeImage(width: width, height: storedPixelHeight, rgba: combined)
        }
    }

    private static func match(previous: PixelBuffer, next: PixelBuffer) -> LongScreenshotMatch? {
        let duplicateDifference = fullFrameDifference(previous: previous, next: next)
        if duplicateDifference <= duplicateDifferenceThreshold {
            return LongScreenshotMatch(
                verticalOffset: 0,
                overlapHeight: previous.height,
                confidence: 1 - min(duplicateDifference, 1),
                normalizedDifference: duplicateDifference
            )
        }

        let minimumOverlap = max(8, Int(ceil(Double(previous.height) * minimumOverlapRatio)))
        let maximumShift = previous.height - minimumOverlap
        guard maximumShift >= 1 else { return nil }

        var candidates: [(shift: Int, difference: Double)] = []
        candidates.reserveCapacity(maximumShift)
        for shift in 1...maximumShift {
            candidates.append((
                shift,
                normalizedDifference(previous: previous, next: next, shift: shift)
            ))
        }
        candidates.sort {
            if $0.difference == $1.difference {
                return $0.shift < $1.shift
            }
            return $0.difference < $1.difference
        }

        guard let best = candidates.first else { return nil }
        let neighborRadius = max(2, previous.height / 200)
        let secondBestDifference = candidates.first {
            abs($0.shift - best.shift) > neighborRadius
        }?.difference ?? 1
        let confidenceMargin = secondBestDifference - best.difference
        let isStrongMatch = best.difference <= acceptedDifferenceThreshold
            && (best.difference <= duplicateDifferenceThreshold * 2
                || confidenceMargin >= minimumConfidenceMargin)
        guard isStrongMatch else { return nil }

        return LongScreenshotMatch(
            verticalOffset: best.shift,
            overlapHeight: previous.height - best.shift,
            confidence: max(0, min(1, 1 - best.difference / acceptedDifferenceThreshold)),
            normalizedDifference: best.difference
        )
    }

    private static func normalizedDifference(
        previous: PixelBuffer,
        next: PixelBuffer,
        shift: Int
    ) -> Double {
        let overlapHeight = previous.height - shift
        guard overlapHeight > 0 else { return 1 }

        let horizontalInset = min(previous.width / 5, max(0, previous.width / 16))
        let sampleWidth = max(1, previous.width - horizontalInset * 2)
        let horizontalStep = max(1, sampleWidth / 72)
        let verticalInset = min(10, max(0, overlapHeight / 40))
        let usableHeight = max(1, overlapHeight - verticalInset * 2)
        let verticalStep = max(1, usableHeight / 128)

        var rowDifferences: [Double] = []
        rowDifferences.reserveCapacity(max(usableHeight / verticalStep, 1))
        var y = verticalInset
        while y < overlapHeight - verticalInset {
            let previousRow = (shift + y) * previous.width
            let nextRow = y * next.width
            var rowDifference: UInt64 = 0
            var rowSampleCount: UInt64 = 0
            var x = horizontalInset
            while x < previous.width - horizontalInset {
                rowDifference += UInt64(abs(
                    Int(previous.grayscale[previousRow + x]) - Int(next.grayscale[nextRow + x])
                ))
                rowSampleCount += 1
                x += horizontalStep
            }
            if rowSampleCount > 0 {
                rowDifferences.append(
                    Double(rowDifference) / Double(rowSampleCount * 255)
                )
            }
            y += verticalStep
        }

        guard !rowDifferences.isEmpty else { return 1 }
        rowDifferences.sort()
        let retainedCount = max(1, Int(ceil(Double(rowDifferences.count) * 0.60)))
        let retained = rowDifferences.prefix(retainedCount)
        let trimmedMean = retained.reduce(0, +) / Double(retainedCount)
        let median = rowDifferences[(rowDifferences.count - 1) / 2]
        return median * 0.65 + trimmedMean * 0.35
    }

    private static func fullFrameDifference(previous: PixelBuffer, next: PixelBuffer) -> Double {
        let horizontalStep = max(1, previous.width / 72)
        let verticalStep = max(1, previous.height / 128)
        var totalDifference: UInt64 = 0
        var sampleCount: UInt64 = 0
        var y = 0
        while y < previous.height {
            let previousRow = y * previous.width
            let nextRow = y * next.width
            var x = 0
            while x < previous.width {
                totalDifference += UInt64(abs(
                    Int(previous.grayscale[previousRow + x]) - Int(next.grayscale[nextRow + x])
                ))
                sampleCount += 1
                x += horizontalStep
            }
            y += verticalStep
        }
        guard sampleCount > 0 else { return 1 }
        return Double(totalDifference) / Double(sampleCount * 255)
    }

    private static func validateCompatible(_ previous: PixelBuffer, _ next: PixelBuffer) throws {
        guard previous.width == next.width, previous.height == next.height else {
            throw StitchingError.incompatibleFrameSize(
                expectedWidth: previous.width,
                expectedHeight: previous.height,
                actualWidth: next.width,
                actualHeight: next.height
            )
        }
    }

    private static func validateLimits(
        width: Int,
        height: Int,
        limits: LongScreenshotLimits
    ) throws {
        guard height <= limits.maxPixelHeight else {
            throw StitchingError.pixelHeightLimitExceeded(
                limit: limits.maxPixelHeight,
                attempted: height
            )
        }
        let rawBytes = rawByteCount(width: width, height: height)
        guard let rawBytes, rawBytes <= limits.maxRawBytes else {
            throw StitchingError.rawMemoryLimitExceeded(
                limit: limits.maxRawBytes,
                attempted: rawBytes ?? Int.max
            )
        }
    }

    private static func rawByteCount(width: Int, height: Int) -> Int? {
        let (pixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelsOverflow || bytesOverflow ? nil : bytes
    }

    private static func makePixelBuffer(from image: CGImage) throws -> PixelBuffer {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let created = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else {
            throw StitchingError.imageConversionFailed
        }

        var grayscale = [UInt8](repeating: 0, count: width * height)
        for pixelIndex in grayscale.indices {
            let rgbaIndex = pixelIndex * 4
            let red = UInt32(rgba[rgbaIndex])
            let green = UInt32(rgba[rgbaIndex + 1])
            let blue = UInt32(rgba[rgbaIndex + 2])
            grayscale[pixelIndex] = UInt8((red * 77 + green * 150 + blue * 29) >> 8)
        }
        return PixelBuffer(width: width, height: height, rgba: rgba, grayscale: grayscale)
    }

    private static func makeImage(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw StitchingError.imageConversionFailed
        }
        return image
    }

    private static func writePNG(_ pixels: PixelBuffer, to url: URL) throws {
        let image = try makeImage(width: pixels.width, height: pixels.height, rgba: pixels.rgba)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StitchingError.imageConversionFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StitchingError.imageConversionFailed
        }
    }

    private static func readPixelBuffer(from url: URL) throws -> PixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw StitchingError.imageConversionFailed
        }
        return try makePixelBuffer(from: image)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
